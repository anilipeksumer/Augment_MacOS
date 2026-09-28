import AudioToolbox
import Combine
import CoreAudio
import Foundation
import AppKit

/// A regular (Dock) app plus every Core Audio process object that belongs to
/// it. Browsers and Electron apps don't play audio from their main process —
/// Chrome uses `com.google.Chrome.helper`, Safari uses `com.apple.WebKit.GPU` —
/// so an app's volume has to be applied to all of those together.
struct MixerAppInfo: Identifiable, Equatable {
    let id: pid_t
    let processObjectIDs: [AudioObjectID]
    let name: String
    let bundleID: String?
    let icon: NSImage?
    var isPlaying: Bool
    var volume: Double
    var isMuted: Bool
    /// Output device UID this app is routed to; nil = system default.
    var outputDeviceUID: String?

    static func == (lhs: MixerAppInfo, rhs: MixerAppInfo) -> Bool {
        lhs.id == rhs.id && lhs.processObjectIDs == rhs.processObjectIDs
            && lhs.isPlaying == rhs.isPlaying && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
            && lhs.outputDeviceUID == rhs.outputDeviceUID
    }
}

struct AudioOutputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Per-app volume control — the "Volume Mixer" macOS has never shipped.
///
/// There is no public API to directly set another process's output gain.
/// What macOS 14.2+ *does* expose publicly (`CATapDescription` /
/// `AudioHardwareCreateProcessTap`, added for screen-recording-style audio
/// capture) is a way to mute a process at the HAL and simultaneously receive
/// its audio ourselves via an aggregate device's IOProc — so instead of
/// letting the app's audio play directly, we intercept it, scale every
/// sample by the user's chosen gain, and re-render it to the real output
/// device ourselves. That's the same technique open-source mixers for macOS
/// (e.g. mac-volume-mixer, MacVolumeMixer) use; no private symbols involved.
///
/// **This could not be verified against real playing audio in the
/// environment this was built in** (no audio hardware/output to listen to).
/// Every mismatch path is written to fail toward silence rather than noise,
/// but a live test with real apps playing sound is still needed.
@available(macOS 14.2, *)
@MainActor
final class AudioProcessMixerService: ObservableObject {
    static let shared = AudioProcessMixerService()

    @Published private(set) var apps: [MixerAppInfo] = []
    @Published private(set) var outputDevices: [AudioOutputDevice] = []

    /// Per-app output routing, remembered by bundle ID.
    private var routes: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "augment.mixerRoutes") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "augment.mixerRoutes") }
    }
    @Published private(set) var isSupported = true

    private final class Channel {
        var tapID: AudioObjectID = .unknown
        var aggregateID: AudioObjectID = .unknown
        var ioProcID: AudioDeviceIOProcID?
        var processObjectIDs: [AudioObjectID] = []
        var gain: Float = 1.0
        var muted = false
        // Diagnostics (written on the I/O thread, read by tests).
        var ioCount = 0
        var inputPeak: Float = 0
        var layout = ""
    }

    /// Last error from creating a tap, surfaced in the UI so a missing
    /// "System Audio Recording" permission isn't a silent no-op.
    @Published private(set) var lastError: String?

    private var channels: [pid_t: Channel] = [:]
    private var refreshTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard refreshTimer == nil else { return }
        refreshApps()
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshApps() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    /// The default output changed: channels that follow it are rebuilt on
    /// the new device (routed apps keep their chosen device).
    func defaultOutputChanged() {
        for (pid, channel) in channels {
            guard let info = apps.first(where: { $0.id == pid }), info.outputDeviceUID == nil else { continue }
            let gain = channel.gain, muted = channel.muted
            teardownChannel(for: pid)
            setupChannel(for: info.processObjectIDs, pid: pid, gain: gain, muted: muted)
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        for pid in Array(channels.keys) { teardownChannel(for: pid) }
        apps = []
    }

    // MARK: - Process enumeration

    private func refreshApps() {
        guard let processObjects = Self.audioObjectIDArray(
            address: Self.address(.hardwareServiceProcessObjectList),
            objectID: AudioObjectID(kAudioObjectSystemObject)
        ) else {
            apps = []
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let regularApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != ownPID
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier // another Augment copy
        }
        let appsByPID = Dictionary(regularApps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })

        var objectsByApp: [pid_t: [AudioObjectID]] = [:]
        var playingApps = Set<pid_t>()
        for objectID in processObjects {
            guard let pid = Self.processPID(objectID) else { continue }
            let bundleID = Self.processBundleID(objectID)
            guard let owner = appsByPID[pid] ?? Self.owningApp(forHelperBundleID: bundleID, among: regularApps)
            else { continue }
            objectsByApp[owner.processIdentifier, default: []].append(objectID)
            if Self.processIsRunningOutput(objectID) { playingApps.insert(owner.processIdentifier) }
        }

        var next: [MixerAppInfo] = []
        for (pid, objectIDs) in objectsByApp {
            guard let app = appsByPID[pid] else { continue }
            let existing = channels[pid]
            next.append(MixerAppInfo(
                id: pid,
                processObjectIDs: objectIDs.sorted(),
                name: app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)",
                bundleID: app.bundleIdentifier,
                icon: app.icon,
                isPlaying: playingApps.contains(pid),
                volume: Double(existing?.gain ?? 1.0),
                isMuted: existing?.muted ?? false,
                outputDeviceUID: app.bundleIdentifier.flatMap { routes[$0] }
            ))
        }
        next.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if next != apps { apps = next }
        let devices = Self.listOutputDevices()
        if devices != outputDevices { outputDevices = devices }

        // Apps routed to another device need their tap even at 100%.
        for info in next where info.outputDeviceUID != nil && channels[info.id] == nil {
            setupChannel(for: info.processObjectIDs, pid: info.id, gain: Float(info.volume), muted: info.isMuted)
        }

        // Rebuild taps whose helper set changed (e.g. a new Chrome tab
        // spawned an audio helper) and drop taps for apps that quit.
        for (pid, channel) in channels {
            guard let info = next.first(where: { $0.id == pid }) else {
                teardownChannel(for: pid)
                continue
            }
            if info.processObjectIDs != channel.processObjectIDs {
                let gain = channel.gain, muted = channel.muted
                teardownChannel(for: pid)
                setupChannel(for: info.processObjectIDs, pid: pid, gain: gain, muted: muted)
            }
        }
    }

    /// Maps a helper process to the Dock app it belongs to — `com.google.Chrome.helper`
    /// → Chrome, `com.tinyspeck.slackmacgap.helper` → Slack. WebKit's shared GPU/
    /// WebContent processes carry no owner in their bundle ID; they're attributed
    /// to Safari when it's running, which covers the common case.
    private static func owningApp(forHelperBundleID bundleID: String?, among apps: [NSRunningApplication]) -> NSRunningApplication? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if bundleID.hasPrefix("com.apple.WebKit.") {
            return apps.first { $0.bundleIdentifier == "com.apple.Safari" }
        }
        return apps
            .filter { app in
                guard let appID = app.bundleIdentifier else { return false }
                return bundleID.hasPrefix(appID + ".")
            }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }

    // MARK: - Volume control

    func setVolume(_ volume: Double, forPID pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        apps[index].volume = volume
        let clamped = Float(max(0, min(2, volume)))
        if let channel = channels[pid] {
            channel.gain = clamped
        } else if clamped != 1.0 || apps[index].isMuted {
            setupChannel(for: apps[index].processObjectIDs, pid: pid, gain: clamped, muted: apps[index].isMuted)
        }
    }

    /// Sends one app's sound to a specific output (nil = system default).
    func setOutputDevice(_ uid: String?, forPID pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        if let bundleID = apps[index].bundleID {
            var r = routes
            r[bundleID] = uid
            routes = r
        }
        apps[index].outputDeviceUID = uid
        let info = apps[index]
        let gain = channels[pid]?.gain ?? Float(info.volume)
        let muted = channels[pid]?.muted ?? info.isMuted
        teardownChannel(for: pid)
        if uid != nil || gain != 1 || muted {
            setupChannel(for: info.processObjectIDs, pid: pid, gain: gain, muted: muted)
        }
    }

    func setMuted(_ muted: Bool, forPID pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        apps[index].isMuted = muted
        if let channel = channels[pid] {
            channel.muted = muted
        } else {
            setupChannel(for: apps[index].processObjectIDs, pid: pid, gain: Float(apps[index].volume), muted: muted)
        }
    }

    // MARK: - Tap + aggregate device plumbing

    private func setupChannel(for processObjectIDs: [AudioObjectID], pid: pid_t, gain: Float, muted: Bool) {
        guard channels[pid] == nil, !processObjectIDs.isEmpty else { return }
        // The app's chosen device if it's still connected, else the default.
        let chosen = apps.first(where: { $0.id == pid })?.outputDeviceUID
        let available = Set(Self.listOutputDevices().map(\.uid))
        guard let outputDeviceUID = chosen.flatMap({ available.contains($0) ? $0 : nil }) ?? Self.defaultOutputDeviceUID() else {
            lastError = "No default output device."
            return
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true

        var tapID: AudioObjectID = .unknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr else {
            lastError = "Could not tap the app's audio (error \(tapStatus)). Allow Augment under System Settings → Privacy & Security → Screen & System Audio Recording."
            NSLog("Augment: AudioProcessMixerService – AudioHardwareCreateProcessTap failed: %d", tapStatus)
            return
        }
        lastError = nil

        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Augment Mixer \(pid)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: true]
            ],
        ]

        var aggregateID: AudioObjectID = .unknown
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID) == noErr else {
            NSLog("Augment: AudioProcessMixerService – failed to create aggregate device for pid %d", pid)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        let channel = Channel()
        channel.tapID = tapID
        channel.aggregateID = aggregateID
        channel.processObjectIDs = processObjectIDs
        channel.gain = gain
        channel.muted = muted

        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, aggregateID, nil, Self.makeIOBlock(for: channel)
        )
        guard status == noErr, let ioProcID else {
            NSLog("Augment: AudioProcessMixerService – failed to install IOProc for pid %d", pid)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }
        channel.ioProcID = ioProcID
        AudioDeviceStart(aggregateID, ioProcID)
        channels[pid] = channel
    }

    /// Test hook: tap an arbitrary process (e.g. `say`) and report what the
    /// I/O callback sees.
    func debugTap(pid: pid_t, gain: Float) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &object) == noErr,
              object != kAudioObjectUnknown else { return false }
        setupChannel(for: [object], pid: pid, gain: gain, muted: false)
        return channels[pid] != nil
    }

    func debugStats(pid: pid_t) -> String {
        guard let c = channels[pid] else { return "no channel (\(lastError ?? "no error"))" }
        return "io=\(c.ioCount) peak=\(c.inputPeak) \(c.layout)"
    }

    func debugTeardown(pid: pid_t) { teardownChannel(for: pid) }

    private func teardownChannel(for pid: pid_t) {
        guard let channel = channels.removeValue(forKey: pid) else { return }
        if let ioProcID = channel.ioProcID {
            AudioDeviceStop(channel.aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(channel.aggregateID, ioProcID)
        }
        AudioHardwareDestroyAggregateDevice(channel.aggregateID)
        AudioHardwareDestroyProcessTap(channel.tapID)
    }

    /// Built outside the `@MainActor` context on purpose: Core Audio calls this
    /// block on its realtime I/O thread, and a closure that inherited main-actor
    /// isolation would trap there.
    nonisolated private static func makeIOBlock(for channel: Channel) -> AudioDeviceIOBlock {
        { [weak channel] _, inInputData, _, outOutputData, _ in
            guard let channel else { return }
            channel.ioCount += 1
            if channel.ioCount % 20 == 1 {
                let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                let outs = UnsafeMutableAudioBufferListPointer(outOutputData)
                var peak: Float = 0
                for b in ins { if let d = b.mData { let n = Int(b.mDataByteSize) / 4; let f = d.bindMemory(to: Float.self, capacity: n); for i in 0..<n { peak = max(peak, abs(f[i])) } } }
                channel.inputPeak = max(channel.inputPeak, peak)
                channel.layout = "in=\(ins.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }) out=\(outs.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" })"
            }
            renderScaled(input: inInputData, output: outOutputData, gain: channel.muted ? 0 : channel.gain)
        }
    }

    /// Copies `input` into `output`, scaling every sample by `gain`.
    /// Falls back to silence (memset 0) on any buffer/channel mismatch
    /// instead of risking garbage/loud audio.
    nonisolated private static func renderScaled(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float
    ) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        guard let sourceBuffer = inputList.last, let sourceData = sourceBuffer.mData else {
            for buffer in outputList {
                guard let outData = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                outData.bindMemory(to: Float.self, capacity: count).update(repeating: 0, count: count)
            }
            return
        }
        let sourceCount = Int(sourceBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let sourceFloats = sourceData.bindMemory(to: Float.self, capacity: sourceCount)

        for buffer in outputList {
            guard let outData = buffer.mData else { continue }
            let outCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let outFloats = outData.bindMemory(to: Float.self, capacity: outCount)
            let count = min(sourceCount, outCount)
            if gain == 0 {
                outFloats.update(repeating: 0, count: outCount)
            } else {
                for i in 0..<count { outFloats[i] = sourceFloats[i] * gain }
                if outCount > count { outFloats.advanced(by: count).update(repeating: 0, count: outCount - count) }
            }
        }
    }

    // MARK: - Core Audio property helpers

    private enum AddressSelector {
        case hardwareServiceProcessObjectList
        case pid
        case bundleID
        case isRunningOutput
        case deviceUID
    }

    private static func address(_ selector: AddressSelector) -> AudioObjectPropertyAddress {
        let selectorValue: AudioObjectPropertySelector
        switch selector {
        case .hardwareServiceProcessObjectList: selectorValue = kAudioHardwarePropertyProcessObjectList
        case .pid: selectorValue = kAudioProcessPropertyPID
        case .bundleID: selectorValue = kAudioProcessPropertyBundleID
        case .isRunningOutput: selectorValue = kAudioProcessPropertyIsRunningOutput
        case .deviceUID: selectorValue = kAudioDevicePropertyDeviceUID
        }
        return AudioObjectPropertyAddress(
            mSelector: selectorValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func audioObjectIDArray(
        address: AudioObjectPropertyAddress, objectID: AudioObjectID
    ) -> [AudioObjectID]? {
        var addr = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var values = [AudioObjectID](repeating: .unknown, count: count)
        let status = values.withUnsafeMutableBytes { ptr -> OSStatus in
            var mutableSize = size
            return AudioObjectGetPropertyData(objectID, &addr, 0, nil, &mutableSize, ptr.baseAddress!)
        }
        return status == noErr ? values : nil
    }

    private static func processPID(_ objectID: AudioObjectID) -> pid_t? {
        var addr = address(.pid)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func processBundleID(_ objectID: AudioObjectID) -> String? {
        var addr = address(.bundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String? else { return nil }
        return string
    }

    private static func processIsRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var addr = address(.isRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// Every device that can play sound (excluding Augment's own aggregates).
    static func listOutputDevices() -> [AudioOutputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var result: [AudioOutputDevice] = []
        for id in ids {
            var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                         mScope: kAudioDevicePropertyScopeOutput,
                                                         mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { continue }
            guard let uid = stringProperty(address(.deviceUID), of: id) else { continue }
            let n = stringProperty(AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                              mScope: kAudioObjectPropertyScopeGlobal,
                                                              mElement: kAudioObjectPropertyElementMain), of: id) ?? uid
            guard !n.hasPrefix("Augment Mixer") else { continue }
            result.append(AudioOutputDevice(uid: uid, name: n))
        }
        return result
    }

    private static func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = .unknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        return stringProperty(address(.deviceUID), of: deviceID)
    }

    /// Reads a CFString property (Core Audio hands back a +1 reference).
    private static func stringProperty(_ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> String? {
        var addr = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

private extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
}

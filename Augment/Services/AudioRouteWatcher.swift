import AppKit
import CoreAudio

/// Watches the default output device. When headphones go away (AirPods
/// out of the ear or disconnected, a wired headset unplugged) it pauses
/// playback like macOS normally does — the mixer's re-rendering otherwise
/// keeps apps playing on the speakers. It also tells the mixer to follow
/// the new default device.
@MainActor
final class AudioRouteWatcher {
    static let shared = AudioRouteWatcher()

    /// Called on the main thread after the default output changes.
    var onDefaultOutputChanged: (() -> Void)?

    private var lastDevice: AudioDeviceID = 0
    private var lastWasHeadphones = false
    private var installed = false

    func start() {
        guard !installed else { return }
        installed = true
        lastDevice = Self.defaultOutput()
        lastWasHeadphones = Self.isHeadphones(lastDevice)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            MainActor.assumeIsolated { AudioRouteWatcher.shared.outputChanged() }
        }
    }

    private func outputChanged() {
        let device = Self.defaultOutput()
        guard device != lastDevice else { return }
        let wasHeadphones = lastWasHeadphones
        lastDevice = device
        lastWasHeadphones = Self.isHeadphones(device)
        if wasHeadphones && !lastWasHeadphones && SharedPreferences.shared.pauseOnHeadphonesRemoved {
            // MediaRemote "pause" (kMRPause = 1) — what the system sends itself.
            _ = MediaRemoteProvider.sendMediaCommand?(1, nil)
        }
        onDefaultOutputChanged?()
    }

    static func defaultOutput() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    /// Bluetooth audio (AirPods, headsets) or wired headphones in the jack.
    static func isHeadphones(_ device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        // Built-in output reports its data source: 'hdpn' = headphones.
        var source = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                             mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr {
            return source == 0x6864_706E // 'hdpn'
        }
        return false
    }
}

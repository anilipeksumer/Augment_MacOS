import AppKit
import Combine
import AudioToolbox
import CoreAudio
import Foundation

/// Brightness and volume for the notch's control row, the way Control
/// Center shows them: the built-in screen's brightness (or an external
/// monitor's over DDC when one is connected) and the current output
/// device's volume.
@MainActor
final class SystemControlsService: ObservableObject {
    static let shared = SystemControlsService()

    /// 0...1
    @Published private(set) var brightness: Double = 0.5
    /// 0...1
    @Published private(set) var volume: Double = 0.5
    @Published private(set) var isMuted = false
    @Published private(set) var canSetBrightness = false
    @Published private(set) var canSetVolume = false
    @Published private(set) var outputDeviceName = ""
    /// Screenshot hook: shows this name instead of the (system-localised) device name.
    var outputDeviceNameOverride: String? { didSet { if let o = outputDeviceNameOverride { outputDeviceName = o } } }
    @Published private(set) var isMicMuted = false
    @Published private(set) var hasMicrophone = false

    private init() {}

    /// The screen the notch lives on (built-in when there is one).
    private var targetDisplayID: CGDirectDisplayID? {
        (NSScreen.screens.first(where: { $0.hasNotch }) ?? NSScreen.main)?.displayID
    }

    /// Re-reads the current values; call when the notch opens.
    func refresh() {
        let displays = DisplayBrightnessService.shared
        if let id = targetDisplayID, let display = displays.displays.first(where: { $0.id == id }) {
            let live = display.method == .native ? DisplayBrightnessService.nativeBrightness(id).map(Double.init) : nil
            brightness = live ?? display.brightness
            canSetBrightness = true
        } else {
            canSetBrightness = false
        }
        if let mic = Self.defaultInputDevice() {
            hasMicrophone = true
            isMicMuted = Self.isInputMuted(mic)
        } else {
            hasMicrophone = false
        }
        if let device = Self.defaultOutputDevice(), let value = Self.volume(of: device) {
            volume = Double(value)
            isMuted = Self.isMuted(device)
            outputDeviceName = outputDeviceNameOverride ?? Self.name(of: device) ?? ""
            canSetVolume = true
        } else {
            canSetVolume = false
        }
    }

    func setBrightness(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        brightness = clamped
        guard let id = targetDisplayID else { return }
        DisplayBrightnessService.shared.setBrightness(clamped, for: id)
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        guard let device = Self.defaultOutputDevice() else { return }
        Self.setVolume(Float(clamped), of: device)
        if isMuted && clamped > 0 {
            Self.setMuted(false, device)
            isMuted = false
        }
    }

    func toggleMute() {
        guard let device = Self.defaultOutputDevice() else { return }
        isMuted.toggle()
        Self.setMuted(isMuted, device)
    }

    // MARK: - Microphone

    /// Mutes the default input. Uses the device's mute switch when it has
    /// one, otherwise drops its input volume to zero (restored on unmute).
    func toggleMicrophone() {
        guard let mic = Self.defaultInputDevice() else { return }
        let mute = !Self.isInputMuted(mic)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(mic, &address),
           AudioObjectIsPropertySettable(mic, &address, &settable) == noErr, settable.boolValue {
            var value = UInt32(mute ? 1 : 0)
            AudioObjectSetPropertyData(mic, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        } else {
            address.mSelector = kAudioDevicePropertyVolumeScalar
            if mute {
                var current = Float32(1)
                var size = UInt32(MemoryLayout<Float32>.size)
                AudioObjectGetPropertyData(mic, &address, 0, nil, &size, &current)
                UserDefaults.standard.set(Double(current), forKey: "augment.micVolumeBeforeMute")
            }
            var value = Float32(mute ? 0 : (UserDefaults.standard.object(forKey: "augment.micVolumeBeforeMute") as? Double ?? 0.75))
            AudioObjectSetPropertyData(mic, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
        isMicMuted = Self.isInputMuted(mic)
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func isInputMuted(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &address) {
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, value != 0 { return true }
        }
        address.mSelector = kAudioDevicePropertyVolumeScalar
        guard AudioObjectHasProperty(device, &address) else { return false }
        var volume = Float32(1)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr && volume == 0
    }

    // MARK: - Output volume (Core Audio)

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volume(of device: AudioDeviceID) -> Float? {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setVolume(_ value: Float, of device: AudioDeviceID) {
        var address = volumeAddress
        var v = Float32(value)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func setMuted(_ muted: Bool, _ device: AudioDeviceID) {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return }
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

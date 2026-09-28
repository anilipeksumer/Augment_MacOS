import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

/// Makes the keyboard's brightness and volume keys work on external
/// monitors (the MonitorControl feature): brightness keys adjust the screen
/// under the pointer when macOS can't, and volume keys drive the monitor's
/// own speakers over DDC when sound is going out through the display cable.
/// Keys macOS already handles (built-in screen, normal speakers) pass through.
final class DisplayKeysService {
    static let shared = DisplayKeysService()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    // NX_KEYTYPE_* values carried by media-key system-defined events.
    private enum MediaKey: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    private init() {}

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        // The key handler reads which method each screen uses from a
        // snapshot the brightness service keeps — make sure it exists.
        if Thread.isMainThread {
            MainActor.assumeIsolated { DisplayBrightnessService.shared.refresh() }
        }
        // NX_SYSDEFINED media keys, plus plain key-downs: some keyboards send
        // brightness as key codes 144/145 (or F14/F15 on extended keyboards).
        let mask: CGEventMask = (1 << 14) | (1 << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<DisplayKeysService>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = service.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return service.handle(event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
        EventTapThread.shared.add(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let source { EventTapThread.shared.remove(source) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    /// Runs on the event-tap thread. Decides synchronously whether to
    /// swallow the key; the actual work hops to the main thread.
    func handle(_ event: CGEvent, pointer: CGPoint? = nil) -> Bool {
        let key: MediaKey
        let isDown: Bool
        let fine: Bool
        if event.type == .keyDown {
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144, 113: key = .brightnessUp     // brightness up / F15
            case 145, 107: key = .brightnessDown   // brightness down / F14
            default: return false
            }
            isDown = true
            fine = event.flags.contains([.maskAlternate, .maskShift])
        } else {
            guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return false }
            let data = nsEvent.data1
            guard let k = MediaKey(rawValue: (data & 0xFFFF_0000) >> 16) else { return false }
            key = k
            isDown = ((data & 0xFF00) >> 8) == 0x0A
            // Option+Shift = quarter steps, like macOS.
            fine = nsEvent.modifierFlags.contains([.option, .shift])
        }
        let step = fine ? 1.0 / 64 : 1.0 / 16

        switch key {
        case .brightnessUp, .brightnessDown:
            guard let target = Self.externalDisplay(at: pointer ?? CGEvent(source: nil)?.location ?? .zero) else { return false }
            if isDown {
                let delta = key == .brightnessUp ? step : -step
                DispatchQueue.main.async {
                    let service = DisplayBrightnessService.shared
                    if let value = service.step(delta, for: target) {
                        LevelHUD.shared.show(icon: value < 0.4 ? "sun.min.fill" : "sun.max.fill", level: value, on: target)
                    }
                }
            }
            return true
        case .soundUp, .soundDown, .mute:
            guard Self.outputGoesThroughDisplayCable(), let target = Self.ddcDisplayForAudio() else { return false }
            if isDown {
                DispatchQueue.main.async {
                    let service = DisplayBrightnessService.shared
                    if key == .mute {
                        let muted = !(UserDefaults.standard.bool(forKey: "augment.ddcMuted.\(target)"))
                        UserDefaults.standard.set(muted, forKey: "augment.ddcMuted.\(target)")
                        service.setDDCMuted(muted, for: target)
                        LevelHUD.shared.show(icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                             level: muted ? 0 : service.ddcVolume(for: target), on: target)
                    } else {
                        let value = min(max(service.ddcVolume(for: target) + (key == .soundUp ? step : -step), 0), 1)
                        service.setDDCVolume(value, for: target)
                        UserDefaults.standard.set(false, forKey: "augment.ddcMuted.\(target)")
                        LevelHUD.shared.show(icon: value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                             level: value, on: target)
                    }
                }
            }
            return true
        }
    }

    /// The display at `point`, if macOS can't set its brightness itself.
    static func externalDisplay(at point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        let method = DisplayBrightnessService.method(for: id)
        return (method == .ddc || method == .software) ? id : nil
    }

    private static func ddcDisplayForAudio() -> CGDirectDisplayID? {
        DisplayBrightnessService.firstDDCDisplay
    }

    /// True when the default output is a monitor's speakers (HDMI or
    /// DisplayPort), whose volume macOS can't change.
    private static func outputGoesThroughDisplayCable() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
    }
}

// MARK: - On-screen level indicator

/// A small glass HUD like macOS's own brightness/volume overlay.
@MainActor
final class LevelHUD {
    static let shared = LevelHUD()

    private var panel: NSPanel?
    private let model = Model()
    private var hideWork: DispatchWorkItem?

    final class Model: ObservableObject {
        @Published var icon = "sun.max.fill"
        @Published var level: Double = 0.5
    }

    func show(icon: String, level: Double, on displayID: CGDirectDisplayID) {
        model.icon = icon
        model.level = level
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main
        if let frame = screen?.frame {
            let size = CGSize(width: 220, height: 56)
            panel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.14,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel?.animator().alphaValue = 0
            } completionHandler: {
                panel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 220, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: LevelHUDView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

private struct LevelHUDView: View {
    @ObservedObject var model: LevelHUD.Model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 22)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(Color.primary).frame(width: geo.size.width * model.level)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 18)
        .frame(width: 220, height: 56)
        .modifier(HUDBackground())
    }
}

private struct HUDBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThickMaterial, in: Capsule())
        }
    }
}

// MARK: - Day/night brightness schedule

/// Switches every display to a day or night brightness at the chosen
/// times. It only acts when the period changes, so manual adjustments in
/// between are kept.
@MainActor
final class BrightnessScheduler {
    static let shared = BrightnessScheduler()

    private var timer: Timer?
    private var lastPeriod: Bool?

    func start() {
        guard timer == nil else { return }
        lastPeriod = nil
        tick()
        let t = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in BrightnessScheduler.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastPeriod = nil
    }

    /// Re-applies the current period now (after the user edits the schedule).
    func reapply() {
        lastPeriod = nil
        tick()
    }

    private func tick() {
        let prefs = SharedPreferences.shared
        let isDay = Self.isDay(now: Date(), dayStart: Int(prefs.brightnessDayStart), nightStart: Int(prefs.brightnessNightStart))
        guard isDay != lastPeriod else { return }
        lastPeriod = isDay
        DisplayBrightnessService.shared.setAll(isDay ? prefs.brightnessDayLevel : prefs.brightnessNightLevel)
    }

    nonisolated static func isDay(now: Date, dayStart: Int, nightStart: Int) -> Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if dayStart <= nightStart {
            return minute >= dayStart && minute < nightStart
        }
        return minute >= dayStart || minute < nightStart
    }
}

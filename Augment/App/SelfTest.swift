import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// Headless diagnostics, run with `Augment --selftest`. Exercises each
/// subsystem for real and prints PASS/FAIL lines to stdout and to
/// `~/Library/Application Support/Augment/selftest.log`, then quits.
@MainActor
enum SelfTest {
    static let argument = "--selftest"

    private static var lines: [String] = []

    static func runAndExit() {
        report("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        report("bundle", Bundle.main.bundlePath)

        let trusted = AXIsProcessTrusted()
        check("Accessibility trusted", trusted)
        if !trusted {
            // Registers this exact binary in System Settings' Accessibility list
            // so the user only has to flip its switch.
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        let screenRecording = CGPreflightScreenCaptureAccess()
        check("Screen Recording granted", screenRecording)
        if !screenRecording { _ = CGRequestScreenCaptureAccess() }
        requestAutomation(of: "com.apple.finder")

        checkPreferencesRoundTrip()
        checkEventTap()
        checkWindows()
        checkFinderScript()
        checkNotchRender()
        // Written before the fix so a crash here aborts the run; the log line
        // below proves the run got past it.
        lines.append("INFO  starting notch expand cycles…")
        flushLog()
        checkNotchExpandCycles()
        checkMedia {
            checkAudioProcesses()
            finish()
        }
    }

    // MARK: - Checks

    /// Triggers the Automation consent prompt so Augment appears under
    /// Privacy & Security → Automation with a Finder switch.
    private static func requestAutomation(of bundleID: String) {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, true
        )
        check("Automation permission for \(bundleID)", status == noErr, detail: "status=\(status)")
    }

    private static func checkPreferencesRoundTrip() {
        let key = "augment.selftest.roundtrip"
        let value = "v\(Int(Date().timeIntervalSince1970))"
        AppGroup.setSuiteValue(value as NSString, forKey: key)
        AppGroup.synchronizeSuitePreferences()
        let readBack = AppGroup.copySuiteValue(forKey: key) as? String
        check("Preferences write+reload from disk", readBack == value, detail: "read=\(readBack ?? "nil")")
        AppGroup.setSuiteValue(nil, forKey: key)
    }

    private static func checkEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        check("Keyboard event tap can be created", tap != nil,
              detail: tap == nil ? "shortcuts (snapping, cut/paste, switcher, layouts) cannot work" : "")
        if let tap { CFMachPortInvalidate(tap) }
    }

    private static func checkWindows() {
        let discovery = WindowDiscoveryService()
        let windows = discovery.windows()
        check("On-screen windows enumerated", !windows.isEmpty, detail: "count=\(windows.count)")
        let captured = windows.prefix(5).filter { discovery.captureThumbnail(for: $0.id) != nil }.count
        check("Window thumbnails captured", captured > 0,
              detail: "\(captured)/\(min(5, windows.count)) (0 = previews will be blank)")
    }

    private static func checkFinderScript() {
        var error: NSDictionary?
        let result = NSAppleScript(source: "tell application \"Finder\" to return name of startup disk")?
            .executeAndReturnError(&error)
        check("AppleScript control of Finder", result?.stringValue != nil,
              detail: error.map { "\($0[NSAppleScript.errorMessage] ?? $0)" } ?? "")
    }

    /// Drives the real `NotchService` overlay panel through several animated
    /// expand/collapse cycles with every widget on — the exact path that
    /// crashed in real use (the static render below never animated).
    private static func checkNotchExpandCycles() {
        let service = NotchService()
        service.start(preferences: SharedPreferences.shared)
        let vm = service.viewModelForTesting
        vm.showMusic = true
        vm.showShelf = true
        vm.clipboardHistoryEnabled = true
        vm.showProductivity = true
        vm.showCaffeinate = true
        vm.showBattery = true
        vm.calendarEnabled = true
        // Let MediaManager deliver real now-playing info (long YouTube titles
        // → scrolling MarqueeText, artwork → ambient colour) before expanding.
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        lines.append("INFO  notch media before expanding: \(vm.mediaInfo?.title ?? "none")")
        flushLog()
        for _ in 0..<4 {
            withAnimation(.interpolatingSpring(stiffness: 340, damping: 30)) { vm.isExpanded = true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            withAnimation(.interpolatingSpring(stiffness: 340, damping: 32)) { vm.isExpanded = false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        service.stop()
        check("Notch animated expand/collapse with all widgets (real panel)", true)
    }

    private static func checkNotchRender() {
        let vm = NotchViewModel()
        vm.showMusic = true
        vm.showShelf = true
        vm.showProductivity = true
        vm.showCaffeinate = true
        vm.clipboardHistoryEnabled = true
        vm.isExpanded = true
        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let host = NSHostingView(rootView: NotchContentView(viewModel: vm, notchRect: rect, hasNotch: true))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        panel.orderOut(nil)
        check("Notch expanded with all widgets renders without crashing", true)
    }

    private static func checkMedia(then next: @escaping () -> Void) {
        MediaManager.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let sources = MediaManager.shared.availableSources
            let summary = sources.map { "\($0.appName)[\($0.isPlaying ? "playing" : "paused")]: \($0.title)" }
            report("Media sources (\(sources.count))", summary.isEmpty ? "none — start some audio to test" : summary.joined(separator: " | "))
            MediaManager.shared.stop()
            next()
        }
    }

    private static func checkAudioProcesses() {
        if #available(macOS 14.2, *) {
            let mixer = AudioProcessMixerService.shared
            mixer.start()
            let apps = mixer.apps
            check("Mixer lists apps with audio", !apps.isEmpty,
                  detail: apps.map { "\($0.name)(\($0.processObjectIDs.count) proc\($0.isPlaying ? ", playing" : ""))" }
                    .joined(separator: ", "))
            if let target = apps.first(where: \.isPlaying) ?? apps.first {
                mixer.setVolume(0.5, forPID: target.id)
                check("Mixer can tap \(target.name)", mixer.lastError == nil, detail: mixer.lastError ?? "tap + aggregate created")
            }
            mixer.stop()
        }
    }

    // MARK: - Output

    private static func check(_ name: String, _ ok: Bool, detail: String = "") {
        lines.append("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    private static func report(_ name: String, _ value: String) {
        lines.append("INFO  \(name): \(value)")
    }

    private static var logURL: URL {
        AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("selftest.log")
    }

    /// Writes what we have so far to a separate `.partial` file, so a crash
    /// mid-run still leaves evidence of how far it got.
    private static func flushLog() {
        let url = logURL.deletingPathExtension().appendingPathExtension("partial.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func finish() {
        let text = lines.joined(separator: "\n") + "\n"
        print(text)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
        fflush(stdout)
        exit(0)
    }
}

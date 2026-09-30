import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import SwiftUI

/// End-to-end feature tests, run with `Augment --functest`. Unlike
/// `SelfTest`, these actually drive each feature the way a user would —
/// synthetic key presses, cursor moves over the Dock, real media commands —
/// and measure the effect. Everything they change is put back afterwards.
@MainActor
enum FuncTest {
    static let argument = "--functest"

    private static var lines: [String] = []

    static func runAndExit() {
        Task { @MainActor in
            if CommandLine.arguments.contains("--hotkey-routing") {
                await testHotKeyRouting()
                finish()
                return
            }
            if CommandLine.arguments.contains("--desktop") {
                await testDesktopMinimization()
                finish()
                return
            }
            if CommandLine.arguments.contains("--displays") {
                let service = DisplayBrightnessService.shared
                service.refresh()
                for d in service.displays {
                    lines.append("INFO  display \(d.id) \(d.name) builtin=\(d.isBuiltIn) method=\(d.method) level=\(d.brightness) vendor=\(CGDisplayVendorNumber(d.id)) model=\(CGDisplayModelNumber(d.id)) serial=\(CGDisplaySerialNumber(d.id))")
                }
                lines.append("INFO  \(service.debugDDCSummary())")
                // Brightness key while the pointer is on the external screen.
                if CommandLine.arguments.contains("--keys"), let ext = service.displays.first(where: { $0.method == .ddc }) {
                    let original = ext.brightness
                    let bounds = CGDisplayBounds(ext.id)
                    let point = CGPoint(x: bounds.midX, y: bounds.midY)
                    let data = (3 << 16) | (0x0A << 8) // brightness down, key down
                    let keyEvent = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                                      timestamp: 0, windowNumber: 0, context: nil,
                                                      subtype: 8, data1: data, data2: -1)?.cgEvent
                    let swallowed = keyEvent.map { DisplayKeysService.shared.handle($0, pointer: point) } ?? false
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    let after = service.displays.first { $0.id == ext.id }?.brightness ?? -1
                    lines.append("INFO  key on external: swallowed=\(swallowed) \(original) -> \(after) \(service.debugDDCSummary())")
                    let builtIn = service.displays.first(where: \.isBuiltIn).map { CGDisplayBounds($0.id) }
                    let passes = builtIn.map { b in keyEvent.map { !DisplayKeysService.shared.handle($0, pointer: CGPoint(x: b.midX, y: b.midY)) } ?? false } ?? true
                    lines.append("INFO  key on built-in passes to macOS: \(passes)")
                    service.setBrightness(original, for: ext.id)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    lines.append("INFO  restored: \(service.debugDDCSummary())")
                }
                if CommandLine.arguments.contains("--write"), let ext = service.displays.first(where: { $0.method == .ddc }) {
                    let original = ext.brightness
                    service.setBrightness(0.95, for: ext.id)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    lines.append("INFO  after write 95: \(service.debugDDCSummary())")
                    service.setBrightness(original, for: ext.id)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    lines.append("INFO  restored: \(service.debugDDCSummary())")
                }
                finish()
                return
            }
            if CommandLine.arguments.contains("--dock-toggle") {
                // Minimize and restore each running app's windows the way a
                // click on its Dock icon does.
                for bundleID in ["net.whatsapp.WhatsApp", "com.apple.TextEdit"] {
                    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                        lines.append("SKIP  \(bundleID) not running")
                        continue
                    }
                    func minimizedStates() -> [Bool] {
                        let element = AXUIElementCreateApplication(app.processIdentifier)
                        var value: AnyObject?
                        AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
                        return ((value as? [AXUIElement]) ?? []).map { w in
                            var m: AnyObject?
                            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
                            return (m as? Bool) ?? false
                        }
                    }
                    let before = minimizedStates()
                    // `--gap N` leaves the window minimized for N seconds first.
                    let args = CommandLine.arguments
                    let gap = args.firstIndex(of: "--gap").flatMap { args.indices.contains($0 + 1) ? UInt64(args[$0 + 1]) : nil } ?? 1
                    DockWindowToggle.toggle(app)
                    try? await Task.sleep(nanoseconds: gap * 1_000_000_000)
                    let afterFirst = minimizedStates()
                    DockWindowToggle.toggle(app)
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    let afterSecond = minimizedStates()
                    let ok = afterFirst.contains(true) != before.contains(true) && afterSecond.contains(true) == before.contains(true)
                    lines.append("\(ok ? "PASS" : "FAIL")  \(bundleID) minimized before=\(before) after 1st click=\(afterFirst) after 2nd click=\(afterSecond)")
                }
                finish()
                return
            }
            if CommandLine.arguments.contains("--mixer-test") {
                if #available(macOS 14.2, *) {
                    let say = Process()
                    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    say.arguments = ["-r", "170", "Augment ses mikseri testi. Bu cümle birkaç saniye sürüyor, sesin kısıldığını duyman gerekiyor."]
                    try? say.run()
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let mixer = AudioProcessMixerService.shared
                    let ok = mixer.debugTap(pid: say.processIdentifier, gain: 0.15)
                    lines.append("INFO  tap created=\(ok)")
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    lines.append("INFO  stats: \(mixer.debugStats(pid: say.processIdentifier))")
                    mixer.debugTeardown(pid: say.processIdentifier)
                    say.terminate()
                }
                finish()
                return
            }
            if CommandLine.arguments.contains("--mixer-app") {
                if #available(macOS 14.2, *) {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("augment-mixer.aiff")
                    let say = Process()
                    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    say.arguments = ["-o", file.path, "Augment ses mikseri, gerçek uygulama testi. Bu ses QuickTime üzerinden çalıyor ve birazdan kısılacak, sonra başka bir hoparlöre geçecek."]
                    try? say.run(); say.waitUntilExit()
                    _ = runScript("tell application \"QuickTime Player\"\nopen POSIX file \"\(file.path)\"\ndelay 1\nplay document 1\nend tell")
                    let mixer = AudioProcessMixerService.shared
                    mixer.start()
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    lines.append("INFO  apps: \(mixer.apps.map { "\($0.name) pid=\($0.id) playing=\($0.isPlaying) objs=\($0.processObjectIDs.count)" })")
                    if let qt = mixer.apps.first(where: { $0.bundleID == "com.apple.QuickTimePlayerX" }) {
                        mixer.setVolume(0.15, forPID: qt.id)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        lines.append("INFO  after volume 15%: \(mixer.debugStats(pid: qt.id))")
                        if let speakers = mixer.outputDevices.first(where: { $0.name.localizedCaseInsensitiveContains("MacBook") }) {
                            mixer.setOutputDevice(speakers.uid, forPID: qt.id)
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            lines.append("INFO  after routing to \(speakers.name): \(mixer.debugStats(pid: qt.id))")
                            mixer.setOutputDevice(nil, forPID: qt.id)
                        }
                        mixer.setVolume(1, forPID: qt.id)
                    } else {
                        lines.append("INFO  QuickTime not in mixer list")
                    }
                    mixer.stop()
                    _ = runScript("tell application \"QuickTime Player\" to close every document saving no")
                    _ = runScript("tell application \"QuickTime Player\" to quit")
                }
                finish()
                return
            }
            if CommandLine.arguments.contains("--mixer-listen") {
                if #available(macOS 14.2, *) {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("augment-tone.wav").path
                    _ = runScript("tell application \"QuickTime Player\"\nopen POSIX file \"\(file)\"\ndelay 1\nplay document 1\nend tell")
                    let mixer = AudioProcessMixerService.shared
                    mixer.start()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if let qt = mixer.apps.first(where: { $0.bundleID == "com.apple.QuickTimePlayerX" }) {
                        lines.append("INFO  stage 1 normal"); flushLog()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        mixer.setVolume(0.1, forPID: qt.id)
                        lines.append("INFO  stage 2 10%: \(mixer.debugStats(pid: qt.id))"); flushLog()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        mixer.setMuted(true, forPID: qt.id)
                        lines.append("INFO  stage 3 muted"); flushLog()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        mixer.setMuted(false, forPID: qt.id)
                        mixer.setVolume(1, forPID: qt.id)
                        if let speakers = mixer.outputDevices.first(where: { $0.name.localizedCaseInsensitiveContains("MacBook") }) {
                            mixer.setOutputDevice(speakers.uid, forPID: qt.id)
                            lines.append("INFO  stage 4 routed to \(speakers.name): \(mixer.debugStats(pid: qt.id))"); flushLog()
                        }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        mixer.setOutputDevice(nil, forPID: qt.id)
                    }
                    mixer.stop()
                    _ = runScript("tell application \"QuickTime Player\" to close every document saving no")
                    _ = runScript("tell application \"QuickTime Player\" to quit")
                }
                finish()
                return
            }
            if CommandLine.arguments.contains("--switcher-list") {
                let service = WindowSwitcherService(windowDiscovery: WindowDiscoveryService())
                let list = service.switchableWindowsForTesting
                for w in list {
                    lines.append("INFO  \(w.isAppPlaceholder ? "APP " : (w.isMinimized ? "MIN " : "WIN ")) \(w.ownerName) — \(w.title ?? "")")
                }
                let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.count
                record("Switcher covers every open app", Set(list.map(\.ownerPID)).count >= apps - 1, "apps=\(apps) covered=\(Set(list.map(\.ownerPID)).count)")
                finish()
                return
            }
            if CommandLine.arguments.contains("--audio-route") {
                let device = AudioRouteWatcher.defaultOutput()
                SystemControlsService.shared.refresh()
                lines.append("INFO  default output=\(SystemControlsService.shared.outputDeviceName) headphones=\(AudioRouteWatcher.isHeadphones(device))")
                finish()
                return
            }
            if CommandLine.arguments.contains("--native-fade") {
                let service = DisplayBrightnessService.shared
                service.refresh()
                if let builtIn = service.displays.first(where: { $0.method == .native }) {
                    let original = builtIn.brightness
                    service.setBrightness(max(0.05, original - 0.25), for: builtIn.id)
                    var samples: [String] = []
                    for _ in 0..<8 {
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        samples.append(String(format: "%.3f", DisplayBrightnessService.nativeBrightness(builtIn.id) ?? -1))
                    }
                    lines.append("INFO  fade samples (60ms apart) from \(String(format: "%.3f", original)): \(samples.joined(separator: " "))")
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    service.setBrightness(original, for: builtIn.id)
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    lines.append("INFO  restored to \(String(format: "%.3f", DisplayBrightnessService.nativeBrightness(builtIn.id) ?? -1))")
                }
                finish()
                return
            }
            if CommandLine.arguments.contains("--services") {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("augment-service-test.txt")
                try? "x".write(to: file, atomically: true, encoding: .utf8)
                let saved = NSPasteboard.general.string(forType: .string)
                let pb = NSPasteboard(name: NSPasteboard.Name("AugmentServiceTest-\(UUID().uuidString)"))
                pb.clearContents()
                pb.writeObjects([file as NSURL])
                let ok = NSPerformService("Copy Path", pb)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let copied = NSPasteboard.general.string(forType: .string) ?? ""
                record("Copy Path service works (any folder, incl. iCloud)", ok && copied == file.path, "performed=\(ok) clipboard=\(copied)")
                if let saved { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(saved, forType: .string) }
                try? FileManager.default.removeItem(at: file)
                finish()
                return
            }
            if CommandLine.arguments.contains("--stats") {
                let stats = SystemStatsService.shared
                stats.retain()
                try? await Task.sleep(nanoseconds: 6_500_000_000)
                let s = stats.snapshot
                lines.append(String(format: "INFO  cpu=%.1f%% mem=%.2f/%.2f GB down=%.0f B/s up=%.0f B/s temp=%@ thermal=%d history=%d",
                                    s.cpu * 100, Double(s.memoryUsed) / 1_073_741_824, Double(s.memoryTotal) / 1_073_741_824,
                                    s.downBytesPerSecond, s.upBytesPerSecond, s.temperature.map { String(format: "%.1f", $0) } ?? "nil",
                                    s.thermalState.rawValue, s.cpuHistory.count))
                stats.release()
                finish()
                return
            }
            if CommandLine.arguments.contains("--readme-shots") {
                await captureReadmeQuickPanel()
                finish()
                return
            }
            if CommandLine.arguments.contains("--demo-gifs") {
                await recordReadmeClips()
                finish()
                return
            }
            if CommandLine.arguments.contains("--finder-menu") {
                await readFinderContextMenu()
                finish()
                return
            }
            if CommandLine.arguments.contains("--finderext") {
                lines.append("INFO  finder extension enabled=\(FinderExtensionStatus.isEnabled)")
                finish()
                return
            }
            if CommandLine.arguments.contains("--extras") {
                await testExtras()
                finish()
                return
            }
            if CommandLine.arguments.contains("--notch-render") {
                await renderNotchOffscreen()
                finish()
                return
            }
            if CommandLine.arguments.contains("--filecut") {
                await testFileCutPaste()
                finish()
                return
            }
            if CommandLine.arguments.contains("--menubar") {
                await inspectMenuBar()
                finish()
                return
            }
            if CommandLine.arguments.contains("--switcher-shot") {
                await captureSwitcher()
                finish()
                return
            }
            if CommandLine.arguments.contains("--dock-min") {
                await testDockPreviewMinimized()
                finish()
                return
            }
            if CommandLine.arguments.contains("--settings-shots") {
                await captureSettingsPages()
                finish()
                return
            }
            if CommandLine.arguments.contains("--notch-hold") {
                // Opens the real notch and keeps it open for 10s for a screenshot.
                let service = NotchService()
                service.start(preferences: SharedPreferences.shared)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let screen = NSScreen.screens.first(where: { $0.hasNotch }) ?? NSScreen.main {
                    moveCursor(to: ScreenGeometry.convertToCG(CGPoint(x: screen.notchRect.midX, y: screen.notchRect.midY)))
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if CommandLine.arguments.contains("--type") {
                        let vm = service.viewModelForTesting
                        let note = ScreenGeometry.convertToCG(CGPoint(x: screen.notchRect.midX - 60, y: screen.frame.maxY - 300))
                        // Glide down into the open notch instead of teleporting.
                        let start = ScreenGeometry.convertToCG(CGPoint(x: screen.notchRect.midX, y: screen.notchRect.midY))
                        for step in 1...20 {
                            let t = CGFloat(step) / 20
                            let p = CGPoint(x: start.x + (note.x - start.x) * t, y: start.y + (note.y - start.y) * t)
                            CGWarpMouseCursorPosition(p); postMouseMove(to: p)
                            try? await Task.sleep(nanoseconds: 30_000_000)
                        }
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        lines.append("INFO  before click: expanded=\(vm.isExpanded)")
                        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: note, mouseButton: .left)?.post(tap: .cghidEventTap)
                            try? await Task.sleep(nanoseconds: 60_000_000)
                        }
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        lines.append("INFO  after click: expanded=\(vm.isExpanded)")
                        for key in [kVK_ANSI_T, kVK_ANSI_E, kVK_ANSI_S, kVK_ANSI_T] {
                            await postKey(keyCode: UInt16(key), down: true, flags: [])
                            await postKey(keyCode: UInt16(key), down: false, flags: [])
                        }
                        let keyWindow = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none"
                        let responder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
                        lines.append("INFO  after typing: note=\(service.viewModelForTesting.quickNoteText.debugDescription) keyWindow=\(keyWindow) firstResponder=\(responder) appActive=\(NSApp.isActive)")
                    }
                }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                service.stop()
                finish()
                return
            }
            if CommandLine.arguments.contains("--notch-only") {
                await testNotchHover()
                finish()
                return
            }
            await testNotchHover()
            await testWindowSnapping()
            await testSnapLayoutsPicker()
            await testWindowSwitcher()
            await testFileCutPaste()
            await testClipboardHistory()
            await testDockHover()
            await testDockPreviewMinimized()
            await testMediaPlayPause()
            testCaffeinate()
            finish()
        }
    }

    // MARK: - Quick panel

    /// Opens the quick panel under a real status item and captures it.
    private static func inspectMenuBar() async {
        let anchor = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        anchor.button?.image = NSImage(systemSymbolName: "square", accessibilityDescription: "anchor")
        try? await Task.sleep(nanoseconds: 800_000_000)
        QuickPanelController.shared.toggle(below: anchor.button)
        lines.append("INFO  right after open: isOpen=\(QuickPanelController.shared.isOpen) panels=\(NSApp.windows.filter { $0 is NSPanel }.map { "\($0.frame) visible=\($0.isVisible)" })")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        record("Quick panel opens", QuickPanelController.shared.isOpen, "displays=\(DisplayBrightnessService.shared.displays.map(\.name))")
        await snapPanel(named: "quick-panel")
        QuickPanelController.shared.close()
        NSStatusBar.system.removeStatusItem(anchor)
    }

    // MARK: - Window switcher screenshot

    /// Opens the ⌥Tab switcher with the user's real windows, advances the
    /// selection to the last window, captures the panel, then closes it
    /// without switching.
    private static func captureSwitcher() async {
        let service = WindowSwitcherService(windowDiscovery: WindowDiscoveryService())
        service.start()
        let total = WindowDiscoveryService().windows().filter { $0.ownerPID != ProcessInfo.processInfo.processIdentifier }.count
        lines.append("INFO  switchable windows: \(total)")
        for i in 0..<max(1, total - 1) {
            await postKey(keyCode: UInt16(kVK_Tab), down: true, flags: .maskAlternate)
            await postKey(keyCode: UInt16(kVK_Tab), down: false, flags: .maskAlternate)
            if i == 0 { await snapPanel(named: "switcher-first") }
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        await snapPanel(named: "switcher-last")
        service.stop()
    }

    private static func snapPanel(named name: String) async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        let dir = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let window = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        else { lines.append("INFO  \(name): no visible panel"); return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: dir.appendingPathComponent("\(name).png"))
        lines.append("INFO  captured \(name) \(image.width)x\(image.height) panelFrame=\(window.frame)")
        // Composite with whatever is behind it, so glass/material shows as the user sees it.
        let f = window.frame.insetBy(dx: -60, dy: -60)
        let topLeft = ScreenGeometry.convertToCG(CGPoint(x: f.minX, y: f.maxY))
        if let composite = CGWindowListCreateImage(CGRect(origin: topLeft, size: f.size), .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) {
            try? NSBitmapImageRep(cgImage: composite).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("\(name)-onscreen.png"))
        }
    }

    // MARK: - Settings screenshots

    /// Opens Settings and saves a PNG of every page to
    /// ~/Library/Application Support/Augment/shots/ for visual review.
    private static func captureSettingsPages() async {
        let controller = SettingsWindowController(
            preferences: SharedPreferences.shared,
            permissionCoordinator: PermissionCoordinator(preferences: .shared)
        )
        // Off-screen and without activating, so it never interrupts the user.
        guard let window = controller.window else { return }
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 800_000_000)
        let dir = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for tab in SettingsTab.allCases {
            NotificationCenter.default.post(name: SettingsRootView.selectTabNotification, object: tab.rawValue)
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(tab.rawValue).png"))
            lines.append("INFO  captured \(tab.rawValue) \(image.width)x\(image.height)")
        }
        controller.close()

        for page in [0, 2] {
            let tour = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 560, height: 440),
                                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            tour.titlebarAppearsTransparent = true
            tour.contentView = NSHostingView(rootView: WelcomeTourView(onFinish: {}, index: page))
            tour.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 700_000_000)
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(tour.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("tour-\(page).png"))
            }
            tour.orderOut(nil)
        }

        let about = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 460, height: 420),
                             styleMask: [.titled], backing: .buffered, defer: false)
        about.contentView = NSHostingView(rootView: AboutView {})
        about.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 700_000_000)
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(about.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("about.png"))
            lines.append("INFO  captured about")
        }
        about.orderOut(nil)
    }

    // MARK: - Notch hover (real panel, real cursor, user's saved widgets)

    private static func testNotchHover() async {
        let service = NotchService()
        service.start(preferences: SharedPreferences.shared)
        try? await Task.sleep(nanoseconds: 4_000_000_000) // let media info arrive

        guard let screen = NSScreen.screens.first(where: { $0.hasNotch }) ?? NSScreen.main else { return }
        let notch = screen.notchRect
        // The very top pixel row, where a real cursor ends up when pushed up.
        let center = CGPoint(x: ScreenGeometry.convertToCG(CGPoint(x: notch.midX, y: notch.midY)).x,
                             y: ScreenGeometry.convertToCG(CGPoint(x: 0, y: screen.frame.maxY)).y)
        let inside = ScreenGeometry.convertToCG(CGPoint(x: notch.midX + 60, y: notch.minY - 140))
        let away = ScreenGeometry.convertToCG(CGPoint(x: notch.midX, y: notch.minY - 500))
        let original = ScreenGeometry.convertToCG(NSEvent.mouseLocation)

        var expandedSeen = false
        for _ in 0..<5 {
            moveCursor(to: center)
            try? await Task.sleep(nanoseconds: 900_000_000)
            expandedSeen = expandedSeen || service.viewModelForTesting.isExpanded
            moveCursor(to: inside)       // wander over the widgets inside the open notch
            try? await Task.sleep(nanoseconds: 600_000_000)
            moveCursor(to: away)
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        record("Closed notch lets clicks through below it",
               !service.viewModelForTesting.isExpanded && service.passesClicksThroughForTesting,
               "expanded=\(service.viewModelForTesting.isExpanded) clickThrough=\(service.passesClicksThroughForTesting)")
        // Interact like a user: open, click the quick-note box, type, press
        // the Pomodoro play button, let it tick.
        // The note and the Pomodoro live on the "Note" tab.
        service.viewModelForTesting.lowerTab = .note
        moveCursor(to: center)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let window = NSApp.windows.first { $0 is NSPanel && $0.frame.maxY == screen.frame.maxY && $0.frame.width == 420 }
        func onScreen(_ key: String) -> CGPoint? {
            guard let window, let f = service.viewModelForTesting.layoutFrames[key] else { return nil }
            return ScreenGeometry.convertToCG(CGPoint(x: window.frame.minX + f.midX, y: window.frame.maxY - f.midY))
        }
        let noteBox = onScreen("note") ?? .zero
        let playButton = onScreen("pomodoro") ?? .zero
        lines.append("INFO  layout frames: \(service.viewModelForTesting.layoutFrames) window=\(window?.frame ?? .zero)")
        lines.append("INFO  interact: clicking note box expanded=\(service.viewModelForTesting.isExpanded)"); flushLog()
        if noteBox != .zero { click(at: noteBox) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Never type unless the keystrokes will land in the notch — they'd
        // otherwise go to whatever app is in front.
        if service.viewModelForTesting.isExpanded, NSApp.keyWindow is NSPanel {
            lines.append("INFO  interact: typing"); flushLog()
            for key in [kVK_ANSI_H, kVK_ANSI_E, kVK_ANSI_Y, kVK_Return, kVK_ANSI_A] {
                await postKey(keyCode: UInt16(key), down: true, flags: [])
                await postKey(keyCode: UInt16(key), down: false, flags: [])
            }
        } else {
            lines.append("INFO  interact: notch not open/key — skipped typing")
        }
        lines.append("INFO  interact: pomodoro play"); flushLog()
        if playButton != .zero { click(at: playButton) }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let vmAfter = service.viewModelForTesting
        record("Quick note accepts typing after one click", vmAfter.quickNoteText.contains("hey"),
               "note=\(vmAfter.quickNoteText.debugDescription)")
        record("Pomodoro play button starts the timer", vmAfter.pomodoroRunning, "")
        vmAfter.resetPomodoro()
        vmAfter.quickNoteText = ""
        flushLog()

        moveCursor(to: original)
        service.stop()
        record("Notch opens on hover and survives 5 open/close cycles", expandedSeen,
               "widgets: music=\(service.viewModelForTesting.showMusic) shelf=\(service.viewModelForTesting.showShelf) productivity=\(service.viewModelForTesting.showProductivity)")
    }

    private static func click(at point: CGPoint) {
        moveCursor(to: point)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    private static func flushLog() {
        let url = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("functest.partial.log")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func moveCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        postMouseMove(to: point)
    }

    // MARK: - Window snapping (⌘←)

    private static func testHotKeyRouting() async {
        let clipboard = ClipboardPanelController.shared
        clipboard.enable()
        ShowDesktopService.shared.setEnabled(true)
        defer {
            clipboard.disable()
            ShowDesktopService.shared.stop()
        }
        func send(signature: OSType, id: UInt32) async {
            var event: EventRef?
            guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr,
                  let event else { fail("Hotkey event creation", "failed"); return }
            defer { ReleaseEvent(event) }
            var identifier = EventHotKeyID(signature: signature, id: id)
            SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              MemoryLayout<EventHotKeyID>.size, &identifier)
            SendEventToEventTarget(event, GetApplicationEventTarget())
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        await send(signature: 0x41554454, id: 1) // Show Desktop key down
        record("Command-D does not open clipboard", !clipboard.isOpen, "")
        await send(signature: 0x41554754, id: 999) // Unregistered clipboard ID
        record("Unknown hotkey ID does not open clipboard", !clipboard.isOpen, "")
        await send(signature: 0x41554754, id: 1) // Clipboard's Command-Shift-V
        record("Command-Shift-V opens clipboard", clipboard.isOpen, "")
        await send(signature: 0x41554454, id: 1)
        record("Command-D does not toggle an open clipboard", clipboard.isOpen, "")
        await send(signature: 0x41554754, id: 1)
        record("Command-Shift-V closes clipboard", !clipboard.isOpen, "")
    }

    /// Uses only this test process's windows; never touches the user's windows.
    private static func testDesktopMinimization() async {
        guard AXIsProcessTrusted() else {
            fail("Desktop minimization", "Accessibility permission required")
            return
        }
        NSApp.setActivationPolicy(.regular)
        let windows = (0..<3).map { index -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: 160 + index * 40, y: 200, width: 260, height: 180),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Augment Desktop Test \(index)"
            window.orderFrontRegardless()
            return window
        }
        defer { windows.forEach { $0.close() } }
        windows[2].miniaturize(nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let worker = DesktopWindowWorker()
        let pid = getpid()
        func toggle() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = worker.toggle(pids: [pid])
                    continuation.resume()
                }
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        await toggle()
        record("Desktop minimizes actual windows", windows.allSatisfy { $0.isMiniaturized }, "")
        await toggle()
        record("Desktop restores only its own minimizations",
               !windows[0].isMiniaturized && !windows[1].isMiniaturized && windows[2].isMiniaturized, "")
    }

    private static func testWindowSnapping() async {
        guard let window = await openFinderWindow() else {
            fail("Window snapping", "could not open a Finder window to test with")
            return
        }
        let original = frame(of: window)
        let service = WindowSnappingService()
        service.start(shortcutsJSON: "")
        await press(keyCode: UInt16(kVK_LeftArrow), flags: .maskCommand)
        let snapped = frame(of: window)
        service.stop()

        if let snapped, let screen = NSScreen.main {
            let half = screen.visibleFrame.width / 2
            let ok = abs(snapped.width - half) < 40 && abs(snapped.minX - screen.visibleFrame.minX) < 40
            record("Window snapping ⌘← moves window to left half", ok,
                   "before=\(describe(original)) after=\(describe(snapped)) expectedWidth≈\(Int(half))")
        } else {
            fail("Window snapping", "could not read window frame")
        }
        if let original { setFrame(of: window, to: original) }
    }

    // MARK: - Snap Layouts (⌃⌥Space)

    private static func testSnapLayoutsPicker() async {
        _ = await openFinderWindow()
        let service = SnapLayoutsService()
        service.start()
        let before = visiblePanelCount()
        await press(keyCode: UInt16(kVK_Space), flags: [.maskControl, .maskAlternate])
        let after = visiblePanelCount()
        await press(keyCode: UInt16(kVK_Escape), flags: [])
        let closed = visiblePanelCount()
        service.stop()
        record("Snap Layouts ⌃⌥Space opens picker", after > before, "panels \(before)→\(after)")
        record("Snap Layouts Escape closes picker", closed <= before, "panels after Esc=\(closed)")
    }

    // MARK: - Window switcher (⌥Tab)

    private static func testWindowSwitcher() async {
        _ = await openFinderWindow()
        let service = WindowSwitcherService(windowDiscovery: WindowDiscoveryService())
        service.start()
        let before = visiblePanelCount()
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        await postKey(keyCode: UInt16(kVK_Tab), down: true, flags: .maskAlternate)
        await postKey(keyCode: UInt16(kVK_Tab), down: false, flags: .maskAlternate)
        let shown = visiblePanelCount()
        await postFlagsChanged(flags: [])
        let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let closed = visiblePanelCount()
        service.stop()
        record("Window switcher ⌥Tab shows panel", shown > before, "panels \(before)→\(shown)")
        record("Window switcher releasing ⌥ closes panel", closed <= before,
               "front app \(frontBefore ?? "?")→\(frontAfter ?? "?")")
    }

    // MARK: - Finder cut & paste (⌘X / ⌘V)

    /// The new display / keep-awake / sound / clipboard / screenshot features,
    /// exercised without touching the user's mouse or keyboard.
    private static func testExtras() async {
        // Day/night schedule maths (including a night that crosses midnight).
        func at(_ h: Int, _ m: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
        let ok = BrightnessScheduler.isDay(now: at(12, 0), dayStart: 420, nightStart: 1260)
            && !BrightnessScheduler.isDay(now: at(23, 0), dayStart: 420, nightStart: 1260)
            && !BrightnessScheduler.isDay(now: at(6, 59), dayStart: 420, nightStart: 1260)
            && BrightnessScheduler.isDay(now: at(1, 0), dayStart: 1320, nightStart: 120)
        record("Brightness schedule picks day/night correctly", ok, "")

        // Keep awake: a rule should create real power assertions.
        let prefs = SharedPreferences.shared
        let caffeinate = CaffeinateService.shared
        let savedPower = prefs.awakeOnPower
        prefs.awakeOnPower = true
        try? await Task.sleep(nanoseconds: 500_000_000)
        caffeinate.evaluate()
        let onPower = CaffeinateService.isOnACPower()
        let assertionsOn = pmsetMentionsAugment()
        record("Keep awake on power (rule)", onPower ? (caffeinate.automaticReason != nil && assertionsOn) : caffeinate.automaticReason == nil,
               "onPower=\(onPower) reason=\(caffeinate.automaticReason ?? "nil") pmset=\(assertionsOn)")
        prefs.awakeOnPower = savedPower
        try? await Task.sleep(nanoseconds: 300_000_000)
        caffeinate.evaluate()
        record("Keep awake releases when the rule is off", caffeinate.isKeepingAwake || !pmsetMentionsAugment(),
               "keeping=\(caffeinate.isKeepingAwake) pmset=\(pmsetMentionsAugment())")

        // Timed manual session.
        caffeinate.activate(for: 60)
        let timed = caffeinate.isActive && caffeinate.endDate != nil && pmsetMentionsAugment()
        caffeinate.deactivate()
        record("Timed keep awake starts and stops", timed && !caffeinate.isActive, "")

        // Microphone mute round trip (restored right away).
        let controls = SystemControlsService.shared
        controls.refresh()
        if controls.hasMicrophone {
            let before = controls.isMicMuted
            controls.toggleMicrophone()
            let flipped = controls.isMicMuted != before
            controls.toggleMicrophone()
            record("Microphone mute toggles and restores", flipped && controls.isMicMuted == before, "before=\(before)")
        }

        if #available(macOS 14.2, *) {
            let devices = AudioProcessMixerService.listOutputDevices()
            record("Output devices listed for per-app routing", !devices.isEmpty, devices.map(\.name).joined(separator: ", "))
        }

        // Clipboard pinning keeps the item at the top and survives trimming.
        let history = ClipboardHistoryService.shared
        if let first = history.items.last {
            history.togglePin(first)
            let pinnedTop = history.items.first?.id == first.id && history.items.first?.isPinned == true
            if let again = history.items.first(where: { $0.id == first.id }) { history.togglePin(again) }
            record("Clipboard pin moves item to top", pinnedTop, "")
        }

        // Shelf zip: two files into one archive in Downloads.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AugmentZipTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let f1 = tmp.appendingPathComponent("bir.txt"), f2 = tmp.appendingPathComponent("iki.txt")
        try? "1".write(to: f1, atomically: true, encoding: .utf8)
        try? "2".write(to: f2, atomically: true, encoding: .utf8)
        var archive: URL?
        var done = false
        ShelfActions.zip([f1, f2]) { archive = $0; done = true }
        for _ in 0..<40 where !done { try? await Task.sleep(nanoseconds: 250_000_000) }
        var listing = ""
        if let archive {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            task.arguments = ["-l", archive.path]
            let pipe = Pipe(); task.standardOutput = pipe
            try? task.run(); task.waitUntilExit()
            listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? FileManager.default.removeItem(at: archive)
        }
        try? FileManager.default.removeItem(at: tmp)
        record("Shelf zips files into one archive", listing.contains("bir.txt") && listing.contains("iki.txt"),
               archive?.lastPathComponent ?? "no archive")

        // Screenshot detection: watch a folder, take a real screenshot into it.
        let watcher = ScreenshotShelfWatcher.shared
        let shotDir = FileManager.default.temporaryDirectory.appendingPathComponent("AugmentShotTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        var caught: URL?
        watcher.onScreenshot = { caught = $0 }
        watcher.start(folder: shotDir)
        let shot = shotDir.appendingPathComponent("Ekran Resmi test.png")
        let shotTask = Process()
        shotTask.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shotTask.arguments = ["-x", "-R", "0,0,40,40", shot.path]
        try? shotTask.run(); shotTask.waitUntilExit()
        for _ in 0..<20 where caught == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
        watcher.stop()
        record("New screenshot is detected for the shelf", caught?.lastPathComponent == shot.lastPathComponent,
               "caught=\(caught?.lastPathComponent ?? "nil") xattr=\(ScreenshotShelfWatcher.isScreenshot(shot))")
        let plain = shotDir.appendingPathComponent("not-a-shot.png")
        try? FileManager.default.copyItem(at: shot, to: plain)
        removexattr(plain.path, "com.apple.metadata:kMDItemIsScreenCapture", 0)
        record("Ordinary files are ignored", !ScreenshotShelfWatcher.isScreenshot(plain), "")
        try? FileManager.default.removeItem(at: shotDir)

    }

    private static func pmsetMentionsAugment() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.contains("Augment: keep awake")
    }

    /// A neutral gradient window used behind recordings.
    /// `level` must sit below whatever is being filmed (the notch panel
    /// is just above the menu bar; the quick panel is a pop-up menu).
    private static func makeBackdrop(_ frame: CGRect, level: NSWindow.Level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)) -> NSWindow {
        let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = level
        let gradient = NSImage(size: frame.size, flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.62, alpha: 1),
                                NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.70, alpha: 1),
                                NSColor(calibratedRed: 0.93, green: 0.55, blue: 0.47, alpha: 1)])!
                .draw(in: rect, angle: -60)
            return true
        }
        let imageView = NSImageView(image: gradient)
        imageView.imageScaling = .scaleAxesIndependently
        backdrop.contentView = imageView
        backdrop.orderFrontRegardless()
        return backdrop
    }

    /// Asks the shell (which has Screen Recording) to record `rect` by
    /// writing it to a file, then gives it a moment to start.
    private static func requestRecording(_ name: String, rect: CGRect, seconds: Int) async {
        let dir = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("shots")
        let spec = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)) \(seconds)"
        try? spec.write(to: dir.appendingPathComponent("\(name).rec"), atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    /// Short clips for the README: the notch opening with sample content,
    /// and the quick panel with live stats — over a neutral backdrop.
    /// Needs no permissions: the notch is opened directly and the pointer
    /// is only moved for the picture.
    private static func recordReadmeClips() async {
        if let screen = NSScreen.screens.first(where: { $0.hasNotch }) {
            let notch = screen.notchRect
            // Between the menu bar (hidden behind it) and the notch panel.
            let backdrop = makeBackdrop(CGRect(x: notch.midX - 330, y: screen.frame.maxY - 700, width: 660, height: 700),
                                        level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2))
            let service = NotchService()
            service.start(preferences: SharedPreferences.shared)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let samples = FileManager.default.temporaryDirectory.appendingPathComponent("AugmentSamples")
            let shelf = ["Moodboard.png", "Welcome.png", "Typeface.ttf"].map { samples.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            service.startDemo(
                media: MediaInfo(title: "Midnight City", artist: "M83", appName: "Music",
                                 appIcon: NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app"),
                                 albumArt: nil, isPlaying: true, duration: 243, elapsedTime: 61,
                                 appBundleID: "com.apple.Music", isJSDisabled: false),
                meeting: UpcomingEvent(id: "d", title: "Weekly product sync", start: Date().addingTimeInterval(9 * 60),
                                       end: Date().addingTimeInterval(39 * 60), color: .systemPurple,
                                       joinURL: URL(string: "https://meet.google.com/abc")),
                shelf: shelf)
            let recordRect = CGRect(origin: ScreenGeometry.convertToCG(CGPoint(x: notch.midX - 300, y: screen.frame.maxY)),
                                    size: CGSize(width: 600, height: 640))
            let away = ScreenGeometry.convertToCG(CGPoint(x: notch.midX + 230, y: screen.frame.maxY - 600))
            let top = CGPoint(x: ScreenGeometry.convertToCG(CGPoint(x: notch.midX, y: 0)).x,
                              y: ScreenGeometry.convertToCG(CGPoint(x: 0, y: screen.frame.maxY)).y + 4)
            CGWarpMouseCursorPosition(away)
            await requestRecording("clip-notch", rect: recordRect, seconds: 8)
            func glide(_ from: CGPoint, _ to: CGPoint, steps: Int) async {
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let e = t * t * (3 - 2 * t)
                    CGWarpMouseCursorPosition(CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e))
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            await glide(away, top, steps: 36)
            let vm = service.viewModelForTesting
            withAnimation(.interpolatingSpring(stiffness: 340, damping: 30)) { vm.isExpanded = true }
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            let inside = ScreenGeometry.convertToCG(CGPoint(x: notch.midX + 60, y: screen.frame.maxY - 330))
            await glide(top, inside, steps: 45)
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.easeInOut(duration: 0.15)) { vm.lowerTab = .note }
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeInOut(duration: 0.15)) { vm.lowerTab = .files }
            try? await Task.sleep(nanoseconds: 700_000_000)
            await glide(inside, away, steps: 30)
            withAnimation(.interpolatingSpring(stiffness: 340, damping: 32)) { vm.isExpanded = false }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            service.stop()
            backdrop.orderOut(nil)
            lines.append("INFO  notch clip done")
        }

        if let screen = NSScreen.main {
            let backdrop = makeBackdrop(CGRect(x: screen.frame.maxX - 900, y: screen.frame.maxY - 1100, width: 900, height: 1100))
            let anchor = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            anchor.button?.image = NSImage(systemSymbolName: "square", accessibilityDescription: nil)
            try? await Task.sleep(nanoseconds: 800_000_000)
            SystemControlsService.shared.outputDeviceNameOverride = "MacBook Pro Speakers"
            QuickPanelController.shared.toggle(below: anchor.button)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            lines.append("INFO  panel open=\(QuickPanelController.shared.isOpen)"); flushLog()
            try? await Task.sleep(nanoseconds: 7_000_000_000) // let the graph fill in
            if let panel = NSApp.windows.first(where: { $0.isVisible && $0.level == .popUpMenu && $0.frame.width >= 300 }) {
                let f = panel.frame.insetBy(dx: -30, dy: -30)
                let rect = CGRect(origin: ScreenGeometry.convertToCG(CGPoint(x: f.minX, y: f.maxY)), size: f.size)
                await requestRecording("clip-panel", rect: rect, seconds: 6)
                try? await Task.sleep(nanoseconds: 6_500_000_000)
                lines.append("INFO  panel clip done")
            }
            QuickPanelController.shared.close()
            NSStatusBar.system.removeStatusItem(anchor)
            backdrop.orderOut(nil)
        }
    }

    /// The quick panel on real glass, over a neutral gradient backdrop (so
    /// nothing personal from the desktop shows through), for the README.
    private static func captureReadmeQuickPanel() async {
        guard let screen = NSScreen.main else { return }
        let backdropFrame = CGRect(x: screen.frame.maxX - 900, y: screen.frame.maxY - 1100, width: 900, height: 1100)
        let backdrop = NSWindow(contentRect: backdropFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        let gradient = NSImage(size: backdropFrame.size, flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.62, alpha: 1),
                                NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.70, alpha: 1),
                                NSColor(calibratedRed: 0.93, green: 0.55, blue: 0.47, alpha: 1)])!
                .draw(in: rect, angle: -60)
            return true
        }
        let imageView = NSImageView(image: gradient)
        imageView.imageScaling = .scaleAxesIndependently
        backdrop.contentView = imageView
        backdrop.orderFrontRegardless()

        let anchor = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        anchor.button?.image = NSImage(systemSymbolName: "square", accessibilityDescription: nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        SystemControlsService.shared.outputDeviceNameOverride = "MacBook Pro Speakers"
        QuickPanelController.shared.toggle(below: anchor.button)
        try? await Task.sleep(nanoseconds: 4_000_000_000) // let stats fill in
        let dir = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("shots")
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0.level == .popUpMenu }) {
            let f = panel.frame.insetBy(dx: -36, dy: -36)
            let topLeft = ScreenGeometry.convertToCG(CGPoint(x: f.minX, y: f.maxY))
            if let image = CGWindowListCreateImage(CGRect(origin: topLeft, size: f.size), .optionOnScreenBelowWindow,
                                                   CGWindowID(0), [.bestResolution]) ?? nil,
               let composite = CGWindowListCreateImage(CGRect(origin: topLeft, size: f.size), .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) {
                _ = image
                try? NSBitmapImageRep(cgImage: composite).representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("readme-quick-panel.png"))
                lines.append("INFO  captured readme quick panel \(composite.width)x\(composite.height)")
            }
        }
        QuickPanelController.shared.close()
        NSStatusBar.system.removeStatusItem(anchor)
        backdrop.orderOut(nil)
    }

    /// Renders the open notch into PNGs without touching the cursor or
    /// showing anything on screen — safe to run while the user works.
    private static func renderNotchOffscreen() async {
        let screen = NSScreen.screens.first(where: { $0.hasNotch }) ?? NSScreen.main!
        let dir = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SystemControlsService.shared.refresh()
        for (name, tab, playing) in [("notch-render-files", NotchLowerTab.files, true),
                                     ("notch-render-note", NotchLowerTab.note, false),
                                     ("notch-render-clipboard", NotchLowerTab.clipboard, true)] {
            let vm = NotchViewModel()
            vm.showCaffeinate = true
            vm.showProductivity = true
            vm.clipboardHistoryEnabled = true
            vm.lowerTab = tab
            vm.battery = BatteryInfo.current()
            vm.mediaInfo = playing ? MediaInfo(title: "Midnight City", artist: "M83", appName: "Music",
                                               appIcon: NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app"),
                                               albumArt: nil, isPlaying: true, duration: 278, elapsedTime: 100,
                                               appBundleID: "com.apple.Music", isJSDisabled: false) : nil
            if name == "notch-render-files" {
                // Neutral English sample files for screenshots.
                let shots = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("shots")
                let samples = FileManager.default.temporaryDirectory.appendingPathComponent("AugmentSamples")
                try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
                let pairs: [(String, URL)] = [
                    ("Moodboard.png", shots.appendingPathComponent("tour-2.png")),
                    ("Welcome.png", shots.appendingPathComponent("tour-0.png")),
                    ("Typeface.ttf", URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")),
                ]
                vm.shelfItems = pairs.compactMap { name, source in
                    let dest = samples.appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(at: source, to: dest) }
                    return FileManager.default.fileExists(atPath: dest.path) ? ShelfItem(url: dest) : nil
                }
                vm.nextMeeting = UpcomingEvent(id: "t", title: "Weekly product sync", start: Date().addingTimeInterval(4 * 60),
                                               end: Date().addingTimeInterval(34 * 60), color: .systemPurple,
                                               joinURL: URL(string: "https://meet.google.com/abc"))
                vm.meetingIsAlert = true
            }
            vm.isExpanded = true
            let size = CGSize(width: 420, height: 580)
            let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.backgroundColor = NSColor(white: 0.35, alpha: 1)
            let host = NSHostingView(rootView: NotchContentView(viewModel: vm, notchRect: screen.notchRect, hasNotch: screen.hasNotch))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
                lines.append("INFO  rendered \(name)")
            }
            window.orderOut(nil)
        }

        // Quick panel and clipboard panel, same off-screen approach.
        DisplayBrightnessService.shared.refresh()
        for (name, view, size, dark) in [("quick-light", QuickPanelController.previewView(), CGSize(width: 340, height: 900), false),
                                         ("quick-dark", QuickPanelController.previewView(), CGSize(width: 340, height: 900), true),
                                         ("clipboard-light", ClipboardPanelController.shared.previewView(), CGSize(width: 440, height: 460), false),
                                         ("clipboard-dark", ClipboardPanelController.shared.previewView(), CGSize(width: 440, height: 460), true)] {
            let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            // Roughly what the glass looks like over a typical desktop.
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.backgroundColor = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)
            let host = NSHostingView(rootView: view)
            host.appearance = window.appearance
            host.frame = CGRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
                lines.append("INFO  rendered \(name)")
            }
            window.orderOut(nil)
        }
    }

    /// Right-clicks an empty spot in a Finder window and reads the context
    /// menu's items through Accessibility (does the extension add its items?).
    private static func readFinderContextMenu() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AugmentMenuTest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "x".write(to: dir.appendingPathComponent("dosya.txt"), atomically: true, encoding: .utf8)
        _ = runScript("""
        tell application "Finder"
            activate
            open (POSIX file "\(dir.path)" as alias)
            delay 0.8
            set current view of front window to icon view
            set bounds of front window to {300, 200, 1000, 700}
        end tell
        """)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        lines.append("INFO  extension enabled=\(FinderExtensionStatus.isEnabled)")
        let point = CGPoint(x: 900, y: 640) // empty area near the bottom-right of the window
        moveCursor(to: point)
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if let image = CGWindowListCreateImage(CGRect(x: 250, y: 150, width: 1000, height: 800), .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) {
            let shots = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("shots")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("finder-menu.png"))
        }
        var titles: [String] = []
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            let app = AXUIElementCreateApplication(finder.processIdentifier)
            func collect(_ element: AXUIElement, depth: Int) {
                guard depth < 6 else { return }
                var role: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                if (role as? String) == kAXMenuItemRole {
                    var t: AnyObject?
                    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &t)
                    if let t = t as? String, !t.isEmpty { titles.append(t) }
                }
                var children: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                for c in (children as? [AXUIElement]) ?? [] where (role as? String) != kAXMenuItemRole || depth == 0 {
                    collect(c, depth: depth + 1)
                }
            }
            var children: AnyObject?
            AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children)
            for c in (children as? [AXUIElement]) ?? [] {
                var role: AnyObject?
                AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &role)
                if (role as? String) == kAXMenuRole { collect(c, depth: 0) }
            }
        }
        lines.append("INFO  context menu items: \(titles)")
        await postKey(keyCode: UInt16(kVK_Escape), down: true, flags: [])
        await postKey(keyCode: UInt16(kVK_Escape), down: false, flags: [])
        _ = runScript("tell application \"Finder\" to close front window")
        try? FileManager.default.removeItem(at: dir)
    }

    private static func snapFrontFinderWindow(_ name: String) {
        guard let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])?
            .first(where: { ($0[kCGWindowOwnerName as String] as? String) == "Finder" && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])
        else { return }
        let dir = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("shots")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private static func testFileCutPaste() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AugmentFuncTest-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let file = src.appendingPathComponent("cut-me.txt")
        try? "augment".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = FileCutPasteService()
        service.start()
        _ = runScript("""
        tell application "Finder"
            activate
            open (POSIX file "\(src.path)" as alias)
            delay 0.5
            select (POSIX file "\(file.path)" as alias)
        end tell
        """)
        try? await Task.sleep(nanoseconds: 800_000_000)
        await press(keyCode: UInt16(kVK_ANSI_X), flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let published = (AppGroup.copySuiteValue(forKey: AppGroupKey.fileCutPaths) as? [String]) ?? []
        record("Finder ⌘X shares the cut item for badging",
               published.contains { $0.hasSuffix("/src/cut-me.txt") }, "published=\(published)")
        snapFrontFinderWindow("filecut-badge")
        _ = runScript("""
        tell application "Finder"
            activate
            set target of front window to (POSIX file "\(dst.path)" as alias)
        end tell
        """)
        try? await Task.sleep(nanoseconds: 800_000_000)
        lines.append("INFO  before ⌘V front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        await press(keyCode: UInt16(kVK_ANSI_V), flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let moved = FileManager.default.fileExists(atPath: dst.appendingPathComponent("cut-me.txt").path)
        let stillInSource = FileManager.default.fileExists(atPath: file.path)
        record("Finder ⌘X then ⌘V moves the file", moved && !stillInSource,
               "inDestination=\(moved) stillInSource=\(stillInSource)")

        await press(keyCode: UInt16(kVK_ANSI_Z), flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let back = FileManager.default.fileExists(atPath: file.path)
        let goneFromDest = !FileManager.default.fileExists(atPath: dst.appendingPathComponent("cut-me.txt").path)
        record("⌘Z after paste moves the file back", back && goneFromDest, "inSource=\(back) goneFromDest=\(goneFromDest)")
        service.stop()
        _ = runScript("tell application \"Finder\" to close front window")
    }

    // MARK: - Clipboard history

    private static func testClipboardHistory() async {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let marker = "augment-functest-\(UUID().uuidString.prefix(8))"
        let service = ClipboardHistoryService.shared
        service.start()
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let captured = service.items.first?.value == marker
        if let item = service.items.first(where: { $0.value == marker }) { service.remove(item) }
        service.stop()
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        record("Clipboard history captures a copy", captured, "")
    }

    // MARK: - Dock hover

    private static func testDockHover() async {
        guard let (bundleID, point) = dockIconCenter(preferring: "com.apple.finder") else {
            fail("Dock hover", "could not locate a Dock icon via Accessibility")
            return
        }
        let original = NSEvent.mouseLocation
        let dock = DockInteractionService()
        var hovered: String?
        dock.onEvent = { event in
            if case .hoverChanged(let id) = event, let id { hovered = id }
        }
        let result = dock.start()
        CGWarpMouseCursorPosition(CGPoint(x: point.x - 3, y: point.y - 3))
        try? await Task.sleep(nanoseconds: 200_000_000)
        postMouseMove(to: point)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        dock.stop()
        let cgOriginal = ScreenGeometry.convertToCG(original)
        CGWarpMouseCursorPosition(cgOriginal)

        record("Dock hover over \(bundleID) is detected", hovered == bundleID,
               "start=\(result) detected=\(hovered ?? "nothing")")
        let snapshots = WindowDiscoveryService().windowsWithThumbnails(
            forBundleIdentifier: bundleID, includeMinimizedWindows: true)
        record("Dock preview finds \(bundleID) windows with images",
               !snapshots.isEmpty && snapshots.allSatisfy { $0.thumbnail != nil },
               "windows=\(snapshots.count) withImage=\(snapshots.filter { $0.thumbnail != nil }.count)")
    }

    // MARK: - Dock preview for a minimized app

    /// Launches Calculator, minimizes its window, and checks the Dock preview
    /// still lists that window with an image. Quits Calculator afterwards.
    private static func testDockPreviewMinimized() async {
        let bundleID = "com.apple.calculator"
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calculator.app"), configuration: config)
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            fail("Dock preview (minimized)", "Calculator did not launch"); return
        }
        let discovery = WindowDiscoveryService()
        let before = discovery.windowsWithThumbnails(forBundleIdentifier: bundleID, includeMinimizedWindows: true)
        lines.append("INFO  calculator before minimize: windows=\(before.count) withImage=\(before.filter { $0.thumbnail != nil }.count)")

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)
        let axWindows = (windowsValue as? [AXUIElement]) ?? []
        for w in axWindows { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        for w in axWindows {
            var sub: AnyObject?, minV: AnyObject?, num: AnyObject?, title: AnyObject?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &sub)
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minV)
            let numStatus = AXUIElementCopyAttributeValue(w, "AXWindowNumber" as CFString, &num)
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
            lines.append("INFO  ax window: subrole=\(sub as? String ?? "nil") minimized=\(minV as? Bool ?? false) number=\(num.map { "\($0)" } ?? "nil")(status \(numStatus.rawValue)) title=\(title as? String ?? "nil") frame=\(describe(frame(of: w)))")
        }
        if let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for e in info where (e[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier {
                lines.append("INFO  cg window: id=\(e[kCGWindowNumber as String] ?? "-") layer=\(e[kCGWindowLayer as String] ?? "-") onscreen=\(e[kCGWindowIsOnscreen as String] ?? "-") bounds=\(e[kCGWindowBounds as String] ?? "-") name=\(e[kCGWindowName as String] ?? "-")")
            }
        }
        let after = discovery.windowsWithThumbnails(forBundleIdentifier: bundleID, includeMinimizedWindows: true)
        let fresh = WindowDiscoveryService().windowsWithThumbnails(forBundleIdentifier: bundleID, includeMinimizedWindows: true)
        record("Dock preview lists a minimized window", !after.isEmpty,
               "axWindows=\(axWindows.count) windows=\(after.count) titles=\(after.map { $0.window.title ?? "-" })")
        record("Minimized window has an image (same session)", after.contains { $0.thumbnail != nil },
               "withImage=\(after.filter { $0.thumbnail != nil }.count)")
        // macOS stops rendering minimized windows, so one Augment never saw on
        // screen can't have an image; it must still appear as an icon card.
        record("Never-seen minimized window still appears (icon card)", !fresh.isEmpty && fresh.allSatisfy(\.window.isMinimized),
               "windows=\(fresh.count) minimizedFlag=\(fresh.map(\.window.isMinimized))")

        await capturePreviewPanel(snapshots: after, app: app, name: "dock-min")
        await capturePreviewPanel(snapshots: fresh, app: app, name: "dock-min-fresh")

        if !wasRunning { app.terminate() } else {
            for w in axWindows { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private static func capturePreviewPanel(snapshots: [WindowSnapshot], app: NSRunningApplication, name: String) async {
        let panel = DockPreviewPanelController()
        panel.show(snapshots: snapshots, bundleID: app.bundleIdentifier ?? "", displayName: app.localizedName ?? "", appIcon: app.icon)
        try? await Task.sleep(nanoseconds: 350_000_000)
        lines.append("INFO  \(name): visible panels=\(NSApp.windows.filter { $0 is NSPanel && $0.isVisible }.count)")
        let dir = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let window = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("\(name).png"))
            lines.append("INFO  captured \(name) \(image.width)x\(image.height)")
        }
        panel.hideImmediately()
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - Media play/pause

    private static func testMediaPlayPause() async {
        let manager = MediaManager.shared
        manager.start()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let source = manager.availableSources.first(where: \.isPlaying) else {
            record("Media play/pause", false, "nothing is playing — start YouTube or Music to test")
            manager.stop()
            return
        }
        MediaManager.sendCommand("playpause", bundleID: source.appBundleID, fallbackAppName: source.appName)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        let paused = manager.availableSources.first { $0.appBundleID == source.appBundleID }?.isPlaying == false
        MediaManager.sendCommand("playpause", bundleID: source.appBundleID, fallbackAppName: source.appName)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        let resumed = manager.availableSources.first { $0.appBundleID == source.appBundleID }?.isPlaying == true
        manager.stop()
        record("Media pause on \(source.appName)", paused, "")
        record("Media resume on \(source.appName)", resumed, "")
    }

    // MARK: - Caffeinate / menu bar

    private static func testCaffeinate() {
        let service = CaffeinateService.shared
        service.activate()
        let active = service.isActive
        service.deactivate()
        record("Keep-awake assertion toggles", active && !service.isActive, "")
    }


    // MARK: - Helpers

    private static func openFinderWindow() async -> AXUIElement? {
        _ = runScript("""
        tell application "Finder"
            activate
            if (count of windows) is 0 then make new Finder window
        end tell
        """)
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return nil }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success
        else { return nil }
        return AXElementCoercion.element(value)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var pos: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let p = AXElementCoercion.point(from: pos), let s = AXElementCoercion.size(from: size)
        else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func setFrame(of window: AXUIElement, to rect: CGRect) {
        var origin = rect.origin, size = rect.size
        if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
    }

    private static func describe(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }

    private static func press(keyCode: UInt16, flags: CGEventFlags) async {
        await postKey(keyCode: keyCode, down: true, flags: flags)
        await postKey(keyCode: keyCode, down: false, flags: flags)
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    private static func postKey(keyCode: UInt16, down: Bool, flags: CGEventFlags) async {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private static func postFlagsChanged(flags: CGEventFlags) async {
        let event = CGEvent(source: nil)
        event?.type = .flagsChanged
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    private static func postMouseMove(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func visiblePanelCount() -> Int {
        NSApp.windows.filter { $0.isVisible && $0 is NSPanel }.count
    }

    private static func dockIconCenter(preferring bundleID: String) -> (String, CGPoint)? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let lists = children as? [AXUIElement], let list = lists.first else { return nil }
        var items: AnyObject?
        guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items) == .success,
              let icons = items as? [AXUIElement] else { return nil }
        for icon in icons {
            var urlValue: AnyObject?
            AXUIElementCopyAttributeValue(icon, kAXURLAttribute as CFString, &urlValue)
            guard let url = urlValue as? URL, Bundle(url: url)?.bundleIdentifier == bundleID,
                  let f = frame(of: icon) else { continue }
            return (bundleID, CGPoint(x: f.midX, y: f.midY))
        }
        return nil
    }

    @discardableResult
    private static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }

    private static func record(_ name: String, _ ok: Bool, _ detail: String) {
        lines.append("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    private static func fail(_ name: String, _ detail: String) { record(name, false, detail) }

    private static func finish() {
        let text = lines.joined(separator: "\n") + "\n"
        print(text)
        let url = AppGroup.sharedDirectory.deletingLastPathComponent().appendingPathComponent("functest.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        fflush(stdout)
        exit(0)
    }
}

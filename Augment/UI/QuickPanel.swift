import AppKit
import SwiftUI

/// The glass panel under Augment's menu bar icon: every screen's
/// brightness, sound (with per-app volumes when the mixer is on) and keep
/// awake — the things worth reaching in one click. Right-clicking the icon
/// still shows Augment's regular menu.
@MainActor
final class QuickPanelController {
    static let shared = QuickPanelController()
    static let openSettingsNotification = Notification.Name("augment.quickPanel.openSettings")
    static let width: CGFloat = 340

    private(set) var isOpen = false
    private var panel: QuickPanelWindow?
    private var monitors: [Any] = []

    private init() {}

    func toggle(below button: NSStatusBarButton?) {
        isOpen ? close() : open(below: button)
    }

    func open(below button: NSStatusBarButton?) {
        DisplayBrightnessService.shared.refresh()
        SystemControlsService.shared.refresh()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? CGSize(width: Self.width, height: 400)

        let anchor = button?.window?.frame ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = visible.maxY - 6
        panel.setFrame(CGRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        isOpen = true
        installMonitors()
    }

    func close(_ reason: String = #function, line: Int = #line) {
        guard isOpen else { return }
        if CommandLine.arguments.contains("--functest") { NSLog("Augment: quick panel closed by %@:%d", reason, line) }
        isOpen = false
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
    }

    /// Keeps the panel's top edge pinned while its content grows/shrinks
    /// (e.g. apps starting to play in the mixer list).
    fileprivate func contentSizeChanged() {
        guard isOpen, let panel, let size = panel.contentView?.fittingSize else { return }
        let top = panel.frame.maxY
        panel.setFrame(CGRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// For off-screen rendering in tests.
    static func previewView() -> AnyView { AnyView(QuickPanelView()) }

    private func makePanel() -> QuickPanelWindow {
        let panel = QuickPanelWindow(
            contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws its own edge; a window shadow would outline the
        // transparent rectangular corners.
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: QuickPanelView())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    private func installMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.close("outside click") }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            self?.close()
            return nil
        }) { monitors.append(m) }
    }
}

private final class QuickPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - View

private struct QuickPanelView: View {
    @ObservedObject private var displays = DisplayBrightnessService.shared
    @ObservedObject private var controls = SystemControlsService.shared
    @ObservedObject private var caffeinate = CaffeinateService.shared
    @ObservedObject private var preferences = SharedPreferences.shared
    @ObservedObject private var meetings = MeetingsService.shared
    @State private var allLevel: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if preferences.quickPanelStats {
                module(title: Localizer.string("stats.title"), icon: "cpu") {
                    SystemStatsModule()
                }
            }
            if preferences.quickPanelMeetings && preferences.meetingsEnabled && !meetings.events.isEmpty {
                module(title: Localizer.string("meetings.today"), icon: "calendar") {
                    ForEach(meetings.events.prefix(3)) { event in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.color)).frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(NotchContentView.meetingTime(event))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let url = event.joinURL {
                                Button(Localizer.string("meetings.join")) {
                                    QuickPanelController.shared.close()
                                    NSWorkspace.shared.open(url)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            if preferences.quickPanelDisplays {
            module(title: Localizer.string("quick.displays"), icon: "sun.max") {
                if displays.displays.count > 1 {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Localizer.string("quick.all_displays")).font(.system(size: 12, weight: .medium))
                        QuickSlider(value: allLevel ?? displays.displays.map(\.brightness).reduce(0, +) / Double(displays.displays.count),
                                    icon: "sun.max.fill") {
                            allLevel = $0
                            displays.setAll($0)
                        }
                    }
                }
                ForEach(displays.displays) { display in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(display.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            if display.method == .software {
                                Text(Localizer.string("displays.method_software"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        QuickSlider(value: display.brightness,
                                    icon: display.brightness < 0.4 ? "sun.min.fill" : "sun.max.fill") {
                            displays.setBrightness($0, for: display.id)
                        }
                    }
                }
            }
            }
            if preferences.quickPanelSound || preferences.quickPanelMic {
            module(title: Localizer.string("quick.sound"), icon: "speaker.wave.2") {
                if preferences.quickPanelSound {
                VStack(alignment: .leading, spacing: 5) {
                    if !controls.outputDeviceName.isEmpty {
                        Text(controls.outputDeviceName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    QuickSlider(value: controls.isMuted ? 0 : controls.volume, icon: volumeIcon,
                                onIconTap: { controls.toggleMute() }) {
                        controls.setVolume($0)
                    }
                }
                }
                if preferences.quickPanelMic && controls.hasMicrophone {
                    Button {
                        controls.toggleMicrophone()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: controls.isMicMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(controls.isMicMuted ? Color.white : Color.primary)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(controls.isMicMuted ? Color.red : Color.primary.opacity(0.1)))
                            Text(Localizer.string(controls.isMicMuted ? "quick.mic_off" : "quick.mic_on"))
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if preferences.quickPanelSound { mixerSection }
            }
            }
            if preferences.quickPanelAwake {
                module(title: Localizer.string("page.awake"), icon: "cup.and.saucer") {
                    awakeSection
                }
            }
            if preferences.showDesktopEnabled && ShowDesktopService.shared.isSupported {
                Button { ShowDesktopService.shared.toggle() } label: {
                    HStack {
                        Label(Localizer.string("desktop.action"), systemImage: "menubar.dock.rectangle")
                        Spacer()
                        Text("⌃⌥D").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Localizer.string("desktop.description"))
            }
            footer
        }
        .padding(12)
        .frame(width: QuickPanelController.width)
        .modifier(QuickPanelBackground())
        .onChange(of: displays.displays.count) { _ in QuickPanelController.shared.contentSizeChanged() }
    }

    private var header: some View {
        HStack {
            Text("Augment").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Localizer.string("menu.settings"))
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var mixerSection: some View {
        if #available(macOS 14.2, *), preferences.volumeMixerEnabled {
            QuickMixerList()
        } else {
            Button {
                openSettings(.sound)
            } label: {
                HStack(spacing: 4) {
                    Text(Localizer.string("quick.enable_mixer"))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var awakeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Localizer.string(caffeinate.isActive ? "notch.awake_on" : "quick.awake_off_title"))
                        .font(.system(size: 12, weight: .medium))
                    if !caffeinate.isActive, let reason = caffeinate.automaticReason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(.green)
                    }
                    if caffeinate.isActive {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(remainingText)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { caffeinate.isActive },
                                         set: { $0 ? caffeinate.activate(for: nil) : caffeinate.deactivate() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(.orange)
            }
            HStack(spacing: 6) {
                ForEach(Array(CaffeinateService.presets.enumerated()), id: \.offset) { _, preset in
                    let selected = caffeinate.isActive && caffeinate.selectedPreset == preset.map { Int($0) }
                    Button {
                        caffeinate.activate(for: preset)
                    } label: {
                        Text(shortTitle(preset))
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .foregroundStyle(selected ? Color.black : Color.primary)
                            .background(
                                Capsule().fill(selected ? Color.orange : Color.primary.opacity(0.08))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(Localizer.string("menu.quit")) { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private func module<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.6))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private var volumeIcon: String {
        if controls.isMuted || controls.volume == 0 { return "speaker.slash.fill" }
        if controls.volume < 0.33 { return "speaker.wave.1.fill" }
        if controls.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var remainingText: String {
        guard let end = caffeinate.endDate else { return Localizer.string("notch.awake_indefinite") }
        let minutes = max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
        return String(format: Localizer.string("quick.awake_remaining"),
                      minutes >= 60 ? "\(minutes / 60)\(Localizer.string("notch.hour_short")) \(minutes % 60)\(Localizer.string("notch.minute_short"))"
                                    : "\(minutes)\(Localizer.string("notch.minute_short"))")
    }

    private func shortTitle(_ preset: TimeInterval?) -> String {
        guard let preset else { return "∞" }
        let minutes = Int(preset / 60)
        return minutes >= 60 ? "\(minutes / 60)\(Localizer.string("notch.hour_short"))" : "\(minutes)\(Localizer.string("notch.minute_short"))"
    }

    private func openSettings(_ tab: SettingsTab?) {
        QuickPanelController.shared.close()
        NotificationCenter.default.post(name: QuickPanelController.openSettingsNotification, object: tab?.rawValue)
    }
}

@available(macOS 14.2, *)
private struct QuickMixerList: View {
    @ObservedObject private var mixer = AudioProcessMixerService.shared

    var body: some View {
        let apps = mixer.apps.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }.prefix(6)
        if apps.isEmpty {
            Text(Localizer.string("mixer.no_apps"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 6) {
                ForEach(Array(apps)) { app in
                    HStack(spacing: 8) {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(app.name).font(.system(size: 11)).lineLimit(1).frame(width: 78, alignment: .leading)
                        QuickSlider(value: app.isMuted ? 0 : min(app.volume, 1),
                                    icon: app.isMuted ? "speaker.slash.fill" : "speaker.fill",
                                    height: 22,
                                    onIconTap: { mixer.setMuted(!app.isMuted, forPID: app.id) }) {
                            mixer.setVolume($0, forPID: app.id)
                        }
                        // Where this app plays: default output or a specific device.
                        Menu {
                            Button {
                                mixer.setOutputDevice(nil, forPID: app.id)
                            } label: {
                                if app.outputDeviceUID == nil { Label(Localizer.string("mixer.default_output"), systemImage: "checkmark") }
                                else { Text(Localizer.string("mixer.default_output")) }
                            }
                            Divider()
                            ForEach(mixer.outputDevices) { device in
                                Button {
                                    mixer.setOutputDevice(device.uid, forPID: app.id)
                                } label: {
                                    if app.outputDeviceUID == device.uid { Label(device.name, systemImage: "checkmark") }
                                    else { Text(device.name) }
                                }
                            }
                        } label: {
                            Image(systemName: app.outputDeviceUID == nil ? "hifispeaker" : "hifispeaker.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(app.outputDeviceUID == nil ? Color.secondary : Color.accentColor)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(outputName(for: app))
                    }
                }
            }
            .onChange(of: apps.count) { _ in QuickPanelController.shared.contentSizeChanged() }
        }
    }
}

@available(macOS 14.2, *)
private extension QuickMixerList {
    func outputName(for app: MixerAppInfo) -> String {
        guard let uid = app.outputDeviceUID else { return Localizer.string("mixer.default_output") }
        return mixer.outputDevices.first { $0.uid == uid }?.name ?? Localizer.string("mixer.default_output")
    }
}

/// CPU, memory, network and temperature as four compact tiles.
private struct SystemStatsModule: View {
    @ObservedObject private var stats = SystemStatsService.shared

    var body: some View {
        let s = stats.snapshot
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            tile(Localizer.string("stats.cpu"), value: "\(Int((s.cpu * 100).rounded()))%", number: s.cpu) {
                ScrollingSparkline(values: s.cpuHistory, updatedAt: s.updatedAt).frame(height: 18)
            }
            tile(Localizer.string("stats.memory"),
                 value: "\(Self.gb(s.memoryUsed)) / \(Self.gb(s.memoryTotal)) GB", number: Double(s.memoryUsed)) {
                LevelBar(fraction: s.memoryTotal > 0 ? Double(s.memoryUsed) / Double(s.memoryTotal) : 0)
            }
            tile(Localizer.string("stats.network"), value: nil, number: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    rateRow("arrow.down", s.downBytesPerSecond)
                    rateRow("arrow.up", s.upBytesPerSecond)
                }
            }
            tile(Localizer.string("stats.temperature"), value: s.temperature.map { "\(Int($0.rounded()))°C" } ?? Self.thermal(s.thermalState),
                 number: s.temperature ?? 0) {
                LevelBar(fraction: s.temperature.map { min(max(($0 - 30) / 70, 0), 1) } ?? Self.thermalFraction(s.thermalState),
                         tint: (s.temperature ?? 0) > 85 || s.thermalState.rawValue >= 2 ? .orange : .green)
            }
        }
        // Every change eases in over most of the 1 s sample interval, so
        // bars and numbers glide instead of jumping.
        .animation(.easeInOut(duration: 0.8), value: s)
        .onAppear { stats.retain() }
        .onDisappear { stats.release() }
    }

    private func rateRow(_ icon: String, _ rate: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.primary.opacity(0.55))
            Text(Self.rate(rate)).modifier(RollingNumber(value: rate))
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
    }

    private func tile<Content: View>(_ title: String, value: String?, number: Double, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .modifier(RollingNumber(value: number))
            }
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    static func gb(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_073_741_824) }

    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1 { return "0 KB/s" }
        if kb < 1024 { return "\(Int(kb)) KB/s" }
        return String(format: "%.1f MB/s", kb / 1024)
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return Localizer.string("stats.thermal_nominal")
        case .fair: return Localizer.string("stats.thermal_fair")
        case .serious: return Localizer.string("stats.thermal_serious")
        case .critical: return Localizer.string("stats.thermal_critical")
        @unknown default: return "—"
        }
    }

    static func thermalFraction(_ state: ProcessInfo.ThermalState) -> Double {
        [0.2, 0.5, 0.8, 1.0][min(max(state.rawValue, 0), 3)]
    }
}

/// Digits roll to their new value (macOS 14+), like Control Center.
private struct RollingNumber: ViewModifier {
    let value: Double
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.contentTransition(.numericText(value: value))
        } else {
            content
        }
    }
}

/// A smooth, filled CPU graph that scrolls continuously between samples
/// instead of redrawing in one-second steps.
private struct ScrollingSparkline: View {
    let values: [Double]
    let updatedAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Canvas { ctx, size in
                guard values.count > 1 else { return }
                let visible = 30
                let step = size.width / CGFloat(visible - 1)
                let progress = min(max(context.date.timeIntervalSince(updatedAt) / 1.0, 0), 1)
                let shift = step * CGFloat(1 - progress)
                let points = values.suffix(visible + 1).enumerated().map { i, v -> CGPoint in
                    let count = min(values.count, visible + 1)
                    let x = size.width - CGFloat(count - 1 - i) * step + shift
                    return CGPoint(x: x, y: size.height - CGFloat(min(max(v, 0), 1)) * (size.height - 2) - 1)
                }
                var line = Path()
                line.move(to: points[0])
                for i in 1..<points.count {
                    let a = points[i - 1], b = points[i]
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    line.addQuadCurve(to: mid, control: a)
                    if i == points.count - 1 { line.addQuadCurve(to: b, control: b) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: points.last!.x, y: size.height))
                fill.addLine(to: CGPoint(x: points.first!.x, y: size.height))
                fill.closeSubpath()
                ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private struct LevelBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

/// Control Center–style slider for the quick panel.
private struct QuickSlider: View {
    @Environment(\.colorScheme) private var scheme
    let value: Double
    let icon: String
    var height: CGFloat = 28
    var onIconTap: (() -> Void)? = nil
    let onChange: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = dragValue ?? value
            ZStack(alignment: .leading) {
                // Control Center style in both appearances: a darker track in
                // light mode so the white fill never blends into the glass.
                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.14 : 0.2))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(geo.size.height, geo.size.width * shown))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.18), radius: 1.5, y: 0.5)
                Image(systemName: icon)
                    .font(.system(size: height * 0.42, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .frame(width: geo.size.height)
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(scheme == .dark ? 0.1 : 0.12), lineWidth: 0.5))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if onIconTap != nil, g.startLocation.x < geo.size.height, abs(g.translation.width) < 3 { return }
                        let v = min(max(g.location.x / geo.size.width, 0), 1)
                        dragValue = v
                        onChange(v)
                    }
                    .onEnded { g in
                        defer { dragValue = nil }
                        if let onIconTap, g.startLocation.x < geo.size.height, abs(g.translation.width) < 3 {
                            onIconTap()
                        }
                    }
            )
        }
        .frame(height: height)
    }
}

private struct QuickPanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

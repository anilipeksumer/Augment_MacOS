import AppKit
import Combine
import Foundation
import IOKit.ps
import Quartz
import SwiftUI
@preconcurrency import UserNotifications

// MARK: - Notch detection helpers

extension NSScreen {
    var hasNotch: Bool {
        if #available(macOS 12.0, *) {
            return safeAreaInsets.top > 0
        }
        return false
    }

    var notchRect: CGRect {
        let screenFrame = frame
        let topInset: CGFloat
        if #available(macOS 12.0, *) {
            topInset = safeAreaInsets.top > 0 ? safeAreaInsets.top : 24
        } else {
            topInset = 24
        }

        if #available(macOS 12.0, *),
           let leftArea = auxiliaryTopLeftArea,
           let rightArea = auxiliaryTopRightArea {
            let notchMinX = screenFrame.minX + leftArea.width
            let notchMaxX = screenFrame.maxX - rightArea.width
            return CGRect(
                x: notchMinX,
                y: screenFrame.maxY - topInset,
                width: notchMaxX - notchMinX,
                height: topInset
            )
        }

        let estimatedWidth: CGFloat = 188
        return CGRect(
            x: screenFrame.midX - estimatedWidth / 2,
            y: screenFrame.maxY - topInset,
            width: estimatedWidth,
            height: topInset
        )
    }
}

// MARK: - Battery Helper

extension BatteryInfo {
    static func current() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?
                .takeUnretainedValue() as? [String: Any]
        else { return nil }

        let level = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
        let source = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let isPluggedIn = source == kIOPSACPowerValue
        return BatteryInfo(level: level, isCharging: isCharging, isPluggedIn: isPluggedIn)
    }
}

// MARK: - View Model

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var mediaInfo: MediaInfo?
    @Published var ambientColor: Color = .white.opacity(0.5)
    @Published var availableSources: [MediaInfo] = []
    @Published var activeSourceIndex: Int = 0
    @Published var mediaCommandInFlight = false
    @Published var battery: BatteryInfo?
    @Published var shelfItems: [ShelfItem] = []
    @Published var currentDate = Date()
    
    @Published var showMusic = true
    @Published var showBattery = true
    @Published var showShelf = true
    @Published var clipboardHistoryEnabled = false
    @Published var showCaffeinate = false
    @Published var showProductivity = false
    @Published var showMirror = false
    /// Where some controls sit inside the notch window (top-left origin),
    /// so the functional tests can click them.
    var layoutFrames: [String: CGRect] = [:]
    /// Which card the lower half of the open notch shows.
    @Published var lowerTab: NotchLowerTab = .files
    /// The next meeting (within the hour) shown under the header.
    @Published var nextMeeting: UpcomingEvent?
    @Published var meetingIsAlert = false
    @Published var quickNoteText: String = "" {
        didSet {
            guard quickNoteText != oldValue else { return }
            SharedPreferences.shared.notchQuickNoteText = quickNoteText
        }
    }
    @Published var pomodoroRemaining: Int = 25 * 60
    @Published var pomodoroRunning = false
    /// Session length in minutes (Settings › Notch, or right-click the timer).
    @Published var pomodoroMinutes: Int = 25 {
        didSet {
            guard pomodoroMinutes != oldValue else { return }
            // A fresh (not started / not paused midway) timer follows the new length.
            if !pomodoroRunning && pomodoroRemaining == oldValue * 60 {
                pomodoroRemaining = pomodoroDuration
            }
        }
    }
    var pomodoroDuration: Int { max(1, pomodoroMinutes) * 60 }
    private var pomodoroTimer: Timer?
    @Published var mediaControlsEnabled = true
    @Published var showAppIcon = true
    @Published var showAlbumArt = true
    @Published var calendarEnabled = true
    @Published var calendarStyle = "compact"
    @Published var batteryStyle = "gauge"
    @Published var hoverDelay: Double = 0.2

    init() {
        let storedPaths = SharedPreferences.shared.notchShelfURLs
        self.shelfItems = storedPaths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            return ShelfItem(url: url)
        }
        self.quickNoteText = SharedPreferences.shared.notchQuickNoteText
        self.pomodoroMinutes = Int(SharedPreferences.shared.notchPomodoroMinutes)
        self.pomodoroRemaining = pomodoroDuration
    }

    deinit {
        pomodoroTimer?.invalidate()
    }

    // MARK: - Pomodoro

    func togglePomodoro() {
        pomodoroRunning ? pausePomodoro() : startPomodoro()
    }

    func startPomodoro() {
        guard !pomodoroRunning else { return }
        pomodoroRunning = true
        pomodoroTimer?.invalidate()
        pomodoroTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPomodoro() }
        }
    }

    func pausePomodoro() {
        pomodoroRunning = false
        pomodoroTimer?.invalidate()
        pomodoroTimer = nil
    }

    func resetPomodoro() {
        pausePomodoro()
        pomodoroRemaining = pomodoroDuration
    }

    private func tickPomodoro() {
        guard pomodoroRemaining > 0 else {
            pausePomodoro()
            notifyPomodoroDone()
            pomodoroRemaining = pomodoroDuration
            return
        }
        pomodoroRemaining -= 1
    }

    private func notifyPomodoroDone() {
        NSSound(named: "Glass")?.play()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Augment"
            content.body = Localizer.string("notch.pomodoro_done")
            center.add(UNNotificationRequest(identifier: "augment.pomodoro", content: content, trigger: nil))
        }
    }

    func addShelfItem(url: URL) {
        if !shelfItems.contains(where: { $0.url == url }) {
            shelfItems.append(ShelfItem(url: url))
            saveShelfItems()
        }
    }
    
    func clearShelf() {
        shelfItems.removeAll()
        saveShelfItems()
    }

    func removeShelfItem(_ item: ShelfItem) {
        shelfItems.removeAll { $0.id == item.id }
        saveShelfItems()
    }

    private func saveShelfItems() {
        let paths = shelfItems.map { $0.url.path }
        SharedPreferences.shared.notchShelfURLs = paths
    }

    func copyToClipboard(_ item: ShelfItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item.url as NSURL])
    }

    func mediaCommand(_ cmd: String) {
        guard !mediaCommandInFlight else { return }
        MediaManager.sendCommand(cmd, bundleID: mediaInfo?.appBundleID, fallbackAppName: mediaInfo?.appName)
    }

    func seekToTime(_ time: Double) {
        guard !mediaCommandInFlight else { return }
        MediaManager.seekToTime(time, bundleID: mediaInfo?.appBundleID, fallbackAppName: mediaInfo?.appName)
    }

    func cycleMediaSource(forward: Bool) {
        MediaManager.shared.cycleSource(forward: forward)
    }

    func selectMediaSource(index: Int) {
        MediaManager.shared.selectSource(at: index)
    }
}

enum NotchLowerTab: Hashable {
    case files, clipboard, note, mirror
}

// MARK: - Notch Service

@MainActor
final class NotchService {
    private var overlayWindow: NSPanel?
    private let viewModel = NotchViewModel()
    private var timers: [Timer] = []
    private var displayObserver: Any?
    private var refreshMediaObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    /// Where the closed notch reacts to the cursor (AppKit coordinates).
    private var hotRect: CGRect = .zero
    private var hoverOpenTask: Task<Void, Never>?

    private(set) var isRunning = false

    func start(preferences: SharedPreferences) {
        guard !isRunning else { return }
        isRunning = true

        preferences.$notchMusicWidget.receive(on: DispatchQueue.main)
            .assign(to: \.showMusic, on: viewModel).store(in: &cancellables)
        preferences.$notchBatteryWidget.receive(on: DispatchQueue.main)
            .assign(to: \.showBattery, on: viewModel).store(in: &cancellables)
        preferences.$notchShelfWidget.receive(on: DispatchQueue.main)
            .assign(to: \.showShelf, on: viewModel).store(in: &cancellables)
        preferences.$notchCaffeinateWidget.receive(on: DispatchQueue.main)
            .assign(to: \.showCaffeinate, on: viewModel).store(in: &cancellables)
        preferences.$notchProductivityWidget.receive(on: DispatchQueue.main)
            .assign(to: \.showProductivity, on: viewModel).store(in: &cancellables)
        preferences.$clipboardHistoryEnabled.receive(on: DispatchQueue.main)
            .assign(to: \.clipboardHistoryEnabled, on: viewModel).store(in: &cancellables)
        preferences.$notchMediaControlsEnabled.receive(on: DispatchQueue.main)
            .assign(to: \.mediaControlsEnabled, on: viewModel).store(in: &cancellables)
        preferences.$notchShowAppIcon.receive(on: DispatchQueue.main)
            .assign(to: \.showAppIcon, on: viewModel).store(in: &cancellables)
        preferences.$notchShowAlbumArt.receive(on: DispatchQueue.main)
            .assign(to: \.showAlbumArt, on: viewModel).store(in: &cancellables)
        preferences.$notchCalendarEnabled.receive(on: DispatchQueue.main)
            .assign(to: \.calendarEnabled, on: viewModel).store(in: &cancellables)
        preferences.$notchCalendarStyle.receive(on: DispatchQueue.main)
            .assign(to: \.calendarStyle, on: viewModel).store(in: &cancellables)
        preferences.$notchBatteryStyle.receive(on: DispatchQueue.main)
            .assign(to: \.batteryStyle, on: viewModel).store(in: &cancellables)
        preferences.$notchMirrorEnabled.receive(on: DispatchQueue.main)
            .assign(to: \.showMirror, on: viewModel).store(in: &cancellables)
        preferences.$notchPomodoroMinutes.receive(on: DispatchQueue.main)
            .map { Int($0) }
            .assign(to: \.pomodoroMinutes, on: viewModel).store(in: &cancellables)
        preferences.$notchHoverDelay.receive(on: DispatchQueue.main)
            .assign(to: \.hoverDelay, on: viewModel).store(in: &cancellables)

        // Observe MediaManager updates
        MediaManager.shared.$currentMedia
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.viewModel.mediaInfo = info
                self?.updateAmbientColor(for: info?.albumArt)
            }
            .store(in: &cancellables)

        MediaManager.shared.$availableSources
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sources in
                self?.viewModel.availableSources = sources
            }
            .store(in: &cancellables)

        MediaManager.shared.$activeSourceIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                self?.viewModel.activeSourceIndex = index
            }
            .store(in: &cancellables)

        // Meetings: show the next one within the hour; open the notch as a
        // heads-up shortly before it starts.
        MeetingsService.shared.$events
            .combineLatest(MeetingsService.shared.$alert, preferences.$meetingsEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] events, alert, enabled in
                guard let self else { return }
                let upcoming = events.first { $0.isInProgress || $0.minutesUntilStart <= 60 }
                self.viewModel.nextMeeting = enabled ? (alert ?? upcoming) : nil
                self.viewModel.meetingIsAlert = enabled && alert != nil
                if enabled, alert != nil { self.peek(seconds: 8) }
            }
            .store(in: &cancellables)

        MediaManager.shared.$isCommandInFlight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.viewModel.mediaCommandInFlight = $0 }
            .store(in: &cancellables)

        setupOverlay()
        startMonitors()
        // Create Quick Look's panel ahead of time so the first preview
        // from the shelf opens instantly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = QLPreviewPanel.shared() }
        startClickThroughTracking()

        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.repositionOverlay()
            }
        }
        
        refreshMediaObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("RefreshMedia"),
            object: nil,
            queue: .main
        ) { _ in
            MediaManager.shared.fire()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        MediaManager.shared.stop()
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        if let obs = displayObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = refreshMediaObserver { NotificationCenter.default.removeObserver(obs) }
        displayObserver = nil
        refreshMediaObserver = nil
        cancellables.removeAll()
    }

    private func setupOverlay() {
        let screen = NSScreen.screens.first(where: { $0.hasNotch }) ?? NSScreen.main ?? NSScreen.screens.first!
        let notchRect = screen.notchRect

        let windowWidth: CGFloat = 420
        // Tall enough for every widget open at once; transparent areas pass
        // clicks through to whatever is underneath.
        let windowHeight: CGFloat = 580
        let windowFrame = CGRect(
            x: screen.frame.minX + (screen.frame.width - windowWidth) / 2,
            y: screen.frame.maxY - windowHeight,
            width: windowWidth,
            height: windowHeight
        )

        let panel = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // The panel is much larger than the closed notch. It only takes the
        // mouse while the cursor is on the notch or the notch is open —
        // otherwise this invisible 420×580 window swallowed every click at
        // the top-center of the screen (Finder items there couldn't be
        // selected). See `updateClickThrough`.
        panel.ignoresMouseEvents = true
        hotRect = CGRect(
            x: notchRect.midX - (notchRect.width + 60) / 2,
            y: screen.frame.maxY - max(notchRect.height, 24) - 4,
            width: notchRect.width + 60,
            height: max(notchRect.height, 24) + 4
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        
        let hostingView = NSHostingView(rootView: NotchContentView(viewModel: viewModel, notchRect: notchRect, hasNotch: screen.hasNotch))
        // By default NSHostingView keeps pushing its SwiftUI content's min/max
        // size onto the window's constraints. While the notch animates open
        // (and whenever content like the scrolling title re-measures) that
        // re-invalidates layout mid-pass, and AppKit aborts with the
        // "needs another Update Constraints pass" exception that crashed the
        // app on open. The panel is sized explicitly, so opt out entirely.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: windowFrame.size)
        panel.contentView = hostingView
        
        panel.orderFrontRegardless()
        overlayWindow = panel
    }

    private func startClickThroughTracking() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            Task { @MainActor in self?.updateClickThrough() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            Task { @MainActor in self?.updateClickThrough() }
            return event
        }) {
            mouseMonitors.append(local)
        }
        viewModel.$isExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                if expanded { SystemControlsService.shared.refresh() }
                // Re-check after SwiftUI has applied the new state.
                DispatchQueue.main.async { self?.updateClickThrough() }
            }
            .store(in: &cancellables)
    }

    /// Accept the mouse only over the closed notch, or anywhere in the
    /// panel while the notch is open (leaving the open notch closes it,
    /// which hands clicks back to the apps underneath).
    private func updateClickThrough() {
        guard let panel = overlayWindow else { return }
        let mouse = NSEvent.mouseLocation
        // Pushed against the top edge the cursor sits at exactly maxY,
        // which `contains` excludes — so pad the rects upward.
        let onNotch = hotRect.insetBy(dx: 0, dy: -3).contains(mouse)
        let overPanel = panel.frame.insetBy(dx: 0, dy: -3).contains(mouse)
        let interactive = viewModel.isExpanded ? overPanel : onNotch
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }

        // Open/close from the cursor position too: a window that just
        // started accepting the mouse gets no "entered" event until the
        // cursor moves again, so SwiftUI's hover alone could miss it.
        if !viewModel.isExpanded && onNotch {
            guard hoverOpenTask == nil else { return }
            let delay = viewModel.hoverDelay
            hoverOpenTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.hoverOpenTask = nil
                if self.hotRect.insetBy(dx: 0, dy: -3).contains(NSEvent.mouseLocation), !self.viewModel.isExpanded {
                    withAnimation(.interpolatingSpring(stiffness: 340, damping: 30)) {
                        self.viewModel.isExpanded = true
                    }
                }
            }
        } else if !onNotch {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil
            if overPanel { isPeeking = false }
            // Keep the notch open while its Quick Look preview is up.
            if viewModel.isExpanded && !overPanel && !isPeeking && !ShelfPreview.shared.isVisible {
                withAnimation(.interpolatingSpring(stiffness: 340, damping: 32)) {
                    viewModel.isExpanded = false
                }
            }
        }
    }

    /// Adds a file to the shelf (screenshots) and briefly shows it.
    func addToShelf(_ url: URL, peek shouldPeek: Bool) {
        viewModel.addShelfItem(url: url)
        viewModel.lowerTab = .files
        if shouldPeek { peek(seconds: 4) }
    }

    private var peekWork: DispatchWorkItem?
    /// While a heads-up is showing, moving the mouse elsewhere doesn't close it.
    private var isPeeking = false

    /// Opens the notch for a few seconds without the cursor, then closes it
    /// again unless the user moved onto it meanwhile.
    private func peek(seconds: Double) {
        guard isRunning, !viewModel.isExpanded else { return }
        isPeeking = true
        withAnimation(.interpolatingSpring(stiffness: 340, damping: 30)) { viewModel.isExpanded = true }
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.overlayWindow, self.isPeeking else { return }
            self.isPeeking = false
            if !panel.frame.insetBy(dx: 0, dy: -3).contains(NSEvent.mouseLocation) {
                withAnimation(.interpolatingSpring(stiffness: 340, damping: 32)) { self.viewModel.isExpanded = false }
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    var passesClicksThroughForTesting: Bool { overlayWindow?.ignoresMouseEvents ?? false }

    /// Lets `SelfTest` drive the real overlay panel through expand/collapse.
    var viewModelForTesting: NotchViewModel { viewModel }

    private func repositionOverlay() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        setupOverlay()
    }

    private var lastArtworkForAmbient: NSImage?

    private func updateAmbientColor(for artwork: NSImage?) {
        guard let artwork else {
            lastArtworkForAmbient = nil
            withAnimation(.easeInOut(duration: 0.5)) { viewModel.ambientColor = .white.opacity(0.5) }
            return
        }
        guard artwork !== lastArtworkForAmbient else { return }
        lastArtworkForAmbient = artwork
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let color = Color(artwork.vividAmbientColor())
            DispatchQueue.main.async {
                guard let self, self.lastArtworkForAmbient === artwork else { return }
                withAnimation(.easeInOut(duration: 0.6)) { self.viewModel.ambientColor = color }
            }
        }
    }

    private func startMonitors() {
        viewModel.battery = BatteryInfo.current()
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.viewModel.battery = BatteryInfo.current() }
        })
        
        MediaManager.shared.start()
        
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.viewModel.currentDate = Date() }
        })
    }
}


/// Borderless panels refuse key status by default, so the quick-note box
/// inside the notch silently dropped every keystroke. `.nonactivatingPanel`
/// still keeps the frontmost app active while you type into it.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// A click on a non-key window is normally spent just making it key, so
    /// the first click into the quick-note box never reached the text view.
    /// Becoming key *before* AppKit routes the click makes it a normal click.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }
}

import AppKit
import Combine
import Foundation
import IOKit.ps
import SwiftUI

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
    @Published var availableSources: [MediaInfo] = []
    @Published var activeSourceIndex: Int = 0
    @Published var mediaCommandInFlight = false
    @Published var battery: BatteryInfo?
    @Published var shelfItems: [ShelfItem] = []
    @Published var currentDate = Date()
    
    @Published var showMusic = true
    @Published var showBattery = true
    @Published var showShelf = true
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
    }

    func addShelfItem(url: URL) {
        if !shelfItems.contains(where: { $0.url == url }) {
            shelfItems.append(ShelfItem(url: url))
            saveShelfItems()
        }
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

// MARK: - Notch Service

@MainActor
final class NotchService {
    private var overlayWindow: NSPanel?
    private let viewModel = NotchViewModel()
    private var timers: [Timer] = []
    private var displayObserver: Any?
    private var refreshMediaObserver: Any?
    private var cancellables = Set<AnyCancellable>()

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
        preferences.$notchHoverDelay.receive(on: DispatchQueue.main)
            .assign(to: \.hoverDelay, on: viewModel).store(in: &cancellables)

        // Observe MediaManager updates
        MediaManager.shared.$currentMedia
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.viewModel.mediaInfo = info
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

        MediaManager.shared.$isCommandInFlight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.viewModel.mediaCommandInFlight = $0 }
            .store(in: &cancellables)

        setupOverlay()
        startMonitors()

        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionOverlay() }
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
        let windowHeight: CGFloat = 320
        let windowFrame = CGRect(
            x: screen.frame.minX + (screen.frame.width - windowWidth) / 2,
            y: screen.frame.maxY - windowHeight,
            width: windowWidth,
            height: windowHeight
        )

        let panel = NSPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        
        let hostingView = NSHostingView(rootView: NotchContentView(viewModel: viewModel, notchRect: notchRect, hasNotch: screen.hasNotch))
        hostingView.frame = NSRect(origin: .zero, size: windowFrame.size)
        panel.contentView = hostingView
        
        panel.orderFrontRegardless()
        overlayWindow = panel
    }

    private func repositionOverlay() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        setupOverlay()
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

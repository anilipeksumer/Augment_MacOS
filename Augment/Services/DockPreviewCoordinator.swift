import AppKit
import ApplicationServices
import Combine
import CoreFoundation
import Foundation

@MainActor
final class DockPreviewCoordinator {
    private let preferences: SharedPreferences
    private let dockService: DockInteractionService
    private let windowDiscovery: WindowDiscoveryService
    private let previewPanel: DockPreviewPanelController

    private var dockServiceStarted = false
    private var pendingHoverBundleID: String?
    private var hoverOpenTimer: Timer?
    private var previewGeneration: UInt64 = 0
    private var cacheWarmTimer: Timer?
    private let previewRenderQueue = DispatchQueue(label: "com.augment.preview-render", qos: .userInitiated)

    init(
        preferences: SharedPreferences,
        dockService: DockInteractionService,
        windowDiscovery: WindowDiscoveryService,
        previewPanel: DockPreviewPanelController? = nil
    ) {
        self.preferences = preferences
        self.dockService = dockService
        self.windowDiscovery = windowDiscovery
        self.previewPanel = previewPanel ?? DockPreviewPanelController()
    }

    func configure() {
        wireDockServiceCallbacks()
        configurePreviewPanel()
    }

    func observePreferenceChanges(storeIn cancellables: inout Set<AnyCancellable>) {
        preferences.$windowPreviewsEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startCacheWarming()
                } else {
                    self.cacheWarmTimer?.invalidate()
                    self.cacheWarmTimer = nil
                    self.previewPanel.hideImmediately()
                    self.windowDiscovery.purgeCache()
                    self.cancelHoverOpen()
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            Publishers.CombineLatest4(
                preferences.$previewSize,
                preferences.$previewCloseButtonVisible,
                preferences.$trafficLightEnabled,
                preferences.$trafficLightSide
            ),
            Publishers.CombineLatest3(
                preferences.$killButtonVisible,
                preferences.$middleClickCloseEnabled,
                preferences.$dragOutEnabled
            ),
            preferences.$headerActionsEnabled,
            preferences.$spaceMagnifyEnabled
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] tuple1, tuple2, headerActions, spaceMagnify in
            guard let self else { return }
            let (size, showClose, tlEnabled, tlSide) = tuple1
            let (killVisible, middleClick, dragOut) = tuple2
            self.previewPanel.updateAppearance(
                panelSize: size,
                showCloseButton: showClose,
                trafficLightEnabled: tlEnabled,
                trafficLightSide: tlSide,
                killButtonVisible: killVisible,
                middleClickEnabled: middleClick,
                dragOutEnabled: dragOut,
                headerActionsEnabled: headerActions
            )
            self.previewPanel.spaceMagnifyEnabled = spaceMagnify
        }
        .store(in: &cancellables)

        Publishers.CombineLatest(
            preferences.$dockLockEnabled,
            preferences.$lockedScreenIdentifiers
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _ in
            self?.refreshDockLock()
        }
        .store(in: &cancellables)
    }

    func startIfReady(permissionState: AccessibilityTrustState) {
        guard !dockServiceStarted else { return }
        guard permissionState == .granted else { return }
        let result = dockService.start()
        if case .started = result {
            dockServiceStarted = true
        }
    }

    func stop() {
        dockService.stop()
        cancelHoverOpen()
    }

    func processPermissionGrant() {
        startIfReady(permissionState: .granted)
    }

    private func wireDockServiceCallbacks() {
        dockService.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .hoverChanged(let bundleID):
                self.handleHover(bundleID: bundleID)
            case .iconClicked(let bundleID):
                self.handleClick(bundleID: bundleID)
            case .iconMiddleClicked(let bundleID):
                self.handleMiddleClick(bundleID: bundleID)
            }
        }

        dockService.shouldHandleLeftClick = { [weak self] bundleID in
            guard let self else { return false }
            guard AppGroup.preferencesBool(forKey: AppGroupKey.dockClickBehaviorEnabled) else { return false }
            guard let activeID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, activeID == bundleID else { return false }
            // Only take the click over to minimize. When the app's windows
            // are already minimized, the Dock brings them back itself, which
            // works for every kind of app (Mac Catalyst ones included).
            return DockWindowToggle.hasVisibleWindow(bundleID: bundleID)
        }
        dockService.shouldHandleMiddleClick = { bundleID in
            guard AppGroup.preferencesBool(forKey: AppGroupKey.middleClickCloseEnabled) else { return false }
            return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
    }

    private func configurePreviewPanel() {
        previewPanel.updateAppearance(
            panelSize: preferences.previewSize,
            showCloseButton: preferences.previewCloseButtonVisible,
            trafficLightEnabled: preferences.trafficLightEnabled,
            trafficLightSide: preferences.trafficLightSide,
            killButtonVisible: preferences.killButtonVisible,
            middleClickEnabled: preferences.middleClickCloseEnabled,
            dragOutEnabled: preferences.dragOutEnabled,
            headerActionsEnabled: preferences.headerActionsEnabled
        )
        previewPanel.spaceMagnifyEnabled = preferences.spaceMagnifyEnabled
        previewPanel.configureCallbacks(
            onActivate: { [weak self] snap in self?.activateWindow(snap) },
            onClose: { [weak self] snap in self?.closeWindow(snap) },
            onMinimize: { [weak self] snap in self?.minimizeWindow(snap) },
            onZoom: { [weak self] snap in self?.zoomWindow(snap) },
            onKill: { [weak self] snap in self?.killApp(for: snap) },
            onDragOut: { [weak self] snap in self?.handleDragOut(snap) },
            onCloseAll: { [weak self] bundleID in self?.closeAllForBundle(bundleID) },
            onMinimizeAll: { [weak self] bundleID in self?.minimizeAllForBundle(bundleID) }
        )
        previewPanel.onWillAutoHide = { [weak self] in
            self?.cancelHoverOpen()
        }
        previewPanel.onPanelVisibilityChanged = { [weak self] visible in
            self?.dockService.setDockPreviewPanelVisible(visible)
        }
        dockService.onSpaceConsumedForDockPreviewMagnify = { [weak self] in
            self?.previewPanel.toggleMagnification()
        }

        refreshDockLock()
    }

    private func refreshDockLock() {
        let enabled = preferences.dockLockEnabled
        let lockedIdentities = preferences.lockedScreenIdentifiers
            .compactMap { ScreenIdentity.parse(storageKey: $0) }

        previewPanel.preferredScreenProvider = { [weak self] in
            guard let self, self.preferences.dockLockEnabled,
                  !lockedIdentities.isEmpty else {
                return nil
            }
            return ScreenGeometry.bestScreen(for: lockedIdentities)
        }

        if enabled && !lockedIdentities.isEmpty {
            dockService.allowEventAtPoint = { point in
                ScreenGeometry.isCGPoint(point, onAnyOf: lockedIdentities)
            }
        } else {
            dockService.allowEventAtPoint = nil
        }
    }

    private func handleHover(bundleID: String?) {
        if previewPanel.isCursorOverPanel() {
            previewPanel.cancelHide()
            cancelHoverOpen()
            return
        }

        guard preferences.windowPreviewsEnabled else {
            previewPanel.hideImmediately()
            cancelHoverOpen()
            return
        }

        if let bundleID {
            if previewPanel.isVisible {
                cancelHoverOpen()
                showPreview(for: bundleID)
                return
            }

            if pendingHoverBundleID == bundleID, hoverOpenTimer != nil {
                return
            }

            cancelHoverOpen()
            pendingHoverBundleID = bundleID

            let delay = SharedPreferences.clampHoverDelay(preferences.hoverOpenDelay)
            if delay <= 0 {
                pendingHoverBundleID = nil
                showPreview(for: bundleID)
            } else {
                hoverOpenTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
                    [weak self] _ in
                    Task { @MainActor in self?.firePendingHoverOpen() }
                }
            }
        } else {
            cancelHoverOpen()
            previewPanel.scheduleHide()
        }
    }

    private func firePendingHoverOpen() {
        guard let bundleID = pendingHoverBundleID else { return }
        pendingHoverBundleID = nil
        hoverOpenTimer = nil
        showPreview(for: bundleID)
    }

    private func showPreview(for bundleID: String) {
        let runningApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first
        guard runningApp != nil else {
            previewPanel.scheduleHide()
            return
        }
        let displayName = runningApp?.localizedName ?? ""
        let icon = runningApp?.icon
        let includeMinimized = true
        let suppressEmpty = preferences.suppressEmptyPreviews
        let discovery = windowDiscovery
        previewGeneration &+= 1
        let generation = previewGeneration

        previewRenderQueue.async { [weak self] in
            let snapshots = discovery.windowsWithThumbnails(
                forBundleIdentifier: bundleID,
                includeMinimizedWindows: includeMinimized
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.previewGeneration else { return }
                if snapshots.isEmpty && suppressEmpty {
                    // Only suppress if the app is genuinely not running.
                    // If it's running but all windows are minimized, show the empty state.
                    let appIsRunning = !NSRunningApplication
                        .runningApplications(withBundleIdentifier: bundleID)
                        .isEmpty
                    if !appIsRunning {
                        if !self.previewPanel.isVisible || self.previewPanel.presentingBundleID != bundleID {
                            self.previewPanel.scheduleHide()
                        }
                        return
                    }
                }
                self.previewPanel.show(
                    snapshots: snapshots,
                    bundleID: bundleID,
                    displayName: displayName,
                    appIcon: icon
                )
            }
        }
    }

    /// Keeps recent images of on-screen windows so a window the user minimizes
    /// later still has a real preview (see `warmThumbnailCache`).
    private func startCacheWarming() {
        guard cacheWarmTimer == nil else { return }
        let discovery = windowDiscovery
        let queue = previewRenderQueue
        queue.async { discovery.warmThumbnailCache() }
        let timer = Timer(timeInterval: 20, repeats: true) { _ in
            queue.async { discovery.warmThumbnailCache() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cacheWarmTimer = timer
    }

    private func cancelHoverOpen() {
        hoverOpenTimer?.invalidate()
        hoverOpenTimer = nil
        pendingHoverBundleID = nil
        previewGeneration &+= 1
    }

    private func activateWindow(_ snapshot: WindowSnapshot) {
        previewPanel.hideImmediately()
        cancelHoverOpen()
        windowDiscovery.focusWindow(snapshot.window)
    }

    private func closeWindow(_ snapshot: WindowSnapshot) {
        let bundleIDBeforeClose = previewPanel.presentingBundleID
        let succeeded = windowDiscovery.closeWindow(snapshot.window)
        guard succeeded else { return }
        previewPanel.removeSnapshotOptimistically(snapshot)
        rerenderPanelAfterMutation(for: bundleIDBeforeClose)
    }

    private func minimizeWindow(_ snapshot: WindowSnapshot) {
        let bundleIDBeforeClose = previewPanel.presentingBundleID
        windowDiscovery.minimizeWindow(snapshot.window)
        previewPanel.removeSnapshotOptimistically(snapshot)
        rerenderPanelAfterMutation(for: bundleIDBeforeClose)
    }

    private func zoomWindow(_ snapshot: WindowSnapshot) {
        windowDiscovery.toggleZoomWindow(snapshot.window)
        previewPanel.hideImmediately()
        cancelHoverOpen()
    }

    private func killApp(for snapshot: WindowSnapshot) {
        guard let app = NSRunningApplication(processIdentifier: snapshot.window.ownerPID),
              let bundleID = app.bundleIdentifier else { return }
        windowDiscovery.terminateApp(bundleIdentifier: bundleID, force: true)
        previewPanel.hideImmediately()
        cancelHoverOpen()
    }

    private func handleDragOut(_ snapshot: WindowSnapshot) {
        windowDiscovery.focusWindow(snapshot.window)
        previewPanel.hideImmediately()
        cancelHoverOpen()
    }

    private func closeAllForBundle(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        previewPanel.hideImmediately()
        cancelHoverOpen()
        windowDiscovery.closeAllWindows(forBundleIdentifier: bundleID)
        rerenderPanelAfterMutation(for: bundleID)
    }

    private func minimizeAllForBundle(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        previewPanel.hideImmediately()
        cancelHoverOpen()
        windowDiscovery.minimizeAllWindows(forBundleIdentifier: bundleID)
        rerenderPanelAfterMutation(for: bundleID)
    }

    private func rerenderPanelAfterMutation(for bundleID: String?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let bundleID, !bundleID.isEmpty else { return }
            guard self.previewPanel.presentingBundleID == bundleID else { return }
            let includeMinimized = true
            let discovery = self.windowDiscovery
            self.previewGeneration &+= 1
            let generation = self.previewGeneration
            self.previewRenderQueue.async { [weak self] in
                let snapshots = discovery.windowsWithThumbnails(
                    forBundleIdentifier: bundleID,
                    includeMinimizedWindows: includeMinimized
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.previewGeneration else { return }
                    guard self.previewPanel.presentingBundleID == bundleID else { return }
                    if snapshots.isEmpty {
                        self.previewPanel.hideImmediately()
                    } else {
                        let runningApp = NSRunningApplication
                            .runningApplications(withBundleIdentifier: bundleID)
                            .first
                        let displayName = runningApp?.localizedName ?? ""
                        self.previewPanel.refresh(
                            snapshots: snapshots,
                            displayName: displayName,
                            appIcon: runningApp?.icon
                        )
                    }
                }
            }
        }
    }

    private func handleClick(bundleID: String) {
        previewPanel.hideImmediately()
        cancelHoverOpen()
        guard preferences.dockClickBehaviorEnabled else { return }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            }
            return
        }
        DockWindowToggle.toggle(app)
    }

    private func handleMiddleClick(bundleID: String) {
        guard preferences.middleClickCloseEnabled else { return }
        previewPanel.hideImmediately()
        cancelHoverOpen()
        windowDiscovery.closeAllWindows(forBundleIdentifier: bundleID)
    }
}

/// What a click on the frontmost app's Dock icon does: minimize its
/// windows, or bring them back when they are all minimized.
@MainActor
enum DockWindowToggle {
    /// Whether the app has a normal window on screen. Safe to call from the
    /// event tap thread: it only reads the window server's list.
    nonisolated static func hasVisibleWindow(bundleID: String) -> Bool {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return info.contains { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { return false }
            return min(bounds["Width"] ?? 0, bounds["Height"] ?? 0) >= 72
        }
    }

    static func toggle(_ app: NSRunningApplication) {
        // Accessibility calls into our own process can't be answered while
        // the main thread is busy making them, so handle Augment's own
        // windows (Settings, the tour) with AppKit directly.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            toggleOwnWindows()
            return
        }
        app.unhide()
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsValue
        ) == .success,
              let windows = windowsValue as? [AXUIElement],
              !windows.isEmpty else {
            app.activate(options: [.activateAllWindows])
            return
        }
        let candidates = dockToggleCandidateWindows(from: windows, bundleID: app.bundleIdentifier)
        guard !candidates.isEmpty else {
            app.activate(options: [.activateAllWindows])
            return
        }

        let allMinimized = candidates.allSatisfy { isMinimized($0) }
        if allMinimized {
            for window in candidates {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            app.activate(options: [.activateAllWindows])
            // Some apps (Mac Catalyst ones such as WhatsApp) ignore the
            // Accessibility request. We swallowed the Dock click, so if the
            // windows are still minimized, do what the Dock itself would:
            // send the app a reopen event.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard candidates.allSatisfy({ isMinimized($0) }) else { return }
                sendReopen(to: app)
            }
        } else {
            for window in candidates where !isMinimized(window) {
                AXUIElementSetAttributeValue(
                    window, kAXMinimizedAttribute as CFString, kCFBooleanTrue
                )
                if !isMinimized(window) {
                    // Same for minimizing: fall back to the window's own
                    // yellow button, which every app honours.
                    pressMinimizeButton(of: window)
                }
            }
        }
    }

    private static func toggleOwnWindows() {
        let windows = NSApp.windows.filter { $0.styleMask.contains(.miniaturizable) && ($0.isVisible || $0.isMiniaturized) }
        guard !windows.isEmpty else { return }
        if windows.allSatisfy(\.isMiniaturized) {
            windows.forEach { $0.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
        } else {
            windows.filter { !$0.isMiniaturized }.forEach { $0.miniaturize(nil) }
        }
    }

    /// The Apple event the Dock sends when an icon is clicked; apps respond
    /// by bringing back a minimized window.
    private static func sendReopen(to app: NSRunningApplication) {
        // `open` goes through LaunchServices exactly like a Dock click, and
        // unlike NSWorkspace it reliably makes Mac Catalyst apps restore a
        // minimized window. Augment isn't sandboxed, so it can run it.
        guard let url = app.bundleURL else {
            app.activate(options: [.activateAllWindows])
            return
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url.path]
        do {
            try open.run()
        } catch {
            app.activate(options: [.activateAllWindows])
        }
    }

    private static func pressMinimizeButton(of window: AXUIElement) {
        var button: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizeButtonAttribute as CFString, &button) == .success,
              let button else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    private static func dockToggleCandidateWindows(from windows: [AXUIElement], bundleID: String?) -> [AXUIElement] {
        let isFinder = bundleID == "com.apple.finder"
        let filtered = windows.filter { !isFinderDesktop($0) }

        if isFinder {
            let finderWindows = filtered.filter { (isMinimizable($0) || isMinimized($0)) }
            if !finderWindows.isEmpty { return finderWindows }
        }

        let standard = filtered.filter { isStandardWindow($0) && (isMinimizable($0) || isMinimized($0)) }
        if !standard.isEmpty { return standard }
        return filtered.filter { isProminentDockTargetWindow($0) && (isMinimizable($0) || isMinimized($0)) }
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        var subroleValue: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
        if subroleValue == nil { return true }
        if let subrole = subroleValue as? String {
            return subrole == (kAXStandardWindowSubrole as String)
        }
        return true
    }

    private static func isProminentDockTargetWindow(_ window: AXUIElement) -> Bool {
        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue) == .success,
              (roleValue as? String) == (kAXWindowRole as String) else {
            return false
        }
        var subroleValue: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
        guard let subrole = subroleValue as? String else { return true }
        if subrole == (kAXFloatingWindowSubrole as String) { return false }
        if subrole.contains("Dialog") || subrole.contains("SystemDialog") { return false }
        return true
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(
            window, kAXMinimizedAttribute as CFString, &value
        )
        return (value as? Bool) ?? false
    }

    private static func isMinimizable(_ window: AXUIElement) -> Bool {
        var isSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &isSettable) == .success {
            return isSettable.boolValue
        }
        return false
    }

    private static func isFinderDesktop(_ window: AXUIElement) -> Bool {
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
        guard let title = titleValue as? String else { return false }
        if title == "Desktop" { return true }

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
        if (roleValue as? String) == "AXScrollArea" { return true }

        return false
    }
}

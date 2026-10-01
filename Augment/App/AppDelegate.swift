import AppKit
import ApplicationServices
import Combine
import CoreFoundation
import Foundation
import SwiftUI

/// Owns the AppKit-side lifecycle of Augment.
///
/// At runtime the delegate:
///   * Forces the accessory activation policy so we behave as a true menu
///     bar / background app even on first launch from Xcode.
///   * Brings up the App Group-backed shared preferences.
///   * Drives the Accessibility permission flow on first launch.
///   * Installs the menu bar status item that hosts quick-access controls.
///   * Starts `DockPreviewCoordinator` once Accessibility trust is granted.
///   * Owns the `SettingsWindowController` so picking "Settings…" from the
///     menu bar reliably brings the window forward.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Long-lived collaborators

    let permissionCoordinator: PermissionCoordinator
    let preferences = SharedPreferences.shared

    private let dockService = DockInteractionService()
    private let windowDiscovery = WindowDiscoveryService()
    private let windowSnappingService = WindowSnappingService()
    private let finderOpenShortcutService = FinderOpenShortcutService()
    private let fileCutPasteService = FileCutPasteService()
    private let snapLayoutsService = SnapLayoutsService()
    private lazy var windowSwitcherService = WindowSwitcherService(windowDiscovery: windowDiscovery)
    private let notchService = NotchService()
    private let finderBridgeService = FinderBridgeService()
    private lazy var dockPreviewCoordinator = DockPreviewCoordinator(
        preferences: preferences,
        dockService: dockService,
        windowDiscovery: windowDiscovery
    )
    private lazy var settingsController = SettingsWindowController(
        preferences: preferences,
        permissionCoordinator: permissionCoordinator
    )

    private var statusItem: NSStatusItem?
    private var onboardingController: OnboardingWindowController?
    private var cancellables: Set<AnyCancellable> = []

    /// Finder Sync sets `pendingFinderBridgeHostLaunch` before cold-launching the host;
    /// Launch Services often strips CLI args for GUI bundles, so we rely on this + env as well.
    private func consumeFinderBridgePendingLaunchSignal() -> Bool {
        AppGroup.synchronizeSuitePreferences()
        guard AppGroup.preferencesBool(forKey: AppGroupKey.pendingFinderBridgeHostLaunch) else {
            return false
        }
        AppGroup.setSuiteValue(nil, forKey: AppGroupKey.pendingFinderBridgeHostLaunch)
        AppGroup.synchronizeSuitePreferences()
        return true
    }

    override init() {
        self.permissionCoordinator = PermissionCoordinator(preferences: .shared)
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(event:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// Clicking Augment's Dock icon (shown while Settings is open) brings a
    /// minimized Settings window back, like any other app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let minimized = sender.windows.filter(\.isMiniaturized)
            minimized.forEach { $0.deminiaturize(nil) }
            if !minimized.isEmpty { sender.activate(ignoringOtherApps: true) }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains(SelfTest.argument) {
            SelfTest.runAndExit()
            return
        }
        if CommandLine.arguments.contains(FuncTest.argument) {
            FuncTest.runAndExit()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        preferences.migrateNotchStylesIfNeeded()
        if let icon = AugmentApplicationIcon.load() {
            NSApp.applicationIconImage = icon
        }

        installMenuBarItem()
        observePermissionState()
        dockPreviewCoordinator.configure()
        dockPreviewCoordinator.observePreferenceChanges(storeIn: &cancellables)

        // The quick panel's "Settings…" (optionally jumping to a page).
        NotificationCenter.default.publisher(for: QuickPanelController.openSettingsNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.showSettings()
                if let tab = note.object as? String {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        NotificationCenter.default.post(name: SettingsRootView.selectTabNotification, object: tab)
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("augment.showAbout"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showAbout() }
            .store(in: &cancellables)

        CaffeinateService.shared.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshStatusItemMenu()
            }
            .store(in: &cancellables)

        // Finder Sync may launch us only to drain `FinderCreateQueue` while Augment
        // was quit — running the full Accessibility onboarding again feels like the
        // system is “asking permission” on every right-click new file.
        let launchedForFinderBridge =
            CommandLine.arguments.contains(AugmentHostLaunchArgument.finderBridge)
            || ProcessInfo.processInfo.environment["AUGMENT_FINDER_BRIDGE"] == "1"
            || consumeFinderBridgePendingLaunchSignal()
        if launchedForFinderBridge {
            permissionCoordinator.refresh()
            dockPreviewCoordinator.startIfReady(permissionState: permissionCoordinator.state)
        } else {
            startPermissionFlow()
            dockPreviewCoordinator.startIfReady(permissionState: permissionCoordinator.state)
        }

        finderBridgeService.start()

        // --- New feature services ---
        startWindowSnappingIfNeeded()
        startFinderOpenShortcutIfNeeded()
        startFileCutPasteIfNeeded()
        startSnapLayoutsIfNeeded()
        startWindowSwitcherIfNeeded()
        startVolumeMixerIfNeeded()
        startClipboardHistoryIfNeeded()
        startExtrasIfNeeded()
        // First launch after installing: the tour, then Settings in front.
        // Later launches only nudge about the Finder extension if needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if !WelcomeTourController.hasShown {
                WelcomeTourController.show { [weak self] in self?.showSettings() }
            } else {
                FinderExtensionStatus.promptIfNeeded(preferences: self.preferences)
            }
        }
        startNotchIfNeeded()
        observeNewFeaturePreferences()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Finder Sync may enqueue a create + Darwin notify while we were
        // inactive; always drain on activation (Settings permission flow
        // also benefits from a fresh pass after returning from System Settings).
        finderBridgeService.processQueues()
        permissionCoordinator.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        finderBridgeService.stop()
        permissionCoordinator.stopPolling()
        dockPreviewCoordinator.stop()
        windowSnappingService.stop()
        finderOpenShortcutService.stop()
        fileCutPasteService.stop()
        snapLayoutsService.stop()
        ShowDesktopService.shared.stop()
        windowSwitcherService.stop()
        QuickPanelController.shared.close()
        DisplayBrightnessService.shared.restoreSoftwareDimming()
        if #available(macOS 14.2, *) { AudioProcessMixerService.shared.stop() }
        ClipboardHistoryService.shared.stop()
        notchService.stop()
        // Belt-and-braces: every individual write already syncs, but if a
        // user toggle was in flight we want the App Group plist on disk
        // before the process exits so the next launch reads the latest.
        SharedPreferences.synchronizeAppGroup()
    }

    // MARK: - Menu bar

    /// Direction A menu bar glyph: a rounded window outline with the notch
    /// pill on its top edge. Drawn as a template so macOS tints it for light,
    /// dark and highlighted menu bars.
    private func createMenuBarImage() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let body = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 3.5, width: 13, height: 11), xRadius: 3, yRadius: 3)
            body.lineWidth = 1.4
            NSColor.black.setStroke()
            body.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 6.5, y: 12.6, width: 5, height: 2.4), xRadius: 1.2, yRadius: 1.2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = createMenuBarImage() {
                button.image = image
                button.imageScaling = .scaleProportionallyDown
            } else {
                let image = NSImage(
                    systemSymbolName: "rectangle.stack.fill",
                    accessibilityDescription: "Augment"
                )
                image?.isTemplate = true
                button.image = image
            }
        }
        statusItem = item
        refreshStatusItemMenu()
    }

    /// A left click opens the quick panel (displays, sound, keep awake);
    /// a right (or Control-) click shows Augment's own menu.
    private func refreshStatusItemMenu() {
        guard let item = statusItem else { return }
        item.menu = nil
        item.button?.target = self
        item.button?.action = #selector(handleStatusItemClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleStatusItemClick() {
        guard let button = statusItem?.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            QuickPanelController.shared.close()
            let menu = makeMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        } else if preferences.showDesktopEnabled && event?.modifierFlags.contains(.option) == true {
            ShowDesktopService.shared.toggle()
        } else {
            QuickPanelController.shared.toggle(below: button)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: Localizer.string("menu.about"), action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: Localizer.string("menu.settings"), action: #selector(showSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: Localizer.string("menu.permissions"),
                     action: #selector(showOnboarding),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: Localizer.string("menu.tour"),
                     action: #selector(showTour),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        let caffeinateItem = menu.addItem(
            withTitle: Localizer.string("menu.caffeinate"),
            action: #selector(toggleCaffeinate),
            keyEquivalent: ""
        )
        caffeinateItem.target = self
        caffeinateItem.state = CaffeinateService.shared.isActive ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: Localizer.string("menu.quit"),
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        return menu
    }

    // MARK: - Menu actions

    @objc private func showAbout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AboutWindowController.showAbout()
        }
    }

    @objc private func showSettings() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.settingsController.show()
        }
    }

    @objc private func toggleCaffeinate() {
        CaffeinateService.shared.toggle()
    }

    @objc private func showTour() {
        WelcomeTourController.show { [weak self] in self?.showSettings() }
    }

    @objc private func showOnboarding() {
        permissionCoordinator.refresh()
        if permissionCoordinator.state != .granted {
            permissionCoordinator.requestAccessAndBeginPolling(force: false)
        }
        presentOnboardingIfNeeded(force: true)
    }

    @objc private func handleGetURLEvent(event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "augment" else { return }

        if url.host == "settings" {
            settingsController.show()
            // Note: In a complete implementation, you could parse url.path to route to a specific tab
            // e.g. /finder routes to Finder settings. The tab reset observer currently resets to General,
            // so we'll just open the Settings window for now.
        } else if url.host == "finder-bridge" || url.host == "finder-reveal" {
            finderBridgeService.processQueues()
        }
    }

    // MARK: - Permission flow

    /// Never prompts at launch. Permissions are requested only when the user
    /// switches on a feature that needs them (see `requestPermissionsWhenEnabled`);
    /// here we just watch quietly for Accessibility being granted so the
    /// features waiting on it can start without a relaunch.
    private func startPermissionFlow() {
        permissionCoordinator.refresh()
        if permissionCoordinator.state == .granted {
            preferences.didCompleteOnboarding = true
        } else {
            permissionCoordinator.requestAccessAndBeginPolling(force: false)
        }
    }

    private func observePermissionState() {
        permissionCoordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .granted {
                    self.preferences.syncAccessibilityPromptFlagIfProcessTrusted()
                    self.preferences.didCompleteOnboarding = true
                    self.onboardingController?.dismissOnGrant()
                    self.dockPreviewCoordinator.processPermissionGrant()
                    self.finderBridgeService.processQueues()
                    // Features switched on while Accessibility was missing
                    // start now instead of needing an app relaunch.
                    self.startWindowSnappingIfNeeded()
                    self.startFinderOpenShortcutIfNeeded()
                    self.startFileCutPasteIfNeeded()
                    self.startSnapLayoutsIfNeeded()
                    self.startWindowSwitcherIfNeeded()
                    self.startExtrasIfNeeded()
                }
            }
            .store(in: &cancellables)

        requestPermissionsWhenEnabled(preferences.$windowPreviewsEnabled, key: AppGroupKey.windowPreviewsEnabled)
        requestPermissionsWhenEnabled(preferences.$dockClickBehaviorEnabled, key: AppGroupKey.dockClickBehaviorEnabled)
        requestPermissionsWhenEnabled(preferences.$windowSnappingEnabled, key: AppGroupKey.windowSnappingEnabled)
        preferences.$finderEnterBehavior
            .dropFirst().removeDuplicates().filter { $0 != .system }
            .receive(on: DispatchQueue.main)
            .sink { _ in FeatureRequirements.requestMissing(forPreferenceKey: AppGroupKey.finderEnterBehavior) }
            .store(in: &cancellables)
        requestPermissionsWhenEnabled(preferences.$fileCutPasteEnabled, key: AppGroupKey.fileCutPasteEnabled)
        requestPermissionsWhenEnabled(preferences.$showDesktopEnabled, key: AppGroupKey.showDesktopEnabled)
        requestPermissionsWhenEnabled(preferences.$snapLayoutsEnabled, key: AppGroupKey.snapLayoutsEnabled)
        requestPermissionsWhenEnabled(preferences.$windowSwitcherEnabled, key: AppGroupKey.windowSwitcherEnabled)
        requestPermissionsWhenEnabled(preferences.$displayKeysEnabled, key: AppGroupKey.displayKeysEnabled)
        requestPermissionsWhenEnabled(preferences.$clipboardPanelEnabled, key: AppGroupKey.clipboardPanelEnabled)
    }

    /// Asks for a feature's missing permissions the moment the user turns it
    /// on — never at launch (`dropFirst` skips the stored value).
    private func requestPermissionsWhenEnabled(_ publisher: Published<Bool>.Publisher, key: String) {
        publisher
            .dropFirst()
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { _ in FeatureRequirements.requestMissing(forPreferenceKey: key) }
            .store(in: &cancellables)
    }

    private func presentOnboardingIfNeeded(force: Bool) {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(
                permissionCoordinator: permissionCoordinator
            )
        }
        if force {
            onboardingController?.show()
        }
    }

    // MARK: - Window snapping & Notch

    private func startWindowSnappingIfNeeded() {
        guard preferences.windowSnappingEnabled else {
            windowSnappingService.stop()
            return
        }
        guard permissionCoordinator.state == .granted else { return }
        windowSnappingService.start(shortcutsJSON: preferences.windowSnappingShortcuts)
    }

    private func startFinderOpenShortcutIfNeeded() {
        guard preferences.finderEnterBehavior != .system, permissionCoordinator.state == .granted else {
            finderOpenShortcutService.stop()
            return
        }
        finderOpenShortcutService.start(mode: preferences.finderEnterBehavior)
    }

    private func startFileCutPasteIfNeeded() {
        guard preferences.fileCutPasteEnabled else {
            fileCutPasteService.stop()
            return
        }
        guard permissionCoordinator.state == .granted else { return }
        fileCutPasteService.start()
    }

    private func startSnapLayoutsIfNeeded() {
        guard preferences.snapLayoutsEnabled else {
            snapLayoutsService.stop()
            return
        }
        guard permissionCoordinator.state == .granted else { return }
        snapLayoutsService.start()
    }

    private func startWindowSwitcherIfNeeded() {
        guard preferences.windowSwitcherEnabled else {
            windowSwitcherService.stop()
            return
        }
        guard permissionCoordinator.state == .granted else { return }
        windowSwitcherService.start()
    }

    private func startVolumeMixerIfNeeded() {
        if #available(macOS 14.2, *) {
            if preferences.volumeMixerEnabled {
                AudioProcessMixerService.shared.start()
            } else {
                AudioProcessMixerService.shared.stop()
            }
        }
    }

    private func startClipboardHistoryIfNeeded() {
        if preferences.clipboardHistoryEnabled || preferences.clipboardPanelEnabled {
            ClipboardHistoryService.shared.start()
        } else {
            ClipboardHistoryService.shared.stop()
        }
    }

    /// Display keys, brightness schedule, keep-awake rules, clipboard
    /// panel, meetings and screenshots-to-shelf.
    private func startExtrasIfNeeded() {
        _ = CaffeinateService.shared // starts evaluating keep-awake rules
        FinderServicesProvider.shared.register()
        AudioRouteWatcher.shared.onDefaultOutputChanged = {
            if #available(macOS 14.2, *) { AudioProcessMixerService.shared.defaultOutputChanged() }
        }
        AudioRouteWatcher.shared.start()

        if preferences.displayKeysEnabled && AXIsProcessTrusted() {
            DisplayKeysService.shared.start()
        } else {
            DisplayKeysService.shared.stop()
        }
        preferences.brightnessScheduleEnabled ? BrightnessScheduler.shared.start() : BrightnessScheduler.shared.stop()
        preferences.clipboardPanelEnabled ? ClipboardPanelController.shared.enable() : ClipboardPanelController.shared.disable()
        preferences.meetingsEnabled ? MeetingsService.shared.start() : MeetingsService.shared.stop()

        if preferences.screenshotShelfEnabled {
            ScreenshotShelfWatcher.shared.onScreenshot = { [weak self] url in
                self?.notchService.addToShelf(url, peek: true)
            }
            ScreenshotShelfWatcher.shared.start()
        } else {
            ScreenshotShelfWatcher.shared.stop()
        }
    }

    private func startNotchIfNeeded() {
        guard preferences.notchEnabled else {
            notchService.stop()
            return
        }
        notchService.start(preferences: preferences)
    }

    private func observeNewFeaturePreferences() {
        preferences.$finderEnterBehavior
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.startFinderOpenShortcutIfNeeded() }
            .store(in: &cancellables)

        preferences.$showDesktopEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { ShowDesktopService.shared.setEnabled($0) }
            .store(in: &cancellables)

        // Window snapping toggle
        preferences.$windowSnappingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startWindowSnappingIfNeeded()
                } else {
                    self.windowSnappingService.stop()
                }
            }
            .store(in: &cancellables)

        // Window snapping shortcut changes
        preferences.$windowSnappingShortcuts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] json in
                guard let self else { return }
                if self.preferences.windowSnappingEnabled {
                    self.windowSnappingService.updateShortcuts(json)
                }
            }
            .store(in: &cancellables)

        // File cut & paste toggle
        preferences.$fileCutPasteEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startFileCutPasteIfNeeded()
                } else {
                    self.fileCutPasteService.stop()
                }
            }
            .store(in: &cancellables)

        // Snap Layouts toggle
        preferences.$snapLayoutsEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startSnapLayoutsIfNeeded()
                } else {
                    self.snapLayoutsService.stop()
                }
            }
            .store(in: &cancellables)

        // Window switcher toggle
        preferences.$windowSwitcherEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startWindowSwitcherIfNeeded()
                } else {
                    self.windowSwitcherService.stop()
                }
            }
            .store(in: &cancellables)

        // Volume mixer toggle
        preferences.$volumeMixerEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.startVolumeMixerIfNeeded() }
            .store(in: &cancellables)

        // Clipboard history toggle
        // Extras: any of these switches re-applies the whole set.
        Publishers.MergeMany(
            preferences.$displayKeysEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            preferences.$brightnessScheduleEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            preferences.$clipboardPanelEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            preferences.$meetingsEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            preferences.$screenshotShelfEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            self?.startExtrasIfNeeded()
            self?.startClipboardHistoryIfNeeded()
        }
        .store(in: &cancellables)

        preferences.$clipboardHistoryEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.startClipboardHistoryIfNeeded() }
            .store(in: &cancellables)

        // Notch toggle
        preferences.$notchEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startNotchIfNeeded()
                } else {
                    self.notchService.stop()
                }
            }
            .store(in: &cancellables)

        // Language toggle
        preferences.$appLanguage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshStatusItemMenu()
            }
            .store(in: &cancellables)
    }

}

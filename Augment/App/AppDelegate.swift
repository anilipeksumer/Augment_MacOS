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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let icon = AugmentApplicationIcon.load() {
            NSApp.applicationIconImage = icon
        }

        installMenuBarItem()
        observePermissionState()
        dockPreviewCoordinator.configure()
        dockPreviewCoordinator.observePreferenceChanges(storeIn: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("augment.showAbout"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showAbout() }
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
        notchService.stop()
        // Belt-and-braces: every individual write already syncs, but if a
        // user toggle was in flight we want the App Group plist on disk
        // before the process exits so the next launch reads the latest.
        SharedPreferences.synchronizeAppGroup()
    }

    // MARK: - Menu bar

    private func createMenuBarImage() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            
            // 1. Draw Left Card (tilted left)
            context.saveGState()
            context.translateBy(x: 5.5, y: 10.5)
            context.rotate(by: 12.0 * .pi / 180.0)
            let leftCardPath = CGPath(roundedRect: CGRect(x: -3.5, y: -5.0, width: 7.0, height: 10.0), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            context.addPath(leftCardPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
            
            // 2. Draw Right Card (tilted right) with transparent separator
            context.saveGState()
            context.translateBy(x: 12.5, y: 10.5)
            context.rotate(by: -12.0 * .pi / 180.0)
            let rightCardPath = CGPath(roundedRect: CGRect(x: -3.5, y: -5.0, width: 7.0, height: 10.0), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            
            // Draw transparent stroke first to carve separator
            context.saveGState()
            context.addPath(rightCardPath)
            context.setBlendMode(.clear)
            context.setStrokeColor(NSColor.clear.cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
            context.restoreGState()
            
            // Fill right card
            context.addPath(rightCardPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
            
            // 3. Draw Bottom Banner (separated by transparent gap)
            let bannerPath = CGPath(roundedRect: CGRect(x: 2.0, y: 2.0, width: 14.0, height: 2.5), cornerWidth: 0.75, cornerHeight: 0.75, transform: nil)
            
            // Carve transparent separator
            context.saveGState()
            context.addPath(bannerPath)
            context.setBlendMode(.clear)
            context.setStrokeColor(NSColor.clear.cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
            context.restoreGState()
            
            // Fill banner
            context.saveGState()
            context.addPath(bannerPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
            
            // 4. Draw Center Arrow (caret/chevron)
            let arrowPath = CGMutablePath()
            arrowPath.move(to: CGPoint(x: 9.0, y: 13.5))
            arrowPath.addLine(to: CGPoint(x: 6.5, y: 10.5))
            arrowPath.addLine(to: CGPoint(x: 7.7, y: 10.5))
            arrowPath.addLine(to: CGPoint(x: 7.7, y: 7.5))
            arrowPath.addLine(to: CGPoint(x: 10.3, y: 7.5))
            arrowPath.addLine(to: CGPoint(x: 10.3, y: 10.5))
            arrowPath.addLine(to: CGPoint(x: 11.5, y: 10.5))
            arrowPath.closeSubpath()
            
            // Carve transparent separator around arrow
            context.saveGState()
            context.addPath(arrowPath)
            context.setBlendMode(.clear)
            context.setStrokeColor(NSColor.clear.cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
            context.restoreGState()
            
            // Fill arrow
            context.saveGState()
            context.addPath(arrowPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
            
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
        item.menu = makeMenu()
        statusItem = item
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

    /// Drives the once-per-install Accessibility prompt. After the first
    /// launch we never re-prompt automatically – the user explicitly chose
    /// to deny, and silently re-asking on every launch is a UX smell that
    /// some users reported as the prompt "spamming" them.
    private func startPermissionFlow() {
        permissionCoordinator.refresh()
        switch permissionCoordinator.state {
        case .granted:
            preferences.didCompleteOnboarding = true
        case .denied, .unknown:
            // Only show onboarding automatically if it's the very first time we ask.
            if !preferences.hasRequestedAccessibilityPrompt {
                presentOnboardingIfNeeded(force: true)
                permissionCoordinator.requestAccessAndBeginPolling()
            } else {
                // If they've already been asked, just poll quietly in the background.
                permissionCoordinator.requestAccessAndBeginPolling(force: false)
            }
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
                }
            }
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

    private func startNotchIfNeeded() {
        guard preferences.notchEnabled else {
            notchService.stop()
            return
        }
        notchService.start(preferences: preferences)
    }

    private func observeNewFeaturePreferences() {
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
                self.statusItem?.menu = self.makeMenu()
            }
            .store(in: &cancellables)
    }

}

import AppKit
import SwiftUI

/// AppKit window controller that hosts the SwiftUI `PermissionView`.
///
/// The window itself uses a translucent titlebar that blends into the
/// `NSVisualEffectView` background of the SwiftUI content, giving the same
/// appearance as Apple's first-run welcome panels (e.g. the Migration
/// Assistant or Setup Assistant).
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private let permissionCoordinator: PermissionCoordinator

    init(permissionCoordinator: PermissionCoordinator) {
        self.permissionCoordinator = permissionCoordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Accessibility Permission"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: PermissionView(
                coordinator: permissionCoordinator,
                onContinue: { [weak window] in window?.performClose(nil) }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Brings the onboarding window to the foreground, activating the app
    /// since `LSUIElement` apps are not normally activated by clicks elsewhere.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Animated dismissal triggered when the permission state flips to
    /// `.granted`. The window is faded out instead of slammed shut so the
    /// transition feels native.
    func dismissOnGrant() {
        guard let window, window.isVisible else { return }
        window.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // No-op for now – kept so we can hook analytics or completion side
        // effects in later milestones without changing the call sites.
    }
}

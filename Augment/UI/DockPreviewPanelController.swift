import AppKit
import SwiftUI

/// Owns the floating panel that hosts the Dock preview UI.
///
/// The panel is `.nonactivatingPanel` so showing it never steals focus from
/// whatever app is currently in front. It runs at `.statusBar` level so it
/// floats above the Dock and ordinary application windows on every Space and
/// in full-screen contexts.
///
/// The controller is also responsible for the panel's lifetime around the
/// cursor: while visible, it installs a global mouse-moved monitor to keep
/// the panel alive only as long as the cursor is genuinely hovering either
/// the Dock icon (driven by `DockInteractionService`) or the panel itself.
@MainActor
final class DockPreviewPanelController {

    private let panel: NSPanel
    private let viewModel: DockPreviewViewModel
    private let hostingView: NSHostingView<DockPreviewView>

    /// Called whenever the hover preview panel becomes visible or is ordered out,
    /// so `DockInteractionService` can swallow Space for magnify without Finder also receiving it.
    var onPanelVisibilityChanged: ((Bool) -> Void)?

    private var hideTimer: Timer?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var currentBundleID: String?
    private var lastDockSidePreference: NSRectEdge = .minY

    /// Closure invoked by the controller right before the panel hides itself
    /// because the cursor wandered off both the icon and the panel. Lets the
    /// AppDelegate cancel any pending "open" timers it has scheduled.
    var onWillAutoHide: (() -> Void)?

    /// Returns the screen the panel should anchor itself to. When dock-lock
    /// is engaged the AppDelegate supplies the user-selected screen, so the
    /// panel never spawns on the "wrong" display. `nil` falls back to the
    /// screen under the cursor.
    var preferredScreenProvider: (() -> NSScreen?)?

    /// Whether the magnify-on-space gesture is currently allowed. The
    /// AppDelegate flips this from `SharedPreferences`.
    var spaceMagnifyEnabled: Bool = true

    init() {
        let viewModel = DockPreviewViewModel()
        self.viewModel = viewModel
        self.hostingView = NSHostingView(rootView: DockPreviewView(viewModel: viewModel))
        // Keep intrinsic size (the panel is sized from `fittingSize`) but stop
        // the hosting view from driving the window's min/max content size —
        // the same constraint-loop crash the notch panel hit.
        self.hostingView.sizingOptions = [.intrinsicContentSize]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        panel.contentView = hostingView
        panel.alphaValue = 0
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false

        self.panel = panel
    }

    deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
    }

    // MARK: - Configuration hooks

    /// Forwards user-controlled appearance flags from `SharedPreferences`
    /// down into the `DockPreviewViewModel`. Safe to call repeatedly.
    func updateAppearance(
        panelSize: PreviewPanelSize,
        showCloseButton: Bool,
        trafficLightEnabled: Bool,
        trafficLightSide: TrafficLightSide,
        killButtonVisible: Bool,
        middleClickEnabled: Bool,
        dragOutEnabled: Bool,
        headerActionsEnabled: Bool
    ) {
        viewModel.updateAppearance(
            panelSize: panelSize,
            showCloseButton: showCloseButton,
            trafficLightEnabled: trafficLightEnabled,
            trafficLightSide: trafficLightSide,
            killButtonVisible: killButtonVisible,
            middleClickEnabled: middleClickEnabled,
            dragOutEnabled: dragOutEnabled,
            headerActionsEnabled: headerActionsEnabled
        )

        guard panel.isVisible else { return }
        deferGeometryUntilAfterCurrentLayoutPass { [weak self] in
            guard let self, self.panel.isVisible else { return }
            let frame = self.computeFrame(for: self.hostingView.fittingSize)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.panel.animator().setFrame(frame, display: true)
            }
        }
    }

    /// Wires the activate / close / minimize / zoom / kill / drag callbacks
    /// the SwiftUI cells invoke.
    func configureCallbacks(
        onActivate: @escaping (WindowSnapshot) -> Void,
        onClose: @escaping (WindowSnapshot) -> Void,
        onMinimize: @escaping (WindowSnapshot) -> Void,
        onZoom: @escaping (WindowSnapshot) -> Void,
        onKill: @escaping (WindowSnapshot) -> Void,
        onDragOut: @escaping (WindowSnapshot) -> Void,
        onCloseAll: @escaping (String) -> Void,
        onMinimizeAll: @escaping (String) -> Void
    ) {
        viewModel.onActivate = onActivate
        viewModel.onClose = onClose
        viewModel.onMinimize = onMinimize
        viewModel.onZoom = onZoom
        viewModel.onKill = onKill
        viewModel.onDragOut = onDragOut
        viewModel.onCloseAll = { [weak self] in
            guard let self else { return }
            onCloseAll(self.viewModel.bundleID)
        }
        viewModel.onMinimizeAll = { [weak self] in
            guard let self else { return }
            onMinimizeAll(self.viewModel.bundleID)
        }
    }

    // MARK: - Public API

    /// Presents (or updates) the preview panel with the supplied snapshots,
    /// anchored above the current cursor position.
    func show(
        snapshots: [WindowSnapshot],
        bundleID: String,
        displayName: String,
        appIcon: NSImage?
    ) {
        cancelHideTimer()

        let isUpdate = (currentBundleID == bundleID && panel.isVisible)
        currentBundleID = bundleID

        viewModel.update(
            snapshots: snapshots,
            displayName: displayName,
            bundleID: bundleID,
            appIcon: appIcon
        )

        // When the user hovers a fresh icon while a magnified preview is up,
        // collapse the magnified state so it doesn't carry over.
        if !isUpdate {
            viewModel.isMagnified = false
        }

        let bundleForLayout = bundleID
        deferGeometryUntilAfterCurrentLayoutPass { [weak self] in
            guard let self else { return }
            guard self.currentBundleID == bundleForLayout else { return }

            let contentSize = self.hostingView.fittingSize
            let frame = self.computeFrame(for: contentSize)

            if isUpdate {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ctx.allowsImplicitAnimation = true
                    self.panel.animator().setFrame(frame, display: true)
                }
            } else {
                self.panel.alphaValue = 0
                self.panel.setFrame(frame, display: false, animate: false)
                self.panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.panel.animator().alphaValue = 1
                }
            }

            self.installMouseMonitorsIfNeeded()
            self.onPanelVisibilityChanged?(true)
        }
    }

    /// Refreshes the snapshots displayed in the panel without changing
    /// `currentBundleID`. Used after the user closes a thumbnail so the
    /// panel re-renders the remaining windows in place.
    func refresh(snapshots: [WindowSnapshot], displayName: String, appIcon: NSImage?) {
        viewModel.update(
            snapshots: snapshots,
            displayName: displayName,
            bundleID: viewModel.bundleID,
            appIcon: appIcon
        )
        guard panel.isVisible else { return }
        deferGeometryUntilAfterCurrentLayoutPass { [weak self] in
            guard let self, self.panel.isVisible else { return }
            let frame = self.computeFrame(for: self.hostingView.fittingSize)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.panel.animator().setFrame(frame, display: true)
            }
        }
    }

    /// Drops the supplied window from the panel's snapshot list immediately,
    /// without waiting for the next AX poll. The Dock service has just
    /// dispatched a close (or minimize) for this window; reflecting that in
    /// the UI right away keeps the panel from showing a thumbnail of a
    /// window that is, from the user's perspective, already gone.
    ///
    /// The follow-up `rerenderPanelAfterMutation` in the AppDelegate still
    /// runs and corrects the list if the close failed for some reason.
    func removeSnapshotOptimistically(_ snapshot: WindowSnapshot) {
        let id = snapshot.id
        let remaining = viewModel.snapshots.filter { $0.id != id }
        if remaining.isEmpty {
            hideImmediately()
            return
        }
        guard viewModel.removeSnapshot(id: id) else { return }
        guard panel.isVisible else { return }
        deferGeometryUntilAfterCurrentLayoutPass { [weak self] in
            guard let self, self.panel.isVisible else { return }
            let frame = self.computeFrame(for: self.hostingView.fittingSize)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.panel.animator().setFrame(frame, display: true)
            }
        }
    }

    /// Schedules a fade-out after the supplied delay. The hide is cancelled
    /// if `show` or `cancelHide` is invoked before it fires.
    func scheduleHide(after delay: TimeInterval = 0.18) {
        cancelHideTimer()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideImmediately() }
        }
    }

    /// Cancels any pending fade-out without altering visibility.
    func cancelHide() {
        cancelHideTimer()
    }

    /// Immediately fades the panel out and orders it off-screen.
    func hideImmediately() {
        cancelHideTimer()
        currentBundleID = nil
        viewModel.isMagnified = false
        removeMouseMonitors()
        onPanelVisibilityChanged?(false)
        guard panel.isVisible else { return }
        let panelRef = panel
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
        } completionHandler: {
            panelRef.orderOut(nil)
            panelRef.alphaValue = 1
        }
    }

    /// Reports whether the cursor is currently inside the visible panel
    /// frame. Used by the AppDelegate to keep the panel alive while the
    /// user is reading the previews instead of hovering the Dock icon.
    func isCursorOverPanel() -> Bool {
        guard panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    var isVisible: Bool { panel.isVisible }

    var presentingBundleID: String? { currentBundleID }

    // MARK: - Magnification toggle

    /// Toggles the magnified preview if the underlying preference allows.
    func toggleMagnification() {
        guard spaceMagnifyEnabled else { return }
        guard panel.isVisible else { return }
        viewModel.isMagnified.toggle()

        deferGeometryUntilAfterCurrentLayoutPass { [weak self] in
            guard let self, self.panel.isVisible else { return }
            let frame = self.computeFrame(for: self.hostingView.fittingSize)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.panel.animator().setFrame(frame, display: true)
            }
        }
    }

    // MARK: - Layout

    /// `NSHostingView` may still be inside a layout pass when `ObservableObject`
    /// updates propagate. Reading `fittingSize` and resizing the panel in that
    /// same turn triggers AppKit’s nested `-layoutSubtreeIfNeeded` check.
    /// A single `async` isn’t always enough; nesting two main-queue passes runs after
    /// SwiftUI has finished the current layout subtree.
    private func deferGeometryUntilAfterCurrentLayoutPass(_ body: @escaping () -> Void) {
        DispatchQueue.main.async {
            DispatchQueue.main.async(execute: body)
        }
    }

    private func computeFrame(for contentSize: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen: NSScreen = preferredScreenProvider?()
            ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!

        let visible = screen.visibleFrame
        let width = max(contentSize.width, 220)
        let height = max(contentSize.height, 80)

        // Detect Dock side – when the visible frame is significantly inset
        // from the left or right of the screen, the Dock is on that side.
        let leftInset = visible.minX - screen.frame.minX
        let rightInset = screen.frame.maxX - visible.maxX
        let dockSide: NSRectEdge
        if leftInset > rightInset && leftInset > 32 {
            dockSide = .minX
        } else if rightInset > leftInset && rightInset > 32 {
            dockSide = .maxX
        } else {
            dockSide = .minY
        }
        lastDockSidePreference = dockSide

        let inset: CGFloat = 12
        let gap: CGFloat = 14

        var x: CGFloat
        var y: CGFloat

        switch dockSide {
        case .minX:
            x = visible.minX + gap
            y = max(visible.minY + inset, min(visible.maxY - height - inset, mouse.y - height / 2))
        case .maxX:
            x = visible.maxX - width - gap
            y = max(visible.minY + inset, min(visible.maxY - height - inset, mouse.y - height / 2))
        default:
            // Anchor just above the Dock and try to center on the cursor.
            x = max(visible.minX + inset, min(visible.maxX - width - inset, mouse.x - width / 2))
            y = visible.minY + gap
            if y < screen.frame.minY + gap {
                y = screen.frame.minY + gap
            }
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    // MARK: - Mouse monitors

    private func installMouseMonitorsIfNeeded() {
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
                [weak self] _ in
                Task { @MainActor in self?.handleGlobalMouseMoved() }
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
                [weak self] event in
                Task { @MainActor in self?.handleGlobalMouseMoved() }
                return event
            }
        }
    }

    private func removeMouseMonitors() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        mouseMonitor = nil
        localMouseMonitor = nil
    }

    /// Re-evaluates panel visibility when the cursor moves anywhere on
    /// screen. Inside the panel: keep it open. Outside: schedule a soft
    /// hide. The dock service-driven `show()` cancels any pending hide
    /// when the cursor returns to a Dock icon, so this loop is safe to
    /// run unconditionally.
    private func handleGlobalMouseMoved() {
        guard panel.isVisible else { return }
        if panel.frame.contains(NSEvent.mouseLocation) {
            cancelHide()
        } else {
            // While magnified, keep the panel alive aggressively – the user
            // is reading the larger preview and will move off the Dock icon
            // by definition.
            if viewModel.isMagnified { return }
            if hideTimer == nil {
                onWillAutoHide?()
                scheduleHide(after: 0.22)
            }
        }
    }
}

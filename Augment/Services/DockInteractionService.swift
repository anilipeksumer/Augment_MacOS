import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

/// Global Dock interaction tap.
///
/// Installs a `CGEventTap` on `.cgSessionEventTap` listening for mouse moves,
/// left-mouse-down and other-mouse-down events. For each interesting event
/// the service uses `AXUIElementCopyElementAtPosition` against the
/// system-wide AX element to detect whether the cursor is currently over a
/// Dock icon owned by the `com.apple.dock` process. When it is, the service
/// resolves that icon to a bundle identifier (preferring the AX `AXURL`
/// attribute, with the icon's AX title as a fallback for stack/folder icons
/// that don't expose a URL).
///
/// The tap runs as a default tap so the service can suppress mouse-down
/// events that target a Dock icon when the relevant Augment feature is
/// enabled. Without that, macOS's own Dock click handler races our AX
/// minimize and immediately un-minimizes the window. Hover events are
/// always passed through, and clicks that don't land on a Dock icon are
/// passed through verbatim, so other apps see exactly the same input
/// stream as before.
final class DockInteractionService {

    enum StartResult {
        case started
        case missingAccessibilityTrust
        case tapCreationFailed
    }

    /// High-level interaction events the service emits to its consumer.
    enum InteractionEvent {
        /// Cursor entered a different (or no) Dock icon. `nil` means the
        /// cursor is no longer over any Dock icon.
        case hoverChanged(bundleID: String?)
        /// Left mouse button was pressed while over a Dock icon.
        case iconClicked(bundleID: String)
        /// Middle mouse button was pressed while over a Dock icon.
        case iconMiddleClicked(bundleID: String)
    }

    /// Callback invoked on the main thread for every emitted event.
    var onEvent: ((InteractionEvent) -> Void)?

    /// Closure consulted when filtering events by Dock-lock rules. Return
    /// `false` to make the service ignore the supplied screen point. Set
    /// from `AppDelegate` so dock-lock toggles can take effect immediately.
    var allowEventAtPoint: ((CGPoint) -> Bool)?

    /// Returns `true` if Augment should intercept the left-mouse-down
    /// targeted at the Dock icon for `bundleID`. The check happens per
    /// click so the AppDelegate can refuse to swallow events that belong
    /// to apps we have no useful action for (e.g. apps that are not
    /// running yet — those clicks must reach the system Dock so it can
    /// launch the app normally).
    var shouldHandleLeftClick: (String) -> Bool = { _ in false }

    /// Same idea for middle-mouse-down events. Defaults to `false` so a
    /// freshly-built service mimics the previous listen-only behaviour
    /// until the AppDelegate wires preferences in.
    var shouldHandleMiddleClick: (String) -> Bool = { _ in false }

    /// While the Dock hover preview panel is visible, Space can otherwise
    /// reach the frontmost app (e.g. Finder Quick Look) at the same time as
    /// Augment’s magnify gesture. `NSEvent` global monitors cannot consume
    /// keys — only a `CGEventTap` can swallow Space here.
    private let dockPreviewVisibilityLock = NSLock()
    private var dockPreviewPanelIsVisible = false

    /// Called from the main thread when the hover preview panel shows or hides.
    func setDockPreviewPanelVisible(_ visible: Bool) {
        dockPreviewVisibilityLock.lock()
        dockPreviewPanelIsVisible = visible
        dockPreviewVisibilityLock.unlock()
    }

    /// Invoked on the main queue when Space was swallowed for dock-preview magnify.
    var onSpaceConsumedForDockPreviewMagnify: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dockPID: pid_t = 0
    private var lastHoveredBundle: String?
    private var lastHoverProcessTime: CFTimeInterval = 0
    /// Throttle hover lookups to ~25 Hz to keep the AX traffic bounded even
    /// during very fast cursor movements.
    private let hoverThrottleInterval: CFTimeInterval = 0.04

    @discardableResult
    func start() -> StartResult {
        guard AXIsProcessTrusted() else {
            return .missingAccessibilityTrust
        }
        if eventTap != nil {
            return .started
        }

        resolveDockPID()

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<DockInteractionService>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = service.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    if service.handleKeyDownForDockPreviewSuppression(event: event) {
                        return nil
                    }
                    return Unmanaged.passUnretained(event)
                }
                if service.handle(type: type, event: event) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            return .tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return .started
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        lastHoveredBundle = nil
    }

    // MARK: - Internals

    /// Returns true when the event must not reach apps (Finder Quick Look, etc.).
    private func handleKeyDownForDockPreviewSuppression(event: CGEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == 49 else { return false } // Space

        dockPreviewVisibilityLock.lock()
        let previewUp = dockPreviewPanelIsVisible
        dockPreviewVisibilityLock.unlock()
        guard previewUp else { return false }
        guard AppGroup.preferencesBool(forKey: AppGroupKey.spaceMagnifyEnabled) else { return false }

        DispatchQueue.main.async { [weak self] in
            self?.onSpaceConsumedForDockPreviewMagnify?()
        }
        return true
    }

    private func resolveDockPID() {
        if let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first {
            dockPID = dock.processIdentifier
        }
    }

    /// Returns `true` when the event should be swallowed before the system
    /// Dock can act on it. Hover and non-Dock clicks always return `false`
    /// so the event continues down the standard input pipeline.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let location = event.location

        // Dock-lock filter is applied at the event boundary. When locked,
        // events outside the user-selected screens are silently dropped so
        // the panel never spawns on the "wrong" display.
        if let allowEventAtPoint, !allowEventAtPoint(location) {
            // For mouseMoved we still want to send a `hoverChanged(nil)`
            // so any open panel auto-hides cleanly when the cursor leaves
            // the locked display.
            if type == .mouseMoved && lastHoveredBundle != nil {
                lastHoveredBundle = nil
                DispatchQueue.main.async { [onEvent] in
                    onEvent?(.hoverChanged(bundleID: nil))
                }
            }
            // Best effort: nudge the cursor up out of the Dock-summon zone
            // on non-locked screens. macOS does not expose a public API
            // that pins the system Dock to a specific display, so this
            // cursor warp is what makes the "lock" actually feel like a
            // lock. It runs only on mouse movement, never on clicks, so
            // the user can still click anywhere on the non-locked screen.
            if type == .mouseMoved {
                confineCursorAwayFromDockZoneIfNeeded()
            }
            return false
        }

        switch type {
        case .mouseMoved:
            handleHover(at: location)
            return false
        case .leftMouseDown:
            return handleClick(at: location)
        case .otherMouseDown:
            // CG only labels button 2 (middle) under .otherMouseDown.
            // Filter for button==2 explicitly so right-click variants on
            // exotic mice never fire the close action.
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if button == 2 {
                return handleMiddleClick(at: location)
            }
            return false
        default:
            return false
        }
    }

    private func handleHover(at point: CGPoint) {
        let now = CACurrentMediaTime()
        guard now - lastHoverProcessTime >= hoverThrottleInterval else { return }
        lastHoverProcessTime = now

        let bundleID = bundleIDForDockIcon(at: point)
        if bundleID != lastHoveredBundle {
            lastHoveredBundle = bundleID
            DispatchQueue.main.async { [onEvent] in
                onEvent?(.hoverChanged(bundleID: bundleID))
            }
        }
    }

    private func handleClick(at point: CGPoint) -> Bool {
        guard let bundleID = bundleIDForDockIcon(at: point) else { return false }
        guard shouldHandleLeftClick(bundleID) else { return false }
        DispatchQueue.main.async { [onEvent] in
            onEvent?(.iconClicked(bundleID: bundleID))
        }
        return true
    }

    private func handleMiddleClick(at point: CGPoint) -> Bool {
        guard let bundleID = bundleIDForDockIcon(at: point) else { return false }
        guard shouldHandleMiddleClick(bundleID) else { return false }
        DispatchQueue.main.async { [onEvent] in
            onEvent?(.iconMiddleClicked(bundleID: bundleID))
        }
        return true
    }

    /// Resolves the bundle identifier of the Dock icon currently under the
    /// supplied screen location, or `nil` if the cursor is not over a Dock
    /// element owned by `com.apple.dock`.
    private func bundleIDForDockIcon(at point: CGPoint) -> String? {
        if dockPID == 0 { resolveDockPID() }
        guard dockPID != 0 else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element
        )
        guard status == .success, let element else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == dockPID else {
            return nil
        }

        // Most reliable signal: Dock items expose AXURL pointing at the app
        // bundle on disk. Resolve directly to a bundle identifier from there.
        var urlValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlValue) == .success {
            if let url = urlValue as? URL,
               let bundleID = Bundle(url: url)?.bundleIdentifier {
                return bundleID
            }
            if let str = urlValue as? String,
               let url = URL(string: str),
               let bundleID = Bundle(url: url)?.bundleIdentifier {
                return bundleID
            }
        }

        // Fallback: match running apps by display name.
        var titleValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
           let title = titleValue as? String, !title.isEmpty {
            return resolveBundleID(forAppName: title)
        }

        return nil
    }

    private func resolveBundleID(forAppName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let running = NSWorkspace.shared.runningApplications

        if let match = running.first(where: { $0.localizedName == trimmed })?.bundleIdentifier {
            return match
        }
        if let match = running.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        })?.bundleIdentifier {
            return match
        }
        // Dock stacks / badges sometimes append suffix text to the AX title.
        if let match = running.first(where: { app in
            guard let n = app.localizedName, !n.isEmpty else { return false }
            return trimmed.hasPrefix(n) || n.hasPrefix(trimmed)
        })?.bundleIdentifier {
            return match
        }
        return nil
    }

    /// When the cursor sits inside the bottom-edge "Dock-summon" zone of a
    /// screen that the user has *not* locked the Dock to, lift the cursor
    /// a few pixels up so macOS doesn't auto-show the Dock there.
    ///
    /// Reads the cursor position via `NSEvent.mouseLocation` (AppKit
    /// coordinates) so the screen-frame check matches the layout the user
    /// configured in System Settings, then routes the warp target through
    /// the shared `ScreenGeometry` converter so we don't duplicate axis
    /// arithmetic across the codebase.
    private func dockOrientation() -> String {
        if let defaults = UserDefaults(suiteName: "com.apple.dock"),
           let orientation = defaults.string(forKey: "orientation") {
            return orientation
        }
        return "bottom"
    }

    private func confineCursorAwayFromDockZoneIfNeeded() {
        let mouse = NSEvent.mouseLocation
        guard let screen = ScreenGeometry.screen(containing: mouse) else { return }

        // 12 px is wide enough to catch macOS's auto-show trigger band
        let triggerMargin: CGFloat = 12
        let pushAmount: CGFloat = 28
        let orientation = dockOrientation()

        var warpRequired = false
        var targetMouse = mouse

        if orientation == "left" {
            if mouse.x - screen.frame.minX < triggerMargin {
                targetMouse.x = screen.frame.minX + pushAmount
                warpRequired = true
            }
        } else if orientation == "right" {
            if screen.frame.maxX - mouse.x < triggerMargin {
                targetMouse.x = screen.frame.maxX - pushAmount
                warpRequired = true
            }
        } else {
            if mouse.y - screen.frame.minY < triggerMargin {
                targetMouse.y = screen.frame.minY + pushAmount
                warpRequired = true
            }
        }

        if warpRequired {
            let cgPoint = ScreenGeometry.convertToCG(targetMouse)
            CGWarpMouseCursorPosition(cgPoint)
        }
    }
}

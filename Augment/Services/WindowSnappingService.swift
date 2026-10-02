import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

// MARK: - Snap direction & shortcut model

/// Cardinal directions a window can be snapped to.
enum SnapDirection: String, CaseIterable, Codable, Identifiable {
    case left, right, up, down

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left:  return Localizer.string("snapping.left_half")
        case .right: return Localizer.string("snapping.right_half")
        case .up:    return Localizer.string("snapping.maximize")
        case .down:  return Localizer.string("snapping.restore_center")
        }
    }

    /// Default key code (Carbon virtual key code) for this direction.
    var defaultKeyCode: UInt16 {
        switch self {
        case .left:  return UInt16(kVK_LeftArrow)
        case .right: return UInt16(kVK_RightArrow)
        case .up:    return UInt16(kVK_UpArrow)
        case .down:  return UInt16(kVK_DownArrow)
        }
    }

    /// Default modifier flags (Cmd).
    var defaultModifiers: CGEventFlags {
        .maskCommand
    }
}

/// Persisted shortcut binding for a single snap direction.
struct SnapShortcut: Codable, Equatable {
    let modifiers: UInt64
    let keyCode: UInt16

    /// The modifier flags as `CGEventFlags` (for event-tap matching).
    var eventFlags: CGEventFlags {
        CGEventFlags(rawValue: modifiers)
    }

    /// The modifier flags as `NSEvent.ModifierFlags` (for UI display).
    var nsModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifiers & 0x00FF_FFFF))
    }
}

/// Full set of snap shortcut overrides, keyed by direction.
typealias SnapShortcutMap = [String: SnapShortcut]

// MARK: - Service

/// Installs a global CGEvent tap that intercepts configurable keyboard
/// shortcuts (default: Cmd + Arrow Keys) and snaps the frontmost window
/// to screen halves / maximized / restored.
///
/// The service requires Accessibility to be granted (it manipulates
/// windows through `AXUIElement`). It consumes matched key-down events
/// so the underlying app never sees them while snapping is active.
@MainActor
final class WindowSnappingService {

    /// Whether the event tap is currently installed and active.
    private(set) var isRunning = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Cached shortcut configuration. Rebuilt every time the user changes
    /// preferences so the hot path (event callback) does zero JSON parsing.
    private var shortcuts: [SnapDirection: SnapShortcut] = [:]

    /// Stores the frame a window had before the last snap so "down" can
    /// restore. Keyed by (PID, windowID via title hash) for simplicity.
    private var restoreFrames: [String: CGRect] = [:]

    // MARK: - Public API

    func start(shortcutsJSON: String) {
        rebuildShortcuts(from: shortcutsJSON)
        guard !isRunning else { return }
        installEventTap()
    }

    func stop() {
        guard isRunning else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        isRunning = false
    }

    func updateShortcuts(_ json: String) {
        rebuildShortcuts(from: json)
    }

    // MARK: - Event tap

    private func installEventTap() {
        // We need a reference to `self` inside the C callback. Store it
        // as an unretained pointer; the service's lifetime always exceeds
        // the tap's.
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<WindowSnappingService>.fromOpaque(refcon)
                    .takeUnretainedValue()
                return service.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("Augment: WindowSnappingService – failed to create event tap (Accessibility?)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    // MARK: - Event handling

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if macOS disabled it (e.g. unresponsive timer).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != FinderOpenShortcutService.syntheticEventTag else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Strip away device-dependent bits so comparison is clean.
        let significantFlags = flags.intersection([
            .maskCommand, .maskShift, .maskAlternate, .maskControl
        ])

        for (direction, shortcut) in shortcuts {
            let wantedFlags = CGEventFlags(rawValue: shortcut.modifiers).intersection([
                .maskCommand, .maskShift, .maskAlternate, .maskControl
            ])
            if keyCode == shortcut.keyCode && significantFlags == wantedFlags {
                // Perform the snap on the main actor.
                DispatchQueue.main.async { [weak self] in
                    self?.snap(direction: direction)
                }
                return nil  // consume the event
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Snap logic

    private func snap(direction: SnapDirection) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedValue
        ) == .success else { return }
        guard let window = AXElementCoercion.element(focusedValue) else { return }

        // Get the screen the window is mostly on.
        guard let windowFrame = axFrame(of: window),
              let screen = bestScreen(for: windowFrame) else { return }

        let visibleFrame = screen.visibleFrame  // respects menu bar + Dock

        // Save restore frame before first snap.
        let restoreKey = "\(frontApp.processIdentifier)_\(axTitle(of: window) ?? "untitled")"
        if restoreFrames[restoreKey] == nil {
            restoreFrames[restoreKey] = windowFrame
        }

        let targetFrame: CGRect
        switch direction {
        case .left:
            targetFrame = CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .right:
            targetFrame = CGRect(
                x: visibleFrame.midX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .up:
            targetFrame = visibleFrame
        case .down:
            if let saved = restoreFrames[restoreKey] {
                targetFrame = saved
                restoreFrames.removeValue(forKey: restoreKey)
            } else {
                // Center the window at 60% of screen size.
                let w = visibleFrame.width * 0.6
                let h = visibleFrame.height * 0.6
                targetFrame = CGRect(
                    x: visibleFrame.midX - w / 2,
                    y: visibleFrame.midY - h / 2,
                    width: w,
                    height: h
                )
            }
        }

        setAXFrame(window, to: targetFrame)
    }

    // MARK: - AX helpers

    private func axFrame(of window: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &posValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                window, kAXSizeAttribute as CFString, &sizeValue
              ) == .success else { return nil }

        guard let point = AXElementCoercion.point(from: posValue),
              let size = AXElementCoercion.size(from: sizeValue) else { return nil }

        // AX uses top-left origin (CG coords). Convert to AppKit for
        // screen matching.
        let appKitPoint = ScreenGeometry.convertFromCG(point)
        return CGRect(
            x: appKitPoint.x,
            y: appKitPoint.y - size.height,  // bottom-left origin
            width: size.width,
            height: size.height
        )
    }

    private func setAXFrame(_ window: AXUIElement, to frame: CGRect) {
        // Convert AppKit frame (bottom-left) back to CG (top-left) for AX.
        var position = ScreenGeometry.convertToCG(
            CGPoint(x: frame.minX, y: frame.maxY)
        )
        var size = CGSize(width: frame.width, height: frame.height)

        if let posVal = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
    }

    private func axTitle(of window: AXUIElement) -> String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        return value as? String
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        var bestOverlap: CGFloat = 0
        var bestScreen: NSScreen?
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(frame)
            let area = overlap.width * overlap.height
            if area > bestOverlap {
                bestOverlap = area
                bestScreen = screen
            }
        }
        return bestScreen ?? NSScreen.main
    }

    // MARK: - Shortcut parsing

    func rebuildShortcuts(from json: String) {
        shortcuts = Self.shortcuts(from: json)
    }

    nonisolated static func shortcuts(from json: String) -> [SnapDirection: SnapShortcut] {
        if json.isEmpty {
            // Use defaults: Cmd + Arrow keys.
            return Dictionary(uniqueKeysWithValues: SnapDirection.allCases.map {
                ($0, SnapShortcut(
                    modifiers: $0.defaultModifiers.rawValue,
                    keyCode: $0.defaultKeyCode
                ))
            })
        }

        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SnapShortcutMap.self, from: data)
        else {
            NSLog("Augment: WindowSnappingService – failed to decode shortcuts JSON, using defaults.")
            return Dictionary(uniqueKeysWithValues: SnapDirection.allCases.map {
                ($0, SnapShortcut(
                    modifiers: $0.defaultModifiers.rawValue,
                    keyCode: $0.defaultKeyCode
                ))
            })
        }

        var result: [SnapDirection: SnapShortcut] = [:]
        for direction in SnapDirection.allCases {
            if let override = decoded[direction.rawValue] {
                result[direction] = override
            } else {
                result[direction] = SnapShortcut(
                    modifiers: direction.defaultModifiers.rawValue,
                    keyCode: direction.defaultKeyCode
                )
            }
        }
        return result
    }
}

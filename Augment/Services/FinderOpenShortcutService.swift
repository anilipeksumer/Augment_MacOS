import AppKit
import ApplicationServices
import Carbon

/// Configurable Return/Open behavior scoped to Finder selection, never text editing.
@MainActor
final class FinderOpenShortcutService {
    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    enum Action { case open, rename }
    private var mode: FinderEnterBehavior = .system
    private var pressedKey: (key: Int64, action: Action)?

    func start(mode: FinderEnterBehavior) {
        self.mode = mode
        guard mode != .system else { stop(); return }
        guard !isRunning else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                         callback: { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<FinderOpenShortcutService>.fromOpaque(context).takeUnretainedValue()
                .handle(proxy: proxy, type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        pressedKey = nil
        isRunning = false
    }

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            pressedKey = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        // Match key-up even if Shift has already been released or opening a
        // file activated another app. Suppress repeats so one hold opens once.
        if let pressed = pressedKey, pressed.key == key {
            if type == .keyUp {
                pressedKey = nil
                Self.send(pressed.action, type: type, original: event, proxy: proxy)
                return nil
            }
            if type == .keyDown { return nil }
        }
        guard type == .keyDown,
              let action = Self.action(keyCode: key, flags: event.flags, mode: mode),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.finder",
              Self.canOpenSelection(pid: app.processIdentifier) else { return Unmanaged.passUnretained(event) }
        pressedKey = (key, action)
        Self.send(action, type: type, original: event, proxy: proxy)
        return nil
    }

    static func action(keyCode: Int64, flags: CGEventFlags, mode: FinderEnterBehavior) -> Action? {
        guard keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter else { return nil }
        let modifiers = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        switch mode {
        case .system: return nil
        case .shiftEnterOpens: return modifiers == .maskShift ? .open : nil
        case .enterOpens:
            if modifiers.isEmpty { return .open }
            return modifiers == .maskShift ? .rename : nil
        }
    }

    private static func send(_ action: Action, type: CGEventType, original: CGEvent, proxy: CGEventTapProxy) {
        // Build a fresh keyboard event: changing only the keycode on Return
        // leaves its original text payload, which Finder can treat as Return.
        // Cmd-O also avoids Augment's Cmd-arrow window snapping shortcuts.
        let key = CGKeyCode(action == .open ? kVK_ANSI_O : kVK_Return)
        guard let replacement = CGEvent(keyboardEventSource: CGEventSource(event: original),
                                        virtualKey: key, keyDown: type == .keyDown) else { return }
        replacement.flags = action == .open ? .maskCommand : []
        replacement.tapPostEvent(proxy)
    }

    static func canOpenSelection(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.025)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              var element = AXElementCoercion.element(focused) else { return false }
        // Rename, search and Go to Folder use editable controls; Shift-Return
        // must remain a text-editing key there. Sheets/dialogs are excluded too.
        for _ in 0..<8 {
            AXUIElementSetMessagingTimeout(element, 0.025)
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                  let role = role as? String else { return false }
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSheetRole].contains(role) { return false }
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if subrole as? String == kAXDialogSubrole { return false }
            if role == kAXWindowRole || role == kAXApplicationRole { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = AXElementCoercion.element(parent) else { return false }
            element = next
        }
        return false
    }
}

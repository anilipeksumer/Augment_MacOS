import AppKit
import ApplicationServices
import Carbon

/// Configurable Return/Open behavior scoped to Finder selection, never text editing.
@MainActor
final class FinderOpenShortcutService {
    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    enum Action { case open, rename, parent, pasteImage }
    static let syntheticEventTag: Int64 = 0x41554746494E44
    private var backspace = false
    private var blankDoubleClick = false
    private var middleClick = false
    private var pasteImage = false
    private var f2 = false
    private var swallowedMouseUp: CGEventType?
    private var pendingMouse: (point: CGPoint, folder: URL?)?
    private var isOpeningTab = false
    private var mode: FinderEnterBehavior = .system
    private var pressedKey: (key: Int64, action: Action)?

    func start(mode: FinderEnterBehavior, backspace: Bool = false, blankDoubleClick: Bool = false,
               middleClick: Bool = false, pasteImage: Bool = false, f2: Bool = false) {
        self.mode = mode
        self.backspace = backspace
        self.blankDoubleClick = blankDoubleClick
        self.middleClick = middleClick
        self.pasteImage = pasteImage
        self.f2 = f2
        guard mode != .system || backspace || blankDoubleClick || middleClick || pasteImage || f2 else { stop(); return }
        guard !isRunning else { return }
        let mask = [CGEventType.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
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
        swallowedMouseUp = nil
        pendingMouse = nil
        isRunning = false
    }

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            pressedKey = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventTag else { return Unmanaged.passUnretained(event) }
        if [.leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp].contains(type) {
            return handleMouse(type: type, event: event)
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
              let action = Self.action(keyCode: key, flags: event.flags, mode: mode, backspace: backspace, f2: f2, pasteImage: pasteImage),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.finder",
              Self.canOpenSelection(pid: app.processIdentifier) else { return Unmanaged.passUnretained(event) }
        if action == .pasteImage {
            guard let data = ClipboardImageStore.data(from: .general), Self.canAutomateFinder else { return Unmanaged.passUnretained(event) }
            let name = Localizer.string("finder.image_name")
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: "tell application \"Finder\" to get POSIX path of (target of front Finder window as alias)")
                guard let path = script?.executeAndReturnError(&error).stringValue, error == nil,
                      let png = ClipboardImageStore.pngData(data) else { DispatchQueue.main.async { NSSound.beep() }; return }
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                do { _ = try ClipboardImageStore.writePNG(png, to: folder, baseName: name) }
                catch { DispatchQueue.main.async { NSSound.beep() } }
            }
        }
        pressedKey = (key, action)
        Self.send(action, type: type, original: event, proxy: proxy)
        return nil
    }

    static func action(keyCode: Int64, flags: CGEventFlags, mode: FinderEnterBehavior,
                       backspace: Bool = false, f2: Bool = false, pasteImage: Bool = false) -> Action? {
        let modifiers = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        if backspace && keyCode == kVK_Delete && modifiers.isEmpty { return .parent }
        if f2 && keyCode == kVK_F2 && modifiers.isEmpty { return .rename }
        if pasteImage && keyCode == kVK_ANSI_V && modifiers == .maskCommand { return .pasteImage }
        guard keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter else { return nil }
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
        guard action != .pasteImage else { return }
        let key = CGKeyCode(action == .parent ? kVK_UpArrow : (action == .open ? kVK_ANSI_O : kVK_Return))
        guard let replacement = CGEvent(keyboardEventSource: CGEventSource(event: original),
                                        virtualKey: key, keyDown: type == .keyDown) else { return }
        replacement.flags = action == .rename ? [] : .maskCommand
        replacement.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        replacement.tapPostEvent(proxy)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    static func fileURL(_ value: CFTypeRef?) -> URL? {
        let raw = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let raw, raw.isFileURL else { return nil }
        return (raw as NSURL).filePathURL
    }

    private static func itemURL(_ element: AXUIElement, depth: Int = 0) -> URL? {
        if let url = fileURL(attribute(element, kAXURLAttribute)) { return url }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        guard depth < 3, [kAXGroupRole, kAXRowRole, kAXCellRole].contains(role) else { return nil }
        for child in ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(8) {
            if let url = itemURL(child, depth: depth + 1) { return url }
        }
        return nil
    }

    struct Hit {
        let element: AXUIElement
        let folder: URL?
        let isBlank: Bool
    }

    static func hit(at point: CGPoint, pid: pid_t) -> Hit? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.025)
        var value: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &value) == .success,
              let leaf = value else { return nil }
        let leafRole = attribute(leaf, kAXRoleAttribute) as? String ?? ""
        var blank = [kAXScrollAreaRole, kAXListRole, kAXOutlineRole, kAXBrowserRole].contains(leafRole)
        var folder: URL?
        var element = leaf
        var standardWindow = false
        var splitGroups = 0
        for _ in 0..<10 {
            let identifier = attribute(element, kAXIdentifierAttribute) as? String ?? ""
            if identifier.localizedCaseInsensitiveContains("sidebar") { return nil }
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if [kAXToolbarRole, kAXButtonRole, kAXTextFieldRole, kAXSheetRole, kAXMenuRole].contains(role) { return nil }
            if role == kAXSplitGroupRole { splitGroups += 1 }
            if folder == nil, let url = itemURL(element),
               let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
               values.isDirectory == true, values.isPackage != true { folder = url; blank = false }
            if role == kAXWindowRole {
                standardWindow = attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
                break
            }
            guard let parent = AXElementCoercion.element(attribute(element, kAXParentAttribute)) else { break }
            element = parent
        }
        return standardWindow && splitGroups >= 2 ? Hit(element: leaf, folder: folder, isBlank: blank) : nil
    }

    private func handleMouse(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == swallowedMouseUp {
            swallowedMouseUp = nil
            let action = pendingMouse
            pendingMouse = nil
            if let action, hypot(event.location.x - action.point.x, event.location.y - action.point.y) < 6 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning,
                          let finder = NSWorkspace.shared.frontmostApplication, finder.bundleIdentifier == "com.apple.finder" else { return }
                    if let folder = action.folder { self.openInNewTab(folder, pid: finder.processIdentifier) }
                    else { Self.postKey(kVK_UpArrow, flags: .maskCommand) }
                }
            }
            return nil
        }
        let middle = middleClick && type == .otherMouseDown && event.getIntegerValueField(.mouseEventButtonNumber) == 2
        let double = blankDoubleClick && type == .leftMouseDown && event.getIntegerValueField(.mouseEventClickState) == 2
        guard middle || double,
              event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty,
              let finder = NSWorkspace.shared.frontmostApplication, finder.bundleIdentifier == "com.apple.finder",
              Self.canOpenSelection(pid: finder.processIdentifier),
              let hit = Self.hit(at: event.location, pid: finder.processIdentifier) else { return Unmanaged.passUnretained(event) }
        if double && hit.isBlank {
            swallowedMouseUp = .leftMouseUp
            pendingMouse = (event.location, nil)
            return nil
        }
        if middle, let folder = hit.folder, Self.canAutomateFinder {
            swallowedMouseUp = .otherMouseUp
            pendingMouse = (event.location, folder)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    static func postKey(_ code: Int, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event?.post(tap: .cghidEventTap)
        }
    }

    static var canAutomateFinder: Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
    }

    private func openInNewTab(_ folder: URL, pid: pid_t) {
        guard !isOpeningTab else { return }
        isOpeningTab = true
        let app = AXUIElementCreateApplication(pid)
        let oldWindow = AXElementCoercion.element(Self.attribute(app, kAXFocusedWindowAttribute))
        // Finder has no AppleScript 'make tab' command. Create a native tab,
        // then set only the newly selected tab's target through Finder.
        let previousTabs = Self.tabCount(in: oldWindow)
        Self.postKey(kVK_ANSI_T, flags: .maskCommand)
        Task { @MainActor [weak self] in
            defer { self?.isOpeningTab = false }
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard self?.isRunning == true, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                let current = AXElementCoercion.element(Self.attribute(app, kAXFocusedWindowAttribute))
                guard Self.tabCount(in: current) > previousTabs else { continue }
                let path = folder.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let script = "tell application \"Finder\" to set target of front Finder window to (POSIX file \"\(path)\" as alias)"
                DispatchQueue.global(qos: .userInitiated).async {
                    var error: NSDictionary?
                    _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
                    if error != nil { DispatchQueue.main.async { NSSound.beep() } }
                }
                return
            }
        }
    }

    static func tabCount(in window: AXUIElement?) -> Int {
        guard let window else { return 0 }
        func count(_ element: AXUIElement, depth: Int) -> Int {
            guard depth < 4 else { return 0 }
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == kAXTabGroupRole { return (attribute(element, kAXTabsAttribute) as? [AXUIElement])?.count ?? 0 }
            guard depth == 0 || role == kAXGroupRole || role == kAXSplitGroupRole else { return 0 }
            for child in ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(30) {
                let result = count(child, depth: depth + 1)
                if result > 0 { return result }
            }
            return 0
        }
        return count(window, depth: 0)
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
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSheetRole, kAXMenuRole, kAXMenuItemRole].contains(role) { return false }
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

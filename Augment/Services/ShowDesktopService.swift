import AppKit
import Carbon
import Combine
import ApplicationServices

/// Minimizes real application windows and restores only this session's windows.
@MainActor
final class ShowDesktopService: ObservableObject {
    static let shared = ShowDesktopService()
    @Published private(set) var shortcutAvailable = true
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var lastToggle = Date.distantPast
    private var enabled = false

    @Published private(set) var hasWindowsToRestore = false
    @Published private(set) var isBusy = false
    private let worker = DesktopWindowWorker()
    private let queue = DispatchQueue(label: "com.anilipeksumer.augment.desktop", qos: .userInitiated)
    private var previousApplication: NSRunningApplication?

    func setEnabled(_ enabled: Bool) {
        stop()
        self.enabled = enabled
        guard enabled else { return }
        // Use key release so holding the shortcut never repeatedly toggles.
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x41554454, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in ShowDesktopService.shared.toggle() }
            return noErr
        }, 1, &event, nil, &handler)
        guard status == noErr else { shortcutAvailable = false; return }
        let identifier = EventHotKeyID(signature: 0x41554454, id: 1)
        shortcutAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey),
                                               identifier, GetApplicationEventTarget(), 0, &hotKey) == noErr
        if !shortcutAvailable, let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        enabled = false
        shortcutAvailable = true
    }

    func toggle() {
        guard enabled, !isBusy else { return }
        guard AXIsProcessTrusted() else {
            FeaturePermission.accessibility.request()
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastToggle) >= 0.5 else { return }
        lastToggle = now
        QuickPanelController.shared.close()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated }
            .map(\.processIdentifier)
        isBusy = true
        queue.async { [self] in
            let result = worker.toggle(pids: pids)
            DispatchQueue.main.async { [self] in
                hasWindowsToRestore = result.hasWindows
                isBusy = false
                if result.restored {
                    if !result.hasWindows {
                        previousApplication?.activate(options: [.activateIgnoringOtherApps])
                        previousApplication = nil
                    }
                } else if result.hasWindows {
                    previousApplication = frontmost
                }
            }
        }
    }
}

/// All cross-process Accessibility calls run serially off the main thread.
/// A hung application gets a short timeout instead of freezing Augment's UI.
final class DesktopWindowWorker {
    private var session = DesktopWindowSession<AXUIElement>()

    func toggle(pids: [pid_t]) -> (restored: Bool, hasWindows: Bool) {
        session.prune(isMinimized: Self.isMinimized)
        if !session.windows.isEmpty {
            session.restore(isMinimized: Self.isMinimized, setMinimized: Self.setMinimized)
            return (true, !session.windows.isEmpty)
        }
        let candidates = pids.flatMap { pid -> [AXUIElement] in
            // AX calls targeting this process invoke AppKit directly, so its
            // own windows must be handled on the main thread.
            if pid == getpid() && !Thread.isMainThread {
                return DispatchQueue.main.sync { Self.windows(for: pid) }
            }
            return Self.windows(for: pid)
        }
        session.minimize(candidates, isMinimized: Self.isMinimized, setMinimized: Self.setMinimized)
        return (false, !session.windows.isEmpty)
    }

    private static func windows(for pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.filter { window in
            AXUIElementSetMessagingTimeout(window, 0.25)
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success
                && settable.boolValue
        }
    }

    private static func onWindowThread<T>(_ window: AXUIElement, _ action: () -> T) -> T {
        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) == .success, pid == getpid(), !Thread.isMainThread {
            return DispatchQueue.main.sync(execute: action)
        }
        return action()
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool? {
        onWindowThread(window) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return nil }
            return value as? Bool
        }
    }

    private static func setMinimized(_ window: AXUIElement, _ minimized: Bool) -> Bool {
        onWindowThread(window) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                        minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
        }
    }
}

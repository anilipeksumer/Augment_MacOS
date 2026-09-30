import AppKit
import Carbon
import Combine

/// Delegates to the Dock's native Show Desktop action so Spaces, minimized
/// windows and window order remain owned by macOS, including restoration.
@MainActor
final class ShowDesktopService: ObservableObject {
    static let shared = ShowDesktopService()
    @Published private(set) var shortcutAvailable = true
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var lastToggle = Date.distantPast
    private var enabled = false

    private typealias DockNotification = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
    // Resolve the private Dock entry point dynamically: a future OS removing it
    // must disable the feature gracefully rather than prevent app launch.
    private static let dockNotification: DockNotification? = {
        guard let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY),
              let symbol = dlsym(library, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(symbol, to: DockNotification.self)
    }()
    var isSupported: Bool { Self.dockNotification != nil }

    func setEnabled(_ enabled: Bool) {
        stop()
        self.enabled = enabled
        guard enabled, isSupported else { return }
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
        guard enabled, let send = Self.dockNotification else { return }
        // Ignore accidental double clicks while the Dock animation runs.
        let now = Date()
        guard now.timeIntervalSince(lastToggle) >= 0.5 else { return }
        lastToggle = now
        QuickPanelController.shared.close()
        send("com.apple.showdesktop.awake" as CFString, nil)
    }
}

import AppKit
import Carbon
import SwiftUI

/// A system-wide hot key through Carbon — needs no permission, unlike an
/// event tap.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private let id: UInt32

    init(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.id = id
        Self.handlers[id] = handler
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x41554754), id: id) // 'AUGT'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            // Numeric IDs are local to each signature. Show Desktop also uses
            // id 1, but its 'AUDT' events must never open the 'AUGT' clipboard.
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID) == noErr,
                  hotKeyID.signature == OSType(0x41554754),
                  GlobalHotKey.handlers[hotKeyID.id] != nil else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            DispatchQueue.main.async { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// ⌘⇧V: search the clipboard history, pin favourites, paste with Return.
@MainActor
final class ClipboardPanelController {
    static let shared = ClipboardPanelController()

    private var panel: ClipboardPanelWindow?
    private var hotKey: GlobalHotKey?
    private var monitors: [Any] = []
    private let model = ClipboardPanelModel()
    private(set) var isOpen = false

    func enable() {
        guard hotKey == nil else { return }
        hotKey = GlobalHotKey(id: 1, keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)) {
            Task { @MainActor in ClipboardPanelController.shared.toggle() }
        }
    }

    func disable() {
        hotKey = nil
        close()
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        model.query = ""
        model.selection = 0
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let size = CGSize(width: 440, height: 460)
        if let frame = screen?.visibleFrame {
            panel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + 60,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        isOpen = true
        installMonitors()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
    }

    fileprivate func paste(_ item: ClipboardHistoryItem) {
        close()
        ClipboardHistoryService.shared.paste(item)
    }

    /// For off-screen rendering in tests.
    func previewView() -> AnyView { AnyView(ClipboardPanelView(model: model)) }

    private func makePanel() -> ClipboardPanelWindow {
        let panel = ClipboardPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 460),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: ClipboardPanelView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func installMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            Task { @MainActor in ClipboardPanelController.shared.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.isOpen else { return event }
            let items = self.model.filtered
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.close(); return nil
            case kVK_DownArrow:
                self.model.selection = min(self.model.selection + 1, max(items.count - 1, 0)); return nil
            case kVK_UpArrow:
                self.model.selection = max(self.model.selection - 1, 0); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if items.indices.contains(self.model.selection) { self.paste(items[self.model.selection]) }
                return nil
            default:
                // ⌘1…⌘9 paste the nth item; ⌘P pins the selection.
                if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers {
                    if let n = Int(chars), (1...9).contains(n), items.indices.contains(n - 1) {
                        self.paste(items[n - 1]); return nil
                    }
                    if chars == "p", items.indices.contains(self.model.selection) {
                        ClipboardHistoryService.shared.togglePin(items[self.model.selection]); return nil
                    }
                }
                return event
            }
        }) { monitors.append(m) }
    }
}

private final class ClipboardPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0

    var filtered: [ClipboardHistoryItem] {
        let items = ClipboardHistoryService.shared.items
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.previewText.localizedCaseInsensitiveContains(q) || $0.value.localizedCaseInsensitiveContains(q) }
    }
}

private struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @ObservedObject private var history = ClipboardHistoryService.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.filtered
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(Localizer.string("clip.search"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if items.isEmpty {
                Spacer()
                Text(Localizer.string(history.items.isEmpty ? "notch.clipboard_empty" : "menubar.no_match"))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index, selected: index == model.selection)
                                    .id(item.id)
                            }
                        }
                    }
                    .onChange(of: model.selection) { value in
                        if items.indices.contains(value) { proxy.scrollTo(items[value].id) }
                    }
                }
            }

            Text(Localizer.string("clip.hint"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 440, height: 460)
        .modifier(ClipboardBackground())
        .onAppear { searchFocused = true }
    }

    private func row(_ item: ClipboardHistoryItem, index: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if item.kind == .image, let image = history.thumbnail(for: item) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: 56, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: item.kind == .fileURL ? "doc" : "text.alignleft")
                    .foregroundStyle(.secondary).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.previewText.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1).truncationMode(.tail).font(.system(size: 13))
                if item.kind == .image {
                    Text(item.capturedAt, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Button {
                history.togglePin(item)
            } label: {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(item.isPinned ? Color.orange : Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Localizer.string("clip.pin"))
        }
        .padding(.horizontal, 10)
        .frame(height: item.kind == .image ? 56 : 32)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { ClipboardPanelController.shared.paste(item) }
        .contextMenu {
            Button(Localizer.string("clip.pin")) { history.togglePin(item) }
            Button(Localizer.string("notch.copy")) { history.copyToPasteboard(item) }
            Divider()
            Button(Localizer.string("notch.remove"), role: .destructive) { history.remove(item) }
        }
    }
}

private struct ClipboardBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

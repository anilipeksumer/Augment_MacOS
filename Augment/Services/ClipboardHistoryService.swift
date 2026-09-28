import AppKit
import Combine
import Foundation

/// One entry in the clipboard history. Only plain text and copied file URLs
/// are tracked — images are skipped to keep the persisted history small and
/// avoid holding onto large blobs in memory indefinitely.
struct ClipboardHistoryItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case fileURL
    }

    let id: UUID
    let kind: Kind
    let value: String
    let capturedAt: Date
    /// Pinned items stay at the top and are never dropped.
    var isPinned: Bool

    init(kind: Kind, value: String, capturedAt: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.value = value
        self.capturedAt = capturedAt
        self.isPinned = false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        value = try c.decode(String.self, forKey: .value)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    var previewText: String {
        switch kind {
        case .text: return value
        case .fileURL: return URL(fileURLWithPath: value).lastPathComponent
        }
    }
}

/// Maccy/Paste-style clipboard history. macOS has no pasteboard-changed
/// notification, so this polls `NSPasteboard.general.changeCount` on a
/// lightweight timer — reading the count itself is essentially free and
/// only triggers a real read when it actually changes.
@MainActor
final class ClipboardHistoryService: ObservableObject {
    static let shared = ClipboardHistoryService()

    @Published private(set) var items: [ClipboardHistoryItem] = []

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private var isRunning = false

    private let maxItems = 40
    private let maxTextLength = 8000
    private let storageKey = "augment.clipboardHistory.v1"

    private init() {
        lastChangeCount = pasteboard.changeCount
        items = Self.loadPersisted(from: storageKey)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPasteboard() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private func pollPasteboard() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first, first.isFileURL {
            addItem(.init(kind: .fileURL, value: first.path))
            return
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let trimmed = text.count > maxTextLength ? String(text.prefix(maxTextLength)) : text
            addItem(.init(kind: .text, value: trimmed))
        }
    }

    private func addItem(_ item: ClipboardHistoryItem) {
        // Skip exact-duplicate of the most recent entry (re-copying the same
        // thing, or our own `copyToPasteboard` echoing back) — otherwise
        // every restore would spawn a fresh duplicate at the top.
        if let mostRecent = items.first, mostRecent.kind == item.kind, mostRecent.value == item.value {
            return
        }
        if items.contains(where: { $0.isPinned && $0.kind == item.kind && $0.value == item.value }) {
            return // already pinned — keep it where it is
        }
        items.removeAll { $0.kind == item.kind && $0.value == item.value }
        let pinnedCount = items.filter(\.isPinned).count
        items.insert(item, at: pinnedCount)
        // Trim only unpinned entries.
        while items.filter({ !$0.isPinned }).count > maxItems, let last = items.lastIndex(where: { !$0.isPinned }) {
            items.remove(at: last)
        }
        persist()
    }

    func copyToPasteboard(_ item: ClipboardHistoryItem) {
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.value, forType: .string)
        case .fileURL:
            pasteboard.writeObjects([URL(fileURLWithPath: item.value) as NSURL])
        }
        lastChangeCount = pasteboard.changeCount
    }

    func togglePin(_ item: ClipboardHistoryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = items.remove(at: index)
        updated.isPinned.toggle()
        let pinnedCount = items.filter(\.isPinned).count
        items.insert(updated, at: updated.isPinned ? 0 : pinnedCount)
        persist()
    }

    /// Puts the item on the clipboard and pastes it into the frontmost app.
    func paste(_ item: ClipboardHistoryItem) {
        copyToPasteboard(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let v: CGKeyCode = 9
            let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    func remove(_ item: ClipboardHistoryItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll { !$0.isPinned }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        AppGroup.setSuiteValue(data as CFData, forKey: storageKey)
    }

    private static func loadPersisted(from key: String) -> [ClipboardHistoryItem] {
        AppGroup.synchronizeSuitePreferences()
        guard let data = AppGroup.copySuiteValue(forKey: key) as? Data,
              let decoded = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data)
        else { return [] }
        return decoded
    }
}

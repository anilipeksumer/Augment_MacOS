import AppKit
import Combine
import Foundation

/// A clipboard entry. Image values are filenames in our private image store;
/// image bytes are never embedded in the preferences plist.
struct ClipboardHistoryItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case fileURL
        case image
    }

    let id: UUID
    let kind: Kind
    let value: String
    let capturedAt: Date
    var sourceName: String?
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
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    var previewText: String {
        switch kind {
        case .text: return value
        case .fileURL: return URL(fileURLWithPath: value).lastPathComponent
        case .image: return sourceName ?? Localizer.string("clip.image")
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

    private let pasteboard: NSPasteboard
    let imageStore: ClipboardImageStore
    private let thumbnails = NSCache<NSString, NSImage>()
    private var generation = UUID()
    private let imageQueue = DispatchQueue(label: "augment.clipboard-images", qos: .utility)
    private var lastChangeCount: Int
    private var timer: Timer?
    private var isRunning = false

    private let maxItems = 40
    private let maxTextLength = 8000
    private let storageKey: String

    init(pasteboard: NSPasteboard = .general,
         imageDirectory: URL = ClipboardImageStore.defaultDirectory,
         storageKey: String = "augment.clipboardHistory.v1") {
        self.pasteboard = pasteboard
        self.storageKey = storageKey
        imageStore = ClipboardImageStore(directory: imageDirectory)
        thumbnails.countLimit = 48
        lastChangeCount = pasteboard.changeCount
        items = Self.loadPersisted(from: storageKey).filter {
            $0.kind != .image || imageStore.url(for: $0.value).map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        imageStore.prune(keeping: Set(items.filter { $0.kind == .image }.map(\.value)))
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
        generation = UUID()
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func pollPasteboard() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first, first.isFileURL {
            addItem(.init(kind: .fileURL, value: first.path))
            return
        }
        if let data = ClipboardImageStore.data(from: pasteboard) {
            captureImage(data)
            return
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let trimmed = text.count > maxTextLength ? String(text.prefix(maxTextLength)) : text
            addItem(.init(kind: .text, value: trimmed))
        }
    }

    func captureScreenshot(_ url: URL) {
        let name = url.lastPathComponent
        let token = generation
        imageQueue.async { [weak self] in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= ClipboardImageStore.maxImageBytes,
                  let data = try? Data(contentsOf: url), let png = ClipboardImageStore.pngData(data) else { return }
            DispatchQueue.main.async { self?.acceptImage(png, name: name, generation: token) }
        }
    }

    func captureImage(_ data: Data) {
        let token = generation
        imageQueue.async { [weak self] in
            guard let png = ClipboardImageStore.pngData(data) else { return }
            DispatchQueue.main.async { self?.acceptImage(png, name: nil, generation: token) }
        }
    }

    private func acceptImage(_ data: Data, name: String?, generation token: UUID) {
        guard token == generation, let file = try? imageStore.save(data) else { return }
        var item = ClipboardHistoryItem(kind: .image, value: file)
        item.sourceName = name
        addItem(item)
    }

    func imageURL(for item: ClipboardHistoryItem) -> URL? {
        item.kind == .image ? imageStore.url(for: item.value) : nil
    }

    func thumbnail(for item: ClipboardHistoryItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        if let image = thumbnails.object(forKey: item.value as NSString) { return image }
        guard let image = imageStore.thumbnail(named: item.value) else { return nil }
        thumbnails.setObject(image, forKey: item.value as NSString)
        return image
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

    @discardableResult
    func copyToPasteboard(_ item: ClipboardHistoryItem) -> Bool {
        var image: NSImage?
        if item.kind == .image {
            guard let url = imageURL(for: item), let loaded = NSImage(contentsOf: url) else { return false }
            image = loaded
        }
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.value, forType: .string)
        case .fileURL:
            pasteboard.writeObjects([URL(fileURLWithPath: item.value) as NSURL])
        case .image:
            if let image { pasteboard.writeObjects([image]) }
            if let url = imageURL(for: item), let data = try? Data(contentsOf: url) { pasteboard.setData(data, forType: .png) }
        }
        lastChangeCount = pasteboard.changeCount
        return true
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
        guard copyToPasteboard(item) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let v: CGKeyCode = 9
            let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    func remove(_ item: ClipboardHistoryItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        generation = UUID()
        items.removeAll { !$0.isPinned }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        var sizes: [String: Int] = [:]
        for item in items where item.kind == .image {
            if let url = imageURL(for: item) { sizes[item.value] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        }
        var bytes = sizes.values.reduce(0, +)
        while bytes > ClipboardImageStore.maxTotalBytes,
              let index = items.lastIndex(where: { $0.kind == .image && !$0.isPinned }) {
            bytes -= sizes[items[index].value] ?? 0
            items.remove(at: index)
        }
        imageStore.prune(keeping: Set(items.filter { $0.kind == .image }.map(\.value)))
        thumbnails.removeAllObjects()
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

import AppKit
import Combine
import EventKit

/// A calendar event reduced to what the notch and quick panel show.
struct UpcomingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: NSColor
    /// A Zoom / Meet / Teams / Webex link found in the event, if any.
    let joinURL: URL?

    var minutesUntilStart: Int { Int(ceil(start.timeIntervalSinceNow / 60)) }
    var isInProgress: Bool { start <= Date() && end > Date() }
}

/// Today's upcoming events and a heads-up shortly before each one starts
/// (the notch opens with the meeting and a Join button).
@MainActor
final class MeetingsService: ObservableObject {
    static let shared = MeetingsService()

    @Published private(set) var events: [UpcomingEvent] = []
    @Published private(set) var accessGranted = false
    /// Set when an event is about to start; the notch shows it.
    @Published private(set) var alert: UpcomingEvent?

    static let alertLeadMinutes = 5

    private let store = EKEventStore()
    private var timer: Timer?
    private var alerted = Set<String>()
    private var changeObserver: Any?

    func start() {
        requestAccess { [weak self] granted in
            guard let self else { return }
            self.accessGranted = granted
            guard granted else { return }
            self.refresh()
            if self.timer == nil {
                let t = Timer(timeInterval: 30, repeats: true) { _ in
                    Task { @MainActor in MeetingsService.shared.refresh() }
                }
                RunLoop.main.add(t, forMode: .common)
                self.timer = t
            }
            if self.changeObserver == nil {
                self.changeObserver = NotificationCenter.default.addObserver(
                    forName: .EKEventStoreChanged, object: self.store, queue: .main
                ) { _ in Task { @MainActor in MeetingsService.shared.refresh() } }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        events = []
        alert = nil
    }

    func dismissAlert() { alert = nil }

    private func requestAccess(_ completion: @escaping @MainActor (Bool) -> Void) {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            if status == .fullAccess { completion(true); return }
            store.requestFullAccessToEvents { granted, _ in
                Task { @MainActor in completion(granted) }
            }
        } else {
            if status == .authorized { completion(true); return }
            store.requestAccess(to: .event) { granted, _ in
                Task { @MainActor in completion(granted) }
            }
        }
    }

    func refresh() {
        let now = Date()
        let endOfDay = Calendar.current.date(byAdding: .hour, value: 18, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: endOfDay, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(5)
            .map { event in
                UpcomingEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "—",
                    start: event.startDate,
                    end: event.endDate,
                    color: event.calendar.map { NSColor(cgColor: $0.cgColor) ?? .systemBlue } ?? .systemBlue,
                    joinURL: Self.joinURL(in: event)
                )
            }
        let next = Array(found)
        if next != events { events = next }

        if let soon = next.first(where: { !$0.isInProgress && $0.minutesUntilStart <= Self.alertLeadMinutes && $0.minutesUntilStart >= 0 }),
           !alerted.contains(soon.id) {
            alerted.insert(soon.id)
            alert = soon
        } else if let current = alert, current.start.addingTimeInterval(120) < now {
            alert = nil
        }
    }

    /// Looks for a video-call link in the event's URL, location and notes.
    private static func joinURL(in event: EKEvent) -> URL? {
        if let url = event.url, isMeetingLink(url.absoluteString) { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { isMeetingLink($0.absoluteString) }
    }

    private static func isMeetingLink(_ s: String) -> Bool {
        ["zoom.us/", "meet.google.com/", "teams.microsoft.com/", "teams.live.com/", "webex.com/", "facetime.apple.com/"]
            .contains { s.contains($0) }
    }
}

/// Drops new screenshots onto the notch shelf. Watches the folder macOS
/// saves screenshots to (System Settings' / ⇧⌘5 "Save to", Desktop by
/// default) and picks up new files carrying the screen-capture flag
/// screencapture writes. Works without Spotlight, which is often off or
/// not indexing an iCloud-synced Desktop.
@MainActor
final class ScreenshotShelfWatcher {
    static let shared = ScreenshotShelfWatcher()

    var onScreenshot: ((URL) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?
    private var startedAt = Date()
    private var seen = Set<String>()
    private var scanWork: DispatchWorkItem?
    private var folderRefreshTimer: Timer?

    /// Where screenshots are saved right now.
    static var screenshotFolder: URL {
        if let custom = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    func start(folder override: URL? = nil) {
        let folder = override ?? Self.screenshotFolder
        guard source == nil || watchedFolder != folder else { return }
        stop()
        startedAt = Date()
        seen.removeAll()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("Augment: can't watch screenshot folder %@", folder.path)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        watchedFolder = folder
        if override == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.start() }
            }
            RunLoop.main.add(timer, forMode: .common)
            folderRefreshTimer = timer
        }
    }

    func stop() {
        folderRefreshTimer?.invalidate()
        folderRefreshTimer = nil
        source?.cancel()
        source = nil
        watchedFolder = nil
        scanWork?.cancel()
    }

    /// screencapture writes a hidden temp file and renames it; wait for the
    /// dust to settle, then look for new screenshots.
    private func scheduleScan() {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func scan() {
        guard let folder = watchedFolder,
              let items = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        else { return }
        for url in items where !seen.contains(url.path) {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard created >= startedAt.addingTimeInterval(-2), Self.isScreenshot(url) else { continue }
            seen.insert(url.path)
            onScreenshot?(url)
        }
    }

    /// screencapture tags its files with kMDItemIsScreenCapture as an
    /// extended attribute, so this works even when Spotlight is off.
    static func isScreenshot(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        return getxattr(url.path, name, nil, 0, 0, 0) > 0
    }
}

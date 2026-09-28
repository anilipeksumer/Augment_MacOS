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

/// Drops new screenshots onto the notch shelf. Uses Spotlight's
/// `kMDItemIsScreenCapture` flag, so it works wherever screenshots are saved.
@MainActor
final class ScreenshotShelfWatcher {
    static let shared = ScreenshotShelfWatcher()

    var onScreenshot: ((URL) -> Void)?
    private var query: NSMetadataQuery?
    private var startedAt = Date()
    private var seen = Set<String>()

    func start() {
        guard query == nil else { return }
        startedAt = Date()
        seen.removeAll()
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        NotificationCenter.default.addObserver(self, selector: #selector(updated(_:)),
                                               name: .NSMetadataQueryDidUpdate, object: q)
        q.start()
        query = q
    }

    func stop() {
        query?.stop()
        if let query { NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query) }
        query = nil
    }

    @objc private func updated(_ note: Notification) {
        guard let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] else { return }
        for item in added {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String, !seen.contains(path) else { continue }
            let created = item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? Date()
            guard created >= startedAt.addingTimeInterval(-2) else { continue }
            seen.insert(path)
            onScreenshot?(URL(fileURLWithPath: path))
        }
    }
}

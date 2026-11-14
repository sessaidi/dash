import Foundation
import Observation

/// Something that happened on the dashboard. Extensions emit these; Claude is told about
/// them before each chat turn and can query them with `dashboard_activity`.
public struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    public enum Importance: String, Codable, Sendable, Comparable {
        case info, notable, critical

        public static func < (a: Importance, b: Importance) -> Bool {
            let order: [Importance] = [.info, .notable, .critical]
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
    }

    public let id: Int
    public let date: Date
    /// Extension id ("pull-requests") or "dashboard".
    public let source: String
    /// Machine-readable kind ("review.completed", "widget.moved").
    public let kind: String
    /// One human sentence.
    public let title: String
    public let detail: String?
    public let link: String?
    public let importance: Importance

    /// "[14:02] pull-requests review.completed: Claude reviewed acme/api#812 — request changes, high risk"
    public var line: String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return "[\(time)] \(source) \(kind): \(title)" + (detail.map { " — \($0)" } ?? "") + (link.map { " <\($0)>" } ?? "")
    }
}

/// An in-memory log of dashboard activity (most recent 1,000 events).
@MainActor
@Observable
public final class ActivityLog {
    public private(set) var events: [ActivityEvent] = []
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var handlers: [(ActivityEvent) -> Void] = []
    @ObservationIgnored private let capacity: Int

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    @discardableResult
    public func emit(
        _ kind: String, source: String, title: String, detail: String? = nil, link: String? = nil,
        importance: ActivityEvent.Importance = .info, at date: Date = Date()
    ) -> ActivityEvent {
        let event = ActivityEvent(id: nextID, date: date, source: source, kind: kind, title: title, detail: detail, link: link, importance: importance)
        nextID += 1
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        for handler in handlers { handler(event) }
        return event
    }

    /// Calls `handler` for every event emitted from now on (notifications, mascot).
    public func onEmit(_ handler: @escaping (ActivityEvent) -> Void) {
        handlers.append(handler)
    }

    /// Events with an id greater than `id` (what happened since a reader last looked).
    public func events(after id: Int) -> [ActivityEvent] {
        events.filter { $0.id > id }
    }

    public func events(since date: Date, source: String? = nil, minimum: ActivityEvent.Importance = .info) -> [ActivityEvent] {
        events.filter { $0.date >= date && (source == nil || $0.source == source) && $0.importance >= minimum }
    }

    public var latestID: Int { events.last?.id ?? 0 }

    /// A compact digest for Claude: notable events in full, routine ones counted.
    public static func digest(_ events: [ActivityEvent], limit: Int = 40) -> String? {
        guard !events.isEmpty else { return nil }
        let important = events.filter { $0.importance >= .notable }
        let routine = events.filter { $0.importance == .info }
        var selected = Array(important.suffix(limit))
        selected += routine.suffix(max(limit - selected.count, 0))
        let skipped = events.count - selected.count
        let lines = selected.sorted { $0.id < $1.id }.map(\.line)
        var text = "Dashboard activity since your last turn (\(events.count) events, oldest first):\n" + lines.joined(separator: "\n")
        if skipped > 0 { text += "\n(\(skipped) older routine events omitted; call dashboard_activity for the full log.)" }
        return text
    }
}

import Foundation

/// A count per day that an extension can chart, e.g. "PRs opened", "worktrees created",
/// "commits". The Activity Heatmap widget lists every enabled extension's series; plugin
/// widgets can draw one with DashKitUI's `ActivityHeatmap`.
///
/// ```swift
/// ActivitySeries(id: "opened", title: "PRs opened", unit: "PRs", systemImage: "arrow.triangle.pull") { interval in
///     ActivitySeries.countPerDay(pulls.map(\.createdAt), in: interval)
/// }
/// ```
public struct ActivitySeries: Sendable, Identifiable {
    /// Unique within the extension; Dash refers to it as "<extension id>.<id>".
    public let id: String
    public let title: String
    /// What one unit is, plural: "PRs", "commits", "tokens".
    public let unit: String
    public let systemImage: String
    /// Totals per day in the interval, keyed by the start of each day (local calendar).
    public let values: @MainActor @Sendable (DateInterval) async -> [Date: Double]

    public init(id: String, title: String, unit: String, systemImage: String = "square.grid.3x3",
                values: @escaping @MainActor @Sendable (DateInterval) async -> [Date: Double]) {
        self.id = id
        self.title = title
        self.unit = unit
        self.systemImage = systemImage
        self.values = values
    }

    /// One per date, grouped by day, keeping only dates in the interval.
    public static func countPerDay(_ dates: [Date], in interval: DateInterval, calendar: Calendar = .current) -> [Date: Double] {
        sumPerDay(dates.map { ($0, 1) }, in: interval, calendar: calendar)
    }

    /// Amounts grouped by day, keeping only dates in the interval.
    public static func sumPerDay(_ entries: [(Date, Double)], in interval: DateInterval, calendar: Calendar = .current) -> [Date: Double] {
        var result: [Date: Double] = [:]
        for (date, amount) in entries where interval.contains(date) {
            result[calendar.startOfDay(for: date), default: 0] += amount
        }
        return result
    }
}

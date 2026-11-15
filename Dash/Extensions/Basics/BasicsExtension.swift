import ClaudeCodeKit
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// Built-in widgets that need no account: a scratch note and Claude usage.
final class BasicsExtension: DashExtension {
    let id = "basics"
    let name = "Basics"
    let systemImage = "square.grid.2x2"
    let metadata = ExtensionMetadata(version: "1.0.0", summary: "Notes and Claude usage.", category: .productivity, homepage: "https://github.com/sessaidi/dash")
    var widgets: [WidgetType] {
        [WidgetType(NoteWidget.self), WidgetType(DataWidget.self), WidgetType(ClaudeUsageWidget.self), WidgetType(WorkspaceAnalyticsWidget.self), WidgetType(ActivityHeatmapWidget.self)]
    }

    private weak var host: (any ExtensionContext)?
    func start(host: any ExtensionContext) { self.host = host }

    /// Claude requests Dash recorded, per day.
    var activitySeries: [ActivitySeries] {
        func calls(_ interval: DateInterval) -> [ClaudeCall] {
            let (start, end) = (interval.start, interval.end)
            return (try? host?.context.fetch(FetchDescriptor<ClaudeCall>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        }
        return [
            ActivitySeries(id: "claude.tokens", title: "Dashii tokens", unit: "tokens", systemImage: "sparkles") { interval in
                ActivitySeries.sumPerDay(calls(interval).map { ($0.date, Double($0.inputTokens + $0.outputTokens + $0.cacheWriteTokens)) }, in: interval)
            },
            ActivitySeries(id: "claude.requests", title: "Dashii requests", unit: "requests", systemImage: "bubble.left.and.bubble.right") { interval in
                ActivitySeries.countPerDay(calls(interval).map(\.date), in: interval)
            },
            ActivitySeries(id: "claude.cost", title: "Dashii cost (USD)", unit: "USD", systemImage: "dollarsign.circle") { interval in
                ActivitySeries.sumPerDay(calls(interval).map { ($0.date, $0.costUSD) }, in: interval)
            },
        ]
    }
}

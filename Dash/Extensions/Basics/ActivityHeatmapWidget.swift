import DashKit
import DashKitUI
import SwiftUI

/// A calendar heatmap of any activity series an extension publishes: commits, worktrees,
/// PRs opened, tickets updated, meetings, agent runs, Claude tokens…
struct ActivityHeatmapWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// "<extension id>.<series id>"
        var series: String
        var months: Int
        /// green, blue, purple, orange or pink.
        var color: String
    }

    static let kind = "activity.heatmap"
    static let displayName = "Activity Heatmap"
    static let summary = "A calendar heatmap of commits, worktrees, PRs, tickets, meetings, agent runs or Claude usage per day."
    static let systemImage = "square.grid.3x3.middle.filled"
    static let defaultSize = WidgetSize.wide
    static let sizeLimits = GridLimits(minW: 6, minH: 5, maxW: 12, maxH: 10)
    static let defaultConfig = Config(series: "knowledge.commits.mine", months: 6, color: "green")
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "series": ["type": "string", "description": "Series id \"<extension>.<series>\" (e.g. knowledge.commits.mine, agents.worktrees, pull-requests.opened, basics.claude.tokens)."],
            "months": ["type": "integer", "description": "Months shown, 3 to 12."],
            "color": ["type": "string", "enum": ["green", "blue", "purple", "orange", "pink"]],
        ],
    ]

    @MainActor
    static func all(_ host: any ExtensionContext) -> [(id: String, owner: String, series: ActivitySeries)] {
        host.extensions.filter { host.isEnabled($0) }.flatMap { owner in
            owner.activitySeries.map { ("\(owner.id).\($0.id)", owner.name, $0) }
        }
    }

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        ActivityHeatmapView(config: config.wrappedValue, host: context.host)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Picker("Show", selection: config.series) {
            ForEach(all(context.host), id: \.id) { item in
                Label("\(item.series.title) · \(item.owner)", systemImage: item.series.systemImage).tag(item.id)
            }
        }
        Picker("Period", selection: config.months) {
            Text("3 months").tag(3)
            Text("6 months").tag(6)
            Text("12 months").tag(12)
        }
        Picker("Colour", selection: config.color) {
            ForEach(["green", "blue", "purple", "orange", "pink"], id: \.self) { Text($0.capitalized).tag($0) }
        }
    }

    static func preview(config: Config) -> some View {
        WorkspaceAnalyticsWidget.preview(config: .init(metric: "requests", months: config.months))
    }

    @MainActor
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let item = all(context.host).first(where: { $0.id == config.series }) else { return ["error": "unknown series"] }
        let end = Date.now
        let start = Calendar.current.date(byAdding: .month, value: -config.months, to: end) ?? end
        let values = await item.series.values(DateInterval(start: start, end: end))
        return ["series": .string(item.series.title), "total": .number(values.values.reduce(0, +)),
                "active_days": .number(Double(values.values.filter { $0 > 0 }.count))]
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "blue": .blue
        case "purple": .purple
        case "orange": .orange
        case "pink": .pink
        default: .green
        }
    }
}

private struct ActivityHeatmapView: View {
    let config: ActivityHeatmapWidget.Config
    let host: any ExtensionContext
    @State private var offset = 0
    @State private var values: [Date: Double] = [:]

    var body: some View {
        let calendar = Calendar.current
        let months = min(max(config.months, 3), 12)
        let end = calendar.date(byAdding: .month, value: -months * offset, to: calendar.startOfDay(for: .now)) ?? .now
        let start = calendar.date(byAdding: .month, value: -months, to: end) ?? end
        let item = ActivityHeatmapWidget.all(host).first { $0.id == config.series }
        Group {
            if let item {
                AnalyticsLayout(heading: item.series.title, metric: "", values: values, from: start, to: end, sources: [],
                                title: WorkspaceAnalyticsWidget.period(start, end),
                                onPrevious: { offset += 1 }, onNext: offset > 0 ? { offset -= 1 } : nil,
                                tint: ActivityHeatmapWidget.color(config.color),
                                formatter: { "\($0.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))) \(item.series.unit)" })
            } else {
                ContentUnavailableView("Pick what to show", systemImage: "square.grid.3x3.middle.filled",
                                       description: Text("Edit the widget and choose a series. Plugins add their own (PRs, worktrees, tickets…)."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(config.series)|\(offset)|\(months)") {
            values = await item?.series.values(DateInterval(start: start, end: end.addingTimeInterval(86_400))) ?? [:]
        }
    }
}

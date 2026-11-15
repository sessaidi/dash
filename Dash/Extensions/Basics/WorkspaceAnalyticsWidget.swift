import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// Claude usage over months, from the requests Dash recorded: a calendar heatmap of tokens,
/// cost or requests per day, the peak day, totals, the streak and the top sources.
struct WorkspaceAnalyticsWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// tokens, cost or requests.
        var metric: String
        /// Months shown at once.
        var months: Int
    }

    static let kind = "workspace.analytics"
    static let displayName = "Workspace Analytics"
    static let summary = "Dashii activity as a calendar heatmap (tokens, cost or requests per day), with the peak day, totals, streak and top sources."
    static let systemImage = "square.grid.3x3.square"
    static let defaultSize = WidgetSize.wide
    static let sizeLimits = GridLimits(minW: 6, minH: 5, maxW: 12, maxH: 10)
    static let defaultConfig = Config(metric: "tokens", months: 6)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "metric": ["type": "string", "enum": ["tokens", "cost", "requests"]],
            "months": ["type": "integer", "description": "Months shown, 3 to 12."],
        ],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        WorkspaceAnalyticsView(config: config.wrappedValue)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Picker("Measure", selection: config.metric) {
            Text("Tokens").tag("tokens")
            Text("Cost").tag("cost")
            Text("Requests").tag("requests")
        }
        Picker("Period", selection: config.months) {
            Text("3 months").tag(3)
            Text("6 months").tag(6)
            Text("12 months").tag(12)
        }
    }

    /// Sample days with a weekday rhythm; no store.
    static func preview(config: Config) -> some View {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .month, value: -config.months, to: end) ?? end
        var values: [Date: Double] = [:]
        var day = start
        var seed = 7
        while day <= end {
            seed = (seed * 1103 + 12345) % 9973
            let weekday = calendar.component(.weekday, from: day)
            if weekday != 1 && weekday != 7 && seed % 3 != 0 { values[day] = Double(seed % 40 + 5) * 80 }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return AnalyticsLayout(metric: config.metric, values: values, from: start, to: end, sources: [("Chat", 0.62), ("Pull requests", 0.23), ("Knowledge", 0.15)],
                               title: Self.period(start, end), onPrevious: nil, onNext: nil)
    }

    static func period(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(.dateTime.month(.abbreviated))) – \(end.formatted(.dateTime.month(.abbreviated).year()))"
    }

    @MainActor
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        let since = Calendar.current.date(byAdding: .month, value: -config.months, to: .now) ?? .now
        let calls = (try? context.host.context.fetch(FetchDescriptor<ClaudeCall>(predicate: #Predicate { $0.date >= since }))) ?? []
        let days = Set(calls.map { Calendar.current.startOfDay(for: $0.date) })
        return ["requests": .number(Double(calls.count)), "active_days": .number(Double(days.count)),
                "tokens": .number(Double(calls.reduce(0) { $0 + $1.inputTokens + $1.outputTokens })),
                "cost_usd": .number(calls.reduce(0) { $0 + $1.costUSD })]
    }
}

private struct WorkspaceAnalyticsView: View {
    let config: WorkspaceAnalyticsWidget.Config
    /// Periods back from now (the < and > buttons).
    @State private var offset = 0
    @Query(sort: \ClaudeCall.date) private var calls: [ClaudeCall]

    var body: some View {
        let calendar = Calendar.current
        let months = min(max(config.months, 3), 12)
        let end = calendar.date(byAdding: .month, value: -months * offset, to: calendar.startOfDay(for: .now)) ?? .now
        let start = calendar.date(byAdding: .month, value: -months, to: end) ?? end
        let inPeriod = calls.filter { $0.date >= start && $0.date < end.addingTimeInterval(86_400) }
        var values: [Date: Double] = [:]
        var bySource: [String: Double] = [:]
        for call in inPeriod {
            let amount = Self.amount(call, metric: config.metric)
            values[calendar.startOfDay(for: call.date), default: 0] += amount
            bySource[Self.source(call.source), default: 0] += amount
        }
        let total = max(bySource.values.reduce(0, +), 1)
        var sources = bySource.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value / total) }
        let rest = 1 - sources.reduce(0) { $0 + $1.1 }
        if rest > 0.005 { sources.append(("Other", rest)) }
        return AnalyticsLayout(metric: config.metric, values: values, from: start, to: end, sources: Array(sources),
                               title: WorkspaceAnalyticsWidget.period(start, end),
                               onPrevious: { offset += 1 }, onNext: offset > 0 ? { offset -= 1 } : nil)
    }

    static func amount(_ call: ClaudeCall, metric: String) -> Double {
        switch metric {
        case "cost": call.costUSD
        case "requests": 1
        default: Double(call.inputTokens + call.outputTokens + call.cacheWriteTokens)
        }
    }

    /// A readable name for where requests came from: "extension.pull-requests/review" → "Pull requests",
    /// "agent.agents-studio.55B6…" → "Agents studio" (ids are dropped so one agent's runs add up).
    static func source(_ source: String) -> String {
        let head = source.split(separator: "/").first.map(String.init) ?? source
        let parts = head.split(separator: ".").map(String.init).filter { part in
            !["extension", "widget", "agent", "feature"].contains(part) && !isIdentifier(part)
        }
        let name = (parts.last ?? head).replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// UUIDs and long hex runs: per-run ids, not names.
    static func isIdentifier(_ text: String) -> Bool {
        UUID(uuidString: text) != nil || (text.count >= 12 && text.allSatisfy { $0.isHexDigit || $0 == "-" })
    }
}

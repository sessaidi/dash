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
            ActivitySeries(id: "claude.tokens", title: "Claude tokens", unit: "tokens", systemImage: "sparkles") { interval in
                ActivitySeries.sumPerDay(calls(interval).map { ($0.date, Double($0.inputTokens + $0.outputTokens + $0.cacheWriteTokens)) }, in: interval)
            },
            ActivitySeries(id: "claude.requests", title: "Claude requests", unit: "requests", systemImage: "bubble.left.and.bubble.right") { interval in
                ActivitySeries.countPerDay(calls(interval).map(\.date), in: interval)
            },
            ActivitySeries(id: "claude.cost", title: "Claude cost (USD)", unit: "USD", systemImage: "dollarsign.circle") { interval in
                ActivitySeries.sumPerDay(calls(interval).map { ($0.date, $0.costUSD) }, in: interval)
            },
        ]
    }
}

struct NoteWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var text: String
    }

    static let kind = "note"
    static let sizeLimits = GridLimits(minW: 2, minH: 3, maxW: 8, maxH: 16)
    static let displayName = "Note"
    static let summary = "A free-text scratch pad."
    static let systemImage = "note.text"
    static let defaultSize = WidgetSize.small
    static let defaultConfig = Config(text: "")
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["text": ["type": "string", "description": "Note contents (plain text)."]],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        TextEditor(text: config.text)
            .font(.body)
            .scrollContentBackground(.hidden)
    }

    static func preview(config: Config) -> some View {
        Text("Standup: ship the PR review fixes, pair on the flaky deploy test, follow up on the INC-42 postmortem.")
            .font(.body)
    }
}

/// Claude Code at a glance: who's logged in, what `/usage` says about the last 24 hours, and
/// what Dash itself spent today.
struct ClaudeUsageWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {}

    static let kind = "claude.usage"
    static let displayName = "Claude Usage"
    static let summary = "Your Claude plan's limits (usage credits or session and weekly limits), /usage for the last 24 hours, and what Dash spent today."
    static let systemImage = "gauge.with.dots.needle.33percent"
    static let defaultSize = WidgetSize.small
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 8, maxH: 10)
    static let defaultConfig = Config()
    static let configSchema: JSONValue = ["type": "object", "properties": .object([:])]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        ClaudeUsageWidgetView()
    }

    static func preview(config: Config) -> some View {
        ClaudeUsageSummary(account: "you@example.com", plan: "Enterprise", requests: 412, sessions: 5,
                           topTip: (64, "Start fresh when you switch tasks · run /clear"), spentToday: 1.84, callsToday: 37,
                           meter: .init(title: "Usage credits", percentUsed: 10, spent: 548.16, limit: 5000, resets: "Dec 1"))
    }

    @MainActor
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        let usage = ClaudeUsage.shared
        let today = usage.totals(days: 1)
        let window = usage.report?.windows.first
        return [
            "plan": .string(usage.auth?.subscriptionType ?? ""),
            "requests_24h": window?.requests.map { .number(Double($0)) } ?? .null,
            "dash_calls_today": .number(Double(today.calls)),
            "dash_cost_today_usd": .number(today.costUSD),
        ]
    }
}

private struct ClaudeUsageWidgetView: View {
    @Environment(AppSettings.self) private var settings
    private var usage: ClaudeUsage { .shared }

    var body: some View {
        let today = usage.totals(days: 1)
        let window = usage.report?.windows.first
        Group {
            if usage.refreshedAt == nil, let error = usage.error {
                StateView(.failed(message: error), action: ("Retry", { Task { await usage.refresh(executable: settings.claudeExecutable) } }))
            } else if usage.refreshedAt == nil {
                StateView(.loading("Reading Claude Code status…"))
            } else {
                ClaudeUsageSummary(account: usage.auth?.loggedIn == true ? usage.auth?.email : nil, plan: usage.auth?.subscriptionType?.capitalized,
                                   requests: window?.requests, sessions: window?.sessions,
                                   topTip: window?.tips.first.map { ($0.percent, $0.text) },
                                   spentToday: today.costUSD, callsToday: today.calls, meter: usage.limits?.meters.first)
            }
        }
        // `/usage` costs nothing (no model call); refresh it every 15 minutes while shown.
        .task {
            while !Task.isCancelled {
                await usage.refresh(executable: settings.claudeExecutable)
                await usage.refreshLimits(executable: settings.claudeExecutable)
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }
}

/// The widget's layout, shared by the live view and the gallery preview.
private struct ClaudeUsageSummary: View {
    let account: String?
    let plan: String?
    let requests: Int?
    let sessions: Int?
    let topTip: (Int, String)?
    let spentToday: Double
    let callsToday: Int
    var meter: ClaudePlanLimits.Meter?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let meter { PlanMeterRow(meter: meter) }
            HStack(spacing: 6) {
                if let plan { Badge(plan, tone: .info, systemImage: "sparkles") }
                Text(account ?? "Not logged in").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 16) {
                MetricView(requests.map { $0.formatted() } ?? "—", label: "Requests 24h")
                MetricView(sessions.map { $0.formatted() } ?? "—", label: "Sessions")
                MetricView(spentToday.formatted(.currency(code: "USD")), label: "Dash today (\(callsToday))")
            }
            if meter == nil, let (percent, text) = topTip {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(percent), total: 100)
                    Text("\(percent)% · \(text)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

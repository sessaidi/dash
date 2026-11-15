import ClaudeCodeKit
import DashKit
import DashKitUI
import SwiftUI

/// Claude Code at a glance: who's logged in, what `/usage` says about the last 24 hours, and
/// what Dash itself spent today.
struct ClaudeUsageWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {}

    static let kind = "claude.usage"
    static let displayName = "Dashii Usage"
    static let summary = "Your plan's limits (usage credits or session and weekly limits), /usage for the last 24 hours, and what Dash spent today."
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
                           meters: [.init(title: "Usage credits", percentUsed: 10, spent: 548.16, limit: 5000, resets: "Dec 1")])
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
                StateView(.loading("Reading Dashii status…"))
            } else {
                ClaudeUsageSummary(account: usage.auth?.loggedIn == true ? usage.auth?.email : nil, plan: usage.auth?.subscriptionType?.capitalized,
                                   requests: window?.requests, sessions: window?.sessions,
                                   topTip: window?.tips.first.map { ($0.percent, $0.text) },
                                   spentToday: today.costUSD, callsToday: today.calls, meters: usage.limits?.meters ?? [])
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

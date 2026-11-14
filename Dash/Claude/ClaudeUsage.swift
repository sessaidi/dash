import ClaudeCodeKit
import DashKit
import Foundation
import Observation
import SwiftData

/// One Claude Code request Dash made: who asked, which model, tokens, cost, time.
/// Kept in the store so usage can be charted over time (Settings › Usage).
@Model
final class ClaudeCall {
    var date: Date
    /// "chat", or "extension.pull-requests/review", "widget.<id>/summarize"…
    var source: String
    var model: String
    var effort: String?
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    /// Claude Code's estimate at API prices (on a subscription it counts toward the plan's limits).
    var costUSD: Double
    var durationMS: Int
    var turns: Int
    var isError: Bool

    init(date: Date = .now, source: String, model: String, effort: String?, inputTokens: Int, outputTokens: Int,
         cacheReadTokens: Int, cacheWriteTokens: Int, costUSD: Double, durationMS: Int, turns: Int, isError: Bool) {
        self.date = date
        self.source = source
        self.model = model
        self.effort = effort
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
        self.durationMS = durationMS
        self.turns = turns
        self.isError = isError
    }

    var totalInputTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens }

    /// "Pull Requests › review", "Chat".
    var sourceLabel: String { ClaudeCall.label(source) }

    static func label(_ source: String) -> String {
        if source == "chat" { return "Chat" }
        let parts = source.split(separator: "/", maxSplits: 1).map(String.init)
        var owner = parts.first ?? source
        for prefix in ["extension.", "widget."] where owner.hasPrefix(prefix) { owner.removeFirst(prefix.count) }
        if parts.first?.hasPrefix("widget.") == true { owner = "Widget" }
        let task = parts.count > 1 ? " › \(parts[1])" : ""
        return owner.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") + task
    }
}

/// Claude Code's status and usage, for Settings › Claude and the Claude Usage widget:
/// the CLI version and login (`claude auth status`), what `/usage` reports, and what Dash
/// itself spent (logged from every Claude Code result: chat, reviews, plugins).
@MainActor
@Observable
final class ClaudeUsage {
    static let shared = ClaudeUsage()

    /// Totals over a set of calls.
    struct Totals: Equatable {
        var calls = 0
        var turns = 0
        var costUSD = 0.0
        var inputTokens = 0
        var outputTokens = 0
        var errors = 0

        mutating func add(_ call: ClaudeCall) {
            calls += 1
            turns += call.turns
            costUSD += call.costUSD
            inputTokens += call.totalInputTokens
            outputTokens += call.outputTokens
            if call.isError { errors += 1 }
        }

        init() {}
        init(_ calls: [ClaudeCall]) { for call in calls { add(call) } }
    }

    private(set) var version: String?
    private(set) var auth: ClaudeAuthStatus?
    private(set) var report: ClaudeUsageReport?
    /// The plan's limit meters from interactive `/usage` (usage credits, session and weekly limits).
    private(set) var limits: ClaudePlanLimits?
    private(set) var limitsError: String?
    private(set) var isReadingLimits = false
    private(set) var refreshedAt: Date?
    private(set) var error: String?
    private(set) var isRefreshing = false
    /// Where calls are saved (the app's store); set by the host at launch.
    @ObservationIgnored weak var host: ExtensionHost?

    init() {}

    /// Dash's own folder for running Claude Code interactively (trusted once, stays empty).
    static var statusFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Dash/claude-status", directoryHint: .isDirectory)
    }

    /// Reads the plan's meters from interactive `/usage` (about ten seconds; no model call, no cost).
    func refreshLimits(executable: URL?) async {
        guard !isReadingLimits else { return }
        isReadingLimits = true
        defer { isReadingLimits = false }
        do {
            let limits = try await ClaudeCodeStatus.planLimits(executable: executable, folder: Self.statusFolder)
            self.limits = limits
            limitsError = limits.meters.isEmpty ? "Claude Code's /usage showed no plan limits." : nil
        } catch {
            limitsError = error.localizedDescription
        }
    }

    /// Runs `claude --version`, `claude auth status` and `/usage` (no model call, no cost).
    func refresh(executable: URL?) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let version = ClaudeCodeStatus.version(executable: executable)
            async let auth = ClaudeCodeStatus.auth(executable: executable)
            async let report = ClaudeCodeStatus.usage(executable: executable)
            (self.version, self.auth, self.report) = try await (version, auth, report)
            error = nil
            refreshedAt = .now
        } catch {
            self.error = error.localizedDescription
            DashLog.error("Couldn't read Claude Code status: \(error.localizedDescription)", category: "claude")
        }
    }

    /// Saves one finished Claude Code run.
    func record(source: String, model: String, effort: String?, result: ResultMessage, costUSD: Double? = nil, now: Date = .now) {
        guard let context = host?.context else { return }
        let usage = result.usage
        context.insert(ClaudeCall(
            date: now, source: source, model: model, effort: effort,
            inputTokens: usage?["input_tokens"]?.int ?? 0, outputTokens: usage?["output_tokens"]?.int ?? 0,
            cacheReadTokens: usage?["cache_read_input_tokens"]?.int ?? 0, cacheWriteTokens: usage?["cache_creation_input_tokens"]?.int ?? 0,
            costUSD: costUSD ?? result.totalCostUSD, durationMS: result.durationMS, turns: result.numTurns, isError: result.isError))
        try? context.save()
    }

    /// Calls since the start of the day `days - 1` days ago (1 = today).
    func calls(days: Int, now: Date = .now) -> [ClaudeCall] {
        guard let context = host?.context else { return [] }
        let start = Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(days - 1) * 86_400))
        let descriptor = FetchDescriptor<ClaudeCall>(predicate: #Predicate { $0.date >= start }, sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func totals(days: Int, now: Date = .now) -> Totals { Totals(calls(days: days, now: now)) }
}

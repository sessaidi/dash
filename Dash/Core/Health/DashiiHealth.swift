import ClaudeCodeKit
import DashKit
import Foundation
import Observation

/// Is Dashii working? Every chat turn and agent run records whether Dash's tools reached it and
/// whether it finished; with the engine's version, the login and Dash's recent crashes, that
/// makes one status the chat header and Settings show. `test` checks the whole path on demand.
@MainActor
@Observable
final class DashiiHealth {
    static let shared = DashiiHealth()

    struct Run: Codable, Identifiable, Equatable {
        var id = UUID()
        let at: Date
        /// "chat", "agent.<id>", "health check"
        let source: String
        /// Whether Dash's tools (the in-process MCP server) connected; nil when not reported.
        let toolsConnected: Bool?
        let ok: Bool
        let error: String?
        let seconds: Double
    }

    enum Level: Equatable { case healthy, degraded, down, unknown }

    struct Status: Equatable {
        let level: Level
        let title: String
        let detail: String
    }

    private(set) var runs: [Run]
    private(set) var crashes: [CrashReport] = []
    private(set) var isTesting = false

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = DashDefaults.shared) {
        self.defaults = defaults
        runs = defaults.data(forKey: "health.runs").flatMap { try? JSONDecoder().decode([Run].self, from: $0) } ?? []
    }

    /// Records one run (newest first, the last 40 kept).
    func record(source: String, toolsConnected: Bool?, ok: Bool, error: String?, started: Date) {
        let run = Run(at: .now, source: source, toolsConnected: toolsConnected, ok: ok,
                      error: error.map { String($0.prefix(300)) }, seconds: Date.now.timeIntervalSince(started))
        runs.insert(run, at: 0)
        runs = Array(runs.prefix(40))
        defaults.set(try? JSONEncoder().encode(runs), forKey: "health.runs")
        if !ok || toolsConnected == false {
            DashLog.error("Dashii run failed (\(source)): \(error ?? "tools didn't connect")", category: "health")
        }
    }

    /// Dash's crashes of the last week.
    func refreshCrashes() {
        crashes = CrashReports.all(limit: 10).filter { $0.date > Date.now.addingTimeInterval(-7 * 86_400) }
    }

    /// The status from the engine, the login, the latest runs and recent crashes, worst first.
    func status(engine: String?, loggedIn: Bool?, engineError: String?) -> Status {
        if engine == nil, let engineError {
            return Status(level: .down, title: "Dashii's engine isn't working", detail: engineError)
        }
        if loggedIn == false {
            return Status(level: .down, title: "Not logged in", detail: "Run `claude /login` in a terminal, then Refresh.")
        }
        if let last = runs.first, last.toolsConnected == false {
            return Status(level: .degraded, title: "Dashii's tools didn't connect",
                          detail: "On the last run (\(last.source), \(last.at.formatted(.relative(presentation: .named)))). Test Dashii to check again.")
        }
        let recent = runs.prefix(3)
        if recent.count >= 2, recent.prefix(2).allSatisfy({ !$0.ok }) {
            return Status(level: .down, title: "Dashii is failing", detail: recent.first?.error ?? "The last runs failed.")
        }
        if let last = runs.first, !last.ok {
            return Status(level: .degraded, title: "The last run failed", detail: last.error ?? "No answer.")
        }
        if let crash = crashes.first, crash.date > Date.now.addingTimeInterval(-86_400) {
            return Status(level: .degraded, title: "Dash crashed \(crash.date.formatted(.relative(presentation: .named)))",
                          detail: crash.reason.isEmpty ? crash.exception : crash.reason)
        }
        guard let last = runs.first else {
            return Status(level: .unknown, title: "Not checked yet", detail: "Ask Dashii something, or Test Dashii.")
        }
        return Status(level: .healthy, title: "Dashii is working",
                      detail: "Last run \(last.at.formatted(.relative(presentation: .named))) in \(String(format: "%.1f", last.seconds)) s, tools connected.")
    }

    /// One tiny run on the fast model: Dash's tools must connect and a `ping` tool must be called.
    /// Costs a little Dashii usage, so only on request.
    func test(settings: AppSettings) async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        let started = Date.now
        final class Ping: @unchecked Sendable { var called = false }
        let ping = Ping()
        var options = ClaudeCodeDefaults.options(settings: settings, system: "You are Dash's health check. Do exactly what you're asked.")
        options.model = DashiiModel.fast.rawValue
        options.effort = nil
        options.maxTurns = 3
        options.allowedTools = ["mcp__dash"]
        options.mcpServers = [DashMCPServer(tools: [["name": "ping", "description": "Answers pong.", "inputSchema": ["type": "object", "properties": [:]]]]) { _, _ in
            ping.called = true
            return MCPToolResult("pong")
        }]
        var connected: Bool?
        do {
            for try await message in query("Call the ping tool once, then answer with the single word OK.", options: options) {
                if case .system(let system) = message, system.subtype == "init" { connected = system.mcpServers["dash"].map { $0 == "connected" } }
                guard case .result(let result) = message else { continue }
                let ok = !result.isError && ping.called
                record(source: "health check", toolsConnected: connected, ok: ok,
                       error: ok ? nil : (result.isError ? (result.result ?? result.subtype) : "The ping tool wasn't called."), started: started)
                return
            }
            record(source: "health check", toolsConnected: connected, ok: false, error: "No answer.", started: started)
        } catch {
            record(source: "health check", toolsConnected: connected, ok: false, error: error.localizedDescription, started: started)
        }
    }
}

import DashKit
import Foundation

/// `data_fetch`: how Dashii and agents get fresh data. They never call a service; they ask the
/// integration that owns it to fetch into Dash's database, then read it there (DashQL datasets,
/// the knowledge graph).
enum FetchTools {
    /// `caller` names who fetches in the activity log ("dashii", "agent Watch SRE").
    @MainActor
    static func tools(host: ExtensionHost, caller: String = "dashii") -> [DashiiTool] {
        let fetchers = host.fetchers
        guard !fetchers.isEmpty else { return [] }
        let catalog = fetchers.map { fetcher in
            "- \(fetcher.name): \(fetcher.summary) Input: \(fetcher.inputSchema["properties"]?.jsonString() ?? "{}")"
        }.joined(separator: "\n")
        return [DashiiTool(
            name: "data_fetch",
            description: """
                Ask an integration to fetch fresh data from its service into Dash's database. You never call services \
                yourself: read what Dash has (DashQL, knowledge search, reader tools) and fetch only when it's missing \
                or stale. The answer says what was stored and where to read it.

                \(catalog)
                """,
            properties: ["fetcher": JSONSchema.string("Which fetcher.", enum: fetchers.map(\.name)),
                         "input": JSONSchema.object("The fetcher's input.")],
            required: ["fetcher"]
        ) { input in
            guard let name = input["fetcher"]?.string else { throw ToolError("Name a fetcher.") }
            return try await fetch(name, input["input"] ?? [:], host: host, caller: caller)
        }]
    }

    /// Runs a fetcher within its rate limit and logs it in the activity log (the Debug window's
    /// Activity pane; its requests show in Network).
    @MainActor
    static func fetch(_ name: String, _ input: JSONValue, host: ExtensionHost, caller: String, limiter: FetchLimiter = .shared) async throws -> JSONValue {
        let source = host.extensions.first { host.isEnabled($0) && $0.fetchers.contains { $0.name == name } }?.id ?? "dashboard"
        let asked = "\(caller) · \(String(Sanitizer.clean(input.jsonString()).prefix(300)))"
        let limit = host.settings.fetchesPerMinute
        if let wait = limiter.wait(for: name, limit: limit) {
            host.activity.emit("data.fetch_limited", source: source, title: "Didn't fetch \(name): \(limit) a minute at most", detail: asked)
            throw ToolError("\(name) was already fetched \(limit) times in the last minute. Read what's stored, or fetch again in \(Int(wait.rounded(.up))) s.")
        }
        do {
            let receipt = try await host.fetch(name, input)
            host.activity.emit("data.fetched", source: source, title: "Fetched \(name)", detail: asked + " → " + summary(of: receipt))
            return receipt
        } catch {
            host.activity.emit("data.fetch_failed", source: source, title: "Couldn't fetch \(name)", detail: asked + " → " + error.localizedDescription)
            throw error
        }
    }

    /// "stored 3, unchanged 1", or the start of a receipt that doesn't follow the convention.
    static func summary(of receipt: JSONValue) -> String {
        if let stored = receipt["stored"]?.int {
            return "stored \(stored)" + (receipt["unchanged"]?.int.map { ", unchanged \($0)" } ?? "")
        }
        return String(Sanitizer.clean(receipt.jsonString()).prefix(200))
    }
}

/// At most `limit` fetches per fetcher in any minute, so a looping agent can't hammer a service.
@MainActor
final class FetchLimiter {
    static let shared = FetchLimiter()
    private var recent: [String: [Date]] = [:]

    /// nil when the fetch may go (it's counted), else the seconds until one is allowed again.
    func wait(for name: String, limit: Int, now: Date = .now) -> TimeInterval? {
        var times = (recent[name] ?? []).filter { now.timeIntervalSince($0) < 60 }
        defer { recent[name] = times }
        if times.count >= max(limit, 1) { return 60 - now.timeIntervalSince(times[0]) }
        times.append(now)
        return nil
    }
}

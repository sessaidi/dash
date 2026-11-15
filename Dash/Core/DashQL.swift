@_spi(DashHost) import DashKit
import Foundation

/// DashQL in Dash: the datasets Dash itself offers (activity, pages, widgets, any widget's live
/// data, notes, knowledge, what Dashii learned) plus every enabled extension's, and the tools
/// Dashii and the agents query them with. Everything is read-only.
@MainActor
enum DashQL {
    static func engine(host: ExtensionHost) -> QueryEngine {
        WidgetQuery.me = me(host: host)
        return QueryEngine(datasets: builtIn(host: host) + host.extensions.filter { host.isEnabled($0) }.flatMap(\.datasets), me: me(host: host))
    }

    /// The statements enabled extensions add to DashQL, first one wins when two claim the same words.
    static func verbs(host: ExtensionHost) -> [DashQLVerb] {
        var seen = Set<String>()
        return host.extensions.filter { host.isEnabled($0) }.flatMap(\.verbs).filter { seen.insert("\($0.keyword) \($0.action)").inserted }
    }

    /// The plugin statements among `tools`, for a tool description; empty when there are none.
    static func verbsGuide(host: ExtensionHost, tools: [DashiiTool]) -> String {
        let allowed = Set(tools.map(\.name))
        let usable = verbs(host: host).filter { allowed.contains($0.tool) }
        guard !usable.isEmpty else { return "" }
        return "\n\nPlugin statements:\n" + usable.map { "  \($0.usage)   \($0.summary)" }.joined(separator: "\n")
    }

    /// Who `me` is: the name on Home and the logins the integrations report.
    static func me(host: ExtensionHost) -> [String] {
        var names = [host.ext(HomeExtension.self)?.userName ?? ""]
        for id in ["github", "gitlab", "atlassian"] {
            if let exports = host.integration(id)?.exports {
                names += ["login", "name", "email", "account", "displayName"].compactMap { exports[$0]?.string }
            }
        }
        return Array(Set(names.filter { !$0.isEmpty }))
    }

    static func builtIn(host: ExtensionHost) -> [QueryDataset] {
        [
            QueryDataset(name: "activity", summary: "What happened in Dash and its integrations: PRs, tickets, agents, deploys, meetings, layout edits (newest first).",
                         fields: [.init("time", "date", "When"), .init("source", "string", "Extension id", aliases: ["from"]), .init("kind"),
                                  .init("title"), .init("detail"), .init("link"), .init("importance", "string", "info, notable or critical")]) { _ in
                host.activity.events.reversed().map { event in
                    ["time": .string(event.date.formatted(.iso8601)), "source": .string(event.source), "kind": .string(event.kind),
                     "title": .string(event.title), "detail": event.detail.map(JSONValue.string) ?? .null,
                     "link": event.link.map(JSONValue.string) ?? .null, "importance": .string("\(event.importance)")]
                }
            },
            QueryDataset(name: "pages", summary: "Dashboard pages.", fields: [.init("id"), .init("name"), .init("icon"), .init("widgets", "number"), .init("draft", "bool")]) { _ in
                host.dashboard.pages().map(host.dashboard.describe)
            },
            QueryDataset(name: "widgets", summary: "Widgets on every page with their kind, title, grid position and config.",
                         fields: [.init("id"), .init("page_id", aliases: ["page"]), .init("kind"), .init("title"), .init("x", "number"), .init("y", "number"),
                                  .init("w", "number"), .init("h", "number"), .init("config", "object")]) { _ in
                host.dashboard.widgets(on: nil).filter { host.isWidgetAvailable($0.kind) }.map(host.dashboard.describe)
            },
            QueryDataset(name: "widget", summary: "One widget's live data, as rows (its main list: pods, tickets, PRs, releases…). Fields depend on the widget; read it once to see them.",
                         argument: "The widget's title or id") { argument in
                guard let argument, !argument.isEmpty else { throw QueryError("Name the widget: from widget \"Failing pods\".") }
                let widgets = host.dashboard.widgets(on: nil)
                guard let record = widgets.first(where: { $0.id.uuidString.caseInsensitiveCompare(argument) == .orderedSame })
                        ?? widgets.first(where: { $0.title.caseInsensitiveCompare(argument) == .orderedSame })
                        ?? widgets.first(where: { $0.title.localizedCaseInsensitiveContains(argument) }) else {
                    throw QueryError("No widget “\(argument)”. Widgets: \(widgets.map(\.title).joined(separator: ", ")).")
                }
                return rows(from: try await host.dashboard.snapshot(record.id)["data"] ?? .null)
            },
            QueryDataset(name: "notes", summary: "The user's notes.", fields: [.init("title"), .init("folder"), .init("modified", "date")]) { argument in
                guard let notes = host.ext(NotesExtension.self) else { return [] }
                let files = argument.map { notes.store.search($0) } ?? notes.store.notes
                return files.map { ["title": .string($0.title), "folder": .string($0.folder), "modified": .string($0.modified.formatted(.iso8601))] }
            },
            QueryDataset(name: "knowledge", summary: "The knowledge graph: repos, files, symbols, concepts, tickets, PRs, people, meetings. Give search text as the argument.",
                         fields: [.init("id"), .init("kind"), .init("name"), .init("summary"), .init("path"), .init("repo"), .init("url"), .init("updated", "date")],
                         argument: "Text to search for") { argument in
                guard let store = host.ext(KnowledgeExtension.self)?.store else { return [] }
                guard let argument, !argument.isEmpty else { throw QueryError("Give text: from knowledge \"rate limiting\".") }
                return try await store.search(argument, limit: 200).map { node in
                    ["id": .string(node.id), "kind": .string(node.kind), "name": .string(node.kind == "symbol" ? node.qualified : node.name),
                     "summary": .string(node.summary), "path": .string(node.path), "repo": .string(node.repo), "url": .string(node.url),
                     "updated": .string(node.updated.formatted(.iso8601))]
                }
            },
            QueryDataset(name: "memory", summary: "What Dashii learned in conversations (facts with confidence).",
                         fields: [.init("id"), .init("fact"), .init("confidence", "string", "stated, observed or inferred"), .init("updated", "date")]) { argument in
                guard let memory = host.ext(KnowledgeExtension.self)?.memory else { return [] }
                let facts = if let argument { await memory.recall(argument, limit: 50) } else { await memory.all() }
                return facts.map { node in
                    ["id": .string(node.id), "fact": .string(node.signature),
                     "confidence": .string(String(node.qualified.split(separator: "|").first ?? "inferred")), "updated": .string(node.updated.formatted(.iso8601))]
                }
            },
        ]
    }

    /// A widget snapshot as rows: the data when it's a list, else its biggest list of objects, else one row.
    static func rows(from data: JSONValue) -> [JSONValue] {
        if case .array(let items) = data { return items }
        if case .object(let fields) = data {
            let lists = fields.compactMap { key, value -> (String, [JSONValue])? in
                guard case .array(let items) = value, items.contains(where: { if case .object = $0 { true } else { false } }) else { return nil }
                return (key, items)
            }
            if let biggest = lists.max(by: { $0.1.count < $1.1.count }) { return biggest.1 }
        }
        return data == .null ? [] : [data]
    }

    // MARK: Linked widgets

    /// `$selected("Jira board").key` → the value of `key` in what's selected in that widget, as a
    /// DashQL literal ("KAN-1", 3, ("a", "b") for a list). `waiting` names the widgets with
    /// nothing selected: the query should then not filter at all.
    static func resolveSelections(_ text: String, host: ExtensionHost) -> (text: String, waiting: [String]) {
        var waiting: [String] = []
        let resolved = text.replacing(/\$selected\("([^"]+)"\)(?:\.([\w.]+))?/) { match in
            let title = String(match.output.1)
            let field = match.output.2.map(String.init)
            let widgets = host.dashboard.widgets(on: nil)
            guard let record = widgets.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame || $0.id.uuidString == title }),
                  let selection = host.live(record.id).selection else {
                waiting.append(title)
                return "null"
            }
            let value = field.flatMap { selection.value(at: $0) } ?? selection
            return literal(value)
        }
        return (resolved, waiting)
    }

    /// Whether a query refers to another widget's selection.
    static func isLinked(_ text: String) -> Bool { text.contains("$selected(") }

    /// A value as DashQL source.
    static func literal(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case .number(let number): DashDate.number(number)
        case .bool(let flag): String(flag)
        case .array(let items): "(" + items.map(literal).joined(separator: ", ") + ")"
        default: "null"
        }
    }

    static let guide = """
        DashQL reads, filters, joins and summarises what Dash knows. A query is a source then stages separated by |:
          from pods | where namespace = "bill-eu" and restarts > 3 | sort -restarts | take 10 | select name, node, restarts
          pods ns:bill-eu status:failing restarts>3         shorthand: field:value (contains, a,b for any of), field>3, -field:x (not), free words
          from jira where assignee = me and status in ("In Progress", "In Review") | join prs on key = ticket | select key, summary, prs.title
          from activity where time > -24h | count by source
          from widget "Failing pods" | where restarts > 5   any widget's live data
          from knowledge "rate limiting" | where kind = "file"
        Conditions: = != > >= < <= ~ (contains) !~ =~ (regex) in (…) not in (…) between a and b, is null, and/or/not, ( ).
        Values: "text", numbers, true/false, null, me, now, today, yesterday, dates (2026-10-12), durations from now (-24h, -7d, -30m).
        Fields: dotted paths (assignee.name); lists match when any element does.
        Linked widgets: $selected("Widget title").field is what the user selected in that widget (e.g. a widget's filter \
        `tickets ~ $selected("Jira board").key` follows the ticket picked on the board); with nothing selected the filter is off.
        Stages: where, search "text", sort [-]field, take n, select f [as a], distinct f, count by f, summarize count(), sum(f), avg(f), min(f), max(f), distinct(f) [as a] by f, join dataset ["arg"] on a = b [as alias].
        """

    static func tools(host: ExtensionHost) -> [DashiiTool] {
        [
            DashiiTool(
                name: "dashql",
                description: "Run a DashQL query: read, filter, join and summarise Dash's data (pods, tickets, PRs, releases, monitors, activity, notes, knowledge, any widget's live data) in one call. Read-only. Call dashql_schema first for the datasets and their fields.\n\n" + guide,
                properties: ["query": JSONSchema.string("The DashQL query.")], required: ["query"]
            ) { input in
                guard let query = input["query"]?.string else { throw ToolError("Give a query.") }
                do {
                    let linked = resolveSelections(query, host: host)
                    guard linked.waiting.isEmpty else {
                        throw ToolError("Nothing is selected in \(linked.waiting.joined(separator: ", ")) yet.")
                    }
                    return try await engine(host: host).run(linked.text).json
                } catch let error as QueryError {
                    throw ToolError(error.message)
                }
            },
            DashiiTool(
                name: "dashql_schema",
                description: "The datasets DashQL can read, with their fields, aliases and arguments, the statements plugins add (keyword action args), and the query syntax."
            ) { _ in
                ["datasets": .array(engine(host: host).datasets.map(\.schema)),
                 "verbs": .array(verbs(host: host).map { ["usage": .string($0.usage), "summary": .string($0.summary), "tool": .string($0.tool)] }),
                 "syntax": .string(guide)]
            },
        ]
    }
}

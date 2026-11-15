import DashKit
import Foundation

/// The one way Dashii and the agents work in Dash: DashQL statements, one per line, run in order.
/// Queries read (`from …`); verbs act on pages, widgets, notes, memory and any tool the caller may
/// use. Each statement goes through the same gate as a direct tool call (approvals, read-only
/// agents, no remote writes), so the language adds no power, only brevity.
///
///     from pods where status ~ crash | sort -restarts | take 5
///     widget "Failing pods" filter ns:papi-eu restarts>3
///     page "On-call" add kubernetes.pods title="Pods" x=0 y=0 w=6 h=8 config={"namespace":"papi-eu"}
///     tool jira_follow key=LAF-123
@MainActor
struct DashScript {
    let host: ExtensionHost
    /// The tools the caller may use (the chat's, or an agent's).
    let tools: [ClaudeTool]
    /// Asked before a tool runs: nil to go ahead, else why it can't.
    let gate: (ClaudeTool, JSONValue) async -> String?
    /// Translate only: report the actions each statement becomes, run nothing.
    var plan = false
    /// The tool calls the current statement became.
    private let actions = ActionLog()

    private final class ActionLog {
        var calls: [JSONValue] = []
    }

    /// Runs each statement; per statement, the actions it became (tool calls) and their result
    /// (or the error). Stops at the first error. With `plan`, only translates.
    func run(_ script: String) async -> JSONValue {
        var results: [JSONValue] = []
        for statement in Self.statements(script) {
            actions.calls = []
            do {
                let result = try await run(statement: statement)
                var entry: [String: JSONValue] = ["statement": .string(statement), "actions": .array(actions.calls)]
                if !plan { entry["result"] = result }
                results.append(.object(entry))
            } catch {
                results.append(["statement": .string(statement), "actions": .array(actions.calls),
                                "error": .string(Sanitizer.clean(error.localizedDescription))])
                break
            }
        }
        return results.count == 1 ? results[0] : .array(results)
    }

    // MARK: Statements

    func run(statement: String) async throws -> JSONValue {
        let lower = statement.lowercased()
        if lower.hasPrefix("from ") || lower == "from" { return try await call("dashql", ["query": .string(statement)]) }
        var words = DashArgs(statement)
        guard let verb = words.word() else { throw ToolError("Empty statement.") }
        switch verb.lowercased() {
        case "help": return help(words.word())
        case "schema": return try await call("dashql_schema", [:])
        case "show": return try await show(&words)
        case "widget": return try await widget(&words)
        case "page": return try await page(&words)
        case "note": return try await note(&words)
        case "remember":
            guard let fact = words.text() else { throw ToolError("remember \"a fact\" [about=[…]]") }
            var input: [String: JSONValue] = ["fact": .string(fact)]
            if let about = words.options()["about"] { input["about"] = about }
            return try await call("memory_remember", .object(input))
        case "recall": return try await call("memory_recall", words.text().map { ["query": .string($0)] } ?? [:])
        case "forget":
            guard let id = words.text() else { throw ToolError("forget obs:… (an id from recall)") }
            return try await call("memory_forget", ["id": .string(id)])
        case "search": return try await call("dashql", ["query": .string("from knowledge \"\(words.rest)\"")])
        case "tool", "call":
            guard let name = words.word() else { throw ToolError("tool <name> key=value … (help lists them)") }
            return try await call(name, .object(words.options()))
        default:
            // A tool name on its own works too: `jira_follow key=LAF-1`.
            if tools.contains(where: { $0.name == verb }) { return try await call(verb, .object(words.options())) }
            throw ToolError("Unknown verb `\(verb)`. Verbs: from, widget, page, show, note, remember, recall, forget, search, tool, help.")
        }
    }

    private func show(_ words: inout DashArgs) async throws -> JSONValue {
        switch words.word()?.lowercased() {
        case "page": return try await call("view_show", ["page": .string(try words.require("page name"))])
        case "note": return try await call("view_show", ["note": .string(try words.require("note title"))])
        case "notes": return try await call("view_show", ["view": "notes"])
        case "knowledge": return try await call("view_show", ["view": "knowledge"])
        case nil, "view", "current": return try await call("view_current", [:])
        case let other?: throw ToolError("show page \"Name\" | note \"Title\" | notes | knowledge | current (not `\(other)`).")
        }
    }

    private func widget(_ words: inout DashArgs) async throws -> JSONValue {
        let name = try words.require("widget title or id")
        let id = try widgetID(name)
        switch words.word()?.lowercased() {
        case nil, "read": return try await call("read_widget", ["id": .string(id)])
        case "filter", "query": return try await call("widget_query", ["id": .string(id), "query": .string(words.rest)])
        case "clear": return try await call("widget_query", ["id": .string(id), "query": ""])
        case "do", "act":
            guard let action = words.word() else { throw ToolError("widget \"…\" do <action> key=value …") }
            return try await call("widget_act", ["id": .string(id), "action": .string(action), "input": .object(words.options())])
        case "set", "configure":
            var input: [String: JSONValue] = ["id": .string(id)]
            let options = words.options()
            if let title = options["title"] { input["title"] = title }
            if let size = options["size"] { input["size"] = size }
            let config = options.filter { !["title", "size", "config"].contains($0.key) }
            input["config"] = options["config"] ?? .object(config)
            return try await call("update_widget", .object(input))
        case "place", "move":
            var input = words.options()
            input["id"] = .string(id)
            return try await call("place_widget", .object(input))
        case "remove", "delete": return try await call("remove_widget", ["id": .string(id)])
        case let other?: throw ToolError("widget \"…\" read | filter <query> | clear | do <action> | set k=v | place x= y= w= h= | remove (not `\(other)`).")
        }
    }

    private func page(_ words: inout DashArgs) async throws -> JSONValue {
        let first = try words.require("create, or a page name")
        if first.lowercased() == "create" || first.lowercased() == "new" {
            let name = try words.require("page name")
            var input: [String: JSONValue] = ["name": .string(name)]
            if let icon = words.options()["icon"] { input["icon"] = icon }
            return try await call("create_page", .object(input))
        }
        let pageID = plan && !host.dashboard.pages().contains(where: { $0.name.localizedCaseInsensitiveContains(first) }) ? "(page \(first))" : try self.pageID(first)
        switch words.word()?.lowercased() {
        case nil, "read": return try await call("dashql", ["query": .string("from widgets | where page_id = \"\(pageID)\"")])
        case "add":
            guard let kind = words.word() else { throw ToolError("page \"…\" add <widget kind> title=… x= y= w= h= config={…}") }
            let options = words.options()
            var add: [String: JSONValue] = ["kind": .string(kind), "page_id": .string(pageID)]
            for key in ["title", "size", "config"] { if let value = options[key] { add[key] = value } }
            let added = try await call("add_widget", .object(add))
            guard let id = added["id"]?.string ?? (plan ? "(the new widget)" : nil), options.keys.contains(where: { ["x", "y", "w", "h"].contains($0) }) else { return added }
            var place: [String: JSONValue] = ["id": .string(id)]
            for key in ["x", "y", "w", "h"] { if let value = options[key] { place[key] = value } }
            return try await call("place_widget", .object(place))
        case "rename", "set":
            var input = words.options()
            input["id"] = .string(pageID)
            if input["name"] == nil, let name = words.text() { input["name"] = .string(name) }
            return try await call("update_page", .object(input))
        case "delete", "remove": return try await call("delete_page", ["id": .string(pageID)])
        case let other?: throw ToolError("page \"…\" read | add <kind> … | rename name=… | delete (not `\(other)`).")
        }
    }

    private func note(_ words: inout DashArgs) async throws -> JSONValue {
        switch words.word()?.lowercased() {
        case "create", "new":
            let title = try words.require("note title")
            let options = words.options()
            return try await call("notes_create", ["title": .string(title), "markdown": options["text"] ?? options["markdown"] ?? ""])
        case "append":
            let title = try words.require("note title")
            let options = words.options()
            return try await call("notes_append", ["title": .string(title), "markdown": options["text"] ?? options["markdown"] ?? ""])
        case "read": return try await call("notes_read", ["title": .string(try words.require("note title"))])
        case "search": return try await call("notes_search", ["query": .string(words.rest)])
        case let other: throw ToolError("note create \"Title\" text=\"…\" | append | read \"Title\" | search words (not `\(other ?? "")`).")
        }
    }

    // MARK: Tools

    func call(_ name: String, _ input: JSONValue) async throws -> JSONValue {
        guard let tool = tools.first(where: { $0.name == name }) else {
            throw ToolError("`\(name)` isn't available here. `help` lists what is.")
        }
        actions.calls.append(["tool": .string(name), "input": input, "asks_first": .bool(tool.requiresApproval)])
        if plan {
            // Later steps may need an id this one would create.
            return name == "add_widget" ? ["id": "(the new widget)"] : name == "create_page" ? ["id": "(the new page)"] : .null
        }
        if let denied = await gate(tool, input) { throw ToolError(denied) }
        return try await tool.run(input)
    }

    private func widgetID(_ name: String) throws -> String {
        let widgets = host.dashboard.widgets(on: nil).filter { host.isWidgetAvailable($0.kind) }
        if let exact = widgets.first(where: { $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame || $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact.id.uuidString
        }
        let partial = widgets.filter { $0.title.localizedCaseInsensitiveContains(name) }
        guard partial.count == 1 else {
            throw ToolError(partial.isEmpty ? "No widget “\(name)”. Widgets: \(widgets.map(\.title).joined(separator: ", "))."
                                            : "“\(name)” matches \(partial.map(\.title).joined(separator: ", ")); use the full title or id.")
        }
        return partial[0].id.uuidString
    }

    private func pageID(_ name: String) throws -> String {
        let pages = host.dashboard.pages()
        guard let page = pages.first(where: { $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame || $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? pages.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
            throw ToolError("No page “\(name)”. Pages: \(pages.map(\.name).joined(separator: ", ")).")
        }
        return page.id.uuidString
    }

    private func help(_ topic: String?) -> JSONValue {
        if let topic, let tool = tools.first(where: { $0.name == topic }) {
            return ["tool": .string(tool.name), "description": .string(tool.description), "input_schema": tool.inputSchema]
        }
        return ["language": .string(Self.guide),
                "tools": .array(tools.map { .string("\($0.name): \(ChatSession.summary(of: $0.description, limit: 110))") })]
    }

    /// Statements: one per line (or separated by `;`), outside quotes and brackets.
    static func statements(_ script: String) -> [String] {
        var statements: [String] = [], current = "", quote: Character?, depth = 0
        for character in script {
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                continue
            }
            switch character {
            case "\"", "'": quote = character; current.append(character)
            case "[", "{", "(": depth += 1; current.append(character)
            case "]", "}", ")": depth -= 1; current.append(character)
            case "\n", ";" where depth == 0:
                statements.append(current); current = ""
            default: current.append(character)
            }
        }
        statements.append(current)
        return statements.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static let guide = """
        Work in Dash with statements, one per line, run in order (it stops at the first error):
          from <dataset> … | where … | sort … | take …      read anything (DashQL; `schema` lists datasets)
          widget "Title" [read]                              its data, UI state, actions, filter fields
          widget "Title" filter ns:papi-eu restarts>3 | sort -restarts | take 20     what it shows (clear: widget "Title" clear)
          widget "Title" do <action> key=value …            e.g. do search text=W43, do select_pod name=api-1
          widget "Title" set key=value … | place x=0 y=0 w=6 h=8 | remove
          page create "Name" icon=bell                       page "Name" [read] | add <kind> title="…" x= y= w= h= config={…} | rename name=… | delete
          show page "Name" | show note "Title" | show notes | show knowledge | show current
          note create "Title" text="…" | note append "Title" text="…" | note read "Title" | note search words
          remember "fact" about=[LAF-1, owner/repo] | recall [words] | forget obs:… | search <words in the knowledge graph>
          tool <name> key=value …   (or just <name> key=value …)   any other tool; `help <name>` shows its inputs
        Values: "text", numbers, true/false, [a, b], {"json": "object"}. Widgets and pages by title or id.
        Each statement's result lists the actions (tool calls) it became; plan: true returns those without running anything.
        """
}

/// The words and `key=value` options of a statement.
struct DashArgs {
    private(set) var rest: String

    init(_ text: String) { rest = text.trimmingCharacters(in: .whitespaces) }

    /// The next bare or quoted word.
    mutating func word() -> String? {
        rest = rest.trimmingCharacters(in: .whitespaces)
        guard let first = rest.first else { return nil }
        if first == "\"" || first == "'" {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: first) else { defer { rest = "" }; return String(body) }
            defer { rest = String(body[body.index(after: end)...]) }
            return String(body[..<end])
        }
        // A `key=value` is an option, not a word.
        let token = rest.prefix { !$0.isWhitespace }
        if token.contains("=") && !token.hasPrefix("=") { return nil }
        rest = String(rest.dropFirst(token.count))
        return String(token)
    }

    mutating func require(_ what: String) throws -> String {
        guard let word = word(), !word.isEmpty else { throw ToolError("Expected the \(what).") }
        return word
    }

    /// The rest as one text: quoted, or everything up to the options.
    mutating func text() -> String? {
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.first == "\"" || rest.first == "'" { return word() }
        let words = rest.split(separator: " ").prefix { !$0.contains("=") }
        guard !words.isEmpty else { return nil }
        let text = words.joined(separator: " ")
        rest = String(rest.dropFirst(text.count))
        return text
    }

    /// `key=value` pairs: "text", numbers, true/false, [lists], {json}, or bare words.
    mutating func options() -> [String: JSONValue] {
        var options: [String: JSONValue] = [:]
        var text = Substring(rest)
        while true {
            text = text.drop { $0.isWhitespace }
            guard let equals = text.firstIndex(of: "="), !text[..<equals].contains(where: \.isWhitespace) else { break }
            let key = String(text[..<equals])
            var value = text[text.index(after: equals)...]
            let raw: Substring
            switch value.first {
            case "\"", "'":
                let quote = value.first!
                let body = value.dropFirst()
                let end = body.firstIndex(of: quote) ?? body.endIndex
                raw = value[value.startIndex..<(end < body.endIndex ? body.index(after: end) : end)]
            case "[", "{":
                var depth = 0, inQuote = false, end = value.endIndex
                for index in value.indices {
                    let character = value[index]
                    if character == "\"" { inQuote.toggle() }
                    guard !inQuote else { continue }
                    if character == "[" || character == "{" { depth += 1 }
                    if character == "]" || character == "}" { depth -= 1; if depth == 0 { end = value.index(after: index); break } }
                }
                raw = value[value.startIndex..<end]
            default:
                raw = value.prefix { !$0.isWhitespace }
            }
            options[key] = Self.value(String(raw))
            value = value.dropFirst(raw.count)
            text = value
        }
        rest = String(text)
        return options
    }

    static func value(_ raw: String) -> JSONValue {
        if raw.hasPrefix("{") || raw.hasPrefix("[\""), let json = try? JSONValue.parse(Data(raw.utf8)) { return json }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            return .array(raw.dropFirst().dropLast().split(separator: ",").map { value($0.trimmingCharacters(in: .whitespaces)) })
        }
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'")), raw.count >= 2 {
            return .string(String(raw.dropFirst().dropLast()))
        }
        if let number = Double(raw) { return .number(number) }
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        return .string(raw)
    }
}

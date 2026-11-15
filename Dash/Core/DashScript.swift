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
    let tools: [DashiiTool]
    /// Asked before a tool runs: nil to go ahead, else why it can't.
    let gate: (DashiiTool, JSONValue) async -> String?
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
        case "sidebar": return try await call("sidebar", [:])
        case "section": return try await section(&words)
        case "plugin", "plugins", "extension":
            guard let name = words.word() else { return try await call("extensions_list", [:]) }
            switch words.word()?.lowercased() {
            case "on", "enable": return try await call("extension_set_enabled", ["id": .string(name), "enabled": true])
            case "off", "disable": return try await call("extension_set_enabled", ["id": .string(name), "enabled": false])
            case nil, "settings", "open": return try await call("open_screen", ["screen": .string(name)])
            case let other?: throw ToolError("plugin \"…\" on | off | settings (not `\(other)`).")
            }
        case "automation": return try await call("automation_list", [:])
        case "rules":
            let scope = words.word() ?? "global"
            if words.rest.trimmingCharacters(in: .whitespaces).isEmpty { return try await call("rules_show", ["scope": .string(scope)]) }
            return try await call("automation_set_rules", ["scope": .string(scope), "text": words.options()["text"] ?? .string(words.rest)])
        case "command":
            guard let action = words.word()?.lowercased(), let name = words.word() else { throw ToolError("command save <name> prompt=\"…\" summary=\"…\" | command delete <name>") }
            if action == "delete" { return try await call("command_delete", ["name": .string(name)]) }
            var input = words.options()
            input["name"] = .string(name)
            return try await call("command_save", .object(input))
        case "hook":
            switch words.word()?.lowercased() {
            case "create", "new":
                let name = words.word()
                var input = words.options()
                if input["name"] == nil, let name { input["name"] = .string(name) }
                return try await call("hook_create", .object(input))
            case "presets": return try await call("hook_presets", [:])
            case "preset":
                var input = words.options()
                input["preset"] = .string(try words.require("preset id (hook presets lists them)"))
                return try await call("hook_create", .object(input))
            case "on": return try await call("hook_set_enabled", ["id": .string(try words.require("hook name or id")), "enabled": true])
            case "off": return try await call("hook_set_enabled", ["id": .string(try words.require("hook name or id")), "enabled": false])
            case "delete": return try await call("hook_delete", ["id": .string(try words.require("hook name or id"))])
            default: throw ToolError("hook create name=\"…\" trigger={…} action={…} | hook on|off|delete \"name\"")
            }
        case "agent", "agents":
            guard let first = words.word() else { return try await call("dash_agents", [:]) }
            switch first.lowercased() {
            case "create", "new":
                let name = words.word()
                var input = words.options()
                if input["name"] == nil, let name { input["name"] = .string(name) }
                return try await call("agent_create", .object(input))
            default:
                switch words.word()?.lowercased() {
                case "run": return try await call("dash_agent_run", ["id": .string(first), "reason": .string(words.rest.isEmpty ? "asked in chat" : words.rest)])
                case "reports": return try await call("dash_agent_reports", ["id": .string(first)])
                case "set", "update":
                    var input = words.options()
                    input["id"] = .string(first)
                    return try await call("agent_update", .object(input))
                case "delete": return try await call("agent_delete", ["id": .string(first)])
                default: throw ToolError("agent create \"Name\" instructions=… every_minutes=… | agent \"Name\" run | reports | set k=v | delete")
                }
            }
        case "open": return try await call("open_screen", ["screen": .string(words.rest)])
        case "skills": return try await call("skills_list", [:])
        case "skill":
            switch words.word()?.lowercased() {
            case "use", "load": return try await call("skill_use", ["name": .string(try words.require("skill name"))])
            case "save", "create":
                let name = try words.require("skill name")
                var input = words.options()
                input["name"] = .string(name)
                return try await call("skill_save", .object(input))
            case "delete": return try await call("skill_delete", ["name": .string(try words.require("skill name"))])
            default: throw ToolError("skill use <name> | skill save <name> when_to_use=\"…\" instructions=\"…\" template=\"…\" | skill delete <name> | skills")
            }
        case "tool", "call":
            guard let name = words.word() else { throw ToolError("tool <name> key=value … (help lists them)") }
            return try await call(name, .object(words.options()))
        default:
            // A tool name on its own works too: `jira_follow key=LAF-1`.
            if tools.contains(where: { $0.name == verb }) { return try await call(verb, .object(words.options())) }
            if let result = try await pluginVerb(verb.lowercased(), &words) { return result }
            let keywords = Set(verbs.map(\.keyword)).sorted()
            throw ToolError("Unknown verb `\(verb)`. Verbs: from, widget, page, show, open, note, sidebar, section, plugin, automation, rules, command, hook, agent, remember, recall, forget, search, tool, help"
                + (keywords.isEmpty ? "." : "; from plugins: \(keywords.joined(separator: ", ")).") )
        }
    }

    /// The statements enabled extensions add (`ticket follow LAF-123`), limited to the tools the caller may use.
    var verbs: [DashQLVerb] {
        let allowed = Set(tools.map(\.name))
        return DashQL.verbs(host: host).filter { allowed.contains($0.tool) }
    }

    /// `keyword action <args…> key=value…`, mapped to the extension's tool; nil if no extension uses `keyword`.
    private func pluginVerb(_ keyword: String, _ words: inout DashArgs) async throws -> JSONValue? {
        let matching = verbs.filter { $0.keyword == keyword }
        guard !matching.isEmpty else { return nil }
        let action = words.word()?.lowercased()
        guard let verb = matching.first(where: { $0.action == action }) else {
            throw ToolError(matching.map(\.usage).joined(separator: " | "))
        }
        var input: [String: JSONValue] = [:]
        for name in verb.arguments {
            guard let value = words.word() else { break }
            input[name] = .string(value)
        }
        input.merge(words.options()) { _, option in option }
        input.merge(verb.presets) { _, preset in preset }
        return try await call(verb.tool, .object(input))
    }

    private func section(_ words: inout DashArgs) async throws -> JSONValue {
        switch words.word()?.lowercased() {
        case "create", "new": return try await call("section_create", ["name": .string(try words.require("section name"))])
        case "rename":
            let section = try words.require("section name")
            let options = words.options()
            return try await call("section_rename", ["section": .string(section), "name": options["name"] ?? .string(words.rest)])
        case "delete": return try await call("section_delete", ["section": .string(try words.require("section name"))])
        default: throw ToolError("section create \"Name\" | section rename \"Old\" name=\"New\" | section delete \"Name\"")
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
        case "move":
            var input = words.options()
            input["page"] = .string(pageID)
            return try await call("page_move", .object(input))
        case "home": return try await call("page_set_home", ["page": .string(pageID), "home": words.options()["on"] ?? .bool(words.word()?.lowercased() != "off")])
        case let other?: throw ToolError("page \"…\" read | add <kind> … | rename name=… | move section=… before=… | home on|off | delete (not `\(other)`).")
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
        if let topic, case let matching = verbs.filter({ $0.keyword == topic.lowercased() }), !matching.isEmpty {
            return .array(matching.map { ["usage": .string($0.usage), "summary": .string($0.summary), "tool": .string($0.tool)] })
        }
        var help: [String: JSONValue] = ["language": .string(Self.guide),
                                         "tools": .array(tools.map { .string("\($0.name): \(ChatSession.summary(of: $0.description, limit: 110))") })]
        if !verbs.isEmpty { help["plugin_verbs"] = .array(verbs.map { .string("\($0.usage): \($0.summary)") }) }
        return .object(help)
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
          sidebar | section create "Ops" | section rename "Ops" name="On-call" | section delete "Ops"
          page "Name" move section="Ops" before="Other page" | page "Name" home on|off
          plugins | plugin "jira-board" on|off|settings       open marketplace | open hooks | open gallery | open jira-board
          automation | rules <scope> (show) | rules <scope> text="…" (propose; the user approves) | command save standup prompt="…" summary="…" | command delete standup
          hook create name="Morning brief" trigger={"schedule":{"time":"09:00","weekdays":[2,3,4,5,6]}} action={"prompt":{"prompt":"…","noteTitle":null,"notify":true}}
          hook on|off|delete "Name" | hook presets | hook preset <id> | hook preset <wake-…id> agent=<agent id>
          (watchers run a query themselves, no Claude, and fire on new rows: prefer them to agents for "tell me when X appears")
          agents | agent create "Release watcher" role="…" instructions="…" integrations=[releases] every_minutes=30 | agent "Name" run | reports | set k=v | delete
          skills | skill use bug-report | skill save <name> when_to_use="…" instructions="…" | skill delete <name>
          <keyword> <action> <args> key=value …   statements plugins add (ticket follow LAF-1); `help` lists them, `help <keyword>` shows one
          tool <name> key=value …   (or just <name> key=value …)   any other tool; `help <name>` shows its inputs
        Saved vs temporary: `filter` and `set` are saved with the widget; `do` actions are temporary.
        Linked widgets: widget "PRs" filter tickets ~ $selected("Jira board").key  (follows the ticket picked on the board)
        Any dataset as a widget: page "X" add dash.data title="High-risk PRs" config={"dataset":"prs","query":"where risk = high","view":"table"}
          (view: table, list, counts, number, bars; counts and bars want a `count by` at the end of query)
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

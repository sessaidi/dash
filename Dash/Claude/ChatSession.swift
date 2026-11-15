import DashKit
import DashKitUI
import ClaudeCodeKit
import Foundation
import Observation
import SwiftData

struct ChatEntry: Identifiable, Equatable, Codable {
    enum Kind: Equatable, Codable {
        case user(String)
        case text(String)
        case thinking(String)
        case tool(name: String, input: String, result: String?, isError: Bool)
        case notice(String, isError: Bool)
        /// A question with answers to click (`ask_user`).
        case choices(ChatChoices)
        /// Layouts drawn for the user to pick (`propose_layouts`).
        case layouts(LayoutProposal)
    }

    let id: String
    var kind: Kind
    var toolUseID: String?
}

/// A past chat, kept so it can be reopened (and continued: Claude Code resumes its session).
@Model
final class ChatConversation {
    @Attribute(.unique) var id: UUID
    /// The first thing the user asked.
    var title: String
    var started: Date
    var updated: Date
    /// Claude Code's session, resumed when the conversation is reopened.
    var sessionID: String?
    var entriesData: Data

    init(title: String) {
        id = UUID()
        self.title = title
        started = .now
        updated = .now
        entriesData = Data("[]".utf8)
    }

    var entries: [ChatEntry] {
        get { (try? JSONDecoder().decode([ChatEntry].self, from: entriesData)) ?? [] }
        set { entriesData = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8) }
    }
}

/// One Claude Code turn, for the Debug window.
struct ClaudeTraceEntry: Identifiable {
    let id = UUID()
    let date: Date
    let model: String
    let stopReason: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let toolCalls: [String]
    let milliseconds: Int
    let error: String?
}

/// The chat panel: a long-lived Claude Code session (your Claude login) with every extension's
/// tools served to it as the in-process MCP server "dash".
@MainActor
@Observable
final class ChatSession {
    // Set from ChatComponents too (questions and layouts drawn in the chat).
    var transcript: [ChatEntry] = []
    /// Recent requests with token usage, for the Debug window.
    private(set) var trace: [ClaudeTraceEntry] = []
    private(set) var live: [ChatEntry] = []
    private(set) var isRunning = false
    var isPanelVisible = true
    /// Tool results that arrived before Claude Code's message naming the call, by tool name.
    @ObservationIgnored private var earlyResults: [String: [(String, Bool)]] = [:]
    /// Text put in the composer for the user to finish (a started request); the panel takes it.
    var pendingDraft: String?
    /// The conversation on screen, saved after every turn.
    private(set) var conversationID: UUID?

    @ObservationIgnored let host: ExtensionHost
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The last activity event Claude has been told about.
    @ObservationIgnored private var lastActivityID = 0
    /// Claude Code backend: one long-lived session per conversation (restarted with `--resume`
    /// when the tool set changes), and the turn waiting for its result.
    @ObservationIgnored private var code: ClaudeCodeSession?
    @ObservationIgnored private var codeToolNames: [String] = []
    @ObservationIgnored private var codeSessionID: String?
    @ObservationIgnored private var codeTurn: CheckedContinuation<ResultMessage, Error>?
    /// The running session's cost so far (results report it cumulatively).
    @ObservationIgnored private var sessionCost = 0.0
    /// The rules the running session was started with; a change starts a fresh session.
    @ObservationIgnored private var codeRules: String?
    @ObservationIgnored private var codeStarted = Date()
    @ObservationIgnored private var codeLiveID = UUID().uuidString

    init(host: ExtensionHost) {
        self.host = host
        host.chat = self
    }

    /// Everything Dashii can do, as tools.
    private var allTools: [DashiiTool] { CoreTools.tools(host: host) + ViewContext.tools(host: host) + DashQL.tools(host: host) + AppTools.tools(host: host) + Skills.tools(host: host) + componentTools + host.availableTools }

    /// What Claude is offered: in compact mode the `dash` statements tool (which reaches all the
    /// others through the same approvals) plus the chat's question and layout tools; otherwise all.
    private var tools: [DashiiTool] {
        let all = allTools
        let dash = dashTool(over: all)
        return host.settings.compactTools ? [dash] + componentTools : [dash] + all
    }

    /// The `dash` tool: DashQL statements run over `tools`, each gated like a direct call.
    private func dashTool(over tools: [DashiiTool]) -> DashiiTool {
        DashiiTool(
            name: "dash",
            description: "Read and work in Dash with DashQL statements (one per line): query any data, drive widgets, build pages, notes, memory, and call any other tool. Start with `help` or `schema` when unsure.\n\n" + DashScript.guide + "\n" + DashQL.guide + DashQL.verbsGuide(host: host, tools: tools),
            properties: ["script": JSONSchema.string("One or more statements, one per line."),
                         "plan": JSONSchema.boolean("Only translate: return the actions (tool calls) each statement becomes, without running them.")],
            required: ["script"]
        ) { [weak self] input in
            guard let self, let script = input["script"]?.string else { throw ToolError("Give a script.") }
            var runner = DashScript(host: host, tools: tools) { [weak self] tool, input in await self?.approve(tool, input) }
            runner.plan = input["plan"]?.bool ?? false
            return await runner.run(script)
        }
    }

    /// The checks a tool call passes: hooks, then the user's approval when it changes things.
    /// nil to go ahead, else why not.
    private func approve(_ tool: DashiiTool, _ input: JSONValue) async -> String? {
        if case .deny(let reason) = await HookEngine.shared.beforeTool(tool.name, input: input) { return reason }
        if tool.requiresApproval, host.settings.confirmWrites {
            let approved = await host.permissions.ask(
                icon: "sparkles", title: "Dashii wants to run \(tool.name)", message: Self.summary(of: tool.description),
                details: [.init(title: "Input", text: input.jsonString(pretty: true))])
            if !approved { return "The user declined this action." }
        }
        return nil
    }

    static let systemPrompt = """
        Dash is a macOS work dashboard. It shows the user's Jira board, \
        the open pull requests on the GitHub repositories they watch (each with an automatic Claude review), \
        coding agents working on Jira tickets in git worktrees, and live transcripts of Zoom meetings.

        Use the tools to look things up; don't guess at ticket, PR or meeting contents. Remote systems \
        (GitHub, GitLab, Jira, clouds, clusters) are read-only for you: you can't post, comment, merge, deploy \
        or change anything there; the user does that themselves. Local changes (pages, widgets, notes) and \
        deleting things may be approved or declined by the user; if one is declined, don't retry it, ask what \
        they want instead.

        The dashboard has pages (sidebar items), each a 12-column grid of widgets. Each widget has a kind, a \
        title, a grid position and size, and a JSON config defined by its kind. You can create pages and fill \
        them, e.g. an "On-call" page with incidents and workspaces. Call list_widget_types before adding or reconfiguring a widget \
        whose config schema you haven't seen in this conversation. read_widget explains a widget (what it is, \
        its data, what it shows right now) and lists its actions; widget_act drives one on screen (search, \
        filter, select, jump to a date) like the user would.

        When the user wants a new page, call layout_context, then ask what the page is for with ask_user \
        (its role first, then one or two more questions when they matter: which services, teams or repos, \
        what to see first), one question per turn. Then draw 2 or 3 options with propose_layouts, each with \
        configured widgets. The user picks one in the chat and Dash builds it; then check the widgets' \
        settings. To rework an existing page, do the same with propose_layouts and its page_id: the pick \
        replaces that page's widgets. Always offer choices this way; use suggest_layout (a single draft) \
        only when the user asks for one draft. Mention Marketplace plugins that would help, but don't \
        install them.

        Dashboard activity since your previous turn (new and reviewed PRs, ticket moves, agent progress, \
        meetings, workspace changes, layout edits) arrives in <dashboard-activity> tags at the start of a \
        user message. Use them to stay \
        current and mention what matters to the question; don't recite them. Call dashboard_activity to look \
        further back.

        Work through the dash tool: DashQL statements read anything (`from …`), drive widgets, build pages \
        and notes, remember facts, and call any other tool; several statements per call, one per line. \
        Prefer one query that filters, joins and summarises over many calls. What lasts and what doesn't: \
        `widget … filter` and `widget … set` are saved with the widget; `widget … do` actions (search, select, \
        zoom) only change what it shows until the user moves on. To show data no widget has, add a `dash.data` \
        widget (any dataset as a table, list, counts, number or bars). To link widgets, filter one on another's \
        selection: `widget "PRs" filter tickets ~ $selected("Jira board").key`. `help` lists every tool and \
        `schema` every dataset.

        What you learned in earlier conversations arrives in <what-i-know>: use it, but the user's word and \
        live data win. When the user tells you to remember something or corrects you, call memory_remember \
        (and memory_forget for what was wrong).

        What the user is looking at (the page and its widgets, or the open note) arrives in <current-view> \
        tags with each message. "This", "here", "this note", "these pods" refer to it: act on it without asking \
        which one. Call view_current to read the view's live data or the open note, and view_show to open a page \
        or note, for example to show what you just made or changed.

        The chat panel is narrow. Keep answers short, and after changing something say in one line what changed.
        """

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        transcript.append(ChatEntry(id: UUID().uuidString, kind: .user(trimmed)))
        // "/standup …" runs the command's prompt; the transcript keeps what was typed.
        let prompt = AutomationStore.shared.expand(trimmed) ?? trimmed
        task = Task { await runClaudeCode(prompt) }
    }

    func stop() {
        task?.cancel()
        host.permissionCenter.denyAll()
        if let code { Task { try? await code.interrupt() } }
    }

    func reset() {
        stop()
        saveConversation()
        transcript = []
        live = []
        earlyResults = [:]
        code?.terminate()
        code = nil
        codeSessionID = nil
        sessionCost = 0
        conversationID = nil
    }

    // MARK: History

    /// Past conversations, most recent first.
    func conversations() -> [ChatConversation] {
        (try? host.context.fetch(FetchDescriptor<ChatConversation>(sortBy: [SortDescriptor(\.updated, order: .reverse)]))) ?? []
    }

    /// Stores the conversation on screen (created at its first message).
    func saveConversation() {
        guard let first = transcript.first(where: { if case .user = $0.kind { true } else { false } }), case .user(let question) = first.kind else { return }
        let conversation: ChatConversation
        if let id = conversationID, let existing = try? host.context.fetch(FetchDescriptor<ChatConversation>(predicate: #Predicate { $0.id == id })).first {
            conversation = existing
        } else {
            conversation = ChatConversation(title: String(question.prefix(120)))
            host.context.insert(conversation)
            conversationID = conversation.id
        }
        conversation.entries = transcript
        conversation.sessionID = codeSessionID
        conversation.updated = .now
        try? host.context.save()
    }

    /// Puts a past conversation back on screen; the next message continues it.
    func open(_ conversation: ChatConversation) {
        guard conversation.id != conversationID else { return }
        reset()
        transcript = conversation.entries
        codeSessionID = conversation.sessionID
        conversationID = conversation.id
    }

    func delete(_ conversation: ChatConversation) {
        if conversation.id == conversationID {
            conversationID = nil
            reset()
        }
        host.context.delete(conversation)
        try? host.context.save()
    }

    private struct ToolCall {
        let id: String
        let name: String
        let input: JSONValue
    }

    /// What an approval prompt says about a tool: its first paragraph, kept short (descriptions
    /// can carry long guides meant for Claude).
    nonisolated static func summary(of description: String, limit: Int = 280) -> String {
        let first = description.components(separatedBy: "\n\n").first ?? description
        return first.count > limit ? String(first.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : first
    }

    private func execute(_ call: ToolCall, tools: [DashiiTool]) async -> (String, Bool) {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return ("Unknown tool \(call.name).", true)
        }
        if case .deny(let reason) = await HookEngine.shared.beforeTool(call.name, input: call.input) {
            return (reason, true)
        }
        if tool.requiresApproval, host.settings.confirmWrites {
            let approved = await host.permissions.ask(
                icon: "sparkles", title: "Dashii wants to run \(call.name)", message: Self.summary(of: tool.description),
                details: [.init(title: "Input", text: call.input.jsonString(pretty: true))])
            guard approved else { return ("The user declined this action.", true) }
        }
        do {
            // Secrets in tool output (tokens, keys, passwords) never reach Dashii.
            let result = Sanitizer.clean(try await tool.run(call.input))
            HookEngine.shared.afterTool(call.name, input: call.input, result: result.jsonString())
            return (host.settings.encodeResult(result), false)
        } catch {
            return (Sanitizer.clean(error.localizedDescription), true)
        }
    }

    private func setToolResult(_ id: String, content: String, isError: Bool) {
        guard let index = transcript.lastIndex(where: { $0.toolUseID == id }),
              case .tool(let name, let input, _, _) = transcript[index].kind else { return }
        transcript[index].kind = .tool(name: name, input: input, result: content, isError: isError)
    }

    func notice(_ text: String, isError: Bool) {
        transcript.append(ChatEntry(id: UUID().uuidString, kind: .notice(text, isError: isError)))
    }

    // MARK: Claude Code session

    private func runClaudeCode(_ text: String) async {
        isRunning = true
        defer {
            isRunning = false
            live = []
            task = nil
            saveConversation()
        }
        let previousActivityID = lastActivityID
        let turnStart = transcript.count
        let memory = host.ext(KnowledgeExtension.self)?.memory
        var prompt = "<current-view>\(ViewContext.summary(host: host))</current-view>\n\n\(text)"
        if let known = await memory?.context(for: text + "\n" + ViewContext.summary(host: host)) { prompt = known + "\n" + prompt }
        if let skills = Skills.catalog(in: host.context) { prompt = skills + "\n" + prompt }
        if let digest = ActivityLog.digest(host.activity.events(after: lastActivityID)) {
            prompt = "<dashboard-activity>\n\(digest)\n</dashboard-activity>\n" + prompt
        }
        lastActivityID = host.activity.latestID
        do {
            let session = try claudeCodeSession()
            codeStarted = Date()
            codeLiveID = UUID().uuidString
            try session.send(prompt)
            let result: ResultMessage = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { codeTurn = $0 }
            } onCancel: {
                Task { try? await session.interrupt() }
            }
            transcript += live
            live = []
            // Learn from the exchange in the background (a cheap model, only durable facts).
            if !result.isError, let memory {
                let exchange = Array(transcript[max(0, turnStart - 1)...])
                Task { if await memory.learn(from: exchange) > 0 { self.host.ext(KnowledgeExtension.self)?.bump() } }
            }
            if result.isError, result.subtype != "error_during_execution" {
                notice("Dashii: \(result.result ?? result.subtype)", isError: true)
            } else if result.subtype == "error_during_execution" {
                notice("Stopped.", isError: false)
            }
        } catch {
            lastActivityID = previousActivityID
            transcript += live
            DashLog.error("Claude Code turn failed: \(error.localizedDescription)", category: "claude")
            notice(error.localizedDescription, isError: true)
        }
    }

    /// The running session, (re)started when the set of available tools changes.
    private func claudeCodeSession() throws -> ClaudeCodeSession {
        let tools = self.tools
        let names = tools.map(\.name)
        // The user's rules: global, plus those of every extension whose tools are offered.
        let owners = host.extensions.filter { item in item.tools.contains { names.contains($0.name) } }.map(\.id)
        let rules = AutomationStore.shared.instructions(for: owners)
        if let code, code.isRunning, names == codeToolNames, rules == codeRules { return code }
        code?.endInput()
        let profile = host.ext(HomeExtension.self)?.profilePrompt.map { "\n\n" + $0 } ?? ""
        var options = ClaudeCodeDefaults.options(settings: host.settings, system: host.persona.prompt + profile + "\n\n" + Self.systemPrompt + (host.settings.compactResults ? "\n\n" + CompactFormat.legend : "")
                                                 + (rules.map { "\n\n" + $0 } ?? ""))
        options.noSessionPersistence = false
        options.resume = codeSessionID
        options.includePartialMessages = true
        options.allowedTools = ["mcp__dash"]
        let definitions = tools.map { tool -> ClaudeCodeKit.JSON in
            ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema.claudeCode]
        }
        options.mcpServers = [DashMCPServer(tools: definitions) { [weak self] name, arguments in
            await self?.callDashTool(name, arguments: arguments.dash) ?? MCPToolResult("Dash is closing.", isError: true)
        }]
        let session = try ClaudeCodeSession(options: options)
        code = session
        codeToolNames = names
        codeRules = rules
        Task { await consume(session) }
        return session
    }

    private func consume(_ session: ClaudeCodeSession) async {
        do {
            for try await message in session.messages { handle(message) }
        } catch {
            codeTurn?.resume(throwing: error)
            codeTurn = nil
        }
        if code === session { code = nil }
        codeTurn?.resume(throwing: ToolError("Dashii stopped."))
        codeTurn = nil
    }

    private func handle(_ message: ClaudeCodeKit.Message) {
        if let id = message.sessionID { codeSessionID = id }
        switch message {
        case .streamEvent(let event):
            // Live text while Claude writes; replaced by the full message when it arrives.
            if event["type"]?.string == "content_block_delta", event["delta"]?["type"]?.string == "text_delta",
               let piece = event["delta"]?["text"]?.string {
                if case .text(let current)? = live.last?.kind {
                    live[live.count - 1].kind = .text(current + piece)
                } else {
                    live.append(ChatEntry(id: "\(codeLiveID)-\(live.count)", kind: .text(piece)))
                }
            }
        case .assistant(let reply):
            live = []
            for block in reply.content {
                switch block {
                case .text(let text) where !text.isEmpty:
                    transcript.append(ChatEntry(id: UUID().uuidString, kind: .text(text)))
                case .thinking(let text) where !text.isEmpty:
                    transcript.append(ChatEntry(id: UUID().uuidString, kind: .thinking(text)))
                case .toolUse(let id, let name, let input):
                    let short = name.replacingOccurrences(of: "mcp__dash__", with: "")
                    var early: (String, Bool)?
                    if var queue = earlyResults[short], !queue.isEmpty { early = queue.removeFirst(); earlyResults[short] = queue }
                    transcript.append(ChatEntry(id: UUID().uuidString, kind: .tool(name: short, input: input.dash.jsonString(pretty: true),
                                                                                  result: early?.0, isError: early?.1 ?? false), toolUseID: id))
                default:
                    break
                }
            }
        case .result(let result):
            let usage = result.usage?.dash ?? .null
            trace.append(ClaudeTraceEntry(
                date: codeStarted, model: host.settings.model, stopReason: result.subtype,
                inputTokens: usage["input_tokens"]?.int ?? 0, outputTokens: usage["output_tokens"]?.int ?? 0,
                cacheReadTokens: usage["cache_read_input_tokens"]?.int ?? 0, cacheWriteTokens: usage["cache_creation_input_tokens"]?.int ?? 0,
                toolCalls: [], milliseconds: result.durationMS, error: result.isError ? (result.result ?? result.subtype) : nil))
            DashLog.info("Claude Code turn \(result.subtype) turns=\(result.numTurns) cost=$\(String(format: "%.4f", result.totalCostUSD))", category: "claude")
            // A long-lived session reports its running cost; log only this turn's share.
            ClaudeUsage.shared.record(source: "chat", model: host.settings.model, effort: host.settings.effort, result: result,
                                      costUSD: max(0, result.totalCostUSD - sessionCost))
            sessionCost = max(sessionCost, result.totalCostUSD)
            codeTurn?.resume(returning: result)
            codeTurn = nil
        default:
            break
        }
    }

    /// An MCP tools/call from Claude Code: same approval rules as the API backend.
    private func callDashTool(_ name: String, arguments: JSONValue) async -> MCPToolResult {
        let pending = pendingToolUseID(for: name)
        let call = ToolCall(id: pending ?? UUID().uuidString, name: name, input: arguments)
        let (content, isError) = await execute(call, tools: tools)
        // Claude Code can run the tool before its message naming it arrives: keep the result for
        // that entry, so its spinner stops when it shows up.
        if let id = pendingToolUseID(for: name) ?? pending {
            setToolResult(id, content: content, isError: isError)
        } else {
            earlyResults[name, default: []].append((content, isError))
        }
        return MCPToolResult(content, isError: isError)
    }

    private func pendingToolUseID(for name: String) -> String? {
        transcript.last { entry in
            if case .tool(let toolName, _, nil, _) = entry.kind { return toolName == name }
            return false
        }?.toolUseID
    }
}

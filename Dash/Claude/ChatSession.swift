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
    private(set) var transcript: [ChatEntry] = []
    /// Recent requests with token usage, for the Debug window.
    private(set) var trace: [ClaudeTraceEntry] = []
    private(set) var live: [ChatEntry] = []
    private(set) var isRunning = false
    var isPanelVisible = true
    /// The conversation on screen, saved after every turn.
    private(set) var conversationID: UUID?

    @ObservationIgnored private let host: ExtensionHost
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

    private var tools: [ClaudeTool] { CoreTools.tools(host: host) + ViewContext.tools(host: host) + host.availableTools }

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

        When the user wants a layout suggested, call layout_context, ask a few short questions about their \
        needs unless you know them, then build a draft with suggest_layout and place configured widgets on \
        it (most important top-left). They keep, change or discard it from the draft's banner. Mention \
        Marketplace plugins that would help, but don't install them.

        Dashboard activity since your previous turn (new and reviewed PRs, ticket moves, agent progress, \
        meetings, workspace changes, layout edits) arrives in <dashboard-activity> tags at the start of a \
        user message. Use them to stay \
        current and mention what matters to the question; don't recite them. Call dashboard_activity to look \
        further back.

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

    private func execute(_ call: ToolCall, tools: [ClaudeTool]) async -> (String, Bool) {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return ("Unknown tool \(call.name).", true)
        }
        if case .deny(let reason) = await HookEngine.shared.beforeTool(call.name, input: call.input) {
            return (reason, true)
        }
        if tool.requiresApproval, host.settings.confirmWrites {
            let approved = await host.permissions.ask(
                icon: "sparkles", title: "Claude wants to run \(call.name)", message: Self.summary(of: tool.description),
                details: [.init(title: "Input", text: call.input.jsonString(pretty: true))])
            guard approved else { return ("The user declined this action.", true) }
        }
        do {
            let result = try await tool.run(call.input).jsonString()
            HookEngine.shared.afterTool(call.name, input: call.input, result: result)
            return (result, false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private func setToolResult(_ id: String, content: String, isError: Bool) {
        guard let index = transcript.lastIndex(where: { $0.toolUseID == id }),
              case .tool(let name, let input, _, _) = transcript[index].kind else { return }
        transcript[index].kind = .tool(name: name, input: input, result: content, isError: isError)
    }

    private func notice(_ text: String, isError: Bool) {
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
        var prompt = "<current-view>\(ViewContext.summary(host: host))</current-view>\n\n\(text)"
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
            if result.isError, result.subtype != "error_during_execution" {
                notice("Claude Code: \(result.result ?? result.subtype)", isError: true)
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
        var options = ClaudeCodeDefaults.options(settings: host.settings, system: host.persona.prompt + profile + "\n\n" + Self.systemPrompt
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
        codeTurn?.resume(throwing: ToolError("Claude Code exited."))
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
                    transcript.append(ChatEntry(id: UUID().uuidString, kind: .tool(name: short, input: input.dash.jsonString(pretty: true), result: nil, isError: false), toolUseID: id))
                default:
                    break
                }
            }
        case .result(let result):
            let usage = result.usage?.dash ?? .null
            trace.append(ClaudeTraceEntry(
                date: codeStarted, model: "\(host.settings.model) via Claude Code", stopReason: result.subtype,
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
        let call = ToolCall(id: pendingToolUseID(for: name) ?? UUID().uuidString, name: name, input: arguments)
        let (content, isError) = await execute(call, tools: tools)
        setToolResult(call.id, content: content, isError: isError)
        return MCPToolResult(content, isError: isError)
    }

    private func pendingToolUseID(for name: String) -> String? {
        transcript.last { entry in
            if case .tool(let toolName, _, nil, _) = entry.kind { return toolName == name }
            return false
        }?.toolUseID
    }
}

import ClaudeCodeKit
import DashKit
import Foundation
import Observation
import SwiftData

/// One stored agent run (the database form of `AgentReport`).
@Model
final class AgentRunRecord {
    @Attribute(.unique) var id: UUID
    var agentID: String
    var startedAt: Date
    var finishedAt: Date
    var reason: String
    var status: String
    var summary: String
    var findingsData: Data
    var costUSD: Double

    init(_ report: AgentReport) {
        id = report.id
        agentID = report.agentID
        startedAt = report.startedAt
        finishedAt = report.finishedAt
        reason = report.reason
        status = report.status.rawValue
        summary = report.summary
        findingsData = (try? JSONEncoder().encode(report.findings)) ?? Data("[]".utf8)
        costUSD = report.costUSD
    }

    var report: AgentReport {
        AgentReport(id: id, agentID: agentID, startedAt: startedAt, finishedAt: finishedAt, reason: reason,
                    status: AgentReport.Status(rawValue: status) ?? .failed, summary: summary,
                    findings: (try? JSONDecoder().decode([AgentFinding].self, from: findingsData)) ?? [], costUSD: costUSD)
    }
}

/// Runs the agents extensions declare: on their schedule, when one of their events happens,
/// or on demand. Each run is Claude Code with only the agent's tools, ending in a structured
/// report that is stored, shown in widgets, and announced when it finds something.
@MainActor
@Observable
final class AgentHub {
    static let shared = AgentHub()

    /// Agents running now ("<extension>.<agent>").
    private(set) var running: Set<String> = []
    /// Bumped when a report is stored.
    private(set) var revision = 0

    @ObservationIgnored private weak var host: ExtensionHost?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var lastEventRun: [String: Date] = [:]
    @ObservationIgnored private let defaults = DashDefaults.shared
    /// Keep this many reports per agent.
    static let keep = 200

    @MainActor
    struct Entry: Identifiable {
        let owner: any DashExtension
        let agent: AgentDefinition
        let id: String

        init(owner: any DashExtension, agent: AgentDefinition) {
            self.owner = owner
            self.agent = agent
            id = "\(owner.id).\(agent.id)"
        }
    }

    func start(host: ExtensionHost) {
        self.host = host
        host.activity.onEmit { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.runDue()
            }
        }
    }

    /// The agents of enabled extensions.
    var entries: [Entry] {
        guard let host else { return [] }
        return host.extensions.filter { host.isEnabled($0) }.flatMap { owner in owner.agents.map { Entry(owner: owner, agent: $0) } }
    }

    /// An agent by its id ("acme-board.triage"), else by its name when only one agent has it
    /// ("PR nudger": custom agents' ids are UUIDs nobody types).
    func entry(_ id: String) -> Entry? {
        let all = entries
        if let exact = all.first(where: { $0.id == id }) { return exact }
        let named = all.filter { $0.agent.name.caseInsensitiveCompare(id) == .orderedSame }
        return named.count == 1 ? named[0] : nil
    }

    /// The agents Dashii can ask (scheduled or not), one line each, for its prompt; nil when there are none.
    var catalog: String? {
        let experts = entries
        guard !experts.isEmpty else { return nil }
        return "<agents>\nExperts you can hand a question to (`agent <id> ask \"…\"` in dash, or dash_agent_ask); they answer with evidence:\n"
            + experts.map { entry in
                let role = entry.agent.role.isEmpty ? "" : " (\(entry.agent.role))"
                let specialities = entry.agent.specialities.isEmpty ? "" : ": " + entry.agent.specialities.joined(separator: ", ")
                return "- \(entry.id) — \(entry.agent.name)\(role)\(specialities). \(entry.agent.summary)"
            }.joined(separator: "\n") + "\n</agents>"
    }

    func settings(_ entry: Entry) -> AISettings {
        host?.aiSettings(.extension(entry.owner.id), tasks: [entry.agent.task]) ?? AISettings(tasks: [entry.agent.task])
    }

    func isEnabled(_ entry: Entry) -> Bool { settings(entry).isEnabled(entry.agent.task.id) }

    func setEnabled(_ entry: Entry, _ enabled: Bool) {
        var choice = settings(entry).choices[entry.agent.task.id] ?? AITaskChoice()
        choice.enabled = enabled
        host?.setAIChoice(choice, task: entry.agent.task.id, scope: .extension(entry.owner.id))
    }

    /// Minutes between scheduled runs: the user's choice, else the agent's (nil: not scheduled).
    func interval(_ entry: Entry) -> Int? {
        let saved = defaults.integer(forKey: "dash.agents.\(entry.id).every")
        return saved > 0 ? saved : entry.agent.schedule.everyMinutes
    }

    func setInterval(_ entry: Entry, _ minutes: Int) {
        defaults.set(minutes, forKey: "dash.agents.\(entry.id).every")
    }

    // MARK: Triggers

    private func runDue(now: Date = .now) async {
        for entry in entries where isEnabled(entry) && !running.contains(entry.id) {
            guard let minutes = interval(entry) else { continue }
            let last = reports(entry.id, limit: 1).first?.startedAt ?? .distantPast
            if now.timeIntervalSince(last) >= Double(minutes) * 60 {
                _ = try? await run(entry.id, reason: "schedule")
            }
        }
    }

    private func handle(_ event: ActivityEvent) {
        // Its own reports never start another run.
        guard event.source != "agents" else { return }
        for entry in entries where isEnabled(entry) && entry.agent.schedule.events.contains(event.kind) && !running.contains(entry.id) {
            // At most one event-started run per agent every two minutes.
            if Date.now.timeIntervalSince(lastEventRun[entry.id] ?? .distantPast) < 120 { continue }
            lastEventRun[entry.id] = .now
            Task { _ = try? await run(entry.id, reason: event.kind + (event.title.isEmpty ? "" : ": " + event.title)) }
        }
    }

    // MARK: Running

    /// Runs an agent now and stores its report. With a `question` (Dashii delegating to it), the
    /// precheck can't skip the run: what it saw becomes context, and the report answers the question.
    func run(_ name: String, reason: String, question: String? = nil) async throws -> AgentReport {
        guard let host, let entry = entry(name) else { throw ToolError("No agent \(name) (is its extension enabled?).") }
        let id = entry.id
        guard !running.contains(id) else { throw ToolError("\(entry.agent.name) is already running.") }
        running.insert(id)
        defer { running.remove(id) }
        let started = Date()
        var context = ""
        if let precheck = entry.agent.precheck {
            switch await precheck(host) {
            case .skip(let note):
                guard question != nil else {
                    return store(AgentReport(agentID: id, startedAt: started, reason: reason, status: .skipped, summary: note))
                }
                context = note
            case .run(let seen):
                context = seen
            @unknown default:
                break
            }
        }
        let report: AgentReport
        do {
            do {
                report = try await claude(entry, reason: reason, question: question, context: context, started: started)
            } catch is ToolsNotConnected {
                // Once more: a run without its tools would report on nothing.
                DashLog.error("\(entry.id): Dash's tools didn't connect; retrying", category: "agents")
                report = try await claude(entry, reason: reason, question: question, context: context, started: started)
            }
        } catch is ToolsNotConnected {
            report = AgentReport(agentID: id, startedAt: started, reason: reason, status: .failed,
                                 summary: "Dash's tools didn't connect to the agent twice in a row, so it didn't run. Try again in a moment.")
        } catch {
            report = AgentReport(agentID: id, startedAt: started, reason: reason, status: .failed, summary: error.localizedDescription)
        }
        return store(report)
    }

    private func claude(_ entry: Entry, reason: String, question: String?, context: String, started: Date) async throws -> AgentReport {
        guard let host else { throw ToolError("Dash is closing.") }
        let tools = Self.tools(for: entry.agent, in: host)
        let settings = settings(entry)
        let rules = AutomationStore.shared.instructions(for: [entry.owner.id])
        var options = ClaudeCodeDefaults.options(settings: host.settings, system: """
            \(entry.agent.systemPrompt)

            You run unattended as a Dash agent ("\(entry.agent.name)"). Use your tools to check, then answer with the report: \
            a short summary and one finding per real problem (info only for things worth knowing). No findings when all is well.
            """ + (host.settings.compactResults ? "\n\n" + CompactFormat.legend : "") + (rules.map { "\n\n" + $0 } ?? ""))
        options.model = settings.model(entry.agent.task.id).rawValue
        options.effort = settings.effort(entry.agent.task.id)?.rawValue
        options.maxTurns = 30
        options.jsonSchema = AgentReport.outputSchema.claudeCode
        options.allowedTools = ["mcp__dash"]
        let definitions = tools.map { tool -> ClaudeCodeKit.JSON in
            ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema.claudeCode]
        }
        let agentName = entry.agent.name
        options.mcpServers = [DashMCPServer(tools: definitions) { [weak self] name, arguments in
            await self?.call(name, arguments: arguments.dash, tools: tools, agent: agentName) ?? MCPToolResult("Dash is closing.", isError: true)
        }]
        var prompt = "Run now. Reason: \(reason). Time: \(Date.now.formatted(date: .abbreviated, time: .shortened))."
        if !context.isEmpty { prompt += "\n\nWhat the precheck saw:\n\(context)" }
        if let question {
            prompt += "\n\nDashii (the user's assistant) asks you, on the user's behalf:\n\(question)\n\n"
                + "Answer it in the report's summary, plainly and with the evidence; findings are the problems you found while answering."
        }
        let runStarted = Date.now
        for try await message in query(prompt, options: options) {
            // Without Dash's tools the agent has nothing to check: stop rather than report on nothing.
            if case .system(let system) = message, system.subtype == "init", let status = system.mcpServers["dash"], status != "connected" {
                DashiiHealth.shared.record(source: "agent.\(entry.id)", toolsConnected: false, ok: false, error: "Dash's tools didn't connect.", started: runStarted)
                throw ToolsNotConnected()
            }
            guard case .result(let result) = message else { continue }
            DashiiHealth.shared.record(source: "agent.\(entry.id)", toolsConnected: true, ok: !result.isError,
                                       error: result.isError ? (result.result ?? result.subtype) : nil, started: runStarted)
            ClaudeUsage.shared.record(source: "agent.\(entry.id)", model: options.model ?? host.settings.model, effort: options.effort, result: result)
            if result.isError { throw ToolError("Dashii: \(result.result ?? result.subtype)") }
            let text = result.structuredOutput?.line ?? result.result ?? ""
            return try AgentReport.parse(text, agentID: entry.id, startedAt: started, reason: reason, costUSD: result.totalCostUSD)
        }
        throw ToolError("Dashii ended without a report.")
    }

    /// The tools an agent may use: the ones it names and those of its integrations, minus the
    /// ones that change things when it's read-only, and never one that writes remotely or calls a service.
    static func tools(for agent: AgentDefinition, in host: ExtensionHost) -> [DashiiTool] {
        // DashQL is read-only, so every agent can query; `dash` reaches the same tools, no more.
        // Skills are guidance, so every agent may read and load them (not save or delete).
        let skills = Skills.tools(host: host).filter { ["skills_list", "skill_use"].contains($0.name) }
        // Functions are reads with a smaller model; a run gets a few. Fetching asks integrations
        // to refresh the database, which is all an agent ever reads.
        let allowed = DashQL.tools(host: host) + skills + FunctionTools.tools(host: host, limit: 6) + FetchTools.tools(host: host, caller: "agent \(agent.name)") + host.extensions.filter { host.isEnabled($0) }.flatMap { owner in
            owner.tools.filter { $0.isForDashii && agent.allows(tool: $0.name, from: owner.id, requiresApproval: $0.requiresApproval) }
        }
        let dash = DashiiTool(
            name: "dash",
            description: "Read Dash's data and use your tools with DashQL statements (one per line). `help` lists your tools, `schema` the datasets.\n\n" + DashQL.guide + DashQL.verbsGuide(host: host, tools: allowed),
            properties: ["script": JSONSchema.string("One or more statements, one per line."),
                         "plan": JSONSchema.boolean("Only translate: return the actions (tool calls) each statement becomes, without running them.")],
            required: ["script"]
        ) { input in
            guard let script = input["script"]?.string else { throw ToolError("Give a script.") }
            // Tools that change things ask the user, as when the agent calls them directly.
            var runner = DashScript(host: host, tools: allowed) { tool, input in
                guard tool.requiresApproval else { return nil }
                let approved = await host.permissions.ask(icon: "hammer", title: "\(agent.name) wants to run \(tool.name)",
                                                          message: ChatSession.summary(of: tool.description), input: input,
                                                          remember: PermissionCenter.rememberKey("agent.\(agent.id)", tool: tool))
                return approved ? nil : "The user declined this action."
            }
            runner.plan = input["plan"]?.bool ?? false
            return await runner.run(script)
        }
        return [dash] + allowed
    }

    /// An agent's tool call: hooks may deny it, tools that change things ask the user first.
    private func call(_ name: String, arguments: JSONValue, tools: [DashiiTool], agent: String) async -> MCPToolResult {
        guard let host, let tool = tools.first(where: { $0.name == name }) else { return MCPToolResult("Unknown tool \(name).", isError: true) }
        if case .deny(let reason) = await HookEngine.shared.beforeTool(name, input: arguments) { return MCPToolResult(reason, isError: true) }
        if tool.requiresApproval {
            let approved = await host.permissions.ask(
                icon: "person.badge.shield.checkmark", title: "\(agent) wants to run \(name)", message: ChatSession.summary(of: tool.description),
                input: arguments, remember: PermissionCenter.rememberKey("agent.\(agent)", tool: tool))
            guard approved else { return MCPToolResult("The user declined this action.", isError: true) }
        }
        do {
            let result = Sanitizer.clean(try await tool.run(arguments))
            HookEngine.shared.afterTool(name, input: arguments, result: result.jsonString())
            return MCPToolResult(ResultBudget.fit(host.settings.encodeResult(result)))
        } catch {
            return MCPToolResult(Sanitizer.clean(error.localizedDescription), isError: true)
        }
    }

    // MARK: Reports

    @discardableResult
    func store(_ report: AgentReport) -> AgentReport {
        guard let host else { return report }
        let context = host.context
        context.insert(AgentRunRecord(report))
        // Older reports beyond `keep` go.
        let id = report.agentID
        let all = FetchDescriptor<AgentRunRecord>(predicate: #Predicate { $0.agentID == id }, sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        for record in ((try? context.fetch(all)) ?? []).dropFirst(Self.keep) { context.delete(record) }
        try? context.save()
        revision += 1
        let name = entry(id)?.agent.name ?? id
        switch report.status {
        case .findings where (report.severity ?? .info) >= .warning:
            let worst = report.findings.max { $0.severity < $1.severity }
            host.activity.emit("agent.finding", source: "agents", title: "\(name): \(worst?.title ?? report.summary)",
                               detail: report.summary, importance: report.severity == .critical ? .critical : .notable)
        case .failed:
            host.activity.emit("agent.run_failed", source: "agents", title: "\(name) failed", detail: report.summary, importance: .notable)
        default:
            host.activity.emit("agent.run", source: "agents", title: "\(name): \(report.summary)", importance: .info)
        }
        return report
    }

    func reports(_ id: String, limit: Int) -> [AgentReport] {
        guard let host else { return [] }
        _ = revision
        var descriptor = FetchDescriptor<AgentRunRecord>(predicate: #Predicate { $0.agentID == id }, sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? host.context.fetch(descriptor)) ?? []).map(\.report)
    }
}

/// An agent run whose Dash tools (the in-process MCP server) didn't connect.
struct ToolsNotConnected: Error {}

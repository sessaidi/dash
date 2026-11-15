import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftData
import SwiftUI

/// An agent the user made: a role, specialities, the integrations it may use and how far, a
/// scope, instructions and a schedule. Runs exactly like the agents plugins declare.
@Model
final class CustomAgent {
    @Attribute(.unique) var id: UUID
    var name: String
    var role: String
    var specialities: [String]
    var systemImage: String
    var instructions: String
    /// Extension ids whose tools it may use, plus single tools by name.
    var integrations: [String]
    var tools: [String]
    var canAct: Bool
    var scope: String
    /// 0: only on demand or on events.
    var everyMinutes: Int
    var events: [String]
    var model: String
    var createdAt: Date

    init(name: String = "New agent") {
        id = UUID()
        self.name = name
        role = ""
        specialities = []
        systemImage = "person.badge.shield.checkmark"
        instructions = ""
        integrations = []
        tools = []
        canAct = false
        scope = ""
        everyMinutes = 0
        events = []
        model = DashiiModel.balanced.rawValue
        createdAt = .now
    }

    var definition: AgentDefinition {
        AgentDefinition(
            id: id.uuidString, name: name, summary: role.isEmpty ? "Custom agent" : role, systemImage: systemImage,
            role: role, specialities: specialities, instructions: instructions, tools: tools, integrations: integrations,
            access: canAct ? .actWithApproval : .readOnly, scope: scope,
            schedule: AgentSchedule(everyMinutes: everyMinutes > 0 ? everyMinutes : nil, events: events),
            defaultModel: DashiiModel(rawValue: model) ?? .balanced, enabledByDefault: true)
    }

    /// Starting points for the editor.
    static let templates: [(name: String, role: String, specialities: [String], icon: String, instructions: String, integrations: [String], every: Int)] = [
        ("Cluster SRE", "Site reliability engineer", ["Kubernetes", "incident response"], "server.rack",
         "Check the pods and deployments. Report crash loops, frequent restarts, pending or failing pods and degraded deployments, with the evidence (status, restarts, recent events) and the likely cause.",
         ["kubernetes"], 15),
        ("Review shepherd", "Code review lead", ["code review", "risk assessment"], "arrow.triangle.pull",
         "Look at the open pull requests. Report PRs waiting long for review, high-risk reviews nobody acted on, and my PRs with requested changes.",
         ["pull-requests"], 60),
        ("Sprint watcher", "Delivery manager", ["Jira", "planning"], "checklist",
         "Look at the followed boards and tickets. Report urgent tickets not started, tickets stuck in the same status for days, and work at risk for the sprint.",
         ["jira-board"], 120),
        ("Container doctor", "Platform engineer", ["Docker"], "shippingbox",
         "Check the local containers. Report exited or unhealthy containers with the last log lines that explain why.",
         ["docker"], 30),
    ]
}

/// Dash's own extension for custom agents: makes them runnable, gives Dashii tools to list and
/// run any agent and read reports, and offers the Agents widget.
@MainActor
@Observable
final class AgentsStudio: DashExtension {
    let id = "agents-studio"
    let name = "Agents"
    let systemImage = "person.2.badge.gearshape"
    let metadata = ExtensionMetadata(version: "1.0.0", summary: "Background agents with a role and a scope: yours and the ones plugins offer.",
                                     category: .ai, homepage: "https://github.com/sessaidi/dash")

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?

    var models: [any PersistentModel.Type] { [CustomAgent.self, AgentRunRecord.self] }

    func start(host: any ExtensionContext) { self.host = host }

    func settingsView() -> AnyView { AnyView(AgentsSettings()) }

    var custom: [CustomAgent] {
        (try? host?.context.fetch(FetchDescriptor<CustomAgent>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    var agents: [AgentDefinition] { custom.map(\.definition) }

    /// Each agent's model and effort live in this extension's AI tab.
    var aiTasks: [AITask] { agents.map(\.task) }

    var widgets: [WidgetType] { [WidgetType(AgentsWidget.self)] }

    var activitySeries: [ActivitySeries] {
        [ActivitySeries(id: "runs", title: "Agent runs", unit: "runs", systemImage: "person.2.badge.gearshape") { [weak self] interval in
            let (start, end) = (interval.start, interval.end)
            let runs = (try? self?.host?.context.fetch(FetchDescriptor<AgentRunRecord>(predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end }))) ?? []
            return ActivitySeries.countPerDay(runs.map(\.startedAt), in: interval)
        }]
    }

    var events: [EventDefinition] {
        [EventDefinition("agent.finding", "An agent reported a warning or critical finding."),
         EventDefinition("agent.run", "An agent finished a run with nothing serious."),
         EventDefinition("agent.run_failed", "An agent's run failed.")]
    }

    private struct RunInput: Decodable { let id: String; let reason: String? }
    private struct AskInput: Decodable { let id: String; let question: String }
    private struct ReportsInput: Decodable { let id: String; let limit: Int? }

    var tools: [DashiiTool] {
        [
            DashiiTool(name: "dash_agents", description: "List the background agents (the user's and plugins'): id, name, role, specialities, access, schedule, and their latest report.") { _ in
                let hub = AgentHub.shared
                return .array(hub.entries.map { entry in
                    let last = hub.reports(entry.id, limit: 1).first
                    return [
                        "id": .string(entry.id), "name": .string(entry.agent.name), "role": .string(entry.agent.role),
                        "specialities": .array(entry.agent.specialities.map { .string($0) }), "access": .string(entry.agent.access.rawValue),
                        "scope": .string(entry.agent.scope), "enabled": .bool(hub.isEnabled(entry)),
                        "everyMinutes": hub.interval(entry).map { .number(Double($0)) } ?? .null,
                        "last": last.map { ["status": .string($0.status.rawValue), "summary": .string($0.summary),
                                            "at": .string($0.startedAt.formatted(.iso8601))] } ?? .null,
                    ]
                })
            },
            DashiiTool(name: "dash_agent_run", description: "Run a background agent now and return its report (summary and findings).",
                       properties: ["id": JSONSchema.string("Agent id from dash_agents."), "reason": JSONSchema.string("Why it runs now.")],
                       required: ["id"]) { input in
                let request = try input.toolInput(RunInput.self)
                let report = try await AgentHub.shared.run(request.id, reason: request.reason ?? "asked in chat")
                return try JSONValue.parse(String(decoding: JSONEncoder().encode(report), as: UTF8.self))
            },
            DashiiTool(name: "dash_agent_ask", description: "Hand a question to an expert agent (an on-call SRE, a release manager…; see dash_agents) and get its answer: the report's summary answers it, findings list problems with evidence. Use it for questions in the agent's speciality instead of investigating yourself.",
                       properties: ["id": JSONSchema.string("Agent id from dash_agents."), "question": JSONSchema.string("The question, with what you already know.")],
                       required: ["id", "question"]) { input in
                let request = try input.toolInput(AskInput.self)
                let report = try await AgentHub.shared.run(request.id, reason: "asked by Dashii", question: request.question)
                return try JSONValue.parse(String(decoding: JSONEncoder().encode(report), as: UTF8.self))
            },
            DashiiTool(name: "dash_agent_reports", description: "An agent's latest reports, newest first.",
                       properties: ["id": JSONSchema.string("Agent id."), "limit": JSONSchema.integer("How many (default 5).")],
                       required: ["id"]) { input in
                let request = try input.toolInput(ReportsInput.self)
                let reports = AgentHub.shared.reports(request.id, limit: min(request.limit ?? 5, 30))
                return try JSONValue.parse(String(decoding: JSONEncoder().encode(reports), as: UTF8.self))
            },
        ]
    }
}

// MARK: Widget

struct AgentsWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// One agent's id, or empty for all.
        var agent: String
    }

    static let kind = "dash.agents"
    static let displayName = "Background Agents"
    static let summary = "Your background agents: their status, latest findings, and a Run button."
    static let systemImage = "person.2.badge.gearshape"
    static let defaultSize = WidgetSize.medium
    static let sizeLimits = GridLimits(minW: 3, minH: 3, maxW: 12, maxH: 16)
    static let defaultConfig = Config(agent: "")
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["agent": ["type": "string", "description": "Agent id (\"<extension>.<agent>\"), or empty for all."]],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        AgentsWidgetView(only: config.wrappedValue.agent)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Picker("Agent", selection: config.agent) {
            Text("All agents").tag("")
            ForEach(AgentHub.shared.entries, id: \.id) { Text($0.agent.name).tag($0.id) }
        }
    }

    static func preview(config: Config) -> some View {
        AgentRowsView(rows: [
            .init(id: "a", name: "Cluster SRE", icon: "server.rack", running: false,
                  report: AgentReport(agentID: "a", startedAt: .now.addingTimeInterval(-300), reason: "schedule", status: .findings,
                                      summary: "2 pods restarting in prod.",
                                      findings: [AgentFinding(severity: .critical, title: "api-7f9 in CrashLoopBackOff", target: "prod/api")])),
            .init(id: "b", name: "Review shepherd", icon: "arrow.triangle.pull", running: true,
                  report: AgentReport(agentID: "b", startedAt: .now.addingTimeInterval(-3600), reason: "schedule", status: .ok,
                                      summary: "No PR waiting more than a day.")),
        ], onRun: nil)
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        let hub = AgentHub.shared
        return .array(hub.entries.filter { config.agent.isEmpty || $0.id == config.agent }.map { entry in
            ["id": .string(entry.id), "name": .string(entry.agent.name),
             "last": .string(hub.reports(entry.id, limit: 1).first?.summary ?? "never ran")]
        })
    }
}

private struct AgentsWidgetView: View {
    let only: String
    @State private var hub = AgentHub.shared

    var body: some View {
        let rows = hub.entries.filter { only.isEmpty || $0.id == only }.map { entry in
            AgentRowsView.Row(id: entry.id, name: entry.agent.name, icon: entry.agent.systemImage, running: hub.running.contains(entry.id),
                              report: hub.reports(entry.id, limit: 1).first)
        }
        if rows.isEmpty {
            ContentUnavailableView("No agents", systemImage: "person.2.badge.gearshape",
                                   description: Text("Create one in Settings › Automation › Agents."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AgentRowsView(rows: rows) { id in Task { _ = try? await hub.run(id, reason: "manual") } }
        }
    }
}

struct AgentRowsView: View {
    struct Row: Identifiable {
        let id: String
        let name: String
        let icon: String
        let running: Bool
        let report: AgentReport?
    }

    let rows: [Row]
    let onRun: ((String) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: row.icon).foregroundStyle(.tint).frame(width: 18)
                            Text(row.name).font(.headline)
                            Circle().fill(Self.color(row.report)).frame(width: 8, height: 8)
                            Spacer()
                            if row.running {
                                ProgressView().controlSize(.small)
                            } else if let onRun {
                                Button("Run", systemImage: "play.fill") { onRun(row.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                        if let report = row.report {
                            Text(report.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            ForEach(report.findings.filter { $0.severity >= .warning }.prefix(3)) { finding in
                                Label(finding.title, systemImage: finding.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(finding.severity == .critical ? .red : .orange).lineLimit(1)
                            }
                            Text(report.startedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            Text("Never ran.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func color(_ report: AgentReport?) -> Color {
        guard let report else { return .gray }
        switch report.status {
        case .failed: return .red
        case .skipped, .ok: return .green
        case .findings: return report.severity == .critical ? .red : report.severity == .warning ? .orange : .green
        @unknown default: return .gray
        }
    }
}

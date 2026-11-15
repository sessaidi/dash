import DashKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Dash

/// A plugin-like extension with one tool that reads and one that changes things, and an agent.
@MainActor
private final class WatchExtension: DashExtension {
    let id = "watch"
    let name = "Watch"
    let systemImage = "eye"
    var healthy = true
    func settingsView() -> AnyView { AnyView(EmptyView()) }
    func start(host: any ExtensionContext) {}
    var tools: [ClaudeTool] {
        [ClaudeTool(name: "watch_status", description: "Status.") { _ in "ok" },
         ClaudeTool(name: "watch_restart", description: "Restart.", requiresApproval: true) { _ in "done" },
         ClaudeTool(name: "watch_comment", description: "Comment remotely.", writesRemotely: true) { _ in "posted" }]
    }
    var agents: [AgentDefinition] {
        [AgentDefinition(id: "sre", name: "Watch SRE", summary: "Watches.", role: "SRE", specialities: ["Kubernetes"],
                         instructions: "Check the status.", integrations: ["watch"], scope: "only prod",
                         schedule: AgentSchedule(everyMinutes: 10), enabledByDefault: true,
                         precheck: { [weak self] _ in self?.healthy == false ? .run(context: "unhealthy") : .skip("All healthy.") })]
    }
}

@MainActor
struct AgentsTests {
    @Test func definitionPromptAndAccess() {
        let agent = AgentDefinition(id: "a", name: "Ops", summary: "", role: "SRE", specialities: ["Kubernetes", "Postgres"],
                                    instructions: "Check pods.", tools: ["k8s_get"], integrations: ["docker"], scope: "prod only")
        #expect(agent.systemPrompt.contains("You are Ops, a SRE. Your specialities: Kubernetes, Postgres."))
        #expect(agent.systemPrompt.contains("prod only") && agent.systemPrompt.contains("read-only"))
        #expect(agent.allows(tool: "k8s_get", from: "kubernetes", requiresApproval: false))
        #expect(agent.allows(tool: "docker_logs", from: "docker", requiresApproval: false))
        #expect(!agent.allows(tool: "docker_container_action", from: "docker", requiresApproval: true))
        #expect(!agent.allows(tool: "gcp_api_get", from: "gcp", requiresApproval: false))
        let acting = AgentDefinition(id: "b", name: "Fixer", summary: "", instructions: "x", integrations: ["docker"], access: .actWithApproval)
        #expect(acting.allows(tool: "docker_container_action", from: "docker", requiresApproval: true))
    }

    @Test func hubRunsPrechecksStoresReportsAndAnnouncesFindings() async throws {
        let watch = WatchExtension()
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "agents-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions() + [watch], inMemory: true)
        host.start()
        let hub = AgentHub()
        hub.start(host: host)
        let entry = try #require(hub.entry("watch.sre"))
        // AI choices live in the standard defaults: start from the agent's own default.
        host.clearAIChoices(.extension("watch"))
        defer { host.clearAIChoices(.extension("watch")) }
        #expect(hub.isEnabled(entry) && hub.interval(entry) == 10)
        #expect(AgentHub.tools(for: entry.agent, in: host).map(\.name) == ["dash", "dashql", "dashql_schema", "watch_status"])
        // Remote writes never reach Claude, not even an acting agent or the chat.
        let acting = AgentDefinition(id: "fix", name: "Fixer", summary: "", instructions: "x", integrations: ["watch"], access: .actWithApproval)
        #expect(AgentHub.tools(for: acting, in: host).map(\.name) == ["dash", "dashql", "dashql_schema", "watch_status", "watch_restart"])
        #expect(!host.availableTools.contains { $0.name == "watch_comment" })
        #expect(watch.tools.last?.requiresApproval == true)

        let skipped = try await hub.run("watch.sre", reason: "manual")
        #expect(skipped.status == .skipped && skipped.summary == "All healthy.")
        #expect(hub.reports("watch.sre", limit: 5).map(\.id) == [skipped.id])

        hub.store(AgentReport(agentID: "watch.sre", startedAt: .now, reason: "schedule", status: .findings, summary: "One pod down.",
                              findings: [AgentFinding(severity: .critical, title: "api crash loop", target: "prod/api")]))
        let finding = try #require(host.activity.events.last)
        #expect(finding.kind == "agent.finding" && finding.importance == .critical && finding.title == "Watch SRE: api crash loop")
        #expect(hub.reports("watch.sre", limit: 5).first?.findings.first?.target == "prod/api")

        hub.setEnabled(entry, false)
        #expect(!hub.isEnabled(entry))
    }

    @Test func customAgentsBecomeDefinitions() throws {
        let agent = CustomAgent(name: "Cluster SRE")
        agent.role = "Site reliability engineer"
        agent.integrations = ["kubernetes"]
        agent.everyMinutes = 15
        agent.events = ["kubernetes.crashloop"]
        agent.canAct = true
        let definition = agent.definition
        #expect(definition.id == agent.id.uuidString && definition.access == .actWithApproval)
        #expect(definition.schedule == AgentSchedule(everyMinutes: 15, events: ["kubernetes.crashloop"]))
        #expect(definition.task.enabledByDefault == true)
        #expect(CustomAgent.templates.map(\.name).contains("Cluster SRE"))
    }

    @Test func reportsParseFromClaudesAnswer() throws {
        let report = try AgentReport.parse(#"{"summary":"2 issues","findings":[{"severity":"warning","title":"slow","detail":"p99 2s","target":"api","suggestion":""},{"severity":"critical","title":"down","detail":"","target":"db","suggestion":"failover"}]}"#,
                                           agentID: "x.y", startedAt: .now, reason: "schedule", costUSD: 0.02)
        #expect(report.status == .findings && report.severity == .critical && report.costUSD == 0.02)
        let quiet = try AgentReport.parse(#"{"summary":"all good","findings":[]}"#, agentID: "x.y", startedAt: .now, reason: "manual")
        #expect(quiet.status == .ok)
    }
}

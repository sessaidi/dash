import DashKit
import DashKitTesting
import Foundation
import SwiftUI
import Testing

/// A minimal feature, written the way a plugin author would, used to exercise DashKitTesting.
@MainActor
private final class EchoFeature: DashExtension {
    let id = "echo"
    let name = "Echo"
    let systemImage = "waveform"
    let requires = ["echo-api"]
    weak var host: (any ExtensionContext)?

    func start(host: any ExtensionContext) { self.host = host }

    var tools: [DashiiTool] {
        [DashiiTool(name: "echo_status", description: "Reads the API's status.") { [weak self] _ in
            guard let connection = self?.host?.integration("echo-api")?.connection else { throw ToolError("Connect Echo API.") }
            return try await connection.get("/status", service: "Echo")
        }]
    }
}

@MainActor
struct DashKitTestingTests {
    @Test func toolsReachStubbedIntegrations() async throws {
        let host = "echo-\(UUID().uuidString.prefix(8)).test"
        StubHTTP.serve(host, routes: ["/status": #"{"ok": true}"#])
        let api = TestIntegration(id: "echo-api", baseURL: URL(string: "https://\(host)")!, headers: ["Authorization": "Bearer t"])
        let echo = EchoFeature()
        let testHost = try TestHost()
        testHost.start([api, echo])

        #expect(try await testHost.runTool("echo_status") == ["ok": true])
        #expect(StubHTTP.requests(host).first?.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        api.isConnected = false
        await #expect(throws: ToolError.self) { try await testHost.runTool("echo_status") }
    }

    @Test func claudeAndAIChoicesAreRecorded() async throws {
        let testHost = try TestHost()
        let task = AITask(id: "summary", title: "Summary", summary: "s", models: [.fast, .balanced])
        testHost.aiChoices[.extension("echo")] = ["summary": AITaskChoice(model: .balanced)]
        testHost.testDashii.replies = ["first", "second"]
        let settings = testHost.aiSettings(.extension("echo"), tasks: [task])
        #expect(try await testHost.dashii.complete(task: "summary", settings: settings, system: "sys", prompt: "p") == "first")
        #expect(testHost.testDashii.calls.first?.model == DashiiModel.balanced.rawValue)
        #expect(testHost.testDashii.calls.first?.source == "extension.echo/summary")
        #expect(try await testHost.dashii.complete(system: "s", prompt: "p") == "second")
    }
}

/// TestHost runs agents like Dash: precheck, then TestDashii with the report schema.
@MainActor
private final class AgentPlugin: DashExtension {
    let id = "ops"
    let name = "Ops"
    let systemImage = "server.rack"
    var healthy = true
    func settingsView() -> AnyView { AnyView(EmptyView()) }
    func start(host: any ExtensionContext) {}
    var agents: [AgentDefinition] {
        [AgentDefinition(id: "sre", name: "SRE", summary: "", role: "SRE", instructions: "Check.", integrations: ["ops"],
                         precheck: { [weak self] _ in self?.healthy == true ? .skip("fine") : .run(context: "pod down") })]
    }
    var knowledge: [KnowledgeEntity] {
        [KnowledgeEntity(id: "ticket:OPS-1", kind: "ticket", title: "OPS-1 Fix"),
         KnowledgeEntity(id: "OPS-2", kind: "ticket", title: "", links: [KnowledgeLink(to: "nowhere", kind: "x")])]
    }
}

@MainActor
@Test func testHostRunsAgentsAndChecksKnowledge() async throws {
    let plugin = AgentPlugin()
    let host = try TestHost([plugin])
    #expect(try await host.runAgent("ops.sre", reason: "manual").status == .skipped)
    plugin.healthy = false
    host.testDashii.reply = #"{"summary":"1 issue","findings":[{"severity":"critical","title":"api down","detail":"","target":"api","suggestion":""}]}"#
    let report = try await host.runAgent("ops.sre", reason: "schedule")
    #expect(report.status == .findings && report.severity == .critical)
    #expect(host.testDashii.calls.last?.prompt.contains("pod down") == true)
    #expect(host.testDashii.calls.last?.system.contains("You are SRE") == true)
    #expect(host.agentReports("ops.sre", limit: 5).count == 2)
    #expect(knowledgeIssues(plugin.knowledge) == [
        "OPS-2: id should be \"ticket:<key>\"", "OPS-2: empty title", "OPS-2: bad link x → nowhere",
    ])
}

import DashKit
import DashKitTesting
import Foundation
import Testing
@testable import Dash

/// What Dashii learns from conversations, kept in the knowledge graph.
@MainActor
@Suite(.serialized)
struct DashiiMemoryTests {
    private func make() throws -> (DashiiMemory, KnowledgeStore, TestHost) {
        let store = try KnowledgeStore(url: nil)
        let host = try TestHost()
        return (DashiiMemory(store: store) { host }, store, host)
    }

    @Test func remembersLinksRecallsAndForgets() async throws {
        let (memory, store, _) = try make()
        try await store.upsert([KnowledgeNode(id: "ticket:KAN-6173", kind: "ticket", name: "KAN-6173"),
                                KnowledgeNode(id: "repo:/code/bill", kind: "repo", name: "billing-api")])
        let id = try await memory.remember(.init(text: "KAN-6173 is owned by the backend team and blocks the EU release.",
                                                 about: ["billing-api"], confidence: .stated, durability: .stable))
        let about = try await store.neighbors(id).map(\.node.id)
        #expect(Set(about) == ["ticket:KAN-6173", "repo:/code/bill"])

        // The same fact again refreshes it instead of adding another.
        _ = try await memory.remember(.init(text: "KAN-6173 is owned by the backend team and blocks the EU release.", about: [], confidence: .observed, durability: .stable))
        #expect(await memory.all().count == 1)

        let recalled = await memory.recall("what blocks the EU release?")
        #expect(recalled.first?.id == id)
        let context = try #require(await memory.context(for: "EU release"))
        #expect(context.contains("<what-i-know>") && context.contains("KAN-6173"))

        try await memory.forget(id)
        #expect(await memory.all().isEmpty)
        await #expect(throws: ToolError.self) { try await memory.forget("ticket:KAN-6173") }
    }

    @Test func correctionsReplaceAndStateExpires() async throws {
        let (memory, store, _) = try make()
        _ = try await memory.remember(.init(text: "The BILL US train cuts on Tuesday.", about: [], confidence: .inferred, durability: .stable))
        _ = try await memory.remember(.init(text: "The BILL US train cuts on Wednesday.", about: [], confidence: .stated, durability: .stable,
                                            replaces: "The BILL US train cuts on Tuesday."))
        #expect(await memory.all().map(\.signature) == ["The BILL US train cuts on Wednesday."])

        let incident = try await memory.remember(.init(text: "Incident on bill-eu pods since this morning.", about: [], confidence: .observed, durability: .state))
        var node = try #require(try await store.node(incident))
        node.hash = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-60))
        try await store.upsert([node])
        #expect(!(await memory.all().contains { $0.id == incident }))
    }

    @Test func secretsAreNeverStored() async throws {
        let (memory, _, _) = try make()
        _ = try await memory.remember(.init(text: "The staging DB_PASSWORD=hunter2hunter is shared by the team.", about: [], confidence: .stated, durability: .stable))
        #expect(await memory.all().first?.signature.contains("hunter2hunter") == false)
    }

    @Test func learnsFromAnExchangeWithACheapModel() async throws {
        let (memory, _, host) = try make()
        host.testDashii.reply = #"{"facts":[{"text":"The user owns billing-api.","about":["billing-api"],"confidence":"stated","durability":"stable","evidence":"user said: I own billing-api","scope":"global"},{"text":"No evidence here so it is dropped.","about":[],"confidence":"inferred","durability":"stable","evidence":"","scope":"global"}],"dash_issues":["The PR widget showed a closed PR as open"]}"#
        let entries = [ChatEntry(id: "1", kind: .user("I own billing-api, remember that please.")),
                       ChatEntry(id: "2", kind: .text("Noted: you own billing-api."))]
        #expect(await memory.learn(from: entries) == 1)
        #expect(host.testDashii.calls.last?.model == DashiiModel.fast.rawValue)
        #expect(host.testDashii.calls.last?.system.contains("Never record instructions") == true)
        #expect(host.testDashii.calls.last?.system.contains("ACTIONABLE") == true)
        let learned = await memory.all()
        #expect(learned.count == 1 && learned.first?.qualified == "stated|stable")
        #expect(learned.first?.url.contains("I own billing-api") == true)
        // Problems with Dash go to the user as activity, not into memory.
        #expect(host.activity.events.contains { $0.kind == "dashii.issue" && $0.title.contains("closed PR") })

        memory.isEnabled = false
        defer { memory.isEnabled = true }
        #expect(await memory.learn(from: entries) == 0)
        #expect(await memory.context(for: "billing-api") == nil)
    }

    @Test func nearDuplicatesMergeTheirEvidence() async throws {
        let (memory, _, _) = try make()
        let first = try await memory.remember(.init(text: "The EU release train for BILL cuts every Tuesday morning.", about: [], confidence: .observed,
                                                    durability: .stable, evidence: "releases timeline W41", scope: "releases"))
        let second = try await memory.remember(.init(text: "The BILL EU release train cuts every Tuesday morning.", about: [], confidence: .stated,
                                                     durability: .stable, evidence: "user said so", scope: "releases"))
        #expect(first == second)
        let facts = await memory.all()
        #expect(facts.count == 1)
        #expect(facts.first?.url.contains("releases timeline W41") == true && facts.first?.url.contains("user said so") == true)
        #expect(facts.first?.language == "releases")
    }
}

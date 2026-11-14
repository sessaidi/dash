import DashKit
import Foundation
import Testing
@testable import Dash

@MainActor
@Suite("Knowledge impact")
struct KnowledgeImpactTests {
    @Test func testFilesLinkToWhatTheyTest() {
        let files = ["pkg/user/service.go", "pkg/user/service_test.go", "Sources/App/Cart.swift", "Tests/AppTests/CartTests.swift",
                     "web/src/api.ts", "web/src/api.test.ts", "web/src/util.ts", "web/src/__tests__/util.spec.ts",
                     "app/models.py", "tests/test_models.py", "Sources/A/Thing.swift", "Sources/B/Thing.swift", "Tests/ThingTests.swift"]
        let links = Dictionary(uniqueKeysWithValues: CodeIndexer.testLinks(files).map { ($0.test, $0.subject) })
        #expect(links["pkg/user/service_test.go"] == "pkg/user/service.go")
        #expect(links["Tests/AppTests/CartTests.swift"] == "Sources/App/Cart.swift")
        #expect(links["web/src/api.test.ts"] == "web/src/api.ts")
        #expect(links["web/src/__tests__/util.spec.ts"] == "web/src/util.ts")
        #expect(links["tests/test_models.py"] == "app/models.py")
        // Two files named Thing.swift: no guess.
        #expect(links["Tests/ThingTests.swift"] == nil)
    }

    @Test func extensionEntitiesNeverReplaceKnowledgesOwnLinks() {
        #expect(KnowledgeExtension.entitySource("git") == "ext:git")
        #expect(KnowledgeExtension.entitySource("claude") == "ext:claude")
        #expect(KnowledgeExtension.entitySource("pull-requests") == "pull-requests")
    }

    /// A small Go repository with history: two authors, a test, a caller.
    func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "dash-impact-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root.appending(path: "billing"), withIntermediateDirectories: true)
        func git(_ arguments: [String], author: String = "Ada <ada@x.io>") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "user.name=\(author.split(separator: "<")[0].trimmingCharacters(in: .whitespaces))",
                                 "-c", "user.email=\(author.split(separator: "<")[1].dropLast())"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        func write(_ path: String, _ text: String) throws { try text.write(to: root.appending(path: path), atomically: true, encoding: .utf8) }
        git(["init", "-q"])
        try write("go.mod", "module example.com/shop\n")
        try write("billing/charge.go", "package billing\n\nfunc Charge(amount int) int {\n\treturn amount\n}\n")
        try write("billing/charge_test.go", "package billing\n\nfunc TestCharge() {\n\tCharge(1)\n}\n")
        try write("billing/invoice.go", "package billing\n\nfunc Invoice() int {\n\treturn Charge(2)\n}\n")
        git(["add", "-A"]); git(["commit", "-qm", "SHOP-1 billing"])
        for round in 0..<3 {
            try write("billing/charge.go", "package billing\n\nfunc Charge(amount int) int {\n\treturn amount + \(round)\n}\n")
            try write("billing/invoice.go", "package billing\n\nfunc Invoice() int {\n\treturn Charge(\(round))\n}\n")
            git(["add", "-A"]); git(["commit", "-qm", "SHOP-2 tweak \(round)"], author: "Grace <grace@x.io>")
        }
        return root
    }

    @Test func impactExpertsContextAndStatus() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let knowledge = KnowledgeExtension(defaults: UserDefaults(suiteName: "ki-\(UUID())")!, url: nil)
        let store = try #require(knowledge.store)
        _ = try await KnowledgeExtension.index(root.path, store: store, history: true)
        func tool(_ name: String) throws -> ClaudeTool { try #require(knowledge.tools.first { $0.name == name }) }

        let found = try await tool("knowledge_search").run(["query": "Charge", "kind": "symbol"])
        let charge = try #require(found.array?.first { $0["name"] == "Charge" }?["id"]?.string)
        let impact = try await tool("knowledge_impact").run(["id": .string(charge)])
        #expect(impact["callers"]?.array?.contains { $0["name"] == "Invoice" } == true)
        #expect(impact["tests"] == ["billing/charge_test.go"])
        #expect(impact["changes_with"]?.array?.first?["file"] == "billing/invoice.go")
        #expect(impact["experts"]?.array?.first?["name"] == "Grace")

        let repoID = "repo:" + root.path
        let experts = try await tool("knowledge_experts").run(["id": .string(repoID)])
        #expect(experts["experts"]?.array?.map { $0["name"]?.string } == ["Grace", "Ada"])

        let context = try await tool("knowledge_context").run(["question": "charge amount"])
        #expect(context["matches"]?.array?.isEmpty == false)

        let status = try await tool("knowledge_status").run([:])
        #expect((status["repositories"]?[0]?["history_links"]?.double ?? 0) > 0 && (status["repositories"]?[0]?["test_links"]?.double ?? 0) == 1)

        // Re-reading an extension called "git" leaves the history links alone.
        try await KnowledgeLinker.ingest([], source: KnowledgeExtension.entitySource("git"), into: store)
        #expect(try await store.edgeCount(kind: "authored", repo: repoID) > 0)
    }
}

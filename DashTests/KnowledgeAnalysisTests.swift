import DashKit
import Foundation
import Testing
@testable import Dash

/// The knowledge graph's analyses: call confidence, stale edges, modules, cycles, flows,
/// configuration, decisions, search fusion, and the tools on top.
@MainActor
@Suite(.serialized)
struct KnowledgeAnalysisTests {
    @Test func clustersSplitTwoCliques() {
        let a = [("a1", "a2", 1.0), ("a2", "a3", 1.0), ("a1", "a3", 1.0)]
        let b = [("b1", "b2", 1.0), ("b2", "b3", 1.0), ("b1", "b3", 1.0)]
        let groups = KnowledgeAnalysis.clusters(a + b + [("a3", "b1", 0.2)])
        #expect(groups["a1"] == groups["a2"] && groups["a2"] == groups["a3"])
        #expect(groups["b1"] == groups["b3"] && groups["a1"] != groups["b1"])
        #expect(KnowledgeAnalysis.name(of: ["api/handlers/a.go", "api/handlers/b.go"]) == "api/handlers")
    }

    @Test func cyclesAndFlows() {
        #expect(KnowledgeAnalysis.cycles([("a", "b"), ("b", "c"), ("c", "a"), ("c", "d")]) == [["a", "b", "c"]])
        let graph = ["main": [("serve", 0.9), ("log", 0.3)], "serve": [("handle", 0.85)], "handle": [("main", 0.6)]]
        #expect(KnowledgeAnalysis.flow(from: "main") { graph[$0] ?? [] } == ["main", "serve", "log", "handle"])
        #expect(KnowledgeAnalysis.isEntryPoint(name: "ServeHTTP", signature: "func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request)", path: "api/h.go"))
        #expect(!KnowledgeAnalysis.isEntryPoint(name: "parse", signature: "func parse(s string) int", path: "lib/p.go"))
    }

    @Test func configurationAndDecisions() {
        #expect(KnowledgeAnalysis.environmentReads(#"url := os.Getenv("DATABASE_URL"); k := process.env.API_KEY; os.environ["REGION"]"#)
                == ["DATABASE_URL", "API_KEY", "REGION"])
        #expect(KnowledgeAnalysis.environmentSets("env:\n  - name: DATABASE_URL\n    value: x\n", path: "deploy/k8s.yaml") == ["DATABASE_URL"])
        #expect(KnowledgeAnalysis.environmentSets("export API_KEY=1\nREGION=eu\n", path: ".env") == ["API_KEY", "REGION"])
        let adr = "# ADR 7: Use Pub/Sub for page updates\n\n## Status\nAccepted\n\nDate: 2026-03-02\n\nThe `app/messaging` subscriber replaces polling in `server.go`."
        #expect(KnowledgeAnalysis.isDecision(path: "docs/adr/0007-pubsub.md", text: adr))
        let record = KnowledgeAnalysis.decision(adr)
        #expect(record.title == "ADR 7: Use Pub/Sub for page updates" && record.status == "Accepted" && record.date == "2026-03-02")
        #expect(record.mentions == ["app/messaging", "server.go"])
    }

    @Test func searchHelpers() {
        #expect(KnowledgeAnalysis.words("PodsFeature.refreshPods") == "pods feature refresh pods")
        #expect(KnowledgeAnalysis.fuse([["a", "b", "c"], ["c", "a"]]).prefix(2) == ["a", "c"])
        #expect(KnowledgeAnalysis.stableHash("x") == KnowledgeAnalysis.stableHash("x") && KnowledgeAnalysis.stableHash("x") != KnowledgeAnalysis.stableHash("y"))
    }

    @Test func callConfidenceTiers() {
        let root = "/r"
        let index = ["Save": ["sym:/r/store/db.go#Save", "sym:/r/cache/c.go#Save"], "local": ["sym:/r/api/h.go#local"], "Unique": ["sym:/r/x/y.go#Unique"]]
        let imports: [String: Set<String>] = ["file:/r/api/h.go": ["dir:/r/store"]]
        let edges = CodeIndexer.resolveCalls(from: "sym:/r/api/h.go#Handle", names: ["Save", "local", "Unique", "Missing"], index: index, imports: imports, root: root)
        let weights = Dictionary(uniqueKeysWithValues: edges.map { ($0.dst, $0.weight) })
        #expect(weights["sym:/r/api/h.go#local"] == 0.95)
        #expect(weights["sym:/r/store/db.go#Save"] == 0.85 && weights["sym:/r/cache/c.go#Save"] == nil)
        #expect(weights["sym:/r/x/y.go#Unique"] == 0.6)
    }

    /// A small Go repository in git, indexed for real.
    func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "dash-analysis-\(UUID().uuidString)")
        let files = [
            "cmd/server/main.go": "package main\n\nimport \"os\"\n\nfunc main() {\n\tport := os.Getenv(\"PORT\")\n\tServe(port)\n}\n",
            "cmd/server/serve.go": "package main\n\nfunc Serve(port string) {\n\tRoute(port)\n}\n\nfunc Route(p string) {\n\tSave(p)\n}\n",
            "cmd/server/store.go": "package main\n\nfunc Save(v string) {\n}\n",
            "deploy/app.yaml": "env:\n  - name: PORT\n    value: \"8080\"\n",
            "docs/adr/0001-go.md": "# ADR 1: Serve with net/http\n\nStatus: Accepted\n\n`cmd/server` uses the standard library.\n",
        ]
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        for arguments in [["init", "-q", "-b", "main"], ["add", "-A"], ["-c", "user.email=t@x.io", "-c", "user.name=T", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "init"]] {
            _ = CodeIndexer.git(root, arguments)
        }
        return root
    }

    @Test func indexingBuildsTheDerivedGraphAndKeepsCallsFresh() async throws {
        let root = try makeRepo()
        let knowledge = KnowledgeExtension(defaults: UserDefaults(suiteName: "analysis-\(UUID())")!, url: nil)
        let store = try #require(knowledge.store)
        knowledge.repositories = [root.path]
        _ = try await KnowledgeExtension.index(root.path, store: store, history: false)
        let repo = "repo:" + root.path

        // Calls with confidence, a flow from main, configuration, a decision.
        let main = "sym:\(root.path)/cmd/server/main.go#main"
        let route = "sym:\(root.path)/cmd/server/serve.go#Route"
        #expect(try await store.callees(main).map(\.0) == ["sym:\(root.path)/cmd/server/serve.go#Serve"])
        let flows = try await store.nodes(kind: "flow", repo: repo, limit: 10)
        #expect(flows.first?.signature == "main → Serve → Route → Save")
        let readers = try await store.neighbors("env:PORT", kinds: ["reads_env", "sets_env"], limit: 10)
        #expect(Set(readers.map(\.edge.kind)) == ["reads_env", "sets_env"])
        #expect(try await store.nodes(kind: "decision", repo: repo, limit: 5).first?.name == "ADR 1: Serve with net/http")
        #expect(!(try await store.nodes(kind: "cluster", repo: repo, limit: 5)).isEmpty)

        // Rename Save in an unchanged caller's target: Route's edge must not point at the old one.
        try "package main\n\nfunc Persist(v string) {\n}\n".write(to: root.appending(path: "cmd/server/store.go"), atomically: true, encoding: .utf8)
        _ = try await KnowledgeExtension.index(root.path, store: store, history: false)
        #expect(try await store.callees(route).isEmpty)
        try "package main\n\nfunc Save(v string) {\n}\n".write(to: root.appending(path: "cmd/server/store.go"), atomically: true, encoding: .utf8)
        _ = try await KnowledgeExtension.index(root.path, store: store, history: false)
        #expect(try await store.callees(route).map(\.0) == ["sym:\(root.path)/cmd/server/store.go#Save"])

        // The tools.
        let tools = Dictionary(uniqueKeysWithValues: knowledge.tools.map { ($0.name, $0) })
        let rows = try await tools["knowledge_query"]!.run(["sql": "SELECT name FROM nodes WHERE kind = 'env' ORDER BY name"])
        #expect(rows.array?.compactMap { $0["name"]?.string } == ["PORT"])
        await #expect(throws: (any Error).self) { try await tools["knowledge_query"]!.run(["sql": "DELETE FROM nodes"]) }
        let config = try await tools["knowledge_config"]!.run(["name": "PORT"])
        #expect(config[0]?["set_in"]?.array?.count == 1)
        let health = try await tools["knowledge_health"]!.run(["repository": .string(root.path)])
        #expect(health["coverage"]?["files"]?.double ?? 0 >= 3)
        let context = try await tools["knowledge_edit_context"]!.run(["id": .string(route), "intent": "modify"])
        #expect(context["source"]?.string?.contains("func Route") == true && context["callers"]?.array?.isEmpty == false)

        // A change to Route's body, against HEAD.
        try "package main\n\nfunc Serve(port string) {\n\tRoute(port)\n}\n\nfunc Route(p string) {\n\tSave(p + \"!\")\n}\n"
            .write(to: root.appending(path: "cmd/server/serve.go"), atomically: true, encoding: .utf8)
        let changes = try await tools["knowledge_changes"]!.run(["repository": .string(root.path)])
        let touched = changes["files"]?[0]?["symbols"]?.array ?? []
        #expect(touched.contains { $0["symbol"] == "Route" && $0["change"] == "body" })
    }
}

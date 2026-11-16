import DashKit
import Foundation
import Testing
@testable import Dash

/// Writes `files` into a fresh folder (a git repository when `git` is set) and returns it.
func makeFixtureRepo(_ files: [String: String], git: Bool = false) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "dash-extract-\(UUID().uuidString.prefix(8))")
    for (path, text) in files {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    if git {
        for arguments in [["init", "-q", "-b", "main"], ["add", "-A"],
                          ["-c", "user.email=ada@example.com", "-c", "user.name=Ada", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "init"]] {
            _ = CodeIndexer.git(root, arguments)
        }
    }
    return root
}

/// An `ExtractionInput` for one file of a fixture folder, parsed like the indexer does.
func extractionInput(_ root: URL, _ path: String, files: [String]? = nil) throws -> ExtractionInput {
    let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
    let language = try #require(CodeParser.language(of: path))
    let parsed = CodeParser.parse(text, language: language)
    let ids = parsed.symbols.map { "sym:\(root.path)/\(path)#" + ($0.container.isEmpty ? $0.name : "\($0.container).\($0.name)") }
    let all = try files ?? CodeIndexer(root: root, store: KnowledgeStore(url: nil)).listFiles()
    return ExtractionInput(root: root.path, path: path, language: language, text: text, parsed: parsed, symbolIDs: ids, files: all,
                           context: ExtractionContext(root: root, files: all, goModule: CodeIndexer.goModule(root)))
}

/// A stand-in extractor: `// route <name> <handler>` comments in Go files become shared `fake` nodes.
private struct RouteComments: CodeExtractor {
    let name = "route-comments"
    var sharedKinds: [String] { ["fake"] }
    func accepts(path: String, language: String) -> Bool { language == "go" }
    func extract(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        for match in SourceScan.matches(#"// route (\w+) (\w+)"#, in: file.text) {
            let id = "fake:" + match[1]
            result.nodes.append(KnowledgeNode(id: id, kind: "fake", name: match[1], source: "code"))
            result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
            result.refs.append(KnowledgeRef(src: id, kind: "handled_by", names: [match[2]]))
        }
        return result
    }
}

@MainActor
@Suite("Knowledge extraction")
struct KnowledgeExtractionTests {
    // MARK: Framework

    @Test func extractedEdgesAndRefsFollowTheirFile() async throws {
        let root = try makeFixtureRepo([
            "api/routes.go": "package api\n\nfunc Register() {\n\t// route users ListUsers\n}\n",
            "api/users.go": "package api\n\nfunc ListUsers() {}\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        var indexer = CodeIndexer(root: root, store: store)
        indexer.readHistory = false
        indexer.extractors = [RouteComments()]
        let report = try await indexer.index()
        #expect(report.parsed == 2)

        let routes = indexer.fileID("api/routes.go")
        let around = try await store.neighbors("fake:users")
        #expect(around.contains { $0.edge.kind == "defined_in" && $0.node.id == routes && $0.edge.source == routes })
        let handler = try #require(around.first { $0.edge.kind == "handled_by" })
        #expect(handler.node.id == "sym:\(root.path)/api/users.go#ListUsers" && handler.edge.weight == 0.7 && handler.edge.source == "code-links")

        // The file changes: its old node has nothing left and goes; the new one is linked.
        try "package api\n\nfunc Register() {\n\t// route orders ListUsers\n}\n".write(to: root.appending(path: "api/routes.go"), atomically: true, encoding: .utf8)
        #expect(try await indexer.index().parsed == 1)
        #expect(try await store.node("fake:users") == nil)
        #expect(try await store.neighbors("fake:orders").contains { $0.edge.kind == "handled_by" })

        // The file goes: so do its edges, refs and the node.
        try FileManager.default.removeItem(at: root.appending(path: "api/routes.go"))
        #expect(try await indexer.index().removed == 1)
        #expect(try await store.node("fake:orders") == nil)
        #expect(try await store.refs(repo: indexer.repoID).isEmpty)

        // A repository indexed before this extraction version is parsed again in full, once.
        #expect(try await indexer.index().parsed == 0)
        try await store.run("DELETE FROM meta WHERE key = ?1", [CodeExtractors.version + ":" + indexer.repoID])
        #expect(try await indexer.index().parsed == 1)
        #expect(try await indexer.index().parsed == 0)

        // Removing the repository drops what its files filed, even between shared nodes.
        try await store.removeRepo(indexer.repoID)
        #expect(try await store.query("SELECT COUNT(*) AS n FROM edges", limit: 1).first?["n"]?.double == 0)
    }

    @Test func readsStringsArgumentsAndConstants() throws {
        #expect(SourceScan.literal(#""/users/:id""#) == "/users/:id")
        #expect(SourceScan.literal("`/users/${id}/orders`") == "/users/{}/orders")
        #expect(SourceScan.literal(#"f"/users/{user_id}""#) == "/users/{user_id}")
        #expect(SourceScan.literal(#""a" + "b""#) == nil)
        #expect(SourceScan.formatCall(#"fmt.Sprintf("/users/%s/plans/%d", id, n)"#) == "/users/{}/plans/{}")
        #expect(SourceScan.withoutLineComment(#"x := "http://a" // note"#) == #"x := "http://a" "#)

        let text = #"r.Get("/a, b", h.Show(x, y), // comment, here"# + "\n" + #"  mw)"#
        let units = Array(text.utf16)
        let open = (text as NSString).range(of: "(").location
        let arguments = try #require(SourceScan.arguments(units, at: open, limit: 1000))
        #expect(arguments.ranges.map { (text as NSString).substring(with: $0) } == [#""/a, b""#, "h.Show(x, y)", "mw"])
        #expect(arguments.end == units.count)

        let constants = SourceScan.goConstants("""
            package api

            const Prefix = "/billing" // the mount

            const (
                Version = Prefix + "/v1"
                count = 3
            )

            func f() {
                local := "/nope"
            }
            """)
        #expect(constants == ["Prefix": #""/billing""#, "Version": #"Prefix + "/v1""#])
    }

    // MARK: Services

    @Test func findsServicesInEveryKindOfDefinition() async throws {
        let root = try makeFixtureRepo([
            "Dockerfile": "FROM golang:1.23\n",
            "apps/billing-api/Dockerfile": "FROM golang:1.23\n",
            "apps/billing-api/Dockerfile.dev": "FROM golang:1.23\n",
            "apps/billing-api/Dockerfile.worker": "FROM golang:1.23\n",
            "apps/billing-api/helm/Chart.yaml": "apiVersion: v2\nname: billing-api\nversion: 1.0.0\n",
            "apps/billing-api/main.go": "package main\n\nfunc main() {}\n",
            "cmd/invoicer/main.go": "package main\n\nfunc main() {\n\trun()\n}\n",
            "cmd/invoicer/run.go": "package main\n\nfunc run() {}\n",
            "deploy/k8s/cron.yaml": """
                apiVersion: v1
                kind: ConfigMap
                metadata:
                  name: report-config
                ---
                apiVersion: batch/v1
                kind: CronJob
                metadata:
                  labels:
                    app: report
                  name: nightly-report
                spec:
                  schedule: "0 3 * * *"
                """,
            "charts/users-api/Chart.yaml": "apiVersion: v2\nname: users-api\n",
            "charts/users-api/templates/deployment.yaml": "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: {{ include \"users-api.fullname\" . }}\n",
            "lib/Chart.yaml": "apiVersion: v2\nname: shared\ntype: library\n",
            "web/package.json": #"{"name": "@acme/web", "scripts": {"start": "node server.js", "test": "jest"}}"#,
            "tools/package.json": #"{"name": "tools", "scripts": {"lint": "eslint ."}}"#,
            "docker-compose.yml": "services:\n  api:\n    build:\n      context: ./apps/billing-api\n  db:\n    image: postgres:16\n  outside:\n    build: ../elsewhere\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        var indexer = CodeIndexer(root: root, store: store)
        indexer.readHistory = false
        _ = try await indexer.index()

        let repo = indexer.repoID
        let services = try await store.nodes(kind: "service", repo: repo)
        #expect(Set(services.map(\.name)) == [root.lastPathComponent, "billing-api", "billing-api-worker", "invoicer", "nightly-report", "users-api", "@acme/web", "api"])
        let billing = try #require(services.first { $0.name == "billing-api" })
        #expect(billing.id == "service:\(repo):billing-api")
        #expect(billing.signature == "Defined in apps/billing-api/Dockerfile, apps/billing-api/Dockerfile.dev, apps/billing-api/helm/Chart.yaml")
        func runs(_ name: String) async throws -> [String] {
            try await store.neighbors(ServiceExtractor.id(repo: repo, name: name), kinds: ["runs"]).filter { !$0.incoming }.map(\.node.id)
        }
        #expect(try await runs("billing-api") == [indexer.directoryID("apps/billing-api")])
        #expect(try await runs("api") == [indexer.directoryID("apps/billing-api")])
        #expect(try await runs("invoicer") == [indexer.directoryID("cmd/invoicer")])
        #expect(try await runs("@acme/web") == [indexer.directoryID("web")])
        #expect(try await runs("users-api") == [repo])
        #expect(try await runs("nightly-report") == [repo])
        let deployed = try await store.neighbors(repo, kinds: ["deploys"]).map(\.node.name)
        #expect(deployed.count == services.count)
        #expect(try await store.search("billing-api", kinds: ["service"]).first?.id == billing.id)

        // A definition that goes takes its service with it.
        try FileManager.default.removeItem(at: root.appending(path: "apps/billing-api/Dockerfile.worker"))
        _ = try await indexer.index()
        #expect(try await store.node(ServiceExtractor.id(repo: repo, name: "billing-api-worker")) == nil)

        #expect(ServiceExtractor.codeFolder(of: "apps/billing-api/helm", name: "billing-api") == "apps/billing-api")
        #expect(ServiceExtractor.codeFolder(of: "deploy/charts/billing-api", name: "billing-api") == "")
        #expect(ServiceExtractor.commandName("cmd/invoicer/main.go") == "invoicer" && ServiceExtractor.commandName("internal/cmd.go") == nil)
        #expect(SourceScan.join("apps/x", "../y/./z") == "apps/y/z" && SourceScan.join("", "../x") == nil)
    }

    @Test func evaluatesGoConstantsAcrossPackages() throws {
        let root = try makeFixtureRepo([
            "go.mod": "module example.com/acme\n",
            "internal/paths/paths.go": "package paths\n\nconst Base = \"/billing\"\n",
            "api/server.go": """
                package api

                import (
                \tp "example.com/acme/internal/paths"
                )

                const v1 = p.Base + "/v1"

                func routes() {}
                """,
            "api/prefix.go": "package api\n\nvar admin = v1 + \"/admin\"\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try extractionInput(root, "api/server.go")
        #expect(input.evaluate(#"v1 + "/users""#) == "/billing/v1/users")
        #expect(input.evaluate(#"admin + "/x""#) == "/billing/v1/admin/x")
        #expect(input.evaluate(#"p.Base"#) == "/billing")
        #expect(input.evaluate(#"unknown + "/tail""#) == "/tail")
        #expect(input.evaluate("unknown") == nil)
        #expect(input.line(at: (input.text as NSString).range(of: "const v1").location) == 7)
        #expect(input.symbol(at: 9) == "sym:\(root.path)/api/server.go#routes")
    }
}

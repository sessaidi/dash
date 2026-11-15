import DashKit
import DashKitTesting
import Foundation
import Testing
@testable import Dash

/// The native parser per language, the indexer on a real git repository (incremental, git
/// history, call resolution), entity linking, search and paths, and Claude's study pass.
@MainActor
struct KnowledgeTests {
    // MARK: Parser

    @Test func parsesSwiftTypesMethodsAndCalls() {
        let parsed = CodeParser.parse("""
            import Foundation

            struct Billing {
                let rate: Double

                init(rate: Double) { self.rate = rate }

                func renew(_ plan: Plan) -> Double {
                    let amount = charge(plan.price)
                    return amount
                }

                private func charge(_ price: Double) -> Double {
                    price * rate // charge(this) in a comment
                }
            }

            func freeFunction() {}
            """, language: "swift")
        #expect(parsed.imports == ["Foundation"])
        #expect(parsed.symbols.map(\.name) == ["Billing", "init", "renew", "charge", "freeFunction"])
        #expect(parsed.symbols.map(\.kind) == ["struct", "method", "method", "method", "function"])
        #expect(parsed.symbols[2].container == "Billing" && parsed.symbols[4].container == "")
        #expect(parsed.symbols[2].calls.contains("charge"))
        #expect(parsed.symbols[2].line == 8 && parsed.symbols[2].endLine == 11)
        #expect(parsed.symbols[0].endLine == 16)
        #expect(!parsed.symbols[2].calls.contains("renew"))
    }

    @Test func parsesGoReceiversAndImportBlocks() {
        let parsed = CodeParser.parse("""
            package billing

            import (
                "context"
                pay "example.com/acme/api/payments"
            )

            type Service struct {
                repo Repo
            }

            func (s *Service) Renew(ctx context.Context) error {
                return s.repo.Save(ctx)
            }

            func New() *Service { return &Service{} }
            """, language: "go")
        #expect(parsed.imports == ["context", "example.com/acme/api/payments"])
        #expect(parsed.symbols.map(\.name) == ["Service", "Renew", "New"])
        #expect(parsed.symbols[1].kind == "method" && parsed.symbols[1].container == "Service")
        #expect(parsed.symbols[1].calls.contains("Save"))
    }

    @Test func parsesTypeScriptAndPython() {
        let ts = CodeParser.parse("""
            import { charge } from "./payments";
            export class Cart {
              total(): number {
                return charge(1);
              }
            }
            export const renew = async (id: string) => { await charge(2); };
            export function helper() {}
            """, language: "typescript")
        #expect(ts.imports == ["./payments"])
        #expect(ts.symbols.map(\.name) == ["Cart", "total", "renew", "helper"])
        #expect(ts.symbols[1].container == "Cart" && ts.symbols[1].calls.contains("charge"))

        let python = CodeParser.parse("""
            from billing import charge

            class Cart:
                def total(self):
                    return charge(1)

            def helper():
                pass
            """, language: "python")
        #expect(python.imports == ["billing"])
        #expect(python.symbols.map(\.name) == ["Cart", "total", "helper"])
        #expect(python.symbols[1].container == "Cart" && python.symbols[2].container == "")
        #expect(python.symbols[1].endLine == 5)
    }

    @Test func parsesTerraformKubernetesAndMakefiles() {
        let tf = CodeParser.parse("""
            module "vpc" {
              source = "./modules/vpc"
            }

            resource "aws_s3_bucket" "logs" {
              bucket = var.bucket_name
              tags   = { vpc = module.vpc.id }
            }

            variable "bucket_name" {}
            """, language: "terraform")
        #expect(tf.symbols.map(\.name) == ["module.vpc", "aws_s3_bucket.logs", "var.bucket_name"])
        #expect(tf.symbols[1].calls == ["var.bucket_name", "module.vpc"])
        #expect(tf.imports == ["./modules/vpc"] && tf.symbols[1].line == 5 && tf.symbols[1].endLine == 8)

        let k8s = CodeParser.parse("""
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: user-api
            spec:
              template:
                spec:
                  containers:
                    - name: api
                      image: gcr.io/acme/user-api:1.2
                      envFrom:
                        - configMapRef:
                            name: user-config
            ---
            apiVersion: v1
            kind: ConfigMap
            metadata:
              name: user-config
            """, language: "yaml")
        #expect(k8s.symbols.map(\.name) == ["user-api", "user-config"])
        #expect(k8s.symbols.map(\.kind) == ["k8s.Deployment", "k8s.ConfigMap"])
        #expect(k8s.symbols[0].calls.contains("user-config") && k8s.imports == ["image:gcr.io/acme/user-api:1.2"])

        let make = CodeParser.parse("include common.mk\n\nbuild: generate\n\tgo build ./...\n\ttest:\n\nrelease: build\n\t$(MAKE) publish\n", language: "makefile")
        #expect(make.symbols.map(\.name) == ["build", "release"])
        #expect(make.symbols[0].calls == ["generate"] && make.symbols[1].calls == ["build", "publish"])
        #expect(make.imports == ["common.mk"])

        let markdown = CodeParser.parse("# Billing\nSee [setup](docs/setup.md#run).\n```\n# not a heading\n```\n## Renewals\ntext\n# Other\n", language: "markdown")
        #expect(markdown.symbols.map(\.name) == ["Billing", "Renewals", "Other"])
        #expect(markdown.symbols[0].endLine == 7 && markdown.symbols[1].endLine == 7 && markdown.imports == ["docs/setup.md"])

        let package = CodeParser.parse(#"{"name":"web","scripts":{"build":"vite build"},"dependencies":{"vue":"^3"}}"#, language: "json")
        #expect(package.symbols.map(\.name) == ["build"] && package.imports == ["vue"])
        #expect(CodeParser.language(of: "web/package-lock.json") == nil && CodeParser.language(of: "Makefile") == "makefile")

        let vue = CodeParser.parse("<template><div/></template>\n<script setup lang=\"ts\">\nfunction save() { post() }\n</script>\n", language: "vue")
        #expect(vue.language == "vue" && vue.symbols.map(\.name) == ["save"] && vue.symbols[0].line == 3)
    }

    // MARK: Indexer

    /// A small git repository: Swift billing code, a TypeScript client, two commits mentioning LAF-12.
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "dash-kg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Sources/Billing"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "web/src"), withIntermediateDirectories: true)
        try """
            struct Billing {
                func renew() -> Double { charge(10) }
                func charge(_ price: Double) -> Double { price }
            }
            """.write(to: root.appending(path: "Sources/Billing/Billing.swift"), atomically: true, encoding: .utf8)
        try """
            struct Invoice {
                func send() { Billing().renew() }
            }
            """.write(to: root.appending(path: "Sources/Billing/Invoice.swift"), atomically: true, encoding: .utf8)
        try "export function pay() {}\n".write(to: root.appending(path: "web/src/payments.ts"), atomically: true, encoding: .utf8)
        try "import { pay } from \"./payments\";\nexport function checkout() { pay(); }\n"
            .write(to: root.appending(path: "web/src/cart.ts"), atomically: true, encoding: .utf8)
        try "node_modules/\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "node_modules/lib"), withIntermediateDirectories: true)
        try "export function ignored() {}\n".write(to: root.appending(path: "node_modules/lib/x.ts"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["config", "user.email", "ada@example.com"], ["config", "user.name", "Ada"],
                          ["remote", "add", "origin", "git@github.com:acme/api.git"], ["add", "."],
                          ["commit", "-q", "-m", "LAF-12 add renewals"]] {
            #expect(CodeIndexer.git(root, arguments) != nil, "git \(arguments)")
        }
        for round in 1...3 {
            try "// \(round)\n".appending(String(contentsOf: root.appending(path: "Sources/Billing/Billing.swift"), encoding: .utf8))
                .write(to: root.appending(path: "Sources/Billing/Billing.swift"), atomically: true, encoding: .utf8)
            try "// \(round)\n".appending(String(contentsOf: root.appending(path: "Sources/Billing/Invoice.swift"), encoding: .utf8))
                .write(to: root.appending(path: "Sources/Billing/Invoice.swift"), atomically: true, encoding: .utf8)
            _ = CodeIndexer.git(root, ["commit", "-qam", "LAF-12 tweak \(round)"])
        }
        return root
    }

    @Test func indexesARepositoryIncrementally() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        let indexer = CodeIndexer(root: root, store: store)
        let report = try await indexer.index()
        #expect(report.files == 4 && report.parsed == 4)   // node_modules ignored

        let repo = try #require(try await store.node(indexer.repoID))
        #expect(repo.qualified == "acme/api")
        let renew = "sym:\(root.path)/Sources/Billing/Billing.swift#Billing.renew"
        let charge = "sym:\(root.path)/Sources/Billing/Billing.swift#Billing.charge"
        let send = "sym:\(root.path)/Sources/Billing/Invoice.swift#Invoice.send"
        #expect(try await store.node(renew)?.line == 5)   // three "// n" lines added above by later commits
        // Calls resolved by name: within the file, and across files.
        #expect(try await store.trace(renew, kinds: ["calls"], reverse: false, depth: 1).map(\.node.id) == [charge])
        let callers = try await store.trace(charge, kinds: ["calls"], reverse: true, depth: 2).map(\.node.id)
        #expect(callers == [renew, send], "\(callers)")
        // A relative TypeScript import points at the file.
        let cart = indexer.fileID("web/src/cart.ts")
        #expect(try await store.neighbors(cart, kinds: ["imports"]).map(\.node.id) == [indexer.fileID("web/src/payments.ts")])
        // Directories, and history: author, files changed together, the ticket in commit subjects.
        #expect(try await store.subdirectories(repo: indexer.repoID, directory: "Sources").map(\.path) == ["Sources/Billing"])
        let billingFile = indexer.fileID("Sources/Billing/Billing.swift")
        let around = try await store.neighbors(billingFile)
        #expect(around.contains { $0.edge.kind == "authored" && $0.node.id == "person:ada@example.com" && $0.edge.weight == 4 })
        #expect(around.contains { $0.edge.kind == "changes_with" && $0.node.id == indexer.fileID("Sources/Billing/Invoice.swift") })
        #expect(around.contains { $0.edge.kind == "touches" && $0.node.id == "ticket:LAF-12" })
        // Search and paths.
        #expect(try await store.search("renew").first?.id == renew)
        let path = try #require(try await store.path(from: "ticket:LAF-12", to: renew))
        #expect(path.last?.node.id == renew && path.count == 3, "\(path.map { "\($0.edge.kind) \($0.node.id)" })")

        // Nothing changed: nothing parsed. A renamed function replaces the old symbol.
        #expect(try await indexer.index().parsed == 0)
        try String(contentsOf: root.appending(path: "Sources/Billing/Billing.swift"), encoding: .utf8)
            .replacingOccurrences(of: "func renew", with: "func renewPlan")
            .write(to: root.appending(path: "Sources/Billing/Billing.swift"), atomically: true, encoding: .utf8)
        #expect(try await indexer.index().parsed == 1)
        #expect(try await store.node(renew) == nil)
        #expect(try await store.node(renew + "Plan") != nil)
        // Edges from other files to symbols that still exist survive.
        #expect(try await store.trace(charge, kinds: ["calls"], reverse: true, depth: 1).map(\.node.id) == [renew + "Plan"])
    }

    @Test func linksEntitiesToCodeAndTickets() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        _ = try await CodeIndexer(root: root, store: store).index()
        let pr = KnowledgeEntity(id: "pr:acme/api#7", kind: "pr", title: "Renewals for LAF-12", text: "Adds renewals.",
                                 links: [KnowledgeLink(to: "repo:acme/api", kind: "in_repo"),
                                         KnowledgeLink(to: "repofile:acme/api:Sources/Billing/Billing.swift", kind: "touches"),
                                         KnowledgeLink(to: "repofile:other/repo:x.swift", kind: "touches")])
        try await KnowledgeLinker.ingest([pr], source: "pull-requests", into: store)
        let around = try await store.neighbors("pr:acme/api#7")
        #expect(Set(around.map { "\($0.edge.kind) \($0.node.id)" }) == [
            "in_repo repo:\(root.path)", "touches file:\(root.path)/Sources/Billing/Billing.swift", "mentions ticket:LAF-12",
        ])
        // Re-ingesting without it removes it.
        try await KnowledgeLinker.ingest([], source: "pull-requests", into: store)
        #expect(try await store.node("pr:acme/api#7") == nil)
        #expect(KnowledgeLinker.ticketKeys(in: "Fix LAF-12 and OPS-3, see LAF-12; not utf-8 or A-1") == ["LAF-12", "OPS-3"])
    }

    @Test func claudeStudiesDirectoriesAndConcepts() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kg-\(UUID().uuidString)"
        let knowledge = KnowledgeExtension(defaults: UserDefaults(suiteName: suite)!, url: nil)
        let host = try TestHost([knowledge])
        knowledge.start(host: host)
        knowledge.stop()
        knowledge.readHistory = false
        knowledge.repositories = [root.path]
        await knowledge.refresh()
        #expect(knowledge.lastError == nil && (knowledge.counts["symbol"] ?? 0) == 7)

        host.testDashii.reply = #"{"summary":"Bills customers.","responsibilities":["Renewals"],"concepts":[{"name":"Subscription renewal","description":"Charging again each period."}]}"#
        let studied = await knowledge.learn(budget: 2)
        #expect(studied == 2)
        let store = try #require(knowledge.store)
        let billing = try #require(try await store.node("dir:\(root.path)/Sources/Billing"))
        #expect(billing.summary.hasPrefix("Bills customers.") && billing.summarized != nil)
        #expect(host.testDashii.calls.contains { $0.prompt.contains("func renew() -> Double") })
        #expect(try await store.neighbors(billing.id, kinds: ["about"]).map(\.node.name) == ["Subscription renewal"])
        // The repository gets an overview from its top-level directories.
        #expect(try await store.node("repo:\(root.path)")?.summary.isEmpty == false)

        // Tools Dashii uses.
        let search = try await host.runTool("knowledge_search", ["query": "renew"])
        #expect(search?.array?.first?["name"]?.string == "renew")
        let snippet = try await host.runTool("knowledge_snippet", ["id": .string("sym:\(root.path)/Sources/Billing/Billing.swift#Billing.renew")])
        #expect(snippet?["code"]?.string?.contains("charge(10)") == true)
    }
}

/// Indexes a real repository named by KG_REPO and prints sizes and timings (skipped otherwise).
@MainActor
struct KnowledgeRealRepoTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KG_REPO"] != nil))
    func indexesARealRepository() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KG_REPO"]!)
        let store = try KnowledgeStore(url: nil)
        let indexer = CodeIndexer(root: root, store: store)
        let clock = ContinuousClock()
        var report = CodeIndexer.Report()
        let first = try await clock.measure { report = try await indexer.index() }
        let again = try await clock.measure { _ = try await indexer.index() }
        let counts = try await store.counts()
        print("KG \(root.lastPathComponent): \(report) first \(first) again \(again) counts \(counts.sorted { $0.key < $1.key })")
        let query = ProcessInfo.processInfo.environment["KG_QUERY"] ?? "user"
        for node in try await store.search(query, limit: 5) { print("KG search \(query): \(node.kind) \(node.qualified) \(node.path):\(node.line)") }
        #expect(report.parsed > 0)
    }
}

@MainActor
struct ActivitySeriesTests {
    @Test func builtInsPublishSeriesAndCommitsComeFromGit() async throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "series-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.start()
        let ids = ActivityHeatmapWidget.all(host).map(\.id)
        for id in ["basics.claude.tokens", "basics.claude.requests", "knowledge.commits.mine", "agents-studio.runs", "notes.edited"] {
            #expect(ids.contains(id), "\(id)")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "dash-series-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for arguments in [["init", "-q"], ["config", "user.email", "me@example.com"], ["config", "user.name", "Me"],
                          ["commit", "-q", "--allow-empty", "-m", "one"], ["commit", "-q", "--allow-empty", "-m", "two"]] {
            _ = CodeIndexer.git(root, arguments)
        }
        let knowledge = try #require(host.ext(KnowledgeExtension.self))
        knowledge.repositories = [root.path]
        defer { knowledge.repositories = [] }
        let series = try #require(knowledge.activitySeries.first { $0.id == "commits.mine" })
        let values = await series.values(DateInterval(start: .now.addingTimeInterval(-86_400), end: .now.addingTimeInterval(60)))
        #expect(values.values.reduce(0, +) == 2)
    }
}

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

        // A long metadata block without a literal name is read in linear time.
        let annotations = (1...40).map { "        acme.test/note-\($0): \"value \($0)\"" }.joined(separator: "\n")
        let manifest = try makeFixtureRepo(["deploy/api.yaml": "kind: Deployment\nmetadata:\n  annotations:\n\(annotations)\n  name: {{ .Values.name }}\nspec:\n  replicas: 2\n"])
        defer { try? FileManager.default.removeItem(at: manifest) }
        let clock = ContinuousClock()
        let input = try extractionInput(manifest, "deploy/api.yaml")
        var found = Extraction()
        #expect(clock.measure { found = ServiceExtractor().extract(input) } < .seconds(1))
        #expect(found.nodes.isEmpty)

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

    // MARK: Endpoints

    /// "METHOD /path" → best handler name for the endpoints a fixture file declares.
    private func routes(_ root: URL, _ path: String) throws -> [String: String] {
        let extraction = EndpointExtractor().extract(try extractionInput(root, path))
        var result: [String: String] = [:]
        for node in extraction.nodes {
            result[String(node.id.dropFirst("endpoint:".count))] = extraction.refs.first { $0.src == node.id }?.names.first ?? ""
        }
        return result
    }

    @Test func normalizesEndpointPathsAndHandlers() {
        #expect(EndpointExtractor.normalize("/users/:id/plans/{plan_id}") == "/users/{}/plans/{}")
        #expect(EndpointExtractor.normalize("users/<int:pk>/") == "/users/{}")
        #expect(EndpointExtractor.normalize("/invoices/[id]") == "/invoices/{}")
        #expect(EndpointExtractor.normalize("/files/*path") == "/files/*")
        #expect(EndpointExtractor.normalize("/legacy/(?P<slug>[\\w-]+)/$") == "/legacy/{}")
        #expect(EndpointExtractor.normalize("https://billing.acme.test//v1/plans?all=1") == "/v1/plans")
        #expect(EndpointExtractor.clean("/users/:id/") == "/users/:id")
        #expect(EndpointExtractor.join("/api/", "/users") == "/api/users" && EndpointExtractor.join("/api", "/") == "/api")

        #expect(EndpointExtractor.handlerNames("hf.Handle(handlers.Invoices.Get)") == ["handlers.Invoices.Get"])
        #expect(EndpointExtractor.handlerNames("applyMiddlewares(middlewares.Auth, hf.Handle(h.Create))") == ["h.Create", "middlewares.Auth"])
        #expect(EndpointExtractor.handlerNames("users.Get(repo)") == ["users.Get", "repo"])
        #expect(EndpointExtractor.handlerNames(#"http.StripPrefix("/static/", files)"#) == ["files"])
        #expect(EndpointExtractor.handlerNames("views.AccountView.as_view()") == ["views.AccountView"])
        #expect(EndpointExtractor.handlerNames("(req, res) => res.send('ok')").isEmpty && EndpointExtractor.handlerNames("async (req) => {}").isEmpty)
        #expect(EndpointExtractor.handlerNames("asyncHandler(orders.create)") == ["orders.create"])
        #expect(EndpointExtractor.handlerNames("func(w http.ResponseWriter, r *http.Request) {}").isEmpty)
    }

    @Test func findsGoRoutes() throws {
        let root = try makeFixtureRepo([
            "go.mod": "module example.com/acme\n",
            "internal/paths/paths.go": "package paths\n\nconst Service = \"/billing\"\n",
            "cmd/gateway/routes.go": """
                package main

                import (
                \t"net/http"

                \t"goji.io"
                \t"goji.io/pat"
                \t"example.com/acme/internal/paths"
                )

                func (s *Server) routes() {
                \tall := goji.SubMux()
                \ts.mux.Handle(pat.New(paths.Service+"/*"), all)
                \tall.Handle(pat.Get("/invoices/:id"), hf.Handle(handlers.Invoices.Get))
                \tall.Handle(pat.Post("/invoices"), applyMiddlewares(middlewares.Auth, hf.Handle(handlers.Invoices.Create)))
                \ts.mux.Handle(pat.New("/health"), health)
                \ts.mux.HandleFunc(pat.Get("/version"), func(w http.ResponseWriter, r *http.Request) {})
                \ttraced := newTraced(cfg, all)
                \ttraced.Handle(pat.Get("/plans"), handlers.Plans.List)
                \ts.mux.Handle(pat.New("/admin/*"), adminMux)
                }
                """,
            "api/chi.go": """
                package api

                import "github.com/go-chi/chi/v5"

                func Router() http.Handler {
                \tr := chi.NewRouter()
                \tr.Get("/", index)
                \tr.Route("/v1", func(r chi.Router) {
                \t\tr.Get("/users/{userID}", users.Show)
                \t\tr.With(auth).Post("/users", users.Create)
                \t})
                \tr.Mount("/admin", adminRouter())
                \treturn r
                }

                func adminRouter() http.Handler {
                \tr := chi.NewRouter()
                \tr.Delete("/cache", clearCache)
                \treturn r
                }
                """,
            "api/mux.go": """
                package api

                import "github.com/gorilla/mux"

                func routes(r *mux.Router) {
                \tapi := r.PathPrefix("/api").Subrouter()
                \tapi.HandleFunc("/orders/{id:[0-9]+}", getOrder).Methods("GET", "HEAD")
                \tapi.Path("/orders").Methods(http.MethodPost).HandlerFunc(createOrder)
                }
                """,
            "api/gin.go": """
                package api

                import "github.com/gin-gonic/gin"

                func Setup(r *gin.Engine) {
                \tv1 := r.Group("/v1")
                \tv1.GET("/plans/:id", plans.Get)
                \tv1.Handle("PUT", "/plans/:id", plans.Update)
                \tclient.Get("/not-a-route")
                }
                """,
            "cmd/billing-api/main.go": """
                package main

                import "net/http"

                func main() {
                \tmux := http.NewServeMux()
                \tmux.HandleFunc("GET /invoices/{id}", showInvoice)
                \tmux.Handle("/static/", http.StripPrefix("/static/", files))
                \thttp.ListenAndServe(":8080", mux)
                }
                """,
            "api/chi_test.go": "package api\n\nfunc TestX() {\n\tr.Get(\"/test-only\", h)\n}\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try routes(root, "cmd/gateway/routes.go") == [
            "GET /billing/invoices/{}": "handlers.Invoices.Get", "POST /billing/invoices": "handlers.Invoices.Create",
            "ANY /health": "health", "GET /version": "", "GET /billing/plans": "handlers.Plans.List",
        ])
        #expect(try routes(root, "api/chi.go") == ["GET /": "index", "GET /v1/users/{}": "users.Show", "POST /v1/users": "users.Create", "DELETE /admin/cache": "clearCache"])
        #expect(try routes(root, "api/mux.go") == ["GET /api/orders/{}": "getOrder", "HEAD /api/orders/{}": "getOrder", "POST /api/orders": "createOrder"])
        #expect(try routes(root, "api/gin.go") == ["GET /v1/plans/{}": "plans.Get", "PUT /v1/plans/{}": "plans.Update"])
        #expect(try routes(root, "cmd/billing-api/main.go") == ["GET /invoices/{}": "showInvoice", "ANY /static": "files"])
        #expect(!EndpointExtractor().accepts(path: "api/chi_test.go", language: "go"))

        let node = try #require(EndpointExtractor().extract(try extractionInput(root, "api/chi.go")).nodes.first { $0.id == "endpoint:GET /v1/users/{}" })
        #expect(node.name == "GET /v1/users/{userID}" && node.language == "chi" && node.signature == "GET /v1/users/{} → users.Show")
    }

    @Test func findsScriptRoutes() throws {
        let root = try makeFixtureRepo([
            "web/server.ts": """
                import express from 'express'

                const app = express()
                const api = express.Router()
                api.get('/users/:id', auth, users.show)
                api.route('/orders').get(orders.list).post(asyncHandler(orders.create))
                app.use('/api/v1', api)
                app.get('/health', (req, res) => res.send('ok'))
                axios.get('/remote', { timeout: 5 })
                """,
            "web/koa.js": "const Router = require('@koa/router')\nconst router = new Router({ prefix: '/koa' })\nrouter.del('/x', h)\nrouter.post('/items', items.add)\n",
            "web/fastify.ts": """
                import Fastify from 'fastify'

                const app = Fastify({ logger: true })
                app.route({ method: ['GET', 'HEAD'], url: '/plans', handler: plans.list })
                """,
            "web/users.controller.ts": """
                import { Controller, Get, Post } from '@nestjs/common'

                @Controller('users')
                export class UsersController {
                  @Get(':id')
                  findOne(id: string) {
                    return id
                  }

                  @Post()
                  create() {}
                }
                """,
            "web/pages/api/invoices/[id].ts": "export default function handler(req, res) {\n  res.json({})\n}\n",
            "web/app/(shop)/billing/[plan]/route.ts": "export async function GET(request: Request) {\n  return Response.json({})\n}\n\nexport async function POST() {}\n",
            "web/client.ts": "import axios from 'axios'\n\nexport const load = () => axios.get('/users/1', { params: {} })\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let base = "sym:\(root.path)/web/"
        let express = try routes(root, "web/server.ts")
        #expect(express == [
            "GET /api/v1/users/{}": "users.show", "GET /api/v1/orders": "orders.list", "POST /api/v1/orders": "orders.create", "GET /health": "",
        ])
        #expect(try routes(root, "web/koa.js") == ["DELETE /koa/x": "h", "POST /koa/items": "items.add"])
        #expect(try routes(root, "web/fastify.ts") == ["GET /plans": "plans.list", "HEAD /plans": "plans.list"])
        #expect(try routes(root, "web/users.controller.ts") == [
            "GET /users/{}": base + "users.controller.ts#UsersController.findOne", "POST /users": base + "users.controller.ts#UsersController.create",
        ])
        #expect(try routes(root, "web/pages/api/invoices/[id].ts") == ["ANY /api/invoices/{}": base + "pages/api/invoices/[id].ts#handler"])
        #expect(try routes(root, "web/app/(shop)/billing/[plan]/route.ts") == [
            "GET /billing/{}": base + "app/(shop)/billing/[plan]/route.ts#GET", "POST /billing/{}": base + "app/(shop)/billing/[plan]/route.ts#POST",
        ])
        #expect(try routes(root, "web/client.ts").isEmpty)
    }

    @Test func findsPythonAndVaporRoutes() throws {
        let root = try makeFixtureRepo([
            "api/app.py": """
                from flask import Flask, Blueprint

                app = Flask(__name__)
                bp = Blueprint("invoices", __name__, url_prefix="/invoices")

                @bp.route("/<int:invoice_id>", methods=["GET", "DELETE"])
                def invoice(invoice_id):
                    return ""

                @app.get("/health")
                def health():
                    return "ok"

                app.register_blueprint(bp, url_prefix="/api")
                """,
            "api/routers.py": """
                from fastapi import APIRouter, FastAPI

                router = APIRouter(prefix="/plans")

                @router.post("/{plan_id}/renew")
                async def renew(plan_id: str):
                    ...

                app = FastAPI()
                app.include_router(router, prefix="/v2")
                """,
            "api/urls.py": """
                from django.urls import include, path, re_path
                from . import views

                urlpatterns = [
                    path("accounts/<int:pk>/", views.AccountView.as_view(), name="account"),
                    re_path(r"^legacy/(?P<slug>[\\w-]+)/$", views.legacy),
                    path("admin/", include("admin.urls")),
                ]
                """,
            "Sources/App/routes.swift": """
                import Vapor

                func routes(_ app: Application) throws {
                    app.get("health") { req in "ok" }
                    let users = app.grouped("api", "users")
                    users.get(":id", use: UserController.show)
                    users.on(.DELETE, ":id", use: UserController.delete)
                    app.group("admin") { admin in
                        admin.post("reindex") { req async throws -> HTTPStatus in .ok }
                    }
                    if let id = req.parameters.get("id") { print("in") }
                }
                """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let base = "sym:\(root.path)/api/"
        #expect(try routes(root, "api/app.py") == [
            "GET /api/invoices/{}": base + "app.py#invoice", "DELETE /api/invoices/{}": base + "app.py#invoice", "GET /health": base + "app.py#health",
        ])
        #expect(try routes(root, "api/routers.py") == ["POST /v2/plans/{}/renew": base + "routers.py#renew"])
        #expect(try routes(root, "api/urls.py") == ["ANY /accounts/{}": "views.AccountView", "ANY /legacy/{}": "views.legacy"])
        #expect(try routes(root, "Sources/App/routes.swift") == [
            "GET /health": "", "GET /api/users/{}": "UserController.show", "DELETE /api/users/{}": "UserController.delete", "POST /admin/reindex": "",
        ])
    }

    // MARK: Outbound calls

    /// "caller → target" for the calls a fixture file makes (the caller's name after "#").
    private func outbound(_ root: URL, _ path: String) throws -> Set<String> {
        let extraction = OutboundCallExtractor().extract(try extractionInput(root, path))
        return Set(extraction.edges.map { String($0.src.split(separator: "#").last ?? "") + " → " + $0.dst })
    }

    @Test func findsOutboundCalls() throws {
        let root = try makeFixtureRepo([
            "go.mod": "module example.com/acme\n",
            "internal/config/config.go": """
                package config

                type Config struct {
                \tBillingURL string `env:"BILLING_API_URL" envDefault:"http://billing-api:8080"`
                \tTimeout    int    `env:"TIMEOUT"`
                }
                """,
            "clients/billing.go": """
                package clients

                import (
                \t"fmt"
                \t"net/http"
                \t"os"
                )

                const usersBase = "http://users-api.default.svc.cluster.local:8080/v1"

                type Billing struct {
                \tcfg    config.Config
                \tclient *http.Client
                }

                func (b *Billing) Invoice(id string) error {
                \turl := fmt.Sprintf("%s/invoices/%s", b.cfg.BillingURL, id)
                \treq, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
                \t_ = req
                \treturn err
                }

                func (b *Billing) Refund(id string) {
                \tb.client.Post(b.cfg.BillingURL+"/invoices/"+id+"/refunds", "application/json", nil)
                }

                func User(id string) {
                \thttp.Get(usersBase + "/users/" + id)
                }

                func Plans() {
                \tbase := os.Getenv("PLANS_URL")
                \tu, _ := url.Parse(base + "/plans?active=true")
                \thttp.Get(u.String())
                }

                func Charge(c *resty.Client) {
                \tc.R().SetBody(nil).Post("/charges")
                }

                func Cached(cacheClient *Cache) {
                \tcacheClient.Get("user:1")
                }
                """,
            "web/src/api.ts": """
                import axios from 'axios'

                const BILLING = process.env.BILLING_API_URL

                export async function loadInvoice(id: string) {
                  const response = await fetch(`${BILLING}/invoices/${id}`)
                  return response.json()
                }

                export function refund(id: string) {
                  return fetch(`${process.env.BILLING_API_URL}/invoices/${id}/refunds`, { method: 'POST' })
                }

                const users = axios.create({ baseURL: 'https://users.acme.test/v1' })

                export function getUser(id: string) {
                  return users.get(`/users/${id}`)
                }

                export function plans() {
                  return axios.get<Plan[]>(import.meta.env.VITE_PLANS_URL + '/plans')
                }
                """,
            "jobs/sync.py": """
                import os
                import httpx
                import requests

                BASE = os.environ["BILLING_API_URL"]


                def sync_invoice(invoice_id):
                    return requests.get(f"{BASE}/invoices/{invoice_id}", timeout=5)


                def close(invoice_id):
                    requests.request("POST", BASE + f"/invoices/{invoice_id}/close")


                async def users():
                    async with httpx.AsyncClient(base_url="https://users.acme.test") as client:
                        await client.get("/v1/users")
                """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let go = try outbound(root, "clients/billing.go")
        #expect(go == [
            "Billing.Invoice → endpoint:GET /invoices/{}", "Billing.Invoice → host:BILLING_API_URL",
            "Billing.Refund → endpoint:POST /invoices/{}/refunds", "Billing.Refund → host:BILLING_API_URL",
            "User → endpoint:GET /v1/users/{}", "User → host:users-api.default.svc.cluster.local",
            "Plans → endpoint:GET /plans", "Plans → host:PLANS_URL",
            "Charge → endpoint:POST /charges",
        ])
        let script = try outbound(root, "web/src/api.ts")
        #expect(script == [
            "loadInvoice → endpoint:GET /invoices/{}", "loadInvoice → host:BILLING_API_URL",
            "refund → endpoint:POST /invoices/{}/refunds", "refund → host:BILLING_API_URL",
            "getUser → endpoint:GET /v1/users/{}", "getUser → host:users.acme.test",
            "plans → endpoint:GET /plans", "plans → host:VITE_PLANS_URL",
        ])
        let python = try outbound(root, "jobs/sync.py")
        #expect(python == [
            "sync_invoice → endpoint:GET /invoices/{}", "sync_invoice → host:BILLING_API_URL",
            "close → endpoint:POST /invoices/{}/close", "close → host:BILLING_API_URL",
            "users → endpoint:GET /v1/users", "users → host:users.acme.test",
        ])
        // A client's Post(url, contentType, body) isn't a route.
        #expect(try routes(root, "clients/billing.go").isEmpty)

        let host = try #require(OutboundCallExtractor().extract(try extractionInput(root, "clients/billing.go")).nodes.first { $0.id == "host:PLANS_URL" })
        #expect(host.kind == "host" && host.signature == "Base URL from the environment variable PLANS_URL")
        #expect(URLPart.target([.text("https://user:secret@api.acme.test:8443/v2/plans/"), .unknown("id")]).host?.name == "api.acme.test")
        #expect(URLPart.target([.text("https://"), .unknown("host"), .text("/x")]).host == nil)
        let assembled = URLPart.target([.env("MAIL_SCHEME"), .text("://"), .env("MAIL_HOST"), .text(":"), .env("MAIL_PORT"), .text("/email/send")])
        #expect(assembled.host?.name == "MAIL_HOST" && assembled.path == "/email/send")
        #expect(URLPart.target([.text("http://mail.acme.test:"), .env("MAIL_PORT"), .text("/email")]).host?.name == "mail.acme.test")
        #expect(URLPart.target([.text("https://api-"), .unknown("region"), .text(".acme.test/v1/x")]).host == nil)
        #expect(URLPart.target([.unknown("base"), .text("/{}")]).path == nil)
    }

    @Test func calledEndpointsComeAndGoWithTheirCalls() async throws {
        let root = try makeFixtureRepo([
            "go.mod": "module example.com/acme\n",
            "api/routes.go": """
                package api

                import "github.com/go-chi/chi/v5"

                func Routes(r chi.Router) {
                \tr.Get("/invoices/{id}", GetInvoice)
                }

                func GetInvoice(w http.ResponseWriter, r *http.Request) {}
                """,
            "web/api.ts": """
                export const invoice = (id: string) => fetch(`${process.env.BILLING_API_URL}/invoices/${id}`)
                export const plans = () => fetch(process.env.BILLING_API_URL + '/plans')
                """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        var indexer = CodeIndexer(root: root, store: store)
        indexer.readHistory = false
        _ = try await indexer.index()

        let defined = try #require(try await store.node("endpoint:GET /invoices/{}"))
        #expect(defined.signature == "GET /invoices/{} → GetInvoice")
        let called = try #require(try await store.node("endpoint:GET /plans"))
        #expect(called.signature == "GET /plans" && called.repo.isEmpty)
        let callers = try await store.neighbors(defined.id, kinds: ["calls_endpoint"]).filter(\.incoming).map(\.node.id)
        #expect(callers.count == 1 && callers.allSatisfy { $0.hasSuffix("web/api.ts#invoice") })
        #expect(try await store.node("host:BILLING_API_URL")?.kind == "host")

        try FileManager.default.removeItem(at: root.appending(path: "web/api.ts"))
        _ = try await indexer.index()
        #expect(try await store.node("endpoint:GET /plans") == nil)
        #expect(try await store.node("host:BILLING_API_URL") == nil)
        #expect(try await store.node(defined.id)?.signature == defined.signature)
    }

    /// A Go service in one repository; a web app and a job calling it from another.
    private func makeServiceAndClients() throws -> (server: URL, clients: URL) {
        let server = try makeFixtureRepo([
            "go.mod": "module example.com/billing\n",
            "billing-api/Dockerfile": "FROM golang:1.23\n",
            "billing-api/main.go": """
                package main

                import "github.com/go-chi/chi/v5"

                func main() {
                \tr := chi.NewRouter()
                \tr.Get("/v1/invoices/{id}", getInvoice)
                \tr.Post("/v1/invoices/{id}/refunds", refund)
                \tr.Get("/v1/plans", listPlans)
                }

                func getInvoice(w http.ResponseWriter, r *http.Request) {}
                func refund(w http.ResponseWriter, r *http.Request) {}
                func listPlans(w http.ResponseWriter, r *http.Request) {}
                """,
        ])
        let clients = try makeFixtureRepo([
            "web/src/api.ts": """
                const BILLING = process.env.BILLING_API_URL

                export function loadInvoice(id: string) {
                  return fetch(`${BILLING}/v1/invoices/${id}`)
                }

                export function refund(id: string) {
                  return fetch(`${BILLING}/v1/invoices/${id}/refunds`, { method: 'POST' })
                }
                """,
            "jobs/sync.py": """
                import os
                import requests

                BASE = os.environ["BILLING_API_URL"]


                def sync_invoice(invoice_id):
                    return requests.get(f"{BASE}/invoices/{invoice_id}")


                def plans(base, method):
                    return requests.request(method, base + "/v1/plans")
                """,
        ])
        return (server, clients)
    }

    @Test func linksCallsAcrossRepositories() async throws {
        let (server, clients) = try makeServiceAndClients()
        defer { for url in [server, clients] { try? FileManager.default.removeItem(at: url) } }
        let store = try KnowledgeStore(url: nil)
        for root in [server, clients] {
            var indexer = CodeIndexer(root: root, store: store)
            indexer.readHistory = false
            _ = try await indexer.index()
        }
        let service = ServiceExtractor.id(repo: "repo:" + server.path, name: "billing-api")
        func callers(_ endpoint: String) async throws -> [String: Double] {
            var result: [String: Double] = [:]
            for neighbor in try await store.neighbors(endpoint, kinds: ["calls_endpoint"]) where neighbor.incoming {
                result[String(neighbor.node.id.split(separator: "#").last ?? "")] = neighbor.edge.weight
            }
            return result
        }

        // The same route id on both sides; a prefix the job's base URL carries; a method it doesn't say.
        #expect(try await callers("endpoint:GET /v1/invoices/{}") == ["loadInvoice": 1, "sync_invoice": 0.9])
        #expect(try await callers("endpoint:POST /v1/invoices/{}/refunds") == ["refund": 1])
        #expect(try await callers("endpoint:GET /v1/plans") == ["plans": 0.8])
        let about = try await store.neighbors("host:BILLING_API_URL", kinds: ["about"]).filter { !$0.incoming }
        #expect(about.map(\.node.id) == [service] && about.first?.edge.weight == 0.9)
        #expect(try await store.node("endpoint:GET /invoices/{}")?.signature == "GET /invoices/{}")

        // A client file that goes takes its calls with it.
        var again = CodeIndexer(root: clients, store: store)
        again.readHistory = false
        try FileManager.default.removeItem(at: clients.appending(path: "web/src/api.ts"))
        _ = try await again.index()
        #expect(try await callers("endpoint:GET /v1/invoices/{}") == ["sync_invoice": 0.9])
        #expect(try await callers("endpoint:POST /v1/invoices/{}/refunds").isEmpty)

        // The service's repository goes: its routes are only called now, and nothing points into it.
        try await store.removeRepo("repo:" + server.path)
        try await ServiceLinks.link(store: store)
        #expect(try await store.node("endpoint:GET /v1/plans") == nil)
        #expect(try await store.node("endpoint:GET /v1/invoices/{}") == nil)
        #expect(try await store.node("endpoint:GET /invoices/{}")?.signature == "GET /invoices/{}")
        #expect(try await store.neighbors("host:BILLING_API_URL", kinds: ["about"]).isEmpty)

        #expect(ServiceLinks.hostWords("VITE_PLANS_API_BASE_URL") == ["plans", "api"])
        #expect(ServiceLinks.hostWords("users-api.default.svc.cluster.local") == ["users", "api"])
        #expect(ServiceLinks.hostWords("localhost").isEmpty && ServiceLinks.hostWords("10.0.0.1").isEmpty)
        func named(_ names: String...) -> [KnowledgeNode] {
            names.enumerated().map { KnowledgeNode(id: "service:r\($0.offset):\($0.element)", kind: "service", name: $0.element, qualified: $0.element, source: "code") }
        }
        #expect(ServiceLinks.serviceMatches(host: "users.acme.test", services: named("users-api", "web")).weight == 0.6)
        #expect(ServiceLinks.serviceMatches(host: "USERS_SERVICE_URL", services: named("users-api", "users-worker")).ids == ["service:r0:users-api"])
        #expect(ServiceLinks.serviceMatches(host: "users.acme.test", services: named("users-api", "users-svc")).ids.isEmpty)
        #expect(ServiceLinks.serviceMatches(host: "api.acme.test", services: named("api")).ids == ["service:r0:api"])
    }

    @Test func dashiiMapsAServiceBothWays() async throws {
        let (server, clients) = try makeServiceAndClients()
        defer { for url in [server, clients] { try? FileManager.default.removeItem(at: url) } }
        let knowledge = KnowledgeExtension(defaults: UserDefaults(suiteName: "kx-\(UUID())")!, url: nil)
        let store = try #require(knowledge.store)
        for root in [server, clients] { _ = try await KnowledgeExtension.index(root.path, store: store, history: false) }
        let search = try #require(knowledge.tools.first { $0.name == "knowledge_search" })
        let hosts = try await search.run(["query": "BILLING_API_URL", "kind": "host"])
        #expect(hosts.array?.map { $0["id"]?.string } == ["host:BILLING_API_URL"])
        #expect(KnowledgeView.kinds.contains("host"))
        let tool = try #require(knowledge.tools.first { $0.name == "knowledge_service_map" })
        func entry(_ list: JSONValue?, _ key: String, _ value: String) -> JSONValue? { list?.array?.first { $0[key]?.string == value } }

        let service = try await tool.run(["name": "billing-api"])
        #expect(service["service"] == "billing-api" && service["runs_from"] == ["billing-api"])
        #expect(service["defined_in"]?.array?.contains("billing-api/Dockerfile") == true)
        #expect(service["exposes"]?.array?.compactMap { $0["endpoint"]?.string } == ["GET /v1/invoices/{}", "POST /v1/invoices/{}/refunds", "GET /v1/plans"])
        #expect(service["exposes"]?.array?.first == ["endpoint": "GET /v1/invoices/{}", "handler": "getInvoice", "at": "billing-api/main.go:7"])
        let clientsName = clients.lastPathComponent
        let invoice = entry(service["called_by"], "endpoint", "GET /v1/invoices/{}")
        #expect(invoice?["from"] == [.string("loadInvoice at \(clientsName)/web/src/api.ts:3"), .string("sync_invoice at \(clientsName)/jobs/sync.py:7")])
        #expect(entry(service["called_by"], "endpoint", "GET /v1/plans")?["confidence"] == 0.8)
        #expect(entry(service["called_by"], "host", "BILLING_API_URL")?["from"]?.array?.count == 3)
        #expect(service["calls"] == [])

        let repository = try await tool.run(["name": .string(clientsName)])
        #expect(repository["repository"]?.string == clientsName && repository["exposes"] == [])
        let answered: JSONValue = [.string("billing-api (\(server.lastPathComponent))")]
        #expect(entry(repository["calls"], "endpoint", "GET /v1/invoices/{}")?["answered_by"] == answered)
        #expect(entry(repository["calls"], "host", "BILLING_API_URL")?["answered_by"] == answered)
        #expect(entry(repository["calls"], "endpoint", "GET /invoices/{}")?["answered_by"] == nil)
        #expect(repository["env"]?.array?.contains("BILLING_API_URL") == true)
        await #expect(throws: (any Error).self) { try await tool.run(["name": "no-such-service"]) }
    }

    // MARK: gRPC

    private static let billingProto = """
        syntax = "proto3";
        // service Commented { rpc Nope(A) returns (B); }
        package acme.billing.v1;

        import "google/api/annotations.proto";
        option go_package = "example.com/acme/gen/billing/v1;billingv1";

        /* Invoices of a customer. */
        service Invoices {
          option (acme.owner) = "billing";
          rpc GetInvoice(GetInvoiceRequest) returns (Invoice);
          rpc Watch(stream WatchRequest) returns (stream .acme.billing.v1.Event) {
            option (google.api.http) = { get: "/v1/invoices:watch" };
          }
        }

        message Invoice {
          string id = 1;
          repeated LineItem items = 2 [json_name = "lines"];
          map<string, string> labels = 3;
          oneof payer {
            string user_id = 4;
            string org_id = 5;
          }
          message LineItem { string sku = 1; int64 cents = 2; }
          enum Status { DRAFT = 0; PAID = 1; }
          Status status = 6;
          reserved 9;
        }

        message GetInvoiceRequest { string id = 1; }
        """

    @Test func readsProtoFilesAndTheCodeUsingThem() throws {
        let root = try makeFixtureRepo([
            "proto/acme/billing/v1/billing.proto": Self.billingProto,
            "gen/billing/v1/billing_grpc.pb.go": "package billingv1\n\nfunc NewInvoicesClient(cc grpc.ClientConnInterface) InvoicesClient { return nil }\n",
            "server/invoices.go": """
                package server

                import (
                \tbillingv1 "example.com/acme/gen/billing/v1"
                \t"google.golang.org/grpc"
                )

                type InvoiceServer struct {
                \tbillingv1.UnimplementedInvoicesServer
                }

                func Register(s *grpc.Server) {
                \tbillingv1.RegisterInvoicesServer(s, &InvoiceServer{})
                }
                """,
            "clients/billing.go": """
                package clients

                import (
                \tbillingv1 "example.com/acme/gen/billing/v1"
                \t"github.com/redis/go-redis/v9"
                )

                func Dial(conn *grpc.ClientConn) billingv1.InvoicesClient {
                \t_ = redis.NewClient(nil)
                \treturn billingv1.NewInvoicesClient(conn)
                }
                """,
            "jobs/invoices.py": """
                import grpc
                from gen import billing_pb2_grpc


                class Invoices(billing_pb2_grpc.InvoicesServicer):
                    def GetInvoice(self, request, context):
                        return None


                def fetch(channel):
                    stub = billing_pb2_grpc.InvoicesStub(channel)
                    return stub
                """,
            "web/src/billing.ts": """
                import { InvoicesClient } from './gen/billing_grpc_pb'

                export function client(address: string) {
                  return new InvoicesClient(address, credentials)
                }
                """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let proto = ProtoFile.parse(Self.billingProto)
        #expect(proto.package == "acme.billing.v1" && proto.services.map(\.name) == ["Invoices"])
        #expect(proto.services.first?.rpcs.map(\.signature) == [
            "rpc GetInvoice(GetInvoiceRequest) returns (Invoice)", "rpc Watch(stream WatchRequest) returns (stream acme.billing.v1.Event)",
        ])
        #expect(proto.messages.map(\.name) == ["Invoice", "Invoice.LineItem", "GetInvoiceRequest"])
        #expect(proto.messages.first?.fields == ["id", "items", "labels", "user_id", "org_id", "status"])
        #expect(proto.messages.first?.line == 17 && proto.services.first?.rpcs.first?.line == 11)

        let extraction = ProtobufExtractor().extract(try extractionInput(root, "proto/acme/billing/v1/billing.proto"))
        #expect(Set(extraction.nodes.map(\.id)) == [
            "grpc:acme.billing.v1.Invoices", "grpc:acme.billing.v1.Invoices/GetInvoice", "grpc:acme.billing.v1.Invoices/Watch",
            "proto:acme.billing.v1.Invoice", "proto:acme.billing.v1.Invoice.LineItem", "proto:acme.billing.v1.GetInvoiceRequest",
        ])
        let service = try #require(extraction.nodes.first { $0.kind == "rpc_service" })
        #expect(service.signature == "service acme.billing.v1.Invoices: GetInvoice, Watch" && service.path == "proto/acme/billing/v1/billing.proto")
        #expect(extraction.edges.contains(KnowledgeEdge(src: service.id, dst: "grpc:acme.billing.v1.Invoices/Watch", kind: "contains")))
        #expect(extraction.nodes.first { $0.id == "proto:acme.billing.v1.Invoice.LineItem" }?.signature == "message Invoice.LineItem { sku, cents }")

        func refs(_ path: String) throws -> Set<String> {
            Set(ProtobufExtractor().extract(try extractionInput(root, path)).refs.map {
                "\($0.src.split(separator: "#").last ?? "") \($0.kind) \($0.names.joined(separator: " "))"
            })
        }
        let importPath = "import:example.com/acme/gen/billing/v1"
        #expect(try refs("server/invoices.go") == ["InvoiceServer implements Invoices \(importPath)", "Register implements Invoices \(importPath)"])
        #expect(try refs("clients/billing.go") == ["Dial calls_rpc Invoices \(importPath)"])
        let python = try refs("jobs/invoices.py")
        #expect(python == ["Invoices implements Invoices", "fetch calls_rpc Invoices"])
        #expect(try refs("web/src/billing.ts") == ["client calls_rpc Invoices"])
        #expect(!ProtobufExtractor().accepts(path: "gen/billing/v1/billing_grpc.pb.go", language: "go"))
    }

    @Test func linksGRPCAcrossRepositories() async throws {
        let protos = try makeFixtureRepo([
            "acme/billing/v1/billing.proto": Self.billingProto,
            "acme/legacy/v1/legacy.proto": "syntax = \"proto3\";\npackage acme.legacy.v1;\nservice Invoices { rpc Get(Req) returns (Res); }\n",
        ])
        let app = try makeFixtureRepo([
            "server/invoices.go": "package server\n\nimport billingv1 \"example.com/acme/gen/billing/v1\"\n\ntype InvoiceServer struct {\n\tbillingv1.UnimplementedInvoicesServer\n}\n",
            "web/src/billing.ts": "import { InvoicesClient } from './gen/billing_grpc_pb'\n\nexport function client(address: string) {\n  return new InvoicesClient(address)\n}\n",
        ])
        defer { for url in [protos, app] { try? FileManager.default.removeItem(at: url) } }
        let store = try KnowledgeStore(url: nil)
        for root in [protos, app] {
            var indexer = CodeIndexer(root: root, store: store)
            indexer.readHistory = false
            _ = try await indexer.index()
        }
        func links(_ kind: String, _ service: String) async throws -> [String: Double] {
            var result: [String: Double] = [:]
            for neighbor in try await store.neighbors(service, kinds: [kind]) where neighbor.incoming {
                result[String(neighbor.node.id.split(separator: "#").last ?? "")] = neighbor.edge.weight
            }
            return result
        }
        // The Go import path names the billing package; the TypeScript client can't tell the two apart.
        #expect(try await links("implements", "grpc:acme.billing.v1.Invoices") == ["InvoiceServer": 0.9])
        #expect(try await links("implements", "grpc:acme.legacy.v1.Invoices").isEmpty)
        #expect(try await links("calls_rpc", "grpc:acme.billing.v1.Invoices") == ["client": 0.3])
        #expect(try await links("calls_rpc", "grpc:acme.legacy.v1.Invoices") == ["client": 0.3])
        #expect(try await store.node("grpc:acme.billing.v1.Invoices/GetInvoice")?.signature == "rpc GetInvoice(GetInvoiceRequest) returns (Invoice)")

        try await store.removeRepo("repo:" + protos.path)
        try await ServiceLinks.link(store: store)
        #expect(try await store.node("grpc:acme.billing.v1.Invoices") == nil)
        #expect(try await store.node("proto:acme.billing.v1.Invoice") == nil)
    }

    // MARK: GraphQL

    @Test func readsGraphQLSchemasAndResolvers() throws {
        let root = try makeFixtureRepo([
            "graph/schema.graphqls": #"""
                """The root."""
                schema { query: RootQuery mutation: Mutation }

                directive @auth(role: String) repeatable on FIELD_DEFINITION | OBJECT

                # Invoices
                type RootQuery {
                  "One invoice"
                  invoice(id: ID!): Invoice @auth(role: "user")
                  invoices(first: Int = 20, filter: InvoiceFilter = { status: [PAID] }): [Invoice!]!
                }

                type Mutation {
                  payInvoice(input: PayInput!): Invoice
                }

                type Invoice implements Node & Timestamped @key(fields: "id") {
                  id: ID!
                  total: Int
                  status: Status
                }

                input PayInput { id: ID!, cents: Int = 0 }
                enum Status { DRAFT PAID @deprecated(reason: "no") VOID }
                union SearchResult = | Invoice | Customer
                scalar Time
                extend type RootQuery { me: User }

                query Ignored($id: ID!) { invoice(id: $id) { id } }
                """#,
            "server/schema.ts": """
                import { gql } from 'graphql-tag'
                import * as plans from './plans'

                export const typeDefs = gql`
                  type Query {
                    plans: [Plan!]!
                    plan(id: ID!): Plan
                  }
                  type Plan { id: ID! name: String }
                `

                export const resolvers = {
                  Query: {
                    plans: async () => listPlans(),
                    plan: plans.getPlan,
                  },
                }
                """,
            "graph/schema.resolvers.go": """
                package graph

                func (r *queryResolver) InvoiceByID(ctx context.Context, id string) (*model.Invoice, error) {
                \treturn nil, nil
                }

                func (r *mutationResolver) PayInvoice(ctx context.Context, input model.PayInput) (*model.Invoice, error) {
                \treturn nil, nil
                }

                func (r *invoiceResolver) Total(ctx context.Context, obj *model.Invoice) (int, error) { return 0, nil }
                """,
            "src/invoices.resolver.ts": """
                import { Resolver, Query, Mutation, Args } from '@nestjs/graphql'

                @Resolver(() => Invoice)
                export class InvoicesResolver {
                  @Query(() => [Invoice], { name: 'allInvoices' })
                  findAll() {
                    return []
                  }

                  @Mutation(() => Invoice)
                  async voidInvoice(@Args('id') id: string) {
                    return null
                  }
                }
                """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        func nodes(_ path: String) throws -> [String: String] {
            Dictionary(GraphQLExtractor().extract(try extractionInput(root, path)).nodes.map { ($0.id, $0.signature) }, uniquingKeysWith: { a, _ in a })
        }
        #expect(try nodes("graph/schema.graphqls") == [
            "graphql:RootQuery": "type RootQuery { invoice, invoices }",
            "graphql:RootQuery.invoice": "RootQuery.invoice(id: ID!): Invoice",
            "graphql:RootQuery.invoices": "RootQuery.invoices(first: Int, filter: InvoiceFilter): [Invoice!]!",
            "graphql:RootQuery.me": "RootQuery.me: User",
            "graphql:Mutation": "type Mutation { payInvoice }",
            "graphql:Mutation.payInvoice": "Mutation.payInvoice(input: PayInput!): Invoice",
            "graphql:Invoice": "type Invoice implements Node & Timestamped { id, total, status }",
            "graphql:PayInput": "input PayInput { id, cents }",
            "graphql:Status": "enum Status { DRAFT, PAID, VOID }",
            "graphql:SearchResult": "union SearchResult = Invoice | Customer",
            "graphql:Time": "scalar Time",
        ])
        let script = GraphQLExtractor().extract(try extractionInput(root, "server/schema.ts"))
        #expect(Set(script.nodes.map(\.id)) == ["graphql:Query", "graphql:Query.plans", "graphql:Query.plan", "graphql:Plan"])
        #expect(script.nodes.first { $0.id == "graphql:Query.plans" }?.line == 6)
        #expect(script.refs.map { "\($0.src) \($0.names)" } == [#"graphql:Query.plan ["plans.getPlan", "getPlan"]"#])

        let go = GraphQLExtractor().extract(try extractionInput(root, "graph/schema.resolvers.go")).edges.map { "\($0.src) → \($0.dst.split(separator: "#").last ?? "")" }
        #expect(go == ["graphql:Query.invoiceByID → queryResolver.InvoiceByID", "graphql:Mutation.payInvoice → mutationResolver.PayInvoice"])

        let nest = GraphQLExtractor().extract(try extractionInput(root, "src/invoices.resolver.ts"))
        #expect(nest.nodes.map(\.signature) == ["Query.allInvoices: [Invoice] → InvoicesResolver.findAll", "Mutation.voidInvoice: Invoice → InvoicesResolver.voidInvoice"])
        #expect(nest.edges.filter { $0.kind == "handled_by" }.map { $0.dst.split(separator: "#").last ?? "" } == ["InvoicesResolver.findAll", "InvoicesResolver.voidInvoice"])
    }

    // MARK: Messaging

    @Test func findsTopicsWithTheirPublishersAndConsumers() throws {
        let root = try makeFixtureRepo([
            "go.mod": "module example.com/acme\n",
            "events/publisher.go": """
                package events

                import (
                \t"cloud.google.com/go/pubsub/v2"
                \t"github.com/aws/aws-sdk-go-v2/aws"
                \t"github.com/aws/aws-sdk-go-v2/service/sqs"
                \t"github.com/segmentio/kafka-go"
                )

                const invoicesTopic = "invoices"

                type Config struct {
                \tRefundsTopic string `env:"REFUNDS_TOPIC" envDefault:"refunds"`
                \tAuditTopic   string `env:"AUDIT_TOPIC"`
                \tQueueURL     string `env:"JOBS_QUEUE_URL"`
                }

                func Publish(client *pubsub.Client) {
                \tclient.Publisher(invoicesTopic).Publish(ctx, msg)
                \tclient.Publisher("projects/acme/topics/payments")
                }

                func Listen(client *pubsub.Client) {
                \tsub := client.Subscriber("invoices-sub")
                \t_ = sub
                }

                func Writers(cfg Config) *kafka.Writer {
                \ttopic := cfg.RefundsTopic
                \t_ = &kafka.Writer{Addr: kafka.TCP("broker:9092"), Topic: topic}
                \treturn &kafka.Writer{Topic: cfg.AuditTopic}
                }

                func Read() *kafka.Reader {
                \treturn kafka.NewReader(kafka.ReaderConfig{Brokers: []string{"broker:9092"}, GroupID: "billing", Topic: "user-events"})
                }

                func Poll(client *sqs.Client, cfg Config) {
                \tclient.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{QueueUrl: aws.String(cfg.QueueURL)})
                \tclient.SendMessage(ctx, &sqs.SendMessageInput{QueueUrl: aws.String("https://sqs.eu-west-1.amazonaws.com/123456789012/emails")})
                }
                """,
            "web/src/events.ts": """
                import { Kafka } from 'kafkajs'
                import { PubSub } from '@google-cloud/pubsub'
                import { SQSClient, SendMessageCommand } from '@aws-sdk/client-sqs'

                const TOPIC = process.env.ORDERS_TOPIC ?? 'orders'

                export async function publishOrder(producer, order) {
                  await producer.send({ topic: TOPIC, messages: [{ value: JSON.stringify(order) }] })
                }

                export async function consume(consumer) {
                  await consumer.subscribe({ topics: ['orders', 'refunds'], fromBeginning: false })
                }

                export function notify(pubsub: PubSub) {
                  return pubsub.topic('notifications').publishMessage({ data })
                }

                export function enqueue(sqs: SQSClient) {
                  return sqs.send(new SendMessageCommand({ QueueUrl: process.env.EMAILS_QUEUE_URL, MessageBody: 'x' }))
                }
                """,
            "jobs/worker.py": """
                import os
                import boto3
                from kafka import KafkaConsumer, KafkaProducer
                from google.cloud import pubsub_v1

                TOPIC = os.getenv("EVENTS_TOPIC", "user-events")


                def consume():
                    consumer = KafkaConsumer(TOPIC, "audit", bootstrap_servers="broker:9092", group_id="jobs")
                    return consumer


                def produce(producer):
                    producer.send("refunds", b"{}")


                def subscribe(subscriber):
                    path = subscriber.subscription_path("acme", "invoices-sub")
                    return path


                def poll(sqs):
                    return sqs.receive_message(QueueUrl=os.environ["JOBS_QUEUE_URL"], MaxNumberOfMessages=10)
                """,
            "infra/pubsub.tf": """
                resource "google_pubsub_topic" "invoices" {
                  name = "invoices"
                }

                resource "google_pubsub_subscription" "billing" {
                  name  = "invoices-billing"
                  topic = google_pubsub_topic.invoices.name
                }

                resource "aws_sqs_queue" "emails" {
                  name = "emails-${var.env}"
                }
                """,
            "deploy/topics.yaml": """
                apiVersion: kafka.strimzi.io/v1beta2
                kind: KafkaTopic
                metadata:
                  name: user-events-topic
                  labels:
                    strimzi.io/cluster: main
                spec:
                  topicName: user-events
                ---
                apiVersion: pubsub.cnrm.cloud.google.com/v1beta1
                kind: PubSubSubscription
                metadata:
                  name: payments-sub
                spec:
                  topicRef:
                    name: payments
                """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        func uses(_ path: String) throws -> Set<String> {
            Set(MessagingExtractor().extract(try extractionInput(root, path)).edges.map { "\($0.src.split(separator: "#").last ?? "") \($0.kind) \($0.dst)" })
        }
        let go = try uses("events/publisher.go")
        #expect(go == [
            "Publish publishes topic:pubsub:invoices", "Publish publishes topic:pubsub:payments",
            "Listen consumes topic:pubsub:invoices-sub",
            "Writers publishes topic:kafka:refunds", "Writers publishes topic:kafka:$AUDIT_TOPIC",
            "Read consumes topic:kafka:user-events",
            "Poll consumes topic:sqs:$JOBS_QUEUE_URL", "Poll publishes topic:sqs:emails",
        ])
        let script = try uses("web/src/events.ts")
        #expect(script == [
            "publishOrder publishes topic:kafka:orders", "consume consumes topic:kafka:orders", "consume consumes topic:kafka:refunds",
            "notify publishes topic:pubsub:notifications", "enqueue publishes topic:sqs:$EMAILS_QUEUE_URL",
        ])
        let python = try uses("jobs/worker.py")
        #expect(python == [
            "consume consumes topic:kafka:user-events", "consume consumes topic:kafka:audit", "produce publishes topic:kafka:refunds",
            "subscribe consumes topic:pubsub:invoices-sub", "poll consumes topic:sqs:$JOBS_QUEUE_URL",
        ])
        let nodes = MessagingExtractor().extract(try extractionInput(root, "events/publisher.go")).nodes
        #expect(nodes.first { $0.id == "topic:pubsub:invoices-sub" }?.signature == "Pub/Sub subscription invoices-sub")
        #expect(nodes.first { $0.id == "topic:kafka:$AUDIT_TOPIC" }?.signature == "Kafka topic named by the environment variable AUDIT_TOPIC")

        let terraform = MessagingExtractor().extract(try extractionInput(root, "infra/pubsub.tf"))
        #expect(Set(terraform.nodes.map(\.id)) == ["topic:pubsub:invoices", "topic:pubsub:invoices-billing", "topic:sqs:emails-{}"])
        #expect(terraform.edges.contains(KnowledgeEdge(src: "topic:pubsub:invoices-billing", dst: "topic:pubsub:invoices", kind: "consumes")))
        let manifests = MessagingExtractor().extract(try extractionInput(root, "deploy/topics.yaml"))
        #expect(manifests.nodes.map(\.id) == ["topic:kafka:user-events", "topic:pubsub:payments-sub"])
        #expect(manifests.edges.contains(KnowledgeEdge(src: "topic:pubsub:payments-sub", dst: "topic:pubsub:payments", kind: "consumes")))

        let topics = [MessagingExtractor.node(system: "pubsub", name: "invoices"), MessagingExtractor.node(system: "pubsub", name: "invoices-sub", subscription: true),
                      MessagingExtractor.node(system: "pubsub", name: "payments-sub", subscription: true), MessagingExtractor.node(system: "pubsub", name: "payments")]
        #expect(ServiceLinks.subscriptionTopics(topics, declared: ["topic:pubsub:payments-sub"]).map { "\($0.src) \($0.dst) \($0.weight)" }
                == ["topic:pubsub:invoices-sub topic:pubsub:invoices 0.6"])
    }

    // MARK: Databases

    @Test func readsTheTablesOfSQLStatements() {
        func tables(_ sql: String) -> [String] {
            let found = SQLQuery.tables(sql)
            return found.reads.map { "r " + $0 } + found.writes.map { "w " + $0 }
        }
        #expect(tables("SELECT a.id FROM accounts a, billing.invoices i JOIN \"Plans\" p ON p.id = i.plan_id WHERE a.id = $1") == ["r accounts", "r billing.invoices", "r Plans"])
        #expect(tables("WITH recent AS (SELECT * FROM invoices) SELECT extract(day FROM created_at) FROM recent, generate_series(1, 3)") == ["r invoices"])
        #expect(tables("INSERT INTO invoices (id) VALUES ($1) ON CONFLICT (id) DO UPDATE SET total = excluded.total") == ["w invoices"])
        #expect(tables("DELETE FROM invoices USING customers WHERE customers.id = invoices.customer_id AND a IS DISTINCT FROM b") == ["r customers", "w invoices"])
        #expect(tables("UPDATE invoices i SET total = 0 FROM (SELECT id FROM refunds) r WHERE r.id = i.id; TRUNCATE audit") == ["r refunds", "w invoices", "w audit"])
        #expect(tables("select name from users -- FROM ignored\n where id = 'FROM x'") == ["r users"])
        #expect(tables("SELECT id FROM profiles WHERE deleted_at < @from LIMIT @limit") == ["r profiles"])
        #expect(SQLInCode.looksLikeSQL("select * from users where id = $1") && !SQLInCode.looksLikeSQL("Select a file from the list"))
        #expect(DatabaseExtractor.isDownMigration("db/1_init.down.sql") && DatabaseExtractor.isDownMigration("sql/U2__undo.sql") && !DatabaseExtractor.isDownMigration("sql/V2__add.sql"))
        #expect(TableModels.snake("UserID") == "user_id" && TableModels.snake("HTTPCode") == "http_code" && TableModels.snake("LineItem") == "line_item")
    }

    /// Migrations (in numeric order, a down migration among them), ORM models of each framework
    /// and SQL in Go, TypeScript and Python.
    private func makeDatabaseRepo() throws -> URL {
        try makeFixtureRepo([
            "go.mod": "module example.com/billing\n",
            "db/migrations/1_init.up.sql": """
                -- billing schema
                SET search_path TO "$user", billing, public;

                CREATE TABLE IF NOT EXISTS invoices (
                    id BIGSERIAL PRIMARY KEY,
                    customer_id BIGINT NOT NULL,
                    total NUMERIC(10, 2) DEFAULT 0,
                    note TEXT,
                    CONSTRAINT invoices_total_check CHECK (total >= 0)
                );

                CREATE UNIQUE INDEX IF NOT EXISTS invoices_customer_idx ON invoices (customer_id, lower(note));

                CREATE TABLE legacy_payments (id INT);

                CREATE FUNCTION touch() RETURNS trigger AS $$
                BEGIN
                  UPDATE invoices SET total = 0;
                  RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;

                CREATE USER MAPPING FOR app SERVER remote OPTIONS (user 'app', password 'hunter2');
                """,
            "db/migrations/1_init.down.sql": "DROP TABLE billing.invoices;\n",
            "db/migrations/2_currency.up.sql": """
                ALTER TABLE billing.invoices ADD COLUMN currency TEXT NOT NULL DEFAULT 'EUR', DROP COLUMN note;
                ALTER TABLE billing.invoices RENAME COLUMN total TO amount;
                DROP TABLE IF EXISTS billing.legacy_payments;
                INSERT INTO billing.currencies (code) VALUES ('EUR');
                """,
            "db/migrations/10_status.up.sql": """
                ALTER TABLE billing.invoices ADD status TEXT;
                CREATE VIEW billing.open_invoices AS
                  SELECT i.id, i.amount AS due, c.name FROM billing.invoices i JOIN billing.customers c ON c.id = i.customer_id WHERE status = 'open';
                """,
            "prisma/schema.prisma": """
                enum Status {
                  OPEN
                  PAID
                }

                model Customer {
                  id        Int       @id @default(autoincrement())
                  email     String    @unique @map("email_address")
                  status    Status
                  invoices  Invoice[]
                  createdAt DateTime  @default(now())

                  @@map("customers")
                  @@schema("billing")
                }
                """,
            "shop/models.py": """
                from django.db import models


                class Order(models.Model):
                    customer = models.ForeignKey("Customer", on_delete=models.CASCADE)
                    total = models.DecimalField(max_digits=10, decimal_places=2)
                    tags = models.ManyToManyField("Tag")

                    class Meta:
                        ordering = ["-id"]


                class Base(models.Model):
                    class Meta:
                        abstract = True
                """,
            "reports/tables.py": """
                from sqlalchemy import Column, Integer, String, Table, MetaData
                from sqlalchemy.orm import Mapped, mapped_column


                class Report(Base):
                    __tablename__ = "reports"
                    __table_args__ = {"schema": "analytics"}

                    id: Mapped[int] = mapped_column(primary_key=True)
                    title = Column("report_title", String)


                audit = Table("audit_log", metadata, Column("id", Integer), Column("action", String), schema="analytics")
                """,
            "web/src/entities/refund.ts": """
                import { Entity, Column, PrimaryGeneratedColumn, ManyToOne, JoinColumn } from 'typeorm'

                @Entity({ name: 'refunds', schema: 'billing' })
                export class Refund {
                  @PrimaryGeneratedColumn()
                  id: number

                  @Column({ name: 'amount_cents' })
                  amountCents: number

                  @Column()
                  reason?: string

                  @ManyToOne(() => Invoice)
                  @JoinColumn({ name: 'invoice_id' })
                  invoice: Invoice
                }

                @Entity()
                export class LineItem {
                  @PrimaryGeneratedColumn('uuid')
                  id: string
                }
                """,
            "internal/store/payment.go": """
                package store

                import "gorm.io/gorm"

                type Payment struct {
                \tgorm.Model
                \tInvoiceID   uint
                \tAmountCents int64 `gorm:"column:amount"`
                \tNotes       []Note
                \tSecret      string `gorm:"-"`
                }

                func (Payment) TableName() string { return "billing.payments" }
                """,
            "internal/store/queries.go": """
                package store

                const listInvoices = `
                \tSELECT i.id, c.email_address
                \tFROM invoices i
                \tJOIN billing.customers c ON c.id = i.customer_id
                \tWHERE i.status = $1`

                func ListInvoices(db *sql.DB) error {
                \t_, err := db.Query(listInvoices, "open")
                \treturn err
                }

                func MarkPaid(db *sql.DB, id int64) error {
                \t_, err := db.Exec("UPDATE invoices SET status = 'paid' WHERE id = $1", id)
                \treturn err
                }

                func Totals(db *sql.DB) error {
                \t_, err := db.Query(`WITH recent AS (SELECT * FROM invoices) SELECT count(*) FROM recent, billing.payments p`)
                \treturn err
                }
                """,
            "web/src/db.ts": """
                export async function refundsFor(pool, invoiceId) {
                  return pool.query('select * from billing.refunds where invoice_id = $1', [invoiceId])
                }

                export function label() {
                  return "Select a file from the list"
                }
                """,
            "jobs/report.py": #"""
                def archive(cursor):
                    cursor.execute("""
                        INSERT INTO analytics.audit_log (id, action)
                        SELECT id, 'archive' FROM reports
                    """)
                """#,
        ])
    }

    @Test func replaysMigrationsAndReadsModels() async throws {
        let root = try makeDatabaseRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        var indexer = CodeIndexer(root: root, store: store)
        indexer.readHistory = false
        _ = try await indexer.index()

        // 10_status runs after 2_currency; the down migration and the function body don't count.
        let invoices = try #require(try await store.node("table:billing.invoices"))
        #expect(invoices.signature == "table billing.invoices (id, customer_id, amount, currency, status)")
        #expect(invoices.summary == "Created in db/migrations/1_init.up.sql, changed by 2 more migrations. Indexes: invoices_customer_idx (customer_id, lower(note), unique).")
        #expect(invoices.path == "db/migrations/1_init.up.sql" && invoices.line == 4 && invoices.repo.isEmpty)
        let migrations = try await store.neighbors(invoices.id, kinds: ["migrates"]).filter(\.incoming).map(\.node.path).sorted()
        #expect(migrations == ["db/migrations/10_status.up.sql", "db/migrations/1_init.up.sql", "db/migrations/2_currency.up.sql"])
        #expect(try await store.node("table:billing.legacy_payments")?.signature == "table billing.legacy_payments, dropped in db/migrations/2_currency.up.sql")
        #expect(try await store.node("table:billing.open_invoices")?.signature == "view billing.open_invoices (id, due, name)")

        // Models: Prisma, Django, SQLAlchemy (declarative and Core), TypeORM, GORM.
        let models: [String: String] = [
            "table:billing.customers": "table billing.customers (id, email_address, status, createdAt)",
            "table:public.shop_order": "table public.shop_order (id, customer_id, total)",
            "table:analytics.reports": "table analytics.reports (id, report_title)",
            "table:analytics.audit_log": "table analytics.audit_log (id, action)",
            "table:billing.refunds": "table billing.refunds (id, amount_cents, reason, invoice_id)",
            "table:public.line_item": "table public.line_item (id)",
            "table:billing.payments": "table billing.payments (id, created_at, updated_at, deleted_at, invoice_id, amount)",
        ]
        for (id, signature) in models { #expect(try await store.node(id)?.signature == signature) }
        #expect(try await store.node("table:public.base") == nil)
        let customers = try #require(try await store.node("table:billing.customers"))
        #expect(customers.language == "prisma" && customers.summary == "prisma model Customer in prisma/schema.prisma." && customers.path == "prisma/schema.prisma")

        // Only identifiers are kept: no SQL text, no credentials.
        let everything = try await store.nodes("SELECT * FROM nodes", []).flatMap { [$0.signature, $0.summary] }
            + (try await store.refs(repo: indexer.repoID)).flatMap(\.ref.names)
        #expect(!everything.contains { $0.contains("hunter2") || $0.contains("WHERE") || $0.contains("$1") })
    }

    @Test func linksSQLInCodeToItsTables() async throws {
        let root = try makeDatabaseRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        var indexer = CodeIndexer(root: root, store: store)
        indexer.readHistory = false
        _ = try await indexer.index()

        func accesses(_ table: String) async throws -> Set<String> {
            Set(try await store.neighbors(table, kinds: ["reads_table", "writes_table"]).filter(\.incoming).map { neighbor in
                let who = switch neighbor.node.kind {
                case "symbol": String(neighbor.node.id.split(separator: "#").last ?? "")
                case "table": neighbor.node.name
                default: neighbor.node.path
                }
                return "\(who) \(neighbor.edge.kind) \(neighbor.edge.weight)"
            })
        }
        // A bare name is the one table of that name the repository migrates or models.
        #expect(try await accesses("table:billing.invoices") == [
            "ListInvoices reads_table 0.9", "MarkPaid writes_table 0.9", "Totals reads_table 0.9", "open_invoices reads_table 1.0",
        ])
        #expect(try await accesses("table:billing.customers") == ["ListInvoices reads_table 1.0", "open_invoices reads_table 1.0"])
        #expect(try await accesses("table:billing.payments") == ["Totals reads_table 1.0"])
        #expect(try await accesses("table:billing.refunds") == ["refundsFor reads_table 1.0"])
        #expect(try await accesses("table:analytics.audit_log") == ["archive writes_table 1.0"])
        #expect(try await accesses("table:analytics.reports") == ["archive reads_table 0.9"])
        // Written by a migration, defined nowhere: a placeholder.
        #expect(try await accesses("table:billing.currencies") == ["db/migrations/2_currency.up.sql writes_table 1.0"])
        #expect(try await store.node("table:billing.currencies")?.signature == "table billing.currencies")
        let label = try await store.nodes("SELECT * FROM nodes WHERE id LIKE 'table:%the%'", [])
        #expect(label.isEmpty)
    }

    /// A billing repository serving a gRPC service, publishing a topic and migrating a table; a
    /// notifier in another repository calling, consuming and reading them.
    @Test func dashiiMapsRPCsTopicsAndTablesAcrossRepositories() async throws {
        let billing = try makeFixtureRepo([
            "go.mod": "module example.com/billing\n",
            "billing-api/Dockerfile": "FROM golang:1.23\n",
            "proto/acme/billing/v1/billing.proto": Self.billingProto,
            "db/migrations/1_init.up.sql": "CREATE TABLE billing.invoices (id BIGINT, total NUMERIC);\n",
            "billing-api/server.go": """
                package main

                import (
                \t"cloud.google.com/go/pubsub/v2"
                \tbillingv1 "example.com/billing/gen/acme/billing/v1"
                \t"google.golang.org/grpc"
                )

                func main() {
                \tserver := grpc.NewServer()
                \tbillingv1.RegisterInvoicesServer(server, &invoices{})
                }

                func PublishPaid(client *pubsub.Client) {
                \tclient.Publisher("invoice-events")
                }

                func Load(db *sql.DB) {
                \tdb.Query("SELECT id FROM invoices WHERE id = $1", 1)
                }
                """,
        ])
        let notifier = try makeFixtureRepo([
            "go.mod": "module example.com/notifier\n",
            "notifier/Dockerfile": "FROM golang:1.23\n",
            "notifier/main.go": """
                package main

                import (
                \t"cloud.google.com/go/pubsub/v2"
                \tbillingv1 "example.com/billing/gen/acme/billing/v1"
                )

                func Listen(client *pubsub.Client) {
                \tclient.Subscriber("invoice-events-sub")
                }

                func Fetch(conn *grpc.ClientConn) {
                \tbillingv1.NewInvoicesClient(conn)
                }

                func Report(db *sql.DB) {
                \tdb.Query("SELECT count(*) FROM invoices")
                }
                """,
        ])
        defer { for url in [billing, notifier] { try? FileManager.default.removeItem(at: url) } }
        let knowledge = KnowledgeExtension(defaults: UserDefaults(suiteName: "kx-\(UUID())")!, url: nil)
        let store = try #require(knowledge.store)
        for root in [billing, notifier] { _ = try await KnowledgeExtension.index(root.path, store: store, history: false) }
        let (billingName, notifierName) = (billing.lastPathComponent, notifier.lastPathComponent)
        let search = try #require(knowledge.tools.first { $0.name == "knowledge_search" })
        let tables = try await search.run(["query": "invoices", "kind": "table"])
        #expect(tables.array?.first?["id"]?.string == "table:billing.invoices")
        let tool = try #require(knowledge.tools.first { $0.name == "knowledge_service_map" })
        func entry(_ list: JSONValue?, _ key: String, _ value: String) -> JSONValue? { list?.array?.first { $0[key]?.string == value } }

        let server = try await tool.run(["name": .string(billing.path)])
        #expect(server["implements"] == [["rpc_service": "acme.billing.v1.Invoices", "confidence": 0.9, "from": ["main at billing-api/server.go:9"], "methods": "GetInvoice, Watch"]])
        let fetched: JSONValue = [.string("Fetch at \(notifierName)/notifier/main.go:12")]
        #expect(entry(server["called_by"], "rpc_service", "acme.billing.v1.Invoices")?["from"] == fetched)
        let consumed: JSONValue = [.string("Listen at \(notifierName)/notifier/main.go:8")]
        #expect(server["publishes"] == [["topic": "pubsub:invoice-events", "from": ["PublishPaid at billing-api/server.go:14"], "consumed_by": consumed]])
        #expect(server["tables"] == [["table": "billing.invoices", "reads": ["Load at billing-api/server.go:18"], "migrated_by": ["db/migrations/1_init.up.sql"], "confidence": 0.9]])

        let client = try await tool.run(["name": .string(notifier.path)])
        #expect(entry(client["calls"], "rpc_service", "acme.billing.v1.Invoices")?["answered_by"] == [.string(billingName)])
        let published: JSONValue = [.string("PublishPaid at \(billingName)/billing-api/server.go:14")]
        #expect(client["consumes"] == [["topic": "pubsub:invoice-events-sub", "from": ["Listen at notifier/main.go:8"], "published_by": published]])
        #expect(client["tables"] == [["table": "billing.invoices", "reads": ["Report at notifier/main.go:16"], "confidence": 0.6]])
        #expect(client["implements"] == nil && client["publishes"] == nil)
    }

    @Test func dashiiFindsServicesAndEndpoints() async throws {
        let root = try makeFixtureRepo([
            "billing-api/Dockerfile": "FROM golang:1.23\n",
            "billing-api/main.go": "package main\n\nimport \"github.com/go-chi/chi/v5\"\n\nfunc main() {\n\tr := chi.NewRouter()\n\tr.Post(\"/refunds\", issueRefund)\n}\n\nfunc issueRefund() {}\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let knowledge = KnowledgeExtension(defaults: UserDefaults(suiteName: "kx-\(UUID())")!, url: nil)
        let store = try #require(knowledge.store)
        _ = try await KnowledgeExtension.index(root.path, store: store, history: false)
        func tool(_ name: String) throws -> DashiiTool { try #require(knowledge.tools.first { $0.name == name }) }

        let endpoints = try await tool("knowledge_search").run(["query": "refunds", "kind": "endpoint"])
        #expect(endpoints.array?.map { $0["id"]?.string } == ["endpoint:POST /refunds"])
        let services = try await tool("knowledge_search").run(["query": "billing-api", "kind": "service"])
        #expect(services.array?.first?["kind"] == "service")
        let context = try await tool("knowledge_context").run(["question": "refunds"])
        #expect(context["matches"]?.array?.first?["id"] == "endpoint:POST /refunds")
        #expect(KnowledgeView.kinds.contains("service") && KnowledgeView.kinds.contains("endpoint"))
    }

    @Test func readsOpenAPIDocuments() throws {
        let root = try makeFixtureRepo([
            "api/openapi.yaml": """
                openapi: 3.0.3
                info:
                  title: Billing API
                  description: "Invoices: create and read"
                servers:
                  - url: https://{env}.acme.test/billing/
                    variables:
                      env:
                        default: api
                paths:
                  /invoices:
                    parameters:
                      - $ref: '#/components/parameters/Tenant'
                    get:
                      summary: List invoices
                      operationId: listInvoices
                    post:
                      operationId: CreateInvoice # generated
                  "/invoices/{invoiceId}":
                    get:
                      responses:
                        "200":
                          description: ok
                    x-internal: true
                  /invoices/{invoiceId}:void:
                    post:
                      operationId: voidInvoice
                components:
                  schemas:
                    Invoice:
                      type: object
                """,
            "api/swagger.json": #"""
                {"swagger": "2.0", "basePath": "/v1", "paths": {
                  "/plans/{id}": {"get": {"operationId": "getPlan"}, "delete": {}},
                  "/plans": {"post": {"operationId": "createPlan"}}
                }}
                """#,
            "deploy/deployment.yaml": "kind: Deployment\nmetadata:\n  name: billing-api\nspec:\n  template:\n    spec:\n      containers: []\n",
            "web/package.json": #"{"name": "web", "paths": {"/x": {}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        func operations(_ path: String) throws -> [String: String] {
            let extraction = OpenAPIExtractor().extract(try extractionInput(root, path))
            var result: [String: String] = [:]
            for node in extraction.nodes {
                result[String(node.id.dropFirst("endpoint:".count))] = extraction.refs.first { $0.src == node.id }?.names.joined(separator: " ") ?? ""
            }
            return result
        }
        #expect(try operations("api/openapi.yaml") == [
            "GET /billing/invoices": "listInvoices ListInvoices", "POST /billing/invoices": "CreateInvoice",
            "GET /billing/invoices/{}": "", "POST /billing/invoices/{}:void": "voidInvoice VoidInvoice",
        ])
        #expect(try operations("api/swagger.json") == ["GET /v1/plans/{}": "getPlan GetPlan", "DELETE /v1/plans/{}": "", "POST /v1/plans": "createPlan CreatePlan"])
        #expect(try operations("deploy/deployment.yaml").isEmpty && operations("web/package.json").isEmpty)

        let list = try #require(OpenAPIExtractor().extract(try extractionInput(root, "api/openapi.yaml")).nodes.first { $0.id == "endpoint:GET /billing/invoices" })
        #expect(list.language == "openapi" && list.signature == "GET /billing/invoices → listInvoices")
        #expect(OpenAPIExtractor.yaml("openapi: 3.0.0\npaths:\n  /a:\n    get:\n      operationId: a\n")?.first?.line == 4)
        #expect(OpenAPIExtractor.serverPath("/") == "" && OpenAPIExtractor.serverPath("http://localhost:8080") == "")
    }

    @Test func linksEndpointsToHandlersAndServices() async throws {
        let root = try makeFixtureRepo([
            "go.mod": "module example.com/acme\n",
            "apps/billing-api/Dockerfile": "FROM golang:1.23\n",
            "apps/billing-api/main.go": """
                package main

                import "github.com/go-chi/chi/v5"

                func main() {
                \tr := chi.NewRouter()
                \tr.Get("/invoices/{id}", handlers.ShowInvoice)
                \tr.Post("/invoices", handlers.CreateInvoice)
                }
                """,
            "apps/billing-api/handlers/invoices.go": "package handlers\n\nfunc ShowInvoice(w http.ResponseWriter, r *http.Request) {}\n\nfunc CreateInvoice(w http.ResponseWriter, r *http.Request) {}\n",
            "apps/billing-api/helm/Chart.yaml": "apiVersion: v2\nname: billing-api\nversion: 0.1.0\n",
            "apps/billing-api/api/openapi.yaml": """
                openapi: 3.1.0
                paths:
                  /invoices:
                    post:
                      operationId: createInvoice
                  /invoices/{id}/pdf:
                    get:
                      operationId: downloadInvoicePdf
                """,
            "web/package.json": #"{"name": "web", "scripts": {"start": "next start"}}"#,
            "web/pages/api/ping.ts": "export default function handler(req, res) {\n  res.json({})\n}\n",
            "scripts/serve.py": "from flask import Flask\n\napp = Flask(__name__)\n\n@app.get(\"/metrics\")\ndef metrics():\n    return \"\"\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        var indexer = CodeIndexer(root: root, store: store)
        indexer.readHistory = false
        _ = try await indexer.index()
        let repo = indexer.repoID

        let show = try await store.neighbors(EndpointExtractor.id(method: "GET", path: "/invoices/{}"))
        #expect(show.contains { $0.edge.kind == "handled_by" && $0.node.id == "sym:\(root.path)/apps/billing-api/handlers/invoices.go#ShowInvoice" })
        #expect(show.contains { $0.edge.kind == "defined_in" && $0.node.id == indexer.fileID("apps/billing-api/main.go") })
        func exposed(_ service: String) async throws -> Set<String> {
            Set(try await store.neighbors(ServiceExtractor.id(repo: repo, name: service), kinds: ["exposes"]).filter { !$0.incoming }.map(\.node.id))
        }
        #expect(try await exposed("billing-api") == ["endpoint:GET /invoices/{}", "endpoint:POST /invoices", "endpoint:GET /invoices/{}/pdf"])
        #expect(try await store.neighbors(repo, kinds: ["deploys"]).map(\.node.name).sorted() == ["billing-api", "web"])
        // Declared in code and in the spec: one node, defined in both, one handler.
        let create = try await store.neighbors("endpoint:POST /invoices")
        #expect(Set(create.filter { $0.edge.kind == "defined_in" }.map(\.node.id))
            == [indexer.fileID("apps/billing-api/main.go"), indexer.fileID("apps/billing-api/api/openapi.yaml")])
        #expect(create.filter { $0.edge.kind == "handled_by" }.map(\.node.id) == ["sym:\(root.path)/apps/billing-api/handlers/invoices.go#CreateInvoice"])
        #expect(try await store.neighbors("endpoint:GET /invoices/{}/pdf", kinds: ["handled_by"]).isEmpty)
        // Endpoints outside any service folder are nobody's when there are several services.
        #expect(try await exposed("web") == ["endpoint:ANY /api/ping"])
        let ping = try await store.neighbors("endpoint:ANY /api/ping", kinds: ["handled_by"])
        #expect(ping.first?.node.id == "sym:\(root.path)/web/pages/api/ping.ts#handler" && ping.first?.edge.weight == 1)
        #expect(try await store.node("endpoint:GET /metrics") != nil)
        #expect(try await store.search("invoices", kinds: ["endpoint"]).count == 3)

        // A route that goes takes its endpoint, handler edge and exposure with it.
        try "package main\n\nimport \"github.com/go-chi/chi/v5\"\n\nfunc main() {\n\tr := chi.NewRouter()\n\tr.Post(\"/invoices\", handlers.CreateInvoice)\n}\n"
            .write(to: root.appending(path: "apps/billing-api/main.go"), atomically: true, encoding: .utf8)
        _ = try await indexer.index()
        #expect(try await store.node("endpoint:GET /invoices/{}") == nil)
        #expect(try await exposed("billing-api") == ["endpoint:POST /invoices", "endpoint:GET /invoices/{}/pdf"])
    }
}

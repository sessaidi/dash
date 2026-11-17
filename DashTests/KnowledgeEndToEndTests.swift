import DashKit
import Foundation
import Testing
@testable import Dash

/// A monorepo (a Go service with routes, a gRPC server, a flag, config, a migration, a proto, a
/// Helm chart, CODEOWNERS, CI and a README) and a TypeScript client in another repository, indexed
/// together: what Dashii's tools answer about them.
@MainActor
@Suite("Knowledge end to end")
struct KnowledgeEndToEndTests {
    static let shop: [String: String] = [
        "go.mod": "module example.com/shop\n\nrequire (\n\tgithub.com/go-chi/chi/v5 v5.0.12\n\tgithub.com/launchdarkly/go-server-sdk/v7 v7.4.0\n)\n",
        "billing-api/Dockerfile": "FROM golang:1.23 AS build\nFROM gcr.io/distroless/base\nEXPOSE 8080\nENTRYPOINT [\"/billing-api\"]\n",
        "billing-api/main.go": """
            package main

            import (
            \tbillingv1 "example.com/shop/gen/acme/billing/v1"
            \t"github.com/go-chi/chi/v5"
            \tld "github.com/launchdarkly/go-server-sdk/v7"
            \t"github.com/spf13/viper"
            \t"google.golang.org/grpc"
            )

            func main() {
            \tr := chi.NewRouter()
            \tr.Get("/invoices/{id}", GetInvoice)
            \tr.Post("/invoices", CreateInvoice)
            \tserver := grpc.NewServer()
            \tbillingv1.RegisterInvoicesServer(server, &invoices{})
            }

            func GetInvoice(client *ld.LDClient, db *sql.DB) {
            \tif on, _ := client.BoolVariation("billing.pdf-invoices", user, false); on {
            \t}
            \tdb.Query("SELECT id, total FROM invoices WHERE id = $1", 1)
            }

            func CreateInvoice() {
            \t_ = viper.GetString("billing.currency")
            }
            """,
        "billing-api/main_test.go": """
            package main

            import (
            \t"net/http/httptest"
            \t"testing"
            )

            func TestGetInvoice(t *testing.T) {
            \treq := httptest.NewRequest("GET", "/invoices/42", nil)
            }
            """,
        "billing-api/config/production.toml": "[billing]\ncurrency = \"EUR\"\n",
        "billing-api/README.md": "# Billing API\n\nIssues and serves invoices. Routes live in `main.go`; `GET /invoices/{id}` returns one.\n",
        "proto/acme/billing/v1/billing.proto": """
            syntax = "proto3";
            package acme.billing.v1;

            service Invoices {
              rpc GetInvoice(GetInvoiceRequest) returns (Invoice);
            }

            message GetInvoiceRequest { string id = 1; }
            message Invoice { string id = 1; int64 total = 2; }
            """,
        "db/migrations/1_init.up.sql": "CREATE TABLE invoices (id BIGINT, total NUMERIC);\n",
        "billing-api/helm/Chart.yaml": "apiVersion: v2\nname: billing-api\nversion: 0.1.0\n",
        "billing-api/helm/values.yaml": "image:\n  repository: ghcr.io/acme/billing-api\n  tag: 1.4.2\nreplicaCount: 2\nresources:\n  requests:\n    cpu: 250m\n    memory: 256Mi\nenv:\n  LOG_LEVEL: info\n",
        ".github/CODEOWNERS": "* @acme/platform\n/billing-api/ @acme/billing\n",
        ".github/workflows/deploy.yml": """
            name: deploy
            on:
              push:
                branches: [main]
            jobs:
              deploy:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - name: Deploy
                    working-directory: billing-api
                    run: helm upgrade --install billing-api helm
            """,
        "README.md": "# Shop\n\nThe shop's services.\n",
    ]

    static let storefront: [String: String] = [
        "package.json": #"{"name": "storefront", "dependencies": {"axios": "^1.7.0"}}"#,
        "src/billing.ts": "import axios from 'axios';\n\nexport async function loadInvoice(id: string) {\n  return axios.get(`${process.env.BILLING_API_URL}/invoices/${id}`);\n}\n",
    ]

    /// Both repositories indexed into one graph.
    static func indexed() async throws -> (knowledge: KnowledgeExtension, shop: URL, storefront: URL) {
        let shop = try makeFixtureRepo(Self.shop, git: true)
        let storefront = try makeFixtureRepo(Self.storefront)
        let knowledge = KnowledgeExtension(defaults: UserDefaults(suiteName: "e2e-\(UUID())")!, url: nil)
        let store = try #require(knowledge.store)
        for root in [shop, storefront] { _ = try await KnowledgeExtension.index(root.path, store: store, history: false) }
        return (knowledge, shop, storefront)
    }

    private func tool(_ name: String, _ knowledge: KnowledgeExtension) throws -> DashiiTool {
        try #require(knowledge.tools.first { $0.name == name })
    }

    @Test func theServiceMapShowsHowAServiceRunsAndWhoLooksAfterIt() async throws {
        let (knowledge, shop, storefront) = try await Self.indexed()
        defer { for root in [shop, storefront] { try? FileManager.default.removeItem(at: root) } }
        let map = try await tool("knowledge_service_map", knowledge).run(["name": "billing-api"])
        func entry(_ key: String, _ field: String, _ value: String) -> JSONValue? { map[key]?.array?.first { $0[field]?.string == value } }
        #expect(map["runs_from"] == ["billing-api"])

        #expect(entry("exposes", "endpoint", "GET /invoices/{}")?["handler"] == "GetInvoice")
        #expect(entry("called_by", "endpoint", "GET /invoices/{}")?["from"] == [.string("loadInvoice at \(storefront.lastPathComponent)/src/billing.ts:3")])
        #expect(entry("implements", "rpc_service", "acme.billing.v1.Invoices") != nil)
        #expect(entry("tables", "table", "public.invoices")?["reads"] == ["GetInvoice at billing-api/main.go:19"])
        #expect(map["flags"] == [["flag": "billing.pdf-invoices", "from": ["GetInvoice at billing-api/main.go:19"]]])
        #expect(map["config"] == [["config": "billing.currency", "from": ["CreateInvoice at billing-api/main.go:25"]]])
        let workload = try #require(map["workloads"]?.array?.first)
        #expect(workload["workload"]?.string?.hasPrefix("Deployment billing-api") == true && workload["defined_in"] == "billing-api/helm/values.yaml")
        #expect(map["ci"] == [["job": "deploy", "defined_in": ".github/workflows/deploy.yml", "deploys": true]])
        #expect(map["owners"] == [["owner": "@acme/billing", "owns": ["billing-api"]]])
        #expect(map["docs"] == [["doc": "Billing API", "path": "billing-api/README.md"]])
        #expect(map["depends_on"] == [["package": "go:github.com/go-chi/chi/v5", "version": "v5.0.12"],
                                      ["package": "go:github.com/launchdarkly/go-server-sdk/v7", "version": "v7.4.0"]])

        let client = try await tool("knowledge_service_map", knowledge).run(["name": .string(storefront.path)])
        #expect(client["depends_on"] == [["package": "javascript:axios", "version": "^1.7.0"]])
        #expect(client["owners"] == nil && client["workloads"] == nil && client["ci"] == nil)
    }
}

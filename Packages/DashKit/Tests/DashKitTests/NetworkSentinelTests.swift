import DashKitTesting
import Foundation
import Testing
@testable import DashKit

/// The sentinel blocks and reports any request a Dashii tool makes.
@MainActor
struct NetworkSentinelTests {
    @Test func blocksRequestsThroughTheConnection() async throws {
        let host = "sentinel-\(UUID().uuidString.prefix(8)).test"
        StubHTTP.serve(host, json: #"{"ok": true}"#)
        let api = TestIntegration(id: "acme", baseURL: URL(string: "https://\(host)")!)
        let live = DashiiTool(name: "acme_live", description: "Calls the API.") { _ in try await api.testConnection.get("/items?token=secret", service: "Acme") }
        let stored = DashiiTool(name: "acme_stored", description: "Reads the database.") { _ in ["items": []] }

        #expect(await NetworkSentinel.requests(running: [live, stored]) == ["acme_live: GET \(host)/items"])
        #expect(StubHTTP.requests(host).isEmpty)
        // Outside a recording the same request goes through.
        #expect(try await live.run([:]) == ["ok": true])
        #expect(StubHTTP.requests(host).count == 1)
    }

    @Test func seesCustomTransportsAndTheSharedSession() async throws {
        final class Flag: @unchecked Sendable { var sent = false }
        let flag = Flag()
        let socket = IntegrationConnection(baseURL: URL(string: "http://docker")!, transport: { request in
            flag.sent = true
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let (_, viaTransport) = await NetworkSentinel.recording { _ = try? await socket.get("/containers/json", service: "Docker") }
        #expect(viaTransport == ["GET docker/containers/json"])
        #expect(!flag.sent)

        let (_, viaShared) = await NetworkSentinel.recording {
            _ = try? await URLSession.shared.data(from: URL(string: "https://sentinel.invalid/ping")!)
        }
        #expect(viaShared == ["GET sentinel.invalid/ping"])
    }

    @Test func skipsToolsDashiiNeverGets() async {
        let live = DashiiTool(name: "acme_api", description: "For extensions.", callsService: true) { _ in
            _ = try await URLSession.shared.data(from: URL(string: "https://sentinel.invalid/api")!)
            return nil
        }
        let post = DashiiTool(name: "acme_post", description: "Posts.", writesRemotely: true) { _ in nil }
        #expect(await NetworkSentinel.requests(running: [live, post]) == [])
    }

    @Test func minimalInputsFromTheSchema() {
        let tool = DashiiTool(name: "acme_item", description: "",
                              properties: ["repo": JSONSchema.string("owner/name"), "state": JSONSchema.string("", enum: ["open", "closed"]),
                                           "number": JSONSchema.integer(""), "patches": JSONSchema.boolean(""), "labels": JSONSchema.array("", of: JSONSchema.string("")),
                                           "filter": JSONSchema.object(""), "limit": JSONSchema.integer("")],
                              required: ["repo", "state", "number", "patches", "labels", "filter"]) { _ in nil }
        #expect(NetworkSentinel.minimalInput(tool.inputSchema) == ["repo": "x", "state": "open", "number": 1, "patches": false, "labels": [], "filter": [:]])
        #expect(NetworkSentinel.minimalInput(tool.inputSchema, values: ["repo": "acme/billing-api", "limit": 5])["repo"] == "acme/billing-api")
        #expect(NetworkSentinel.minimalInput(tool.inputSchema, values: ["limit": 5])["limit"] == 5)
    }
}

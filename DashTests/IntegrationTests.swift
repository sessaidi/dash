import DashKit
import DashKitUI
import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Dash

/// Canned HTTP for tests: one response for every request, recorded.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, String) = (200, "{}")
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.response.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.response.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct ConnectionTests {
    @Test func allowsOnlyItsOwnHosts() {
        let connection = IntegrationConnection(baseURL: URL(string: "https://sts.us-east-1.amazonaws.com")!, hosts: [".amazonaws.com"])
        #expect(connection.allows(URL(string: "https://ec2.eu-west-1.amazonaws.com/")!))
        #expect(!connection.allows(URL(string: "https://amazonaws.com.evil.test/")!))
        #expect(!connection.allows(URL(string: "http://ec2.eu-west-1.amazonaws.com/")!))
    }

    @Test func authorizeAddsHeadersThenSigns() async throws {
        let connection = IntegrationConnection(baseURL: URL(string: "https://api.example.test")!, headers: ["A": "1"]) { request in
            var request = request
            request.setValue("signed", forHTTPHeaderField: "Authorization")
            return request
        }
        let request = try await connection.authorize(URLRequest(url: try #require(connection.url("/v1/x"))))
        #expect(request.url?.absoluteString == "https://api.example.test/v1/x")
        #expect(request.value(forHTTPHeaderField: "A") == "1" && request.value(forHTTPHeaderField: "Authorization") == "signed")
    }

}

/// Stands in for a plugin integration in app tests (plugins don't load in the test host).
@MainActor
final class FakeIntegration: Integration {
    let id: String
    let name: String
    let systemImage = "testtube.2"
    var isConnected: Bool
    var connection: IntegrationConnection? { isConnected ? IntegrationConnection(baseURL: URL(string: "https://example.test")!) : nil }
    var exports: JSONValue { ["repos": ["acme/api"], "login": "tester"] }
    var tools: [DashiiTool] { [DashiiTool(name: "\(id)_api_get", description: "test") { _ in nil }] }

    init(id: String, connected: Bool = false) {
        self.id = id
        self.name = id.capitalized
        self.isConnected = connected
    }
}

/// A note persisted by `FakeFeature`, to exercise per-extension data in the store.
@Model
final class FakeNote {
    var text: String
    init(text: String) { self.text = text }
}

/// Stands in for a plugin feature in app tests: requires integrations, has a tool and a model.
@MainActor
final class FakeFeature: DashExtension {
    let id: String
    let name: String
    let systemImage = "testtube.2"
    let requires: [String]
    let optional: [String]
    var models: [any PersistentModel.Type] { [FakeNote.self] }
    var tools: [DashiiTool] { [DashiiTool(name: "\(id)_run", description: "test") { _ in nil }] }

    init(id: String, requires: [String] = [], optional: [String] = []) {
        self.id = id
        self.name = id.capitalized
        self.requires = requires
        self.optional = optional
    }
}

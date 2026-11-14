import Foundation
import Security
import Testing
@testable import WorkspaceKit

/// Serves canned responses and records requests (no network).
final class FakeAPI: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requests: [(method: String, path: String, contentType: String?, body: String)] = []
    static let lock = NSLock()

    static func reset(_ routes: [String: (Int, String)]) {
        lock.withLock { self.routes = routes; requests = [] }
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeAPI.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        let (status, text) = Self.lock.withLock { () -> (Int, String) in
            Self.requests.append((request.httpMethod ?? "GET", url.path + (url.query.map { "?" + $0 } ?? ""), request.value(forHTTPHeaderField: "Content-Type"), String(decoding: body, as: UTF8.self)))
            return Self.routes[key] ?? (404, #"{"message":"not found"}"#)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct WorkspaceKitTests {
    private func client() -> WorkspaceClient {
        WorkspaceClient(env: .dev, region: .us,
                        kube: KubernetesClient(server: URL(string: "https://10.0.0.1")!, credentials: StaticToken("t"), session: FakeAPI.session))
    }

    private static let namespaces = #"""
        {"items":[
          {"metadata":{"name":"alpha","creationTimestamp":"2026-11-01T10:00:00Z","labels":{"workspace":"true","deployed_by":"sadik","region":"us"},"annotations":{"deployed_at":"2026-11-12T10:00:00Z","git_branch":"main"}}},
          {"metadata":{"name":"beta","creationTimestamp":"2026-09-01T10:00:00Z","labels":{"workspace":"true","deployed_by":"jo","region":"eu"},"annotations":{"persist":"true"}}}
        ]}
        """#
    private static let capigPods = #"""
        {"items":[{"metadata":{"namespace":"alpha"},"spec":{"nodeName":"gke-workspaces-spot-1"}},
                  {"metadata":{"namespace":"beta"},"spec":{"nodeName":"gke-workspaces-node-9"}}]}
        """#

    @Test func listsWorkspacesWithNodePoolsAndURLs() async throws {
        FakeAPI.reset(["GET /api/v1/namespaces": (200, Self.namespaces), "GET /api/v1/pods": (200, Self.capigPods)])
        let workspaces = try await client().list()
        #expect(workspaces.map(\.name) == ["alpha", "beta"])
        #expect(workspaces[0].nodePool == .spot && workspaces[0].deployedBy == "sadik" && workspaces[0].gitBranch == "main")
        #expect(workspaces[0].url == "alpha.backend-workspace.dev-01.fubo.tv")
        #expect(workspaces[1].url == "beta.backend-workspace-eu.dev-01.fubo.tv")
        #expect(workspaces[1].persist && workspaces[1].nodePool == .legacy)
        let listCall = try #require(FakeAPI.requests.first { $0.path.hasPrefix("/api/v1/namespaces") })
        #expect(listCall.path.contains("labelSelector=workspace%3Dtrue") || listCall.path.contains("labelSelector=workspace=true"))
    }

    @Test func cleanRulesMatchUpToolbox() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!
        FakeAPI.reset(["GET /api/v1/namespaces": (200, Self.namespaces), "GET /api/v1/pods": (200, Self.capigPods)])
        // alpha: deployed yesterday on spot -> kept. beta: legacy pool but persisted -> excluded.
        #expect(try await client().cleanCandidates(now: now).isEmpty)

        let stale = Workspace.url(name: "x", env: .qa, region: "us")
        #expect(stale == "x.backend-workspace.qa-01.fubo.tv")
    }

    @Test func cleanReasonUsesDeployedAtThenCreation() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!
        func workspace(_ annotations: String, created: String, node: NodePool) throws -> Workspace {
            let json = try JSON.parse(#"{"metadata":{"name":"w","creationTimestamp":"\#(created)","labels":{"workspace":"true"},"annotations":{\#(annotations)}}}"#)
            return Workspace(namespace: json, env: .dev, nodePool: node)
        }
        #expect(try workspace(#""deployed_at":"2026-11-01T00:00:00Z""#, created: "2026-11-01T00:00:00Z", node: .spot).cleanReason(now: now) == "not deployed for over a week")
        #expect(try workspace("", created: "2026-09-01T00:00:00Z", node: .spot).cleanReason(now: now) == "created over a month ago and never deployed")
        #expect(try workspace("", created: "2026-11-10T00:00:00Z", node: .unknown).cleanReason(now: now) == "on a unknown node pool")
        #expect(try workspace("", created: "2026-11-10T00:00:00Z", node: .standard).cleanReason(now: now) == nil)
    }

    @Test func refusesNamespacesThatAreNotWorkspaces() async throws {
        FakeAPI.reset(["GET /api/v1/namespaces/default": (200, #"{"metadata":{"name":"default","labels":{}}}"#)])
        await #expect(throws: WorkspaceKitError.notAWorkspace("default")) { try await client().setPersist("default", true) }
        #expect(!FakeAPI.requests.contains { $0.method == "PATCH" })
    }

    @Test func persistUsesMergePatch() async throws {
        FakeAPI.reset([
            "GET /api/v1/namespaces/alpha": (200, #"{"metadata":{"name":"alpha","labels":{"workspace":"true"}}}"#),
            "PATCH /api/v1/namespaces/alpha": (200, "{}"),
        ])
        try await client().setPersist("alpha", true)
        let patch = try #require(FakeAPI.requests.first { $0.method == "PATCH" })
        #expect(patch.contentType == "application/merge-patch+json")
        #expect(patch.body == #"{"metadata":{"annotations":{"persist":"true"}}}"#)
    }

    @Test func deployUsesStrategicMergeAndWaitsForTag() async throws {
        FakeAPI.reset([
            "GET /api/v1/namespaces/alpha": (200, #"{"metadata":{"name":"alpha","labels":{"workspace":"true"}}}"#),
            "PATCH /api/v1/namespaces/alpha": (200, "{}"),
            "PATCH /apis/apps/v1/namespaces/alpha/deployments/papi": (200, "{}"),
            "GET /api/v1/namespaces/alpha/pods": (200, #"{"items":[{"spec":{"containers":[{"image":"r/papi:abc"}]},"status":{"phase":"Running"}}]}"#),
        ])
        let seen = Box()
        try await client().deploy(workspace: "alpha", app: "papi", image: "r/papi:abc", git: ["git_branch": "main"]) { seen.append($0) }
        let patch = try #require(FakeAPI.requests.first { $0.path.hasSuffix("/deployments/papi") })
        #expect(patch.contentType == "application/strategic-merge-patch+json")
        #expect(patch.body.contains(#""containers":[{"image":"r/papi:abc","name":"papi"}]"#))
        #expect(seen.values.last == DeployProgress(runningVersions: ["abc"], done: true))
    }

    @Test func deployFailsFastOnCrashLoop() async throws {
        FakeAPI.reset([
            "GET /api/v1/namespaces/alpha": (200, #"{"metadata":{"name":"alpha","labels":{"workspace":"true"}}}"#),
            "PATCH /api/v1/namespaces/alpha": (200, "{}"),
            "PATCH /apis/apps/v1/namespaces/alpha/deployments/papi": (200, "{}"),
            "GET /api/v1/namespaces/alpha/pods": (200, #"{"items":[{"spec":{"containers":[{"image":"r/papi:abc"}]},"status":{"phase":"Pending","containerStatuses":[{"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}"#),
        ])
        await #expect(throws: WorkspaceKitError.podUnhealthy(pod: "papi:abc", reason: "CrashLoopBackOff")) {
            try await client().deploy(workspace: "alpha", app: "papi", image: "r/papi:abc")
        }
    }

    @Test func pinnedTrustLeavesClientCertificateChallengesToTheDefault() async {
        let space = URLProtectionSpace(host: "34.1.2.3", port: 443, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                   failureResponse: nil, error: nil, sender: ChallengeSender())
        let (disposition, _) = await PinnedTrust(certificate: Data()).urlSession(.shared, didReceive: challenge)
        #expect(disposition == .performDefaultHandling)
    }

    @Test func collectionPathsForWorkspaceKinds() throws {
        let deployment: JSON = ["apiVersion": "apps/v1", "kind": "Deployment"]
        let route: JSON = ["apiVersion": "gateway.networking.k8s.io/v1beta1", "kind": "HTTPRoute"]
        #expect(KubernetesClient.collectionPath(for: deployment, namespace: "w") == "/apis/apps/v1/namespaces/w/deployments")
        #expect(KubernetesClient.collectionPath(for: ["apiVersion": "v1", "kind": "Secret"], namespace: "w") == "/api/v1/namespaces/w/secrets")
        #expect(KubernetesClient.collectionPath(for: route, namespace: "w") == "/apis/gateway.networking.k8s.io/v1beta1/namespaces/w/httproutes")
        #expect(KubernetesClient.collectionPath(for: ["apiVersion": "v1", "kind": "Namespace"], namespace: "w") == "/api/v1/namespaces")
    }

    @Test func gkeDiscoveryDecodesEndpointAndCA() async throws {
        let pem = "-----BEGIN CERTIFICATE-----\nAAEC\n-----END CERTIFICATE-----\n"
        let ca = Data(pem.utf8).base64EncodedString()
        FakeAPI.reset(["GET /v1/projects/fubotv-dev/locations/-/clusters": (200, #"{"clusters":[{"name":"api-cluster-east4","location":"us-east4-b","endpoint":"34.1.2.3","masterAuth":{"clusterCaCertificate":"\#(ca)"}}]}"#)])
        let clusters = try await GKE(credentials: StaticToken("t"), session: FakeAPI.session).clusters(project: "fubotv-dev")
        #expect(clusters == [GKECluster(project: "fubotv-dev", name: "api-cluster-east4", location: "us-east4-b", endpoint: "34.1.2.3", caCertificate: Data([0, 1, 2]))])
        #expect(clusters[0].contextName == "gke_fubotv-dev_us-east4-b_api-cluster-east4")
    }

    @Test func authorizedUserRefreshesOverHTTPS() async throws {
        FakeAPI.reset(["POST /token": (200, #"{"access_token":"ya29.x","expires_in":3599}"#)])
        let credentials = try GoogleCredentials(json: ["type": "authorized_user", "client_id": "id", "client_secret": "s", "refresh_token": "r/1"], session: FakeAPI.session)
        #expect(try await credentials.accessToken() == "ya29.x")
        #expect(try await credentials.accessToken() == "ya29.x")
        #expect(FakeAPI.requests.count == 1)
        #expect(FakeAPI.requests[0].body == "client_id=id&client_secret=s&grant_type=refresh_token&refresh_token=r%2F1")
    }

    @Test func serviceAccountKeySignsAVerifiableJWT() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let pkcs1 = SecKeyCopyExternalRepresentation(key, nil)! as Data
        // Wrap PKCS#1 in a PKCS#8 PrivateKeyInfo, as Google key files are.
        func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            let n = content.count
            let length: [UInt8] = n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xff)]
            return [tag] + length + content
        }
        let algorithm: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        let pkcs8 = der(0x30, [0x02, 0x01, 0x00] + algorithm + der(0x04, [UInt8](pkcs1)))
        let pem = "-----BEGIN PRIVATE KEY-----\n\(Data(pkcs8).base64EncodedString(options: .lineLength64Characters))\n-----END PRIVATE KEY-----\n"

        let loaded = try RSAKey.privateKey(pem: pem)
        let jwt = try JWT.sign(claims: ["iss": "sa@p.iam.gserviceaccount.com"], key: loaded)
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        func decode(_ part: String) -> Data {
            var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            return Data(base64Encoded: base64)!
        }
        let publicKey = SecKeyCopyPublicKey(key)!
        #expect(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, decode(parts[2]) as CFData, nil))
        #expect(try JSON.parse(String(decoding: decode(parts[1]), as: UTF8.self))["iss"] == "sa@p.iam.gserviceaccount.com")
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DeployProgress] = []
    var values: [DeployProgress] { lock.withLock { stored } }
    func append(_ value: DeployProgress) { lock.withLock { stored.append(value) } }
}

final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

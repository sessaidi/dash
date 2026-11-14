import Foundation
import Security

/// A GKE cluster as returned by the Container API.
public struct GKECluster: Sendable, Equatable {
    public let project: String
    public let name: String
    public let location: String
    public let endpoint: String
    /// DER bytes of the cluster CA certificate.
    public let caCertificate: Data

    /// kubeconfig-style name: gke_<project>_<location>_<name>
    public var contextName: String { "gke_\(project)_\(location)_\(name)" }
}

/// Lists GKE clusters over the Container REST API.
public struct GKE: Sendable {
    let credentials: any GoogleTokenSource
    let session: URLSession

    public init(credentials: any GoogleTokenSource, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    public func clusters(project: String) async throws -> [GKECluster] {
        var request = URLRequest(url: URL(string: "https://container.googleapis.com/v1/projects/\(project)/locations/-/clusters")!)
        request.setValue("Bearer \(try await credentials.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let json = try JSON.parse(String(decoding: data, as: UTF8.self))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw WorkspaceKitError.http(service: "GKE", status: status, message: json["error"]?["message"]?.string ?? "")
        }
        return (json["clusters"]?.array ?? []).compactMap { cluster in
            guard let name = cluster["name"]?.string, let endpoint = cluster["endpoint"]?.string,
                  let ca = cluster["masterAuth"]?["clusterCaCertificate"]?.string, let der = Self.der(fromBase64PEM: ca) else { return nil }
            return GKECluster(project: project, name: name, location: cluster["location"]?.string ?? cluster["zone"]?.string ?? "",
                              endpoint: endpoint, caCertificate: der)
        }
    }

    /// `clusterCaCertificate` is base64 of a PEM certificate.
    static func der(fromBase64PEM base64: String) -> Data? {
        guard let pem = Data(base64Encoded: base64).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)
    }
}

/// Minimal Kubernetes REST client: bearer token auth, trust pinned to the cluster CA.
public final class KubernetesClient: Sendable {
    public enum Patch: String, Sendable {
        case merge = "application/merge-patch+json"
        /// Merges lists by key (containers by name), as `kubectl patch` does by default.
        case strategicMerge = "application/strategic-merge-patch+json"
        case json = "application/json-patch+json"
    }

    let server: URL
    let credentials: any GoogleTokenSource
    let session: URLSession
    /// The kubeconfig context name of this cluster, for the commands that replay requests.
    public let contextName: String
    /// Every request made, for "show the command".
    public let recorder = RequestRecorder()

    /// Production initializer: pins TLS trust to `caCertificate` (DER).
    public convenience init(cluster: GKECluster, credentials: any GoogleTokenSource) {
        let delegate = PinnedTrust(certificate: cluster.caCertificate)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        self.init(server: URL(string: "https://\(cluster.endpoint)")!, credentials: credentials, session: session, contextName: cluster.contextName)
    }

    /// For tests, or servers trusted by the system.
    public init(server: URL, credentials: any GoogleTokenSource, session: URLSession, contextName: String = "workspaces") {
        self.server = server
        self.credentials = credentials
        self.session = session
        self.contextName = contextName
    }

    /// Path plus query string exactly as sent.
    func pathAndQuery(_ components: URLComponents) -> String {
        components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    public func get(_ path: String, query: [String: String] = [:]) async throws -> JSON {
        try await send("GET", path, query: query)
    }

    /// Returns nil on 404.
    public func getIfExists(_ path: String) async throws -> JSON? {
        do { return try await get(path) } catch WorkspaceKitError.http(_, 404, _) { return nil }
    }

    public func create(_ path: String, _ object: JSON) async throws -> JSON {
        try await send("POST", path, body: object)
    }

    public func patch(_ path: String, _ patch: JSON, type: Patch) async throws -> JSON {
        try await send("PATCH", path, body: patch, contentType: type.rawValue)
    }

    public func delete(_ path: String) async throws {
        _ = try await send("DELETE", path)
    }

    func send(_ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil, contentType: String = "application/json") async throws -> JSON {
        var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(try await credentials.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = Data(body.line.utf8)
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        recorder.record(RequestTrace(method: method, path: pathAndQuery(components), contentType: body == nil ? nil : contentType,
                                     body: body?.line, status: status, context: contextName))
        let json = data.isEmpty ? JSON.null : ((try? JSON.parse(String(decoding: data, as: UTF8.self))) ?? .string(String(decoding: data, as: UTF8.self)))
        guard (200..<300).contains(status) else {
            throw WorkspaceKitError.http(service: "Kubernetes", status: status, message: json["message"]?.string ?? json.string ?? "")
        }
        return json
    }

    /// REST collection path for a manifest's kind (the kinds workspaces use).
    public static func collectionPath(for object: JSON, namespace: String?) -> String? {
        guard let apiVersion = object["apiVersion"]?.string, let kind = object["kind"]?.string else { return nil }
        let plural: String
        switch kind {
        case "Namespace": return "/api/v1/namespaces"
        case "Service": plural = "services"
        case "Secret": plural = "secrets"
        case "ConfigMap": plural = "configmaps"
        case "Deployment": plural = "deployments"
        case "HTTPRoute": plural = "httproutes"
        case "HealthCheckPolicy": plural = "healthcheckpolicies"
        default: plural = kind.lowercased() + "s"
        }
        let group = apiVersion.contains("/") ? "/apis/\(apiVersion)" : "/api/\(apiVersion)"
        let ns = object["metadata"]?["namespace"]?.string ?? namespace
        return ns.map { "\(group)/namespaces/\($0)/\(plural)" } ?? "\(group)/\(plural)"
    }
}

/// Accepts only server certificates chaining to the cluster CA.
final class PinnedTrust: NSObject, URLSessionDelegate, Sendable {
    let certificate: Data

    init(certificate: Data) {
        self.certificate = certificate
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Other challenges (GKE asks for an optional client certificate) get the default handling;
        // cancelling them aborts the request.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return (.performDefaultHandling, nil)
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, certificate as CFData) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        // GKE endpoints are IP addresses; trust is anchored to the cluster CA alone.
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil))
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

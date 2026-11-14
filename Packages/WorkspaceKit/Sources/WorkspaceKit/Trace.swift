import Foundation

/// One request Dash made to a cluster, kept so the user can run the same thing themselves and
/// get the same output: `exact` replays the request (same path, query and body), `familiar` is
/// the everyday command that shows the same data (formatted its own way).
public struct RequestTrace: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let at: Date
    public let method: String
    /// Path with its query string, e.g. /api/v1/namespaces/laf-12/pods/api-1/log?container=api&tailLines=500
    public let path: String
    public let contentType: String?
    public let body: String?
    public let status: Int
    /// kubeconfig context name of the cluster (gke_<project>_<location>_<name>).
    public let context: String

    public init(at: Date = .now, method: String, path: String, contentType: String?, body: String?, status: Int, context: String) {
        id = UUID()
        self.at = at
        self.method = method
        self.path = path
        self.contentType = contentType
        self.body = body
        self.status = status
        self.context = context
    }

    /// Replays the request byte for byte. Reads use `kubectl get --raw` (same bytes back);
    /// writes go through `kubectl proxy` with curl, since kubectl has no raw PATCH.
    public var exact: String {
        if method == "GET" { return "kubectl --context \(context) get --raw '\(path)'" }
        let data = body.map { " \\\n  -d '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" } ?? ""
        return """
            kubectl --context \(context) proxy --port 8001 &
            curl -s -X \(method) 'http://127.0.0.1:8001\(path)'\(contentType.map { " \\\n  -H 'Content-Type: \($0)'" } ?? "")\(data)
            """
    }

    /// The command people usually type for this request, when there is one.
    public var familiar: String? {
        let (route, query) = Self.split(path)
        let parts = route.split(separator: "/").map(String.init)
        func q(_ key: String) -> String? { query[key] }
        // /api/v1/namespaces/<ns>/pods/<pod>/log
        if method == "GET", parts.count == 7, parts[2] == "namespaces", parts[4] == "pods", parts[6] == "log" {
            var command = "kubectl --context \(context) logs -n \(parts[3]) \(parts[5])"
            if let container = q("container") { command += " -c \(container)" }
            if let tail = q("tailLines") { command += " --tail=\(tail)" }
            if let since = q("sinceSeconds") { command += " --since=\(since)s" }
            if q("previous") == "true" { command += " --previous" }
            if q("timestamps") == "true" { command += " --timestamps" }
            return command
        }
        if method == "GET", route == "/api/v1/namespaces", q("labelSelector") == "workspace=true" {
            return "kubectl --context \(context) get namespaces -l workspace=true -o json   # up-toolbox workspace list"
        }
        // /api/v1/namespaces/<ns>/<kind>  and  /apis/<group>/<version>/namespaces/<ns>/<kind>[/<name>]
        if method == "GET", let index = parts.firstIndex(of: "namespaces"), index + 2 < parts.count {
            let namespace = parts[index + 1]
            let kind = parts[index + 2]
            let name = index + 3 < parts.count ? " " + parts[index + 3] : ""
            let selector = q("labelSelector").map { " -l '\($0)'" } ?? ""
            return "kubectl --context \(context) get \(kind)\(name) -n \(namespace)\(selector) -o json"
        }
        if method == "GET", parts.count == 4, parts[2] == "namespaces" {
            return "kubectl --context \(context) get namespace \(parts[3]) -o json   # up-toolbox workspace status --name \(parts[3])"
        }
        if method == "GET", parts.count == 4, parts[2] == "nodes" {
            return "kubectl --context \(context) get node \(parts[3]) -o json"
        }
        if method == "PATCH", let body, let index = parts.firstIndex(of: "namespaces"), index + 1 < parts.count {
            let type = contentType?.contains("strategic") == true ? "strategic" : contentType?.contains("json-patch") == true ? "json" : "merge"
            let resource = index + 3 < parts.count ? "\(parts[index + 2]) \(parts[index + 3]) -n \(parts[index + 1])" : "namespace \(parts[index + 1])"
            return "kubectl --context \(context) patch \(resource) --type \(type) -p '\(body)'"
        }
        if method == "DELETE", parts.count == 4, parts[2] == "namespaces" {
            return "kubectl --context \(context) delete namespace \(parts[3])   # up-toolbox workspace down --name \(parts[3])"
        }
        return nil
    }

    static func split(_ path: String) -> (String, [String: String]) {
        guard let mark = path.firstIndex(of: "?") else { return (path, [:]) }
        var query: [String: String] = [:]
        for pair in path[path.index(after: mark)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { query[kv[0]] = kv[1] }
        }
        return (String(path[..<mark]), query)
    }
}

/// Keeps the last requests a client made.
public final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RequestTrace] = []
    private let capacity: Int

    public init(capacity: Int = 300) { self.capacity = capacity }

    public func record(_ trace: RequestTrace) {
        lock.withLock {
            items.append(trace)
            if items.count > capacity { items.removeFirst(items.count - capacity) }
        }
    }

    /// Newest first; only those touching `namespace` when given.
    public func traces(namespace: String? = nil) -> [RequestTrace] {
        lock.withLock {
            items.reversed().filter { trace in
                guard let namespace else { return true }
                return trace.path.contains("/namespaces/\(namespace)/") || trace.path.hasSuffix("/namespaces/\(namespace)")
                    || trace.path.contains("/namespaces/\(namespace)?")
            }
        }
    }
}

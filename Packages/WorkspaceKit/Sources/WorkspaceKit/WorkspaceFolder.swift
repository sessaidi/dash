import Foundation

extension YAML {
    /// Block-style YAML for a manifest: apiVersion, kind and metadata first, then the other
    /// keys sorted; multi-line strings as literal blocks; strings quoted when YAML would read
    /// them as something else.
    static func dump(_ value: JSON) -> String {
        var out = ""
        write(value, indent: 0, into: &out, inSequence: false)
        return out
    }

    private static let leading = ["apiVersion", "kind", "metadata", "type"]

    static func orderedKeys(_ fields: [String: JSON]) -> [String] {
        leading.filter { fields[$0] != nil } + fields.keys.filter { !leading.contains($0) }.sorted()
    }

    private static func write(_ value: JSON, indent: Int, into out: inout String, inSequence: Bool) {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case .object(let fields) where !fields.isEmpty:
            for (index, key) in orderedKeys(fields).enumerated() {
                let child = fields[key]!
                let prefix = (inSequence && index == 0) ? "" : pad
                out += prefix + scalarKey(key) + ":"
                writeChild(child, indent: indent, into: &out)
            }
        case .array(let items) where !items.isEmpty:
            for item in items {
                out += pad + "- "
                if case .object(let fields) = item, !fields.isEmpty {
                    write(item, indent: indent + 1, into: &out, inSequence: true)
                } else if case .array(let inner) = item, !inner.isEmpty {
                    out += "\n"
                    write(item, indent: indent + 1, into: &out, inSequence: false)
                } else {
                    out += inline(item, indent: indent + 1) + "\n"
                }
            }
        default:
            out += pad + inline(value, indent: indent) + "\n"
        }
    }

    private static func writeChild(_ child: JSON, indent: Int, into out: inout String) {
        switch child {
        case .object(let fields) where !fields.isEmpty:
            out += "\n"
            write(child, indent: indent + 1, into: &out, inSequence: false)
        case .array(let items) where !items.isEmpty:
            out += "\n"
            write(child, indent: indent, into: &out, inSequence: false)
        case .string(let text) where text.contains("\n"):
            // Literal block; keep the trailing newline exactly.
            let chomp = text.hasSuffix("\n") ? (text.hasSuffix("\n\n") ? "+" : "") : "-"
            out += " |\(text.hasPrefix(" ") ? "2" : "")\(chomp)\n"
            let pad = String(repeating: "  ", count: indent + 1)
            var lines = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") { lines.removeLast() }
            for line in lines { out += line.isEmpty ? "\n" : pad + line + "\n" }
        default:
            out += " " + inline(child, indent: indent) + "\n"
        }
    }

    private static func inline(_ value: JSON, indent: Int) -> String {
        switch value {
        case .object: return "{}"
        case .array: return "[]"
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .string(let text): return scalar(text)
        }
    }

    private static func scalarKey(_ key: String) -> String { scalar(key) }

    /// Plain when it reads back as the same string, double-quoted otherwise.
    static func scalar(_ text: String) -> String {
        let reserved = ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"]
        let plain = !text.isEmpty
            && !reserved.contains(text.lowercased())
            && Double(text) == nil && Int(text) == nil
            && text.range(of: #"^[A-Za-z0-9_./][A-Za-z0-9_./ \-]*$"#, options: .regularExpression) != nil
            && !text.hasSuffix(" ") && !text.contains(": ") && !text.contains(" #")
        if plain { return text }
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\t": quoted += "\\t"
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}

/// A workspace's configuration on disk, laid out like `up-toolbox workspace generate`:
///
///     <name>-<env>[-<region>]/
///       namespace.yaml  kustomization.yaml  .gitignore
///       <service>/secret-<name>.yaml  configmap-<name>.yaml  service.yaml  deployment.yaml
///                 httproute.yaml  healthcheck-policy.yaml  kustomization.yaml
///
/// Edit it, then compare with the cluster (`changes`) and apply. `kubectl create -f
/// namespace.yaml && kubectl create -k .` in it does what `up-toolbox workspace up` does.
public struct WorkspaceFolder: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `<parent>/<name>-<env>[-<region>]`, as up-toolbox names it.
    public static func url(in parent: URL, name: String, env: WorkspaceEnvironment, region: WorkspaceRegion) -> URL {
        parent.appending(path: region == .us ? "\(name)-\(env.rawValue)" : "\(name)-\(env.rawValue)-\(region.rawValue)", directoryHint: .isDirectory)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.appending(path: "namespace.yaml").path) }

    /// Writes the manifests (replacing the folder when `force`).
    public func write(_ manifests: [JSON], force: Bool = false) throws {
        let files = FileManager.default
        if files.fileExists(atPath: url.path) {
            guard force else { throw WorkspaceKitError.http(service: "Workspace files", status: 0, message: "\(url.lastPathComponent) already exists (use force to regenerate)") }
            try files.removeItem(at: url)
        }
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        try "*".write(to: url.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        var services: [String: [(file: String, object: JSON)]] = [:]
        var order: [String] = []
        for object in manifests {
            let kind = object["kind"]?.string ?? ""
            let name = object["metadata"]?["name"]?.string ?? ""
            if kind == "Namespace" {
                try YAML.dump(object).write(to: url.appending(path: "namespace.yaml"), atomically: true, encoding: .utf8)
                continue
            }
            let service = Self.service(of: object, all: manifests)
            if services[service] == nil { order.append(service) }
            let file = switch kind {
            case "Secret": "secret-\(name).yaml"
            case "ConfigMap": name == "common-api-gateway-varnish-config" ? "configmap-varnish.yaml" : "configmap-\(name).yaml"
            case "Service": "service.yaml"
            case "Deployment": "deployment.yaml"
            case "HTTPRoute": "httproute.yaml"
            case "HealthCheckPolicy": "healthcheck-policy.yaml"
            default: "\(kind.lowercased())-\(name).yaml"
            }
            services[service, default: []].append((file, object))
        }
        for service in order {
            let folder = url.appending(path: service, directoryHint: .isDirectory)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let entries = services[service] ?? []
            for entry in entries {
                try YAML.dump(entry.object).write(to: folder.appending(path: entry.file), atomically: true, encoding: .utf8)
            }
            try YAML.dump(Self.kustomization(entries.map(\.file))).write(to: folder.appending(path: "kustomization.yaml"), atomically: true, encoding: .utf8)
        }
        try YAML.dump(Self.kustomization(order)).write(to: url.appending(path: "kustomization.yaml"), atomically: true, encoding: .utf8)
    }

    /// Reads the folder back: the namespace, then every resource its kustomizations list.
    public func read() throws -> [JSON] {
        var objects = [try YAML.parse(String(contentsOf: url.appending(path: "namespace.yaml"), encoding: .utf8))]
        func resources(_ folder: URL) throws -> [String] {
            let kustomization = try YAML.parse(String(contentsOf: folder.appending(path: "kustomization.yaml"), encoding: .utf8))
            return kustomization["resources"]?.array?.compactMap(\.string) ?? []
        }
        for service in try resources(url) {
            let folder = url.appending(path: service, directoryHint: .isDirectory)
            for file in try resources(folder) {
                objects.append(try YAML.parse(String(contentsOf: folder.appending(path: file), encoding: .utf8)))
            }
        }
        return objects
    }

    static func kustomization(_ resources: [String]) -> JSON {
        ["apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization", "resources": .array(resources.map { .string($0) })]
    }

    /// Which service folder an object goes in: its own name, the deployment that uses it
    /// (secrets, ConfigMaps), or common-api-gateway for the route and health check.
    static func service(of object: JSON, all: [JSON]) -> String {
        let kind = object["kind"]?.string ?? ""
        let name = object["metadata"]?["name"]?.string ?? ""
        if ["Service", "Deployment"].contains(kind) { return name }
        if ["HTTPRoute", "HealthCheckPolicy"].contains(kind) || name == "common-api-gateway-varnish-config" { return WorkspaceGenerator.capig }
        for deployment in all where deployment["kind"]?.string == "Deployment" {
            let needs = WorkspaceGenerator.dependencies(of: [deployment])
            if (kind == "Secret" && needs.secrets.contains(name)) || (kind == "ConfigMap" && needs.configMaps.contains(name)) {
                return deployment["metadata"]?["name"]?.string ?? "shared"
            }
        }
        return "shared"
    }
}

/// What differs between the local files and the cluster, object by object.
public struct WorkspaceChange: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case create, update, unchanged }
    public let kind: Kind
    public let object: JSON
    /// "Deployment/services-presentation-api"
    public var id: String { "\(object["kind"]?.string ?? "")/\(object["metadata"]?["name"]?.string ?? "")" }
    /// Top-level paths that differ ("data.services_config.json", "spec.template…containers[0].env").
    public let differences: [String]
}

extension WorkspaceClient {
    /// Compares local manifests with what the cluster has: new objects, changed fields (only the
    /// fields the files set; the cluster's defaults and status are ignored), and unchanged ones.
    public func changes(_ manifests: [JSON], namespace: String) async throws -> [WorkspaceChange] {
        var result: [WorkspaceChange] = []
        for object in manifests where object["kind"]?.string != "Namespace" {
            guard let collection = KubernetesClient.collectionPath(for: object, namespace: namespace),
                  let name = object["metadata"]?["name"]?.string else { continue }
            guard let live = try await kube.getIfExists("\(collection)/\(name)") else {
                result.append(.init(kind: .create, object: object, differences: []))
                continue
            }
            var differences: [String] = []
            Self.diff(object, live, path: "", into: &differences, secret: object["kind"]?.string == "Secret")
            result.append(.init(kind: differences.isEmpty ? .unchanged : .update, object: object, differences: differences))
        }
        return result
    }

    /// Paths where `local` sets something `live` doesn't have the same.
    static func diff(_ local: JSON, _ live: JSON?, path: String, into differences: inout [String], secret: Bool) {
        switch local {
        case .object(let fields):
            for (key, value) in fields where !(path.isEmpty && key == "status") {
                // Secrets are written as stringData; the cluster returns base64 data.
                if secret && path.isEmpty && key == "stringData" {
                    let liveData = live?["data"]?.object ?? [:]
                    for (field, text) in value.object ?? [:] {
                        let encoded = Data((text.string ?? "").utf8).base64EncodedString()
                        if liveData[field]?.string != encoded { differences.append("stringData.\(field)") }
                    }
                    continue
                }
                diff(value, live?[key], path: path.isEmpty ? key : "\(path).\(key)", into: &differences, secret: secret)
            }
        case .array(let items):
            let liveItems = live?.array ?? []
            if items.count != liveItems.count { differences.append(path); return }
            for (index, item) in items.enumerated() {
                diff(item, liveItems[index], path: "\(path)[\(index)]", into: &differences, secret: secret)
            }
        default:
            if !Self.sameScalar(local, live) { differences.append(path) }
        }
    }

    /// "500m" vs "0.5", 8080 vs "8080": the API normalises some values; compare loosely.
    static func sameScalar(_ a: JSON, _ b: JSON?) -> Bool {
        guard let b else { return a == .null }
        if a == b { return true }
        switch (a, b) {
        case (.number(let x), .string(let y)), (.string(let y), .number(let x)): return Double(y) == x
        default: return false
        }
    }

    /// Applies changes: creates new objects, replaces changed ones with a merge patch of the
    /// file's content (Deployments: strategic merge, which keeps sidecars' list entries by name).
    public func apply(_ changes: [WorkspaceChange], namespace: String) async throws {
        for change in changes where change.kind != .unchanged {
            guard let collection = KubernetesClient.collectionPath(for: change.object, namespace: namespace),
                  let name = change.object["metadata"]?["name"]?.string else { continue }
            switch change.kind {
            case .create:
                _ = try await kube.create(collection, change.object)
            case .update:
                let strategic = ["Deployment", "Service"].contains(change.object["kind"]?.string ?? "")
                _ = try await kube.patch("\(collection)/\(name)", change.object, type: strategic ? .strategicMerge : .merge)
            case .unchanged:
                break
            }
        }
    }
}

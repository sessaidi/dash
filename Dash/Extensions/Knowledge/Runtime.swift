import Foundation

/// Workloads: what a repository runs and how, `workload:<repoID>:<Kind>/<name>`. Read from
/// Kubernetes manifests (Deployment, StatefulSet, DaemonSet, CronJob, Job, Rollout), Helm values
/// next to a Chart.yaml, and Terraform Kubernetes, Cloud Run and Helm resources. Each file leaves
/// `workload` facts (image, replicas, resources, ports, probes, schedule, env names, ConfigMap and
/// Secret names, hosts, routes) that the link pass merges into the node, so a values file and its
/// per-environment overlays make one workload. Services, Ingresses, HTTPRoutes and autoscalers add
/// facts to the workload they name (`*` for its kind). Secret values are never read, only names.
struct RuntimeExtractor: CodeExtractor {
    let name = "runtime"
    var sharedKinds: [String] { ["image", "host"] }
    static let factKind = "workload"
    /// The kind of a workload a fact names without knowing it (a Service, an overlay).
    static let anyKind = "*"

    static func id(repo: String, kind: String, name: String) -> String { "workload:" + repo + ":" + kind + "/" + name }

    func accepts(path: String, language: String) -> Bool {
        (language == "yaml" || language == "terraform") && !SourceScan.isTest(path)
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        let found: [Found]
        if file.language == "terraform" {
            found = Self.terraform(file)
        } else if let chart = Self.chart(of: file) {
            found = Self.values(file.text, fileName: file.fileName, chart: chart)
        } else if file.text.contains("apiVersion"), file.text.contains("kind:"), !(file.path.contains("/templates/") && file.text.contains("{{")) {
            found = Self.manifests(file.text)
        } else {
            return result
        }
        for workload in found where Self.isName(workload.name) {
            result.refs.append(KnowledgeRef(src: Self.id(repo: file.repoID, kind: workload.kind, name: workload.name), kind: Self.factKind,
                                            names: workload.facts, line: workload.line))
        }
        return result
    }

    struct Found {
        var kind: String
        var name: String
        var facts: [String]
        var line: Int
    }

    static func isName(_ name: String) -> Bool { name.range(of: #"^[\w.-]+$"#, options: .regularExpression) != nil }

    /// "ghcr.io/acme/users-api:1.2@sha256:…" → "ghcr.io/acme/users-api"; nil when templated.
    static func imageName(_ reference: String) -> String? {
        var name = reference.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("{{"), !name.contains("$"), !name.contains(" ") else { return nil }
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") { name = String(name[..<colon]) }
        return name.isEmpty ? nil : name.lowercased()
    }

    // MARK: Kubernetes manifests

    static func manifests(_ text: String) -> [Found] {
        var result: [Found] = []
        for document in YAMLTree.documents(text) {
            guard let kind = document["kind"]?.string, let name = document.at("metadata", "name")?.string else { continue }
            let line = document["kind"]?.line ?? document.line
            let spec = document["spec"]
            switch kind {
            case _ where ServiceExtractor.workloadKinds.contains(kind):
                var facts = ["kind=" + kind]
                if let replicas = spec?["replicas"]?.string { facts.append("replicas=" + replicas) }
                if let schedule = spec?["schedule"]?.string { facts.append("schedule=" + schedule) }
                let job = kind == "CronJob" ? spec?.at("jobTemplate", "spec") : spec
                if let pod = job?.at("template", "spec") { facts += podFacts(pod) }
                result.append(Found(kind: kind, name: name, facts: facts, line: line))
            case "Service":
                let selector = spec?["selector"]
                let target = selector?["app"]?.string ?? selector?["app.kubernetes.io/name"]?.string ?? name
                let ports = (spec?["ports"]?.items ?? []).compactMap { $0["targetPort"]?.string ?? $0["port"]?.string }
                if !ports.isEmpty { result.append(Found(kind: anyKind, name: target, facts: ports.map { "port=" + $0 }, line: line)) }
            case "Ingress":
                var byBackend: [String: [String]] = [:]
                let fallback = spec?.at("defaultBackend", "service", "name")?.string ?? spec?.at("backend", "serviceName")?.string
                for rule in spec?["rules"]?.items ?? [] {
                    let host = rule["host"]?.string
                    for path in rule.at("http", "paths")?.items ?? [] {
                        guard let backend = path.at("backend", "service", "name")?.string ?? path.at("backend", "serviceName")?.string ?? fallback else { continue }
                        if let host { byBackend[backend, default: []].append("host=" + host) }
                        if let route = path["path"]?.string { byBackend[backend, default: []].append("route=" + route) }
                    }
                }
                for (backend, facts) in byBackend.sorted(by: { $0.key < $1.key }) { result.append(Found(kind: anyKind, name: backend, facts: facts, line: line)) }
            case "HTTPRoute":
                let hosts = (spec?["hostnames"]?.strings ?? []).map { "host=" + $0 }
                var byBackend: [String: [String]] = [:]
                for rule in spec?["rules"]?.items ?? [] {
                    let routes = (rule["matches"]?.items ?? []).compactMap { $0.at("path", "value")?.string }.map { "route=" + $0 }
                    for backend in (rule["backendRefs"]?.items ?? []).compactMap({ $0["name"]?.string }) { byBackend[backend, default: []] += hosts + routes }
                }
                for (backend, facts) in byBackend.sorted(by: { $0.key < $1.key }) { result.append(Found(kind: anyKind, name: backend, facts: facts, line: line)) }
            case "HorizontalPodAutoscaler":
                guard let target = spec?.at("scaleTargetRef", "name")?.string else { continue }
                let facts = [("replicas_min", spec?["minReplicas"]?.string), ("replicas_max", spec?["maxReplicas"]?.string)].compactMap { key, value in value.map { key + "=" + $0 } }
                result.append(Found(kind: anyKind, name: target, facts: facts, line: line))
            default:
                continue
            }
        }
        return result
    }

    /// Images, ports, resources, probes, env names and the ConfigMaps and Secrets a pod spec uses.
    static func podFacts(_ pod: YAMLNode) -> [String] {
        var facts: [String] = []
        for container in pod["containers"]?.items ?? [] {
            if let image = container["image"]?.string.flatMap(imageName) { facts.append("image=" + image) }
            for port in container["ports"]?.items ?? [] { if let number = port["containerPort"]?.string { facts.append("port=" + number) } }
            facts += resourceFacts(container["resources"])
            facts += probeFacts(container)
            facts += environmentFacts(container["env"])
            facts += sourceFacts(container["envFrom"])
        }
        for volume in pod["volumes"]?.items ?? [] {
            if let map = volume.at("configMap", "name")?.string { facts.append("config_map=" + map) }
            if let secret = volume.at("secret", "secretName")?.string { facts.append("secret=" + secret) }
        }
        return facts
    }

    static func resourceFacts(_ resources: YAMLNode?) -> [String] {
        ["cpu", "memory"].compactMap { resource in
            let request = resources?.at("requests", resource)?.string, limit = resources?.at("limits", resource)?.string
            return request == nil && limit == nil ? nil : resource + "=" + (request ?? "–") + "/" + (limit ?? "–")
        }
    }

    static func probeFacts(_ container: YAMLNode) -> [String] {
        ["readinessProbe", "livenessProbe", "startupProbe"].compactMap { container.at($0, "httpGet", "path")?.string }.map { "probe=" + $0 }
    }

    /// `env` as a Kubernetes list (`- name: X`) or, in Helm values, maps of variables, possibly
    /// grouped (`env.open`, `env.secrets.<secret name>`): names only.
    static func environmentFacts(_ env: YAMLNode?, depth: Int = 0, secret: Bool = false) -> [String] {
        guard let env, depth < 4 else { return [] }
        var facts: [String] = []
        for variable in env.items {
            if let name = variable["name"]?.string { facts.append("env=" + name) }
            if let name = variable.at("valueFrom", "secretKeyRef", "name")?.string { facts.append("secret=" + name) }
            if let name = variable.at("valueFrom", "configMapKeyRef", "name")?.string { facts.append("config_map=" + name) }
        }
        for (key, value) in env.entries {
            if isVariable(key) { facts.append("env=" + key); continue }
            if secret, depth >= 1, value.isMap, isName(key) { facts.append("secret=" + key) }
            facts += environmentFacts(value, depth: depth + 1, secret: secret || key.lowercased().contains("secret"))
        }
        return facts
    }

    static func sourceFacts(_ sources: YAMLNode?) -> [String] {
        var facts: [String] = []
        for source in sources?.items ?? [] {
            if let map = source.at("configMapRef", "name")?.string { facts.append("config_map=" + map) }
            if let secret = source.at("secretRef", "name")?.string { facts.append("secret=" + secret) }
        }
        return facts
    }

    static func isVariable(_ key: String) -> Bool { key.range(of: #"^[A-Z][A-Z0-9_]+$"#, options: .regularExpression) != nil }

    // MARK: Helm values

    /// The chart a `values*.yaml` next to a Chart.yaml configures: its name, and the keys its
    /// dependencies' values go under (alias or name).
    static func chart(of file: ExtractionInput) -> (name: String, keys: Set<String>)? {
        let lower = file.fileName.lowercased()
        guard lower.hasPrefix("values"), lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") else { return nil }
        let path = file.directory.isEmpty ? "Chart.yaml" : file.directory + "/Chart.yaml"
        guard file.files.contains(path), let text = try? String(contentsOfFile: file.root + "/" + path, encoding: .utf8),
              let chart = YAMLTree.parse(text), let name = chart["name"]?.string else { return nil }
        var keys: Set<String> = [name]
        for dependency in chart["dependencies"]?.items ?? [] {
            if let key = dependency["alias"]?.string ?? dependency["name"]?.string { keys.insert(key) }
        }
        return (name, keys)
    }

    static let runtimeKeys: Set<String> = ["image", "replicaCount", "replicas", "resources", "env", "schedule", "hpa", "autoscaling", "ingress",
                                           "service", "readinessProbe", "livenessProbe", "containerPort", "httproute", "httpRoute"]

    /// Workloads a values file configures: the chart itself when its keys are at the top, and
    /// each dependency configured under its key. An overlay (`values-prod.yaml`) names its
    /// environment and leaves the kind to the base values.
    static func values(_ text: String, fileName: String, chart: (name: String, keys: Set<String>)) -> [Found] {
        guard let root = YAMLTree.parse(text) else { return [] }
        let base = (fileName as NSString).deletingPathExtension
        let environment = base.count > 7 ? String(base.dropFirst(7)) : nil
        var found: [Found] = []
        func add(_ name: String, _ values: YAMLNode, line: Int) {
            var facts = valueFacts(values)
            if let environment { facts.append("environment=" + environment) }
            let kind = environment != nil ? anyKind : values["schedule"] != nil ? "CronJob" : "Deployment"
            if environment == nil { facts.insert("kind=" + kind, at: 0) }
            found.append(Found(kind: kind, name: name, facts: facts, line: line))
        }
        if root.entries.contains(where: { runtimeKeys.contains($0.key) }) { add(chart.name, root, line: 1) }
        for (key, node) in root.entries where chart.keys.contains(key) && node.entries.contains(where: { runtimeKeys.contains($0.key) }) {
            add(key, node, line: max(node.line - 1, 1))
        }
        return found
    }

    static func valueFacts(_ values: YAMLNode) -> [String] {
        var facts: [String] = []
        if let image = values["image"] {
            let reference = image.string ?? image["repository"]?.string.map { repository in
                [image["registry"]?.string, repository].compactMap { $0 }.joined(separator: "/")
            }
            if let name = reference.flatMap(imageName) { facts.append("image=" + name) }
        }
        if let replicas = (values["replicaCount"] ?? values["replicas"])?.string { facts.append("replicas=" + replicas) }
        for key in ["hpa", "autoscaling"] {
            guard let scaling = values[key], scaling["enabled"]?.string != "false" else { continue }
            if let low = scaling["minReplicas"]?.string { facts.append("replicas_min=" + low) }
            if let high = scaling["maxReplicas"]?.string { facts.append("replicas_max=" + high) }
        }
        facts += resourceFacts(values["resources"])
        facts += probeFacts(values)
        if let schedule = values["schedule"]?.string { facts.append("schedule=" + schedule) }
        for port in [values.at("service", "targetPort"), values.at("service", "port"), values["containerPort"]].compactMap({ $0?.string }) {
            facts.append("port=" + port)
        }
        for key in ["env", "extraEnv", "extraEnvVars", "envVars"] { facts += environmentFacts(values[key]) }
        facts += sourceFacts(values["envFrom"])
        if let ingress = values["ingress"], ingress["enabled"]?.string != "false" {
            if let host = ingress["host"]?.string { facts.append("host=" + host) }
            for host in ingress["hosts"]?.items ?? [] {
                if let name = host.string ?? host["host"]?.string { facts.append("host=" + name) }
                for path in host["paths"]?.items ?? [] { if let route = path.string ?? path["path"]?.string { facts.append("route=" + route) } }
            }
        }
        for route in httpRoutes(values, depth: 0) {
            facts += route.strings("hostnames").map { "host=" + $0 }
            if let rules = route["rules"] {
                let text = rules.string ?? ""
                let paths = text.isEmpty
                    ? rules.items.flatMap { ($0["matches"]?.items ?? []).compactMap { $0.at("path", "value")?.string } }
                    : SourceScan.matches(#"value:\s*["']?(/[^\s"']*)"#, in: text).map { $0[1] }
                facts += paths.map { "route=" + $0 }
            }
        }
        return facts
    }

    private static func httpRoutes(_ node: YAMLNode, depth: Int) -> [YAMLNode] {
        guard depth < 3 else { return [] }
        return node.entries.flatMap { key, value in
            key.lowercased() == "httproute" && value.isMap ? [value] : httpRoutes(value, depth: depth + 1)
        }
    }

    // MARK: Terraform

    static let terraformKinds: [String: String] = [
        "kubernetes_deployment": "Deployment", "kubernetes_deployment_v1": "Deployment", "kubernetes_stateful_set": "StatefulSet",
        "kubernetes_stateful_set_v1": "StatefulSet", "kubernetes_daemonset": "DaemonSet", "kubernetes_daemon_set_v1": "DaemonSet",
        "kubernetes_cron_job": "CronJob", "kubernetes_cron_job_v1": "CronJob", "kubernetes_job": "Job", "kubernetes_job_v1": "Job",
        "google_cloud_run_service": "CloudRunService", "google_cloud_run_v2_service": "CloudRunService", "google_cloud_run_v2_job": "CloudRunJob",
        "helm_release": "HelmRelease",
    ]

    static func terraform(_ file: ExtractionInput) -> [Found] {
        let lines = file.text.components(separatedBy: "\n")
        var result: [Found] = []
        for symbol in file.parsed.symbols where symbol.kind == "resource" {
            guard let kind = terraformKinds[String(symbol.name.prefix { $0 != "." })], symbol.line <= lines.count else { continue }
            let body = lines[(symbol.line - 1)..<min(symbol.endLine, lines.count)].joined(separator: "\n")
            guard let name = SourceScan.matches(#"\bname\s*=\s*"([\w.-]+)""#, in: body).first?[1] else { continue }
            var facts = ["kind=" + kind]
            facts += SourceScan.matches(#"\bimage\s*=\s*"([^"]+)""#, in: body).compactMap { imageName($0[1]) }.map { "image=" + $0 }
            facts += SourceScan.matches(#"\breplicas\s*=\s*"?(\d+)"#, in: body).map { "replicas=" + $0[1] }
            facts += SourceScan.matches(#"\bmin_instance_count\s*=\s*(\d+)"#, in: body).map { "replicas_min=" + $0[1] }
            facts += SourceScan.matches(#"\bmax_instance_count\s*=\s*(\d+)"#, in: body).map { "replicas_max=" + $0[1] }
            facts += SourceScan.matches(#"\bschedule\s*=\s*"([^"]+)""#, in: body).map { "schedule=" + $0[1] }
            facts += SourceScan.matches(#"\bcontainer_port\s*=\s*(\d+)"#, in: body).map { "port=" + $0[1] }
            facts += SourceScan.matches(#"\bname\s*=\s*"([A-Z][A-Z0-9_]+)""#, in: body).map { "env=" + $0[1] }
            facts += SourceScan.matches(#"\bchart\s*=\s*"([^"]+)""#, in: body).map { "chart=" + $0[1] }
            result.append(Found(kind: kind, name: name, facts: facts, line: symbol.line))
        }
        return result
    }
}

private extension YAMLNode {
    func strings(_ key: String) -> [String] { self[key]?.strings ?? [] }
}

/// The link pass for workloads: merges each workload's facts from every file into its node,
/// drops workloads no file mentions any more, and links them to the services deploying them,
/// their images, env variables and hosts.
enum WorkloadLinks {
    static func link(repo: String, root: String, refs: [(file: String, ref: KnowledgeRef)], store: KnowledgeStore) async throws -> [KnowledgeEdge] {
        let prefix = "workload:" + repo + ":"
        let filePrefix = ("file:" + root + "/").count
        var defined: [String: [(file: String, ref: KnowledgeRef)]] = [:]
        var byName: [String: [(file: String, ref: KnowledgeRef)]] = [:]
        for item in refs where item.ref.kind == RuntimeExtractor.factKind && item.ref.src.hasPrefix(prefix) {
            let rest = item.ref.src.dropFirst(prefix.count)
            if rest.hasPrefix(RuntimeExtractor.anyKind + "/") {
                byName[String(rest.dropFirst(2)), default: []].append(item)
            } else {
                defined[item.ref.src, default: []].append(item)
            }
        }
        let services = try await store.definitions(repo: repo, idPrefix: "service:")
        var nodes: [KnowledgeNode] = []
        var shared: [KnowledgeNode] = []
        var edges: [KnowledgeEdge] = []
        for (id, own) in defined {
            let body = id.dropFirst(prefix.count)
            guard let slash = body.firstIndex(of: "/") else { continue }
            let kind = String(body[..<slash]), name = String(body[body.index(after: slash)...])
            let sortedOwn = own.sorted { ($0.ref.names.contains { $0.hasPrefix("kind=") } ? 0 : 1, $0.file) < ($1.ref.names.contains { $0.hasPrefix("kind=") } ? 0 : 1, $1.file) }
            let all = sortedOwn + (byName[name] ?? []).sorted { $0.file < $1.file }
            var paths: [String] = []
            for item in all where !paths.contains(String(item.file.dropFirst(filePrefix))) { paths.append(String(item.file.dropFirst(filePrefix))) }
            let facts = Facts(all.flatMap(\.ref.names))
            let text = describe(kind: kind, name: name, facts: facts, paths: paths)
            nodes.append(KnowledgeNode(id: id, kind: "workload", name: name, qualified: kind + "/" + name, repo: repo, path: paths.first ?? "",
                                       line: sortedOwn.first?.ref.line ?? 0, language: kind, signature: text.signature, summary: text.summary, source: "code"))
            edges += paths.map { KnowledgeEdge(src: id, dst: "file:" + root + "/" + $0, kind: "defined_in", source: ExtractionLinks.source) }
            for image in facts["image"] {
                shared.append(KnowledgeNode(id: "image:" + image, kind: "image", name: image, qualified: image, signature: "Container image " + image, source: "code"))
                edges.append(KnowledgeEdge(src: id, dst: "image:" + image, kind: "uses_image", source: ExtractionLinks.source))
            }
            for variable in facts["env"] {
                shared.append(KnowledgeNode(id: "env:" + variable, kind: "env", name: variable, qualified: variable, source: "code"))
                edges.append(KnowledgeEdge(src: id, dst: "env:" + variable, kind: "sets_env", source: ExtractionLinks.source))
            }
            // The services deploying it: the one of its name, else those defined next to its files.
            let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
            let named = services.filter { $0.id == ServiceExtractor.id(repo: repo, name: name) }
            let deploying = Set((named.isEmpty ? services.filter { folders.contains(($0.path as NSString).deletingLastPathComponent) } : named).map(\.id))
            edges += deploying.map { KnowledgeEdge(src: $0, dst: id, kind: "deploys", source: ExtractionLinks.source) }
            for host in facts["host"] where !host.contains("{{") && !host.contains("*") {
                let hostID = OutboundCallExtractor.hostID(host)
                shared.append(KnowledgeNode(id: hostID, kind: "host", name: host, qualified: host, signature: "Host " + host, source: "code"))
                edges.append(KnowledgeEdge(src: hostID, dst: id, kind: "about", source: ExtractionLinks.source))
                edges += deploying.map { KnowledgeEdge(src: hostID, dst: $0, kind: "about", source: ExtractionLinks.source) }
            }
        }
        let kept = Set(nodes.map(\.id))
        for stale in try await store.nodes(kind: "workload", repo: repo, limit: 100_000) where !kept.contains(stale.id) {
            try await store.removeNode(stale.id)
        }
        try await store.ensure(shared)
        try await store.upsert(nodes)
        return edges
    }

    /// Facts "key=value", each value once, in the order first seen.
    struct Facts {
        private var values: [String: [String]] = [:]

        init(_ facts: [String]) {
            for fact in facts {
                guard let equals = fact.firstIndex(of: "=") else { continue }
                let key = String(fact[..<equals]), value = String(fact[fact.index(after: equals)...])
                if !(values[key] ?? []).contains(value) { values[key, default: []].append(value) }
            }
        }

        subscript(key: String) -> [String] { values[key] ?? [] }
    }

    static func describe(kind: String, name: String, facts: Facts, paths: [String]) -> (signature: String, summary: String) {
        func list(_ items: [String], limit: Int) -> String {
            items.prefix(limit).joined(separator: ", ") + (items.count > limit ? " (+\(items.count - limit) more)" : "")
        }
        var parts = ["\(kind) \(name)"]
        if !facts["image"].isEmpty { parts.append("image " + list(facts["image"], limit: 2)) }
        if let high = facts["replicas_max"].first {
            parts.append("\(facts["replicas_min"].first ?? facts["replicas"].first ?? "1")–\(high) replicas")
        } else if let count = facts["replicas"].first {
            parts.append(count == "1" ? "1 replica" : "\(count) replicas")
        }
        if !facts["port"].isEmpty { parts.append((facts["port"].count == 1 ? "port " : "ports ") + list(facts["port"], limit: 4)) }
        for resource in ["cpu", "memory"] { if let value = facts[resource].first { parts.append(resource + " " + value) } }
        if let schedule = facts["schedule"].first { parts.append("schedule " + schedule) }
        if let chart = facts["chart"].first { parts.append("chart " + chart) }
        var summary: [String] = []
        if !facts["environment"].isEmpty { summary.append("Environments: " + list(facts["environment"], limit: 12) + ".") }
        if !facts["host"].isEmpty { summary.append("Hosts: " + list(facts["host"], limit: 8) + ".") }
        if !facts["route"].isEmpty { summary.append("Routes: " + list(facts["route"], limit: 12) + ".") }
        if !facts["probe"].isEmpty { summary.append("Probes: " + list(facts["probe"], limit: 4) + ".") }
        if !facts["env"].isEmpty { summary.append("Environment variables: " + list(facts["env"], limit: 30) + ".") }
        if !facts["config_map"].isEmpty { summary.append("Config maps: " + list(facts["config_map"], limit: 10) + ".") }
        if !facts["secret"].isEmpty { summary.append("Secrets (names only): " + list(facts["secret"], limit: 10) + ".") }
        summary.append("Defined in " + list(paths, limit: 6) + ".")
        return (parts.joined(separator: " · "), summary.joined(separator: " "))
    }
}

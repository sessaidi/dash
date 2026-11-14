import Foundation

/// What `up-toolbox workspace generate` produces, as Kubernetes objects: the services' manifests
/// copied from the `default` namespace of the source cluster and rewritten for a workspace
/// (one replica, the workspace compute class, fixed resources, rewritten env and configs), plus
/// the namespace and, for common-api-gateway, its varnish sidecar, HTTPRoute and health check.
public enum WorkspaceGenerator {
    public static let capig = "common-api-gateway"
    /// `--services` shortcuts.
    public static let shortcuts = ["capig": "common-api-gateway", "papi": "services-presentation-api",
                                   "vapi": "services-video-api", "vapihb": "services-video-api-heartbeat"]
    public static let defaultServices = ["common-api-gateway", "services-presentation-api"]
    static let baseURLServices: Set<String> = ["services-presentation-api", "services-video-api", "services-video-api-heartbeat"]

    public struct Options: Sendable, Equatable {
        public var name: String
        public var env: WorkspaceEnvironment
        public var region: WorkspaceRegion
        /// The `deployed_by` label (up-toolbox uses the OS user name).
        public var username: String
        /// Full service names (see `expand`).
        public var services: [String]
        /// The service whose ConfigMaps are replaced by `overrideConfig` (`-o`): the project in the worktree.
        public var currentProject: String?
        /// File name → contents, from the `-o` folder (base names, like up-toolbox).
        public var overrideConfig: [String: String]
        public var now: Date

        public init(name: String, env: WorkspaceEnvironment, region: WorkspaceRegion, username: String, services: [String] = WorkspaceGenerator.defaultServices,
                    currentProject: String? = nil, overrideConfig: [String: String] = [:], now: Date = Date()) {
            self.name = name.lowercased()
            self.env = env
            self.region = region
            self.username = username
            self.services = services
            self.currentProject = currentProject
            self.overrideConfig = overrideConfig
            self.now = now
        }
    }

    /// What generate reads from `default` on the source cluster.
    public struct Source: Sendable {
        public var deployments: [String: JSON]
        public var services: [String: JSON]
        /// Every service in `default`: name → first port.
        public var servicePorts: [String: Int]
        public var secrets: [String: JSON]
        public var configMaps: [String: JSON]

        public init(deployments: [String: JSON], services: [String: JSON], servicePorts: [String: Int], secrets: [String: JSON], configMaps: [String: JSON]) {
            self.deployments = deployments
            self.services = services
            self.servicePorts = servicePorts
            self.secrets = secrets
            self.configMaps = configMaps
        }
    }

    public enum GeneratorError: LocalizedError {
        case invalidName(String)
        case missing(String)
        case badConfig(String)
        public var errorDescription: String? {
            switch self {
            case .invalidName(let name): "“\(name)” can't be a workspace name: lowercase letters, digits and hyphens, not default, papi or kube-*."
            case .missing(let what): "Not found in the source cluster: \(what)."
            case .badConfig(let detail): detail
            }
        }
    }

    /// `capig,papi,my-service` → full names.
    public static func expand(_ services: String) -> [String] {
        let names = services.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? defaultServices : names.map { shortcuts[$0] ?? $0 }
    }

    /// Valid Kubernetes namespace and not reserved (stricter than up-toolbox, which lets `_` through).
    public static func validate(_ name: String) throws {
        let lower = name.lowercased()
        guard lower.range(of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil,
              !["default", "papi"].contains(lower), !lower.hasPrefix("kube-") else { throw GeneratorError.invalidName(name) }
    }

    /// `<name>.backend-workspace[-<region>].<env>-01.fubo.tv`
    public static func host(name: String, env: WorkspaceEnvironment, region: WorkspaceRegion) -> String {
        region == .us ? "\(name).backend-workspace.\(env.rawValue)-01.fubo.tv" : "\(name).backend-workspace-\(region.rawValue).\(env.rawValue)-01.fubo.tv"
    }

    /// The secrets and ConfigMaps (volumes) the services' deployments need.
    public static func dependencies(of deployments: [JSON]) -> (secrets: [String], configMaps: [String]) {
        var secrets: [String] = []
        var configMaps: [String] = []
        for deployment in deployments {
            let spec = deployment["spec"]?["template"]?["spec"]
            for container in spec?["containers"]?.array ?? [] {
                for env in container["env"]?.array ?? [] {
                    if let name = env["valueFrom"]?["secretKeyRef"]?["name"]?.string, !secrets.contains(name) { secrets.append(name) }
                }
            }
            for volume in spec?["volumes"]?.array ?? [] {
                if let name = volume["configMap"]?["name"]?.string, !configMaps.contains(name) { configMaps.append(name) }
            }
        }
        return (secrets, configMaps)
    }

    /// Every object, in the order they're created: Namespace, Secrets, ConfigMaps, Services,
    /// Deployments, HTTPRoute, HealthCheckPolicy.
    public static func manifests(_ source: Source, options: Options) throws -> [JSON] {
        try validate(options.name)
        let ws = options.name
        let capigHost = host(name: ws, env: options.env, region: options.region)
        let replaced = Set(options.services.filter { $0 != capig })
        var secrets: [JSON] = []
        var configMaps: [JSON] = []
        var services: [JSON] = []
        var deployments: [JSON] = []
        var extras: [JSON] = []
        var seenSecrets = Set<String>()
        var seenConfigMaps = Set<String>()

        for service in options.services {
            guard let deployment = source.deployments[service] else { throw GeneratorError.missing("deployment \(service)") }
            guard let svc = source.services[service] else { throw GeneratorError.missing("service \(service)") }
            let needs = dependencies(of: [deployment])
            for name in needs.secrets where seenSecrets.insert(name).inserted {
                guard let secret = source.secrets[name] else { throw GeneratorError.missing("secret \(name)") }
                secrets.append(Self.secret(secret, namespace: ws))
            }
            for name in needs.configMaps where seenConfigMaps.insert(name).inserted {
                guard let configMap = source.configMaps[name] else { throw GeneratorError.missing("configmap \(name)") }
                configMaps.append(try Self.configMap(configMap, service: service, options: options, replaced: replaced, ports: source.servicePorts))
            }
            if service == capig {
                configMaps.append(["apiVersion": "v1", "kind": "ConfigMap",
                                   "metadata": ["name": "common-api-gateway-varnish-config", "namespace": .string(ws)],
                                   "data": ["default.vcl": .string(varnishVCL)]])
                extras.append(httpRoute(ws: ws, host: capigHost, region: options.region, port: svc["spec"]?["ports"]?.array?.first?["port"]?.int ?? 80))
                extras.append(healthCheckPolicy(ws: ws))
            }
            services.append(Self.service(svc, namespace: ws))
            deployments.append(Self.deployment(deployment, namespace: ws, capigHost: capigHost))
        }
        return [namespace(options)] + secrets + configMaps + services + deployments + extras
    }

    // MARK: Objects

    static func namespace(_ options: Options) -> JSON {
        ["apiVersion": "v1", "kind": "Namespace",
         "metadata": ["name": .string(options.name),
                      "annotations": ["deployed_at": .string(ISO8601DateFormatter().string(from: options.now))],
                      "labels": ["deployed_by": .string(options.username), "workspace": "true", "region": .string(options.region.rawValue)]]]
    }

    /// Plain-text `stringData`, original type and labels dropped.
    static func secret(_ source: JSON, namespace: String) -> JSON {
        var data: [String: JSON] = [:]
        for (key, value) in source["data"]?.object ?? [:] {
            if let encoded = value.string, let decoded = Data(base64Encoded: encoded) {
                data[key] = .string(String(decoding: decoded, as: UTF8.self))
            }
        }
        for (key, value) in source["stringData"]?.object ?? [:] { data[key] = value }
        return ["apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                "metadata": ["name": source["metadata"]?["name"] ?? .null, "namespace": .string(namespace)],
                "stringData": .object(data)]
    }

    static func configMap(_ source: JSON, service: String, options: Options, replaced: Set<String>, ports: [String: Int]) throws -> JSON {
        var data = (source["data"]?.object ?? [:])
        if service == options.currentProject, !options.overrideConfig.isEmpty {
            for (file, contents) in options.overrideConfig where file != ".DS_Store" { data[file] = .string(contents) }
        }
        for (key, value) in data {
            guard var text = value.string else { continue }
            if ["development.toml", "qa.toml"].contains(key) {
                text = text.replacingOccurrences(of: "rate-limit-redis-sentinel", with: "rate-limit-redis-sentinel.default")
                    .replacingOccurrences(of: "rate-limit-redis-all", with: "rate-limit-redis-all.default")
                data[key] = .string(text)
            } else if ["services_config.json", "services_config_production.json", "services_config_development.json"].contains(key) {
                data[key] = .string(try servicesConfig(text, service: service, ws: options.name, replaced: replaced, ports: ports))
            }
        }
        return ["apiVersion": "v1", "kind": "ConfigMap",
                "metadata": ["name": source["metadata"]?["name"] ?? .null, "namespace": .string(options.name)],
                "data": .object(data)]
    }

    /// Points each service entry at the workspace (services deployed there), at itself
    /// (localhost), or at `default`.
    static func servicesConfig(_ text: String, service: String, ws: String, replaced: Set<String>, ports: [String: Int]) throws -> String {
        guard case .object(var entries) = try JSON.parse(text) else { throw GeneratorError.badConfig("services config is not an object") }
        for (key, entry) in entries {
            guard case .object(var fields) = entry else { continue }
            guard let host = fields["host"]?.string else { throw GeneratorError.badConfig("\(key).host is not a string in \(service)'s services config") }
            if key == service {
                fields["host"] = "localhost"
                fields["port"] = .string(String(ports[key] ?? 80))
            } else if replaced.contains(key) {
                fields["host"] = .string("\(key).\(ws)")
                fields["port"] = .string(String(ports[key] ?? 80))
            } else if ["services-ad-tech", "fubo-segment-proxy"].contains(key) {
                continue
            } else if host.hasPrefix("$") {
                let cleaned = String(host.dropFirst()).replacingOccurrences(of: "_SERVICE_HOST", with: "").lowercased().replacingOccurrences(of: "_", with: "-")
                fields["host"] = .string(cleaned + ".default")
                fields["port"] = .string(String(ports[cleaned] ?? 80))
            } else {
                continue
            }
            entries[key] = .object(fields)
        }
        return JSON.object(entries).pretty
    }

    static func labels(_ source: JSON?, ws: String, dropArgo: Bool) -> JSON {
        var labels = source?.object ?? [:]
        if let env = labels["tags.datadoghq.com/env"]?.string {
            labels["tags.datadoghq.com/env"] = .string("\(env)-workspace")
            labels["tags.datadoghq.com/workspace"] = .string(ws)
        }
        if dropArgo { labels["argocd.argoproj.io/instance"] = nil }
        return .object(labels)
    }

    static func deployment(_ source: JSON, namespace ws: String, capigHost: String) -> JSON {
        let name = source["metadata"]?["name"]?.string ?? ""
        let template = source["spec"]?["template"]
        let podSpec = template?["spec"]
        var volumes: [JSON] = (podSpec?["volumes"]?.array ?? []).map { volume in
            var result: [String: JSON] = ["name": volume["name"] ?? .null]
            if let configMap = volume["configMap"] {
                var source: [String: JSON] = ["name": configMap["name"] ?? .null]
                if let mode = configMap["defaultMode"] { source["defaultMode"] = mode }
                result["configMap"] = .object(source)
            }
            return .object(result)
        }
        if name == capig {
            volumes.append(["name": "varnish-config", "configMap": ["name": "common-api-gateway-varnish-config", "defaultMode": 420]])
        }
        var containers: [JSON] = []
        for container in podSpec?["containers"]?.array ?? [] {
            containers.append(Self.container(container, deployment: name, ws: ws, capigHost: capigHost))
            if name == capig {
                containers.append(["name": "varnish", "image": "varnish:7.4", "imagePullPolicy": "Always",
                                   "ports": [["name": "proxy", "containerPort": 8081]],
                                   "env": [["name": "VARNISH_HTTP_PORT", "value": "8081"]],
                                   "args": ["-p", "http_max_hdr=128"],
                                   "volumeMounts": [["name": "varnish-config", "mountPath": "/etc/varnish/"]]])
            }
        }
        var spec: [String: JSON] = [
            "replicas": 1,
            "template": ["metadata": ["labels": labels(template?["metadata"]?["labels"], ws: ws, dropArgo: false),
                                      "annotations": ["cluster-autoscaler.kubernetes.io/safe-to-evict": "true"]],
                         "spec": ["nodeSelector": ["cloud.google.com/compute-class": "workspaces-cost-optimized"],
                                  "tolerations": [["key": "cloud.google.com/compute-class", "operator": "Equal",
                                                   "value": "workspaces-cost-optimized", "effect": "NoSchedule"]],
                                  "containers": .array(containers), "volumes": .array(volumes)]],
        ]
        if let selector = source["spec"]?["selector"]?["matchLabels"] { spec["selector"] = ["matchLabels": selector] }
        return ["apiVersion": "apps/v1", "kind": "Deployment",
                "metadata": ["name": .string(name), "namespace": .string(ws), "labels": labels(source["metadata"]?["labels"], ws: ws, dropArgo: true)],
                "spec": .object(spec)]
    }

    static func container(_ source: JSON, deployment: String, ws: String, capigHost: String) -> JSON {
        var env: [JSON] = []
        for variable in source["env"]?.array ?? [] {
            let name = variable["name"]?.string ?? ""
            if baseURLServices.contains(deployment) && name == "BASE_URL" { env.append(["name": "BASE_URL", "value": .string("https://\(capigHost)")]); continue }
            if name == "BUILD_SOURCE" { env.append(["name": "BUILD_SOURCE", "value": .string(ws)]); continue }
            if name == "ENABLE_DD_PROFILING" { env.append(["name": .string(name), "value": "false"]); continue }
            if ["ROUTE_DATA_SOURCE", "CB_DATA_SOURCE", "SERVICES_DATA_SOURCE"].contains(name) { env.append(["name": .string(name), "value": "static"]); continue }
            if name == "SHADOW_COMPARE_ENABLED" { continue }
            if let value = variable["value"]?.string, !value.isEmpty { env.append(["name": .string(name), "value": .string(value)]); continue }
            if let from = variable["valueFrom"] {
                if let ref = from["secretKeyRef"] {
                    env.append(["name": .string(name), "valueFrom": ["secretKeyRef": ["key": ref["key"] ?? .null, "name": ref["name"] ?? .null]]])
                } else if let ref = from["fieldRef"] {
                    env.append(["name": .string(name), "valueFrom": ["fieldRef": ["apiVersion": ref["apiVersion"] ?? "v1", "fieldPath": ref["fieldPath"] ?? .null]]])
                } else if let ref = from["resourceFieldRef"] {
                    env.append(["name": .string(name), "valueFrom": ["resourceFieldRef": ["containerName": ref["containerName"] ?? "", "resource": ref["resource"] ?? .null,
                                                                                          "divisor": ref["divisor"] ?? "0"]]])
                }
            }
        }
        if deployment == capig { env.append(["name": "SHADOW_COMPARE_ENABLED", "value": "false"]) }

        func probe(_ probe: JSON?) -> JSON? {
            guard let probe, let get = probe["httpGet"] else { return nil }
            var result: [String: JSON] = [:]
            for key in ["failureThreshold", "successThreshold", "initialDelaySeconds", "periodSeconds", "timeoutSeconds"] { if let value = probe[key] { result[key] = value } }
            result["httpGet"] = ["path": get["path"] ?? "/", "port": .number(Double(get["port"]?.int ?? 0)), "scheme": get["scheme"] ?? "HTTP"]
            return .object(result)
        }
        let memory = deployment == "services-presentation-api" ? "8G" : "2G"
        var result: [String: JSON] = [
            "name": source["name"] ?? .null, "image": source["image"] ?? .null,
            "ports": .array((source["ports"]?.array ?? []).map { ["containerPort": $0["containerPort"] ?? .null, "name": $0["name"] ?? ""] }),
            "volumeMounts": .array((source["volumeMounts"]?.array ?? []).map { ["name": $0["name"] ?? .null, "mountPath": $0["mountPath"] ?? .null] }),
            "env": .array(env),
            "resources": ["requests": ["memory": .string(memory), "cpu": "500m"], "limits": ["memory": .string(memory), "cpu": "1"]],
        ]
        for key in ["imagePullPolicy", "terminationMessagePath", "terminationMessagePolicy"] { if let value = source[key] { result[key] = value } }
        if let liveness = probe(source["livenessProbe"]) { result["livenessProbe"] = liveness }
        if let readiness = probe(source["readinessProbe"]) { result["readinessProbe"] = readiness }
        return .object(result)
    }

    static func service(_ source: JSON, namespace ws: String) -> JSON {
        let name = source["metadata"]?["name"]?.string ?? ""
        let ports = source["spec"]?["ports"]?.array ?? []
        let first = ports.first?["port"]?.int ?? 80
        return ["apiVersion": "v1", "kind": "Service",
                "metadata": ["name": .string(name), "namespace": .string(ws), "labels": source["metadata"]?["labels"] ?? [:],
                             "annotations": ["cloud.google.com/neg": .string(#"{"ingress": true, "exposed_ports": {"\#(first)":{}}}"#)]],
                "spec": ["type": "ClusterIP", "selector": source["spec"]?["selector"] ?? [:],
                         "ports": .array(ports.map { port in
                             var target = port["targetPort"]?.int ?? 0
                             if name == capig && target == 8080 { target = 8081 }
                             return ["port": port["port"] ?? .null, "targetPort": .number(Double(target)),
                                     "protocol": port["protocol"] ?? "TCP", "name": port["name"] ?? ""]
                         })]]
    }

    static func httpRoute(ws: String, host: String, region: WorkspaceRegion, port: Int) -> JSON {
        ["apiVersion": "gateway.networking.k8s.io/v1beta1", "kind": "HTTPRoute",
         "metadata": ["name": "common-api-gateway-route", "namespace": .string(ws)],
         "spec": ["parentRefs": [["kind": "Gateway", "name": .string(region == .us ? "workspaces-http" : "eu-workspaces-http"), "namespace": "default"]],
                  "hostnames": [.string(host)],
                  "rules": [["matches": [["path": ["type": "PathPrefix", "value": "/"]]],
                             "filters": [["type": "RequestHeaderModifier", "requestHeaderModifier": ["add": [
                                 ["name": "X-GCP-Country-Code", "value": "{client_region}"],
                                 ["name": "X-GCP-Client-IP", "value": "{client_ip_address}"]]]]],
                             "backendRefs": [["name": "common-api-gateway", "port": .number(Double(port))]]]]]]
    }

    static func healthCheckPolicy(ws: String) -> JSON {
        ["apiVersion": "networking.gke.io/v1", "kind": "HealthCheckPolicy",
         "metadata": ["name": "common-api-gateway-healthcheck", "namespace": .string(ws)],
         "spec": ["default": ["checkIntervalSec": 10, "timeoutSec": 2, "healthyThreshold": 1, "unhealthyThreshold": 2,
                              "logConfig": ["enabled": false],
                              "config": ["type": "HTTP", "httpHealthCheck": ["portSpecification": "USE_SERVING_PORT", "requestPath": "/gateway/healthcheck"]]],
                  "targetRef": ["group": "", "kind": "Service", "name": "common-api-gateway"]]]
    }
}

extension WorkspaceClient {
    /// The cluster generate copies from: the `api*` cluster serving `default/common-api-gateway`.
    public static func connectSource(env: WorkspaceEnvironment, region: WorkspaceRegion, credentials: any GoogleTokenSource) async throws -> WorkspaceClient {
        let clusters = try await GKE(credentials: credentials).clusters(project: env.project)
            .filter { $0.name.hasPrefix("api") && $0.location.hasPrefix(region.locationPrefix) }
        var lastError: Error?
        for cluster in clusters {
            let kube = KubernetesClient(cluster: cluster, credentials: credentials)
            do {
                if try await kube.getIfExists("/api/v1/namespaces/default/services/\(WorkspaceGenerator.capig)") != nil {
                    return WorkspaceClient(env: env, region: region, kube: kube)
                }
            } catch { lastError = error }
        }
        if let lastError { throw lastError }
        throw WorkspaceKitError.clusterNotFound("\(env.project): no api* cluster serves default/\(WorkspaceGenerator.capig)")
    }

    /// Reads what generate needs from `default`.
    public func readSource(services: [String]) async throws -> WorkspaceGenerator.Source {
        var deployments: [String: JSON] = [:]
        var svcs: [String: JSON] = [:]
        for service in services {
            guard let deployment = try await kube.getIfExists("/apis/apps/v1/namespaces/default/deployments/\(service)") else {
                throw WorkspaceGenerator.GeneratorError.missing("deployment default/\(service)")
            }
            guard let svc = try await kube.getIfExists("/api/v1/namespaces/default/services/\(service)") else {
                throw WorkspaceGenerator.GeneratorError.missing("service default/\(service)")
            }
            deployments[service] = deployment
            svcs[service] = svc
        }
        var ports: [String: Int] = [:]
        for item in try await kube.get("/api/v1/namespaces/default/services", query: ["limit": "500"])["items"]?.array ?? [] {
            if let name = item["metadata"]?["name"]?.string, let port = item["spec"]?["ports"]?.array?.first?["port"]?.int { ports[name] = port }
        }
        let needs = WorkspaceGenerator.dependencies(of: Array(deployments.values))
        var secrets: [String: JSON] = [:]
        for name in needs.secrets { secrets[name] = try await kube.getIfExists("/api/v1/namespaces/default/secrets/\(name)") }
        var configMaps: [String: JSON] = [:]
        for name in needs.configMaps { configMaps[name] = try await kube.getIfExists("/api/v1/namespaces/default/configmaps/\(name)") }
        return .init(deployments: deployments, services: svcs, servicePorts: ports, secrets: secrets, configMaps: configMaps)
    }

    /// `up`: creates every object, Namespace first (fails if any exists, like `kubectl create`).
    public func up(_ manifests: [JSON], namespace: String) async throws {
        try await create(manifests: manifests, namespace: namespace)
    }

    /// Replaces a ConfigMap's data (configuration changes), then restarts the deployments that
    /// mount it so they read the new files.
    public func updateConfigMap(workspace: String, name: String, data: [String: String]) async throws -> [String] {
        _ = try await kube.patch("/api/v1/namespaces/\(workspace)/configmaps/\(name)",
                                 ["data": .object(data.mapValues { .string($0) })], type: .merge)
        let deployments = try await kube.get("/apis/apps/v1/namespaces/\(workspace)/deployments")["items"]?.array ?? []
        var restarted: [String] = []
        for deployment in deployments where WorkspaceGenerator.dependencies(of: [deployment]).configMaps.contains(name) {
            let app = deployment["metadata"]?["name"]?.string ?? ""
            _ = try await kube.patch("/apis/apps/v1/namespaces/\(workspace)/deployments/\(app)",
                                     ["spec": ["template": ["metadata": ["annotations": ["kubectl.kubernetes.io/restartedAt": .string(ISO8601DateFormatter().string(from: Date()))]]]]],
                                     type: .strategicMerge)
            restarted.append(app)
        }
        return restarted
    }

    /// Sets or removes environment variables on an app's container, which rolls its pods.
    public func setEnvironment(workspace: String, app: String, set values: [String: String], remove: [String] = []) async throws {
        var env: [JSON] = values.sorted { $0.key < $1.key }.map { ["name": .string($0.key), "value": .string($0.value)] }
        env += remove.map { ["name": .string($0), "$patch": "delete"] }
        _ = try await kube.patch("/apis/apps/v1/namespaces/\(workspace)/deployments/\(app)",
                                 ["spec": ["template": ["spec": ["containers": [["name": .string(app), "env": .array(env)]]]]]], type: .strategicMerge)
    }
}

extension WorkspaceClient {
    /// `kubectl rollout restart deployment/<app>`: new pods with the same spec.
    public func restart(workspace: String, app: String) async throws {
        _ = try await kube.patch("/apis/apps/v1/namespaces/\(workspace)/deployments/\(app)",
                                 ["spec": ["template": ["metadata": ["annotations": ["kubectl.kubernetes.io/restartedAt": .string(ISO8601DateFormatter().string(from: Date()))]]]]],
                                 type: .strategicMerge)
    }

    /// A ConfigMap's data.
    public func configMap(workspace: String, name: String) async throws -> [String: String] {
        (try await kube.get("/api/v1/namespaces/\(workspace)/configmaps/\(name)")["data"]?.object ?? [:]).compactMapValues(\.string)
    }

    /// ConfigMap names in a workspace.
    public func configMaps(workspace: String) async throws -> [String] {
        (try await kube.get("/api/v1/namespaces/\(workspace)/configmaps")["items"]?.array ?? []).compactMap { $0["metadata"]?["name"]?.string }
            .filter { $0 != "kube-root-ca.crt" }
    }

    /// An app's container environment (plain values; secret references shown as references).
    public func environment(workspace: String, app: String) async throws -> [String: String] {
        let deployment = try await kube.get("/apis/apps/v1/namespaces/\(workspace)/deployments/\(app)")
        let container = deployment["spec"]?["template"]?["spec"]?["containers"]?.array?.first { $0["name"]?.string == app }
            ?? deployment["spec"]?["template"]?["spec"]?["containers"]?.array?.first
        var result: [String: String] = [:]
        for variable in container?["env"]?.array ?? [] {
            guard let name = variable["name"]?.string else { continue }
            if let value = variable["value"]?.string { result[name] = value }
            else if let secret = variable["valueFrom"]?["secretKeyRef"] { result[name] = "<secret \(secret["name"]?.string ?? "")/\(secret["key"]?.string ?? "")>" }
            else if let field = variable["valueFrom"]?["fieldRef"]?["fieldPath"]?.string { result[name] = "<field \(field)>" }
        }
        return result
    }
}

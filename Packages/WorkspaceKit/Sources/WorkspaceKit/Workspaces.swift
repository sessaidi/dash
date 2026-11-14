import Foundation

/// A backend-workspace hosting environment (mirrors up-toolbox `localconfig.Env`).
public enum WorkspaceEnvironment: String, Sendable, CaseIterable, Codable {
    case dev, qa

    public var project: String {
        switch self {
        case .dev: "fubotv-dev"
        case .qa: "model-gearing-425"
        }
    }

    /// Workspace clusters per region (up-toolbox `workspaceClusters`).
    public func cluster(region: WorkspaceRegion) -> (location: String, name: String) {
        switch (self, region) {
        case (.dev, .us), (.qa, .us): ("us-east4-b", "api-cluster-east4")
        case (.dev, .eu): ("europe-west1-b", "api-cluster-europe-west1")
        case (.qa, .eu): ("europe-west1", "api-cluster-europe-west1")
        }
    }
}

public enum WorkspaceRegion: String, Sendable, CaseIterable, Codable {
    case us, eu

    var locationPrefix: String { self == .us ? "us" : "europe" }
}

public enum NodePool: String, Sendable, Codable {
    case spot, standard, legacy, unknown

    /// From a node name (up-toolbox `extractNodePool`).
    public init(nodeName: String) {
        if nodeName.contains("workspaces-spot") { self = .spot }
        else if nodeName.contains("workspaces-stand") { self = .standard }
        else if nodeName.contains("workspaces-node") { self = .legacy }
        else { self = .unknown }
    }
}

public struct Workspace: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let deployedBy: String
    public let region: String
    public let createdAt: Date?
    /// Last `run`/deploy, from the `deployed_at` annotation.
    public let deployedAt: Date?
    public let persist: Bool
    public let nodePool: NodePool
    public let gitBranch: String?
    public let gitHash: String?
    /// "owner/name" of the repository last deployed from (Dash's `dash_repo` annotation).
    public let repo: String?
    public let url: String

    init(namespace: JSON, env: WorkspaceEnvironment, nodePool: NodePool) {
        let metadata = namespace["metadata"] ?? .null
        let annotations = metadata["annotations"] ?? .null
        name = metadata["name"]?.string ?? ""
        deployedBy = metadata["labels"]?["deployed_by"]?.string ?? ""
        region = metadata["labels"]?["region"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "us"
        createdAt = metadata["creationTimestamp"]?.string.flatMap(Self.date)
        deployedAt = annotations["deployed_at"]?.string.flatMap(Self.date)
        persist = annotations["persist"]?.string == "true"
        self.nodePool = nodePool
        gitBranch = annotations["git_branch"]?.string
        gitHash = annotations["git_hash"]?.string
        repo = annotations["dash_repo"]?.string
        url = Self.url(name: name, env: env, region: region)
    }

    /// <name>.backend-workspace[-<region>].<env>-01.fubo.tv (up-toolbox `generateAPIURL`)
    public static func url(name: String, env: WorkspaceEnvironment, region: String) -> String {
        region == "us" ? "\(name).backend-workspace.\(env.rawValue)-01.fubo.tv" : "\(name).backend-workspace-\(region).\(env.rawValue)-01.fubo.tv"
    }

    static func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

    /// Why `clean` would delete this workspace, or nil to keep it (up-toolbox `isWorkspaceOld` and
    /// `isWorkspaceLegacyOrUnknown`). Persisted workspaces are listed but never deleted.
    public func cleanReason(now: Date = Date()) -> String? {
        let calendar = Calendar(identifier: .gregorian)
        if let deployedAt {
            if deployedAt < calendar.date(byAdding: .day, value: -7, to: now)! { return "not deployed for over a week" }
        } else if let createdAt, createdAt < calendar.date(byAdding: .month, value: -1, to: now)! {
            return "created over a month ago and never deployed"
        }
        if nodePool == .legacy || nodePool == .unknown { return "on a \(nodePool.rawValue) node pool" }
        return nil
    }
}

public struct WorkspaceStatus: Sendable, Equatable {
    public struct Deployment: Sendable, Equatable {
        public let name: String
        public let ready: Int
        public let desired: Int
        public let images: [String]
    }

    public struct Pod: Sendable, Equatable {
        public let name: String
        public let app: String
        public let phase: String
        public let ready: Bool
        public let restarts: Int
        /// CrashLoopBackOff, ImagePullBackOff, … (nil when healthy or starting normally).
        public let problem: String?
        public let nodePool: NodePool
    }

    public let workspace: Workspace
    public let deployments: [Deployment]
    public let pods: [Pod]
    public let hostnames: [String]
}

/// One step of a deploy's convergence wait.
public struct DeployProgress: Sendable, Equatable {
    public let runningVersions: [String]
    public let done: Bool
}

/// Backend workspaces over the Kubernetes API: what `up-toolbox workspace` does, without kubectl.
public struct WorkspaceClient: Sendable {
    public let env: WorkspaceEnvironment
    public let region: WorkspaceRegion
    public let kube: KubernetesClient

    /// Finds the workspace cluster through the GKE API and connects to it.
    public static func connect(env: WorkspaceEnvironment, region: WorkspaceRegion, credentials: any GoogleTokenSource) async throws -> WorkspaceClient {
        let wanted = env.cluster(region: region)
        let clusters = try await GKE(credentials: credentials).clusters(project: env.project)
        let candidates = clusters.filter { $0.name == wanted.name && $0.location == wanted.location }
            + clusters.filter { $0.name.hasPrefix("api") && $0.location.hasPrefix(region.locationPrefix) && !($0.name == wanted.name && $0.location == wanted.location) }
        // Like up-toolbox: the workspace cluster is the one running external-dns.
        var lastError: Error?
        for cluster in candidates {
            let kube = KubernetesClient(cluster: cluster, credentials: credentials)
            do {
                if try await kube.getIfExists("/api/v1/namespaces/external-dns/services/external-dns") != nil {
                    return WorkspaceClient(env: env, region: region, kube: kube)
                }
            } catch {
                lastError = error
            }
        }
        // Surface why the cluster couldn't be used (TLS, 401, VPN) rather than "not found".
        if let lastError { throw lastError }
        throw WorkspaceKitError.clusterNotFound("\(env.project)/\(wanted.location)/\(wanted.name)")
    }

    public init(env: WorkspaceEnvironment, region: WorkspaceRegion, kube: KubernetesClient) {
        self.env = env
        self.region = region
        self.kube = kube
    }

    // MARK: Reading

    /// namespace -> node pool, from every common-api-gateway pod.
    func nodePools() async -> [String: NodePool] {
        let pods = (try? await kube.get("/api/v1/pods", query: ["labelSelector": "name=common-api-gateway"]))?["items"]?.array ?? []
        var pools: [String: NodePool] = [:]
        for pod in pods {
            guard let namespace = pod["metadata"]?["namespace"]?.string, let node = pod["spec"]?["nodeName"]?.string, !node.isEmpty else { continue }
            pools[namespace] = NodePool(nodeName: node)
        }
        return pools
    }

    public func list() async throws -> [Workspace] {
        let namespaces = try await kube.get("/api/v1/namespaces", query: ["labelSelector": "workspace=true", "fieldSelector": "status.phase=Active"])
        let pools = await nodePools()
        return (namespaces["items"]?.array ?? []).map { namespace in
            Workspace(namespace: namespace, env: env, nodePool: pools[namespace["metadata"]?["name"]?.string ?? ""] ?? .unknown)
        }.sorted { $0.name < $1.name }
    }

    func namespace(_ name: String) async throws -> JSON {
        let namespace = try await kube.get("/api/v1/namespaces/\(name)")
        guard namespace["metadata"]?["labels"]?["workspace"]?.string == "true" else { throw WorkspaceKitError.notAWorkspace(name) }
        return namespace
    }

    public func workspace(_ name: String) async throws -> Workspace {
        Workspace(namespace: try await namespace(name), env: env, nodePool: await nodePools()[name] ?? .unknown)
    }

    public func status(_ name: String) async throws -> WorkspaceStatus {
        let workspace = try await workspace(name)
        let deployments = try await kube.get("/apis/apps/v1/namespaces/\(name)/deployments")["items"]?.array ?? []
        let pods = try await kube.get("/api/v1/namespaces/\(name)/pods")["items"]?.array ?? []
        let routes = (try? await kube.get("/apis/gateway.networking.k8s.io/v1/namespaces/\(name)/httproutes"))?["items"]?.array ?? []
        return WorkspaceStatus(
            workspace: workspace,
            deployments: deployments.map { deployment in
                .init(name: deployment["metadata"]?["name"]?.string ?? "",
                      ready: deployment["status"]?["readyReplicas"]?.int ?? 0,
                      desired: deployment["spec"]?["replicas"]?.int ?? 1,
                      images: deployment["spec"]?["template"]?["spec"]?["containers"]?.array?.compactMap { $0["image"]?.string } ?? [])
            },
            pods: pods.map(Self.pod),
            hostnames: routes.flatMap { $0["spec"]?["hostnames"]?.array?.compactMap(\.string) ?? [] })
    }

    static func pod(_ pod: JSON) -> WorkspaceStatus.Pod {
        let statuses = pod["status"]?["containerStatuses"]?.array ?? []
        return .init(
            name: pod["metadata"]?["name"]?.string ?? "",
            app: pod["metadata"]?["labels"]?["name"]?.string ?? "",
            phase: pod["status"]?["phase"]?.string ?? "",
            ready: !statuses.isEmpty && statuses.allSatisfy { $0["ready"]?.bool == true },
            restarts: statuses.reduce(0) { $0 + ($1["restartCount"]?.int ?? 0) },
            problem: unhealthyReason(pod),
            nodePool: NodePool(nodeName: pod["spec"]?["nodeName"]?.string ?? ""))
    }

    /// A waiting reason other than ContainerCreating/PodInitializing (up-toolbox `getPodUnhealthyStatus`).
    static func unhealthyReason(_ pod: JSON) -> String? {
        for status in pod["status"]?["containerStatuses"]?.array ?? [] {
            if let reason = status["state"]?["waiting"]?["reason"]?.string, !["ContainerCreating", "PodInitializing"].contains(reason) {
                return reason
            }
        }
        return nil
    }

    // MARK: Changing

    public func setPersist(_ name: String, _ persist: Bool) async throws {
        _ = try await namespace(name)
        _ = try await kube.patch("/api/v1/namespaces/\(name)", ["metadata": ["annotations": ["persist": .string(persist ? "true" : "false")]]], type: .merge)
    }

    /// Deletes the workspace namespace and waits until it is gone.
    public func delete(_ name: String, timeout: Duration = .seconds(600)) async throws {
        _ = try await namespace(name)
        try await kube.delete("/api/v1/namespaces/\(name)")
        try await waitUntilGone([name], timeout: timeout)
    }

    /// Workspaces `clean` would delete, with the reason. Persisted ones are excluded.
    public func cleanCandidates(now: Date = Date()) async throws -> [(workspace: Workspace, reason: String)] {
        try await list().compactMap { workspace in
            guard !workspace.persist, let reason = workspace.cleanReason(now: now) else { return nil }
            return (workspace, reason)
        }
    }

    public func clean(_ names: [String], timeout: Duration = .seconds(900)) async throws {
        for name in names { try await kube.delete("/api/v1/namespaces/\(name)") }
        try await waitUntilGone(names, timeout: timeout)
    }

    func waitUntilGone(_ names: [String], timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var remaining = Set(names)
        while !remaining.isEmpty {
            for name in remaining where try await kube.getIfExists("/api/v1/namespaces/\(name)") == nil { remaining.remove(name) }
            if remaining.isEmpty { return }
            guard clock.now < deadline else { throw WorkspaceKitError.timedOut("\(remaining.sorted().joined(separator: ", ")) to be deleted") }
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// The patch `run` sends: image + restartedAt, strategic merge so sidecars (varnish) survive.
    public static func deployPatch(app: String, image: String, at date: Date = Date()) -> JSON {
        ["spec": ["template": [
            "metadata": ["annotations": ["kubectl.kubernetes.io/restartedAt": .string(ISO8601DateFormatter().string(from: date))]],
            "spec": ["containers": [["name": .string(app), "image": .string(image)]]],
        ]]]
    }

    /// Points a workspace deployment at an image already in the registry, then waits until every
    /// running pod of the app runs that tag. Git details are recorded on the namespace.
    public func deploy(
        workspace name: String, app: String, image: String, git: [String: String] = [:],
        timeout: Duration = .seconds(900), progress: @Sendable (DeployProgress) -> Void = { _ in }
    ) async throws {
        _ = try await namespace(name)
        var annotations: [String: JSON] = ["deployed_at": .string(ISO8601DateFormatter().string(from: Date()))]
        for (key, value) in git { annotations[key] = .string(value) }
        _ = try await kube.patch("/api/v1/namespaces/\(name)", ["metadata": ["annotations": .object(annotations)]], type: .merge)
        _ = try await kube.patch("/apis/apps/v1/namespaces/\(name)/deployments/\(app)", Self.deployPatch(app: app, image: image), type: .strategicMerge)

        let tag = image.split(separator: ":").last.map(String.init) ?? image
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let pods = try await kube.get("/api/v1/namespaces/\(name)/pods", query: ["labelSelector": "name=\(app)"])["items"]?.array ?? []
            var running = Set<String>()
            for pod in pods {
                let podTag = pod["spec"]?["containers"]?.array?.first?["image"]?.string?.split(separator: ":").last.map(String.init) ?? ""
                if pod["status"]?["phase"]?.string == "Running" { running.insert(podTag) }
                if podTag == tag, let reason = Self.unhealthyReason(pod) {
                    throw WorkspaceKitError.podUnhealthy(pod: "\(app):\(tag)", reason: reason)
                }
            }
            let done = running == [tag]
            progress(DeployProgress(runningVersions: running.sorted(), done: done))
            if done { return }
            guard clock.now < deadline else { throw WorkspaceKitError.timedOut("\(app) to run \(tag)") }
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// Creates already-rendered manifests (what `kubectl create -f/-k` did): the Namespace first.
    public func create(manifests: [JSON], namespace: String) async throws {
        let ordered = manifests.filter { $0["kind"]?.string == "Namespace" } + manifests.filter { $0["kind"]?.string != "Namespace" }
        for object in ordered {
            guard let path = KubernetesClient.collectionPath(for: object, namespace: namespace) else {
                throw WorkspaceKitError.http(service: "Kubernetes", status: 0, message: "manifest without apiVersion/kind")
            }
            _ = try await kube.create(path, object)
        }
    }
}

import Foundation

extension KubernetesClient {
    /// A plain-text endpoint (pod logs).
    public func text(_ path: String, query: [String: String] = [:]) async throws -> String {
        var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(try await credentials.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        recorder.record(RequestTrace(method: "GET", path: pathAndQuery(components), contentType: nil, body: nil, status: status, context: contextName))
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else {
            let message = (try? JSON.parse(text))?["message"]?.string ?? text
            throw WorkspaceKitError.http(service: "Kubernetes", status: status, message: message)
        }
        return text
    }
}

/// A Kubernetes event in a workspace (scheduling, pulls, probes, kills, evictions…).
public struct WorkspaceEvent: Sendable, Equatable {
    public let type: String
    public let reason: String
    public let message: String
    /// "Pod/api-7f9c", "Deployment/api"…
    public let object: String
    public let count: Int
    public let lastSeen: Date?
}

/// Everything that explains a workspace's health, gathered in one pass.
public struct WorkspaceDiagnosis: Sendable, Equatable {
    public struct Container: Sendable, Equatable {
        public let name: String
        public let image: String
        public let ready: Bool
        public let restarts: Int
        /// running, waiting: <reason>, terminated: <reason>
        public let state: String
        /// The previous run's end, when it restarted: reason (OOMKilled, Error…), exit code, times, message.
        public let lastTermination: Termination?
        public let requests: [String: String]
        public let limits: [String: String]
        /// Current usage from metrics-server (cpu, memory), when available.
        public let usage: [String: String]
    }

    public struct Termination: Sendable, Equatable {
        public let reason: String
        public let exitCode: Int
        public let startedAt: Date?
        public let finishedAt: Date?
        public let message: String
    }

    public struct Pod: Sendable, Equatable {
        public let name: String
        public let app: String
        public let phase: String
        /// Pod-level reason and message (Evicted: "The node was low on resource: ephemeral-storage…").
        public let reason: String
        public let message: String
        public let node: String
        /// Conditions that are not true (PodScheduled=False: "0/12 nodes are available: insufficient memory").
        public let failingConditions: [String]
        public let containers: [Container]
    }

    public struct Node: Sendable, Equatable {
        public let name: String
        /// MemoryPressure, DiskPressure, PIDPressure that are True; Ready when False.
        public let pressures: [String]
        public let allocatable: [String: String]
    }

    /// A likely cause, found by rules (no AI), with where it was seen and the verbatim evidence.
    public struct Finding: Sendable, Equatable {
        public let severity: String
        public let title: String
        /// "pod/api-7f9c container/api", "event Evicted at 10:42"…
        public let reference: String
        /// The exact text that shows it (status message, event message).
        public let evidence: String
        public let hint: String
    }

    public let namespace: String
    public let pods: [Pod]
    public let events: [WorkspaceEvent]
    public let nodes: [Node]
    public let findings: [Finding]
}

extension WorkspaceClient {
    /// A container's logs: the last `tailLines`, or since `sinceSeconds`; `previous` reads the
    /// run before the last restart (where a crash's last words are).
    public func podLogs(_ namespace: String, pod: String, container: String? = nil, tailLines: Int? = 500,
                        sinceSeconds: Int? = nil, previous: Bool = false, timestamps: Bool = true) async throws -> String {
        var query: [String: String] = ["timestamps": timestamps ? "true" : "false"]
        if let container { query["container"] = container }
        if let tailLines { query["tailLines"] = String(tailLines) }
        if let sinceSeconds { query["sinceSeconds"] = String(sinceSeconds) }
        if previous { query["previous"] = "true" }
        return try await kube.text("/api/v1/namespaces/\(namespace)/pods/\(pod)/log", query: query)
    }

    public func events(_ namespace: String) async throws -> [WorkspaceEvent] {
        let items = try await kube.get("/api/v1/namespaces/\(namespace)/events")["items"]?.array ?? []
        return items.map(Self.event).sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    static func event(_ item: JSON) -> WorkspaceEvent {
        let involved = item["involvedObject"]
        let seen = item["lastTimestamp"]?.string ?? item["eventTime"]?.string ?? item["metadata"]?["creationTimestamp"]?.string
        return WorkspaceEvent(type: item["type"]?.string ?? "", reason: item["reason"]?.string ?? "",
                              message: item["message"]?.string ?? item["note"]?.string ?? "",
                              object: "\(involved?["kind"]?.string ?? "")/\(involved?["name"]?.string ?? "")",
                              count: item["count"]?.int ?? 1, lastSeen: seen.flatMap(Workspace.date))
    }

    /// Pods, containers (states, last terminations, requests/limits, usage), events and the
    /// nodes they run on, plus rule-based findings.
    public func diagnose(_ namespace: String) async throws -> WorkspaceDiagnosis {
        let podItems = try await kube.get("/api/v1/namespaces/\(namespace)/pods")["items"]?.array ?? []
        let events = (try? await self.events(namespace)) ?? []
        // Usage needs metrics-server; nodes may be forbidden to the user. Both are optional.
        var usage: [String: [String: String]] = [:]
        if let metrics = try? await kube.get("/apis/metrics.k8s.io/v1beta1/namespaces/\(namespace)/pods") {
            for pod in metrics["items"]?.array ?? [] {
                for container in pod["containers"]?.array ?? [] {
                    let key = "\(pod["metadata"]?["name"]?.string ?? "")/\(container["name"]?.string ?? "")"
                    usage[key] = (container["usage"]?.object ?? [:]).compactMapValues(\.string)
                }
            }
        }
        let pods = podItems.map { Self.diagnosisPod($0, usage: usage) }
        var nodes: [WorkspaceDiagnosis.Node] = []
        for name in Set(pods.map(\.node)).filter({ !$0.isEmpty }).sorted() {
            guard let node = try? await kube.get("/api/v1/nodes/\(name)") else { continue }
            let pressures = (node["status"]?["conditions"]?.array ?? []).compactMap { condition -> String? in
                let type = condition["type"]?.string ?? ""
                let status = condition["status"]?.string ?? ""
                if type == "Ready" { return status == "True" ? nil : "NotReady" }
                return status == "True" ? type : nil
            }
            nodes.append(.init(name: name, pressures: pressures, allocatable: (node["status"]?["allocatable"]?.object ?? [:]).compactMapValues(\.string)))
        }
        return WorkspaceDiagnosis(namespace: namespace, pods: pods, events: events, nodes: nodes,
                                  findings: Self.findings(pods: pods, events: events, nodes: nodes))
    }

    static func diagnosisPod(_ pod: JSON, usage: [String: [String: String]]) -> WorkspaceDiagnosis.Pod {
        let name = pod["metadata"]?["name"]?.string ?? ""
        let specs = Dictionary((pod["spec"]?["containers"]?.array ?? []).map { ($0["name"]?.string ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        let containers = (pod["status"]?["containerStatuses"]?.array ?? []).map { status -> WorkspaceDiagnosis.Container in
            let container = status["name"]?.string ?? ""
            let spec = specs[container]
            let state: String
            if let waiting = status["state"]?["waiting"] { state = "waiting: \(waiting["reason"]?.string ?? "")" }
            else if let terminated = status["state"]?["terminated"] { state = "terminated: \(terminated["reason"]?.string ?? "")" }
            else { state = "running" }
            let last = status["lastState"]?["terminated"].map { terminated in
                WorkspaceDiagnosis.Termination(
                    reason: terminated["reason"]?.string ?? "", exitCode: terminated["exitCode"]?.int ?? 0,
                    startedAt: terminated["startedAt"]?.string.flatMap(Workspace.date), finishedAt: terminated["finishedAt"]?.string.flatMap(Workspace.date),
                    message: terminated["message"]?.string ?? "")
            }
            return .init(name: container, image: status["image"]?.string ?? spec?["image"]?.string ?? "", ready: status["ready"]?.bool ?? false,
                         restarts: status["restartCount"]?.int ?? 0, state: state, lastTermination: last,
                         requests: (spec?["resources"]?["requests"]?.object ?? [:]).compactMapValues(\.string),
                         limits: (spec?["resources"]?["limits"]?.object ?? [:]).compactMapValues(\.string),
                         usage: usage["\(name)/\(container)"] ?? [:])
        }
        let failing = (pod["status"]?["conditions"]?.array ?? []).compactMap { condition -> String? in
            guard condition["status"]?.string == "False" else { return nil }
            let detail = [condition["reason"]?.string, condition["message"]?.string].compactMap { $0 }.joined(separator: ": ")
            return "\(condition["type"]?.string ?? "")=False" + (detail.isEmpty ? "" : " (\(detail))")
        }
        return .init(name: name, app: pod["metadata"]?["labels"]?["name"]?.string ?? pod["metadata"]?["labels"]?["app"]?.string ?? "",
                     phase: pod["status"]?["phase"]?.string ?? "", reason: pod["status"]?["reason"]?.string ?? "",
                     message: pod["status"]?["message"]?.string ?? "", node: pod["spec"]?["nodeName"]?.string ?? "",
                     failingConditions: failing, containers: containers)
    }

    /// The usual causes of restarts and failures, each with its reference and verbatim evidence.
    public static func findings(pods: [WorkspaceDiagnosis.Pod], events: [WorkspaceEvent], nodes: [WorkspaceDiagnosis.Node]) -> [WorkspaceDiagnosis.Finding] {
        var findings: [WorkspaceDiagnosis.Finding] = []
        for pod in pods {
            if pod.reason == "Evicted" {
                let resource = ["ephemeral-storage", "memory", "pid"].first { pod.message.contains($0) } ?? "resources"
                findings.append(.init(severity: "critical", title: "Pod evicted: node low on \(resource)", reference: "pod/\(pod.name) on node/\(pod.node)",
                                      evidence: pod.message,
                                      hint: resource == "ephemeral-storage" ? "The containers write too much to local disk (logs, /tmp, caches). Set an ephemeral-storage request/limit or write less." : "The node ran out of \(resource); raise the request so the pod is scheduled where there is room."))
            }
            for condition in pod.failingConditions where condition.hasPrefix("PodScheduled=False") {
                findings.append(.init(severity: "critical", title: "Pod can't be scheduled", reference: "pod/\(pod.name)", evidence: condition,
                                      hint: "No node has enough free CPU/memory for the requests, or the node pool is full. Lower the requests or wait for the autoscaler."))
            }
            for container in pod.containers {
                let reference = "pod/\(pod.name) container/\(container.name)"
                if let last = container.lastTermination {
                    if last.reason == "OOMKilled" || last.exitCode == 137 {
                        findings.append(.init(severity: "critical", title: "Killed for using too much memory (OOMKilled)", reference: reference,
                                              evidence: "lastState.terminated: reason=\(last.reason) exitCode=\(last.exitCode) finishedAt=\(last.finishedAt.map { $0.formatted(.iso8601) } ?? "?"); memory limit=\(container.limits["memory"] ?? "none") request=\(container.requests["memory"] ?? "none")" + (container.usage["memory"].map { " usage now=\($0)" } ?? ""),
                                              hint: "Raise the memory limit, or find what grows (caches, large payloads, leaks) in the logs before the kill."))
                    } else if container.restarts > 0 {
                        findings.append(.init(severity: container.restarts >= 3 ? "critical" : "warning",
                                              title: "Restarted \(container.restarts)× (last exit: \(last.reason) code \(last.exitCode))", reference: reference,
                                              evidence: "lastState.terminated: reason=\(last.reason) exitCode=\(last.exitCode)" + (last.message.isEmpty ? "" : " message=\(last.message)"),
                                              hint: "Read the previous run's logs (previous=true): the last lines before the exit usually say why."))
                    }
                }
                if container.state.hasPrefix("waiting: ") {
                    let reason = String(container.state.dropFirst(9))
                    let hint = switch reason {
                    case "ImagePullBackOff", "ErrImagePull": "The image can't be pulled: wrong tag, not pushed yet, or no access to the registry."
                    case "CrashLoopBackOff": "It starts and exits again and again; see the previous run's logs."
                    case "CreateContainerConfigError": "A ConfigMap or Secret it needs (env or volume) is missing."
                    default: ""
                    }
                    if !["ContainerCreating", "PodInitializing"].contains(reason) {
                        findings.append(.init(severity: "critical", title: "Waiting: \(reason)", reference: reference, evidence: container.state, hint: hint))
                    }
                }
            }
        }
        for event in events where event.type == "Warning" {
            let hint: String? = switch event.reason {
            case "Unhealthy": "A liveness/readiness probe fails: the app is slow to start or the probe path/port is wrong."
            case "FailedScheduling": "Not enough room on the nodes for the requests."
            case "FailedMount": "A volume (ConfigMap, Secret, disk) can't be mounted."
            case "BackOff": "Kubernetes is backing off restarts or pulls."
            case "Evicted", "OOMKilling": "The node ran out of a resource."
            default: nil
            }
            guard let hint else { continue }
            findings.append(.init(severity: "warning", title: "\(event.reason) ×\(event.count)", reference: "event \(event.reason) on \(event.object)" + (event.lastSeen.map { " at \($0.formatted(.iso8601))" } ?? ""),
                                  evidence: event.message, hint: hint))
        }
        for node in nodes where !node.pressures.isEmpty {
            findings.append(.init(severity: "warning", title: "Node under pressure: \(node.pressures.joined(separator: ", "))", reference: "node/\(node.name)",
                                  evidence: node.pressures.joined(separator: ", "), hint: "Pods on this node may be evicted or throttled."))
        }
        return findings
    }
}

import DashKit
import Foundation
import Testing
@testable import Dash

/// How a repository is run, built, configured, owned and documented: workloads, images, CI jobs,
/// feature flags, config keys, code owners, docs and dependencies.
@MainActor
@Suite("Knowledge operations")
struct KnowledgeOperationsTests {
    private func index(_ root: URL, store: KnowledgeStore) async throws -> CodeIndexer {
        var indexer = CodeIndexer(root: root, store: store)
        indexer.readHistory = false
        _ = try await indexer.index()
        return indexer
    }

    private func targets(_ id: String, _ kind: String, store: KnowledgeStore) async throws -> Set<String> {
        Set(try await store.neighbors(id, kinds: [kind]).filter { !$0.incoming }.map(\.node.id))
    }

    // MARK: Runtime

    @Test func readsYAMLByStructure() throws {
        let text = """
            # a comment
            name: "billing-api"   # trailing comment
            ports: [80, "8080"]
            empty:
            spec:
              containers:
              - name: api
                image: ghcr.io/acme/billing-api:1.2
                env:
                  - name: DATABASE_URL
                    valueFrom: {secretKeyRef: x}
              script: |
                echo one
                echo two
              anchors: &defaults
                url: 'http://billing:80/a#b'
            ---
            kind: Second
            """
        let documents = YAMLTree.documents(text)
        #expect(documents.count == 2)
        let root = try #require(documents.first)
        #expect(root["name"]?.string == "billing-api")
        #expect(root["ports"]?.strings == ["80", "8080"])
        #expect(root["empty"]?.string == nil)
        let container = try #require(root.at("spec", "containers")?.items.first)
        #expect(container["image"]?.string == "ghcr.io/acme/billing-api:1.2" && container["image"]?.line == 8)
        #expect(container["env"]?.items.first?["name"]?.string == "DATABASE_URL")
        #expect(root.at("spec", "script")?.string == "echo one\necho two")
        #expect(root.at("spec", "anchors", "url")?.string == "http://billing:80/a#b")
        #expect(documents.last?["kind"]?.string == "Second" && documents.last?["kind"]?.line == 18)
        #expect(RuntimeExtractor.imageName("ghcr.io/acme/api:1.2@sha256:abc") == "ghcr.io/acme/api")
        #expect(RuntimeExtractor.imageName("localhost:5000/api") == "localhost:5000/api")
        #expect(RuntimeExtractor.imageName("{{ .Values.image }}") == nil)
    }

    private static let runtimeRepo: [String: String] = [
        "apps/users-api/main.go": "package main\n\nfunc main() {}\n",
        "apps/users-api/helm/Chart.yaml": """
            apiVersion: v2
            name: users-api
            dependencies:
              - name: platform-service
                version: 1.2.0
                alias: users-api
            """,
        "apps/users-api/helm/values.yaml": """
            users-api:
              image:
                repository: ghcr.io/acme/users-api
                tag: ""
              readinessProbe:
                httpGet:
                  path: /users/health
                  port: 8080
              env:
                open:
                  LOG_LEVEL: "debug"
                additionalSecrets:
                  billing-keys:
                    BILLING_TOKEN: billing_token
              resources:
                requests:
                  cpu: 250m
                  memory: 256Mi
                limits:
                  cpu: 1
                  memory: 512Mi
              hpa:
                enabled: true
                minReplicas: 2
                maxReplicas: 10
              gclb:
                httproute:
                  rules: |
                    - matches:
                        - path:
                            value: /users
            """,
        "apps/users-api/helm/values-prod.yaml": """
            users-api:
              env:
                open:
                  CONFIG_FILE: /etc/config/production.toml
            """,
        "deploy/worker.yaml": """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: billing-worker
            spec:
              replicas: 3
              template:
                spec:
                  containers:
                    - name: worker
                      image: ghcr.io/acme/billing-worker:1.4
                      ports:
                        - containerPort: 8080
                      env:
                        - name: QUEUE_URL
                          value: https://sqs.example.com/jobs
                      envFrom:
                        - secretRef:
                            name: billing-worker-secrets
                  volumes:
                    - name: config
                      configMap:
                        name: billing-worker-config
            ---
            apiVersion: v1
            kind: Service
            metadata:
              name: billing-worker
            spec:
              selector:
                app: billing-worker
              ports:
                - port: 80
                  targetPort: 8080
            ---
            apiVersion: networking.k8s.io/v1
            kind: Ingress
            metadata:
              name: billing
            spec:
              rules:
                - host: billing.acme.com
                  http:
                    paths:
                      - path: /billing
                        backend:
                          service:
                            name: billing-worker
            ---
            apiVersion: autoscaling/v2
            kind: HorizontalPodAutoscaler
            metadata:
              name: billing-worker
            spec:
              scaleTargetRef:
                kind: Deployment
                name: billing-worker
              minReplicas: 2
              maxReplicas: 6
            ---
            apiVersion: v1
            kind: Secret
            metadata:
              name: billing-worker-secrets
            data:
              TOKEN: aHVudGVyMg==
            """,
        "infra/run.tf": """
            resource "google_cloud_run_v2_service" "reports" {
              name     = "reports-api"
              location = "us-central1"
              template {
                containers {
                  image = "gcr.io/acme/reports:latest"
                }
              }
            }
            """,
        "charts/web/Chart.yaml": "apiVersion: v2\nname: web\n",
        "charts/web/templates/deployment.yaml": "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: {{ .Release.Name }}\n",
    ]

    @Test func findsWorkloadsInManifestsHelmValuesAndTerraform() async throws {
        let root = try makeFixtureRepo(Self.runtimeRepo)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        let indexer = try await index(root, store: store)
        let repo = indexer.repoID

        let workloads = try await store.nodes(kind: "workload", repo: repo).map(\.qualified).sorted()
        #expect(workloads == ["CloudRunService/reports-api", "Deployment/billing-worker", "Deployment/users-api"])

        // Helm: the base values and the prod overlay make one workload, deployed by the chart's service.
        let users = try #require(try await store.node(RuntimeExtractor.id(repo: repo, kind: "Deployment", name: "users-api")))
        #expect(users.signature == "Deployment users-api · image ghcr.io/acme/users-api · 2–10 replicas · cpu 250m/1 · memory 256Mi/512Mi")
        #expect(users.summary == "Environments: prod. Routes: /users. Probes: /users/health. Environment variables: LOG_LEVEL, BILLING_TOKEN, CONFIG_FILE. "
            + "Secrets (names only): billing-keys. Defined in apps/users-api/helm/values.yaml, apps/users-api/helm/values-prod.yaml.")
        #expect(users.path == "apps/users-api/helm/values.yaml")
        #expect(try await targets(users.id, "uses_image", store: store) == ["image:ghcr.io/acme/users-api"])
        #expect(try await targets(users.id, "sets_env", store: store) == ["env:LOG_LEVEL", "env:BILLING_TOKEN", "env:CONFIG_FILE"])
        #expect(try await targets(ServiceExtractor.id(repo: repo, name: "users-api"), "deploys", store: store) == [users.id])

        // A manifest: its Service, Ingress and autoscaler add to the Deployment they target.
        let worker = try #require(try await store.node(RuntimeExtractor.id(repo: repo, kind: "Deployment", name: "billing-worker")))
        #expect(worker.signature == "Deployment billing-worker · image ghcr.io/acme/billing-worker · 2–6 replicas · port 8080")
        #expect(worker.summary == "Hosts: billing.acme.com. Routes: /billing. Environment variables: QUEUE_URL. Config maps: billing-worker-config. "
            + "Secrets (names only): billing-worker-secrets. Defined in deploy/worker.yaml.")
        let host = OutboundCallExtractor.hostID("billing.acme.com")
        let about = try await store.neighbors(host, kinds: ["about"]).filter { !$0.incoming }
        #expect(Set(about.map(\.node.id)) == [worker.id, ServiceExtractor.id(repo: repo, name: "billing-worker")])
        #expect(about.allSatisfy { $0.edge.weight == 1 && $0.edge.source == ExtractionLinks.source })

        let reports = try #require(try await store.node(RuntimeExtractor.id(repo: repo, kind: "CloudRunService", name: "reports-api")))
        #expect(reports.signature == "CloudRunService reports-api · image gcr.io/acme/reports" && reports.line == 1)

        // Secret values are never kept.
        let everything = try await store.nodes("SELECT * FROM nodes", []).flatMap { [$0.signature, $0.summary] }
            + (try await store.refs(repo: repo)).flatMap(\.ref.names)
        #expect(!everything.contains { $0.contains("aHVudGVyMg") || $0.contains("billing_token") || $0.contains("sqs.example.com") })

        // The overlay goes: its environment and variable go with it; the manifest goes: so does its workload.
        try FileManager.default.removeItem(at: root.appending(path: "apps/users-api/helm/values-prod.yaml"))
        try FileManager.default.removeItem(at: root.appending(path: "deploy/worker.yaml"))
        _ = try await indexer.index()
        #expect(try await store.node(users.id)?.summary.hasPrefix("Routes: /users.") == true)
        #expect(try await store.node(worker.id) == nil)
        #expect(try await store.node("image:ghcr.io/acme/billing-worker") == nil)
    }
}

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

    // MARK: Containers

    @Test func readsDockerfilesAndComposeImages() async throws {
        let multiStage = """
            # syntax=docker/dockerfile:1
            ARG GO_VERSION=1.23
            FROM --platform=$BUILDPLATFORM golang:${GO_VERSION} AS build
            EXPOSE 9999
            RUN go build \\
                -o /out/server ./cmd/server
            FROM build AS test
            FROM gcr.io/distroless/static:nonroot
            COPY --from=build /out/server /app/server
            EXPOSE 8080/tcp 9090
            ENTRYPOINT ["/app/server", "--token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"]
            CMD ["serve"]
            """
        let dockerfile = ContainerExtractor.dockerfile(multiStage)
        #expect(dockerfile.images == ["golang", "gcr.io/distroless/static"])
        #expect(dockerfile.facts.prefix(2) == ["port=8080", "port=9090"])
        #expect(dockerfile.facts.last == "cmd=serve")
        let entrypoint = try #require(dockerfile.facts.first { $0.hasPrefix("entrypoint=") })
        #expect(entrypoint.hasPrefix("entrypoint=/app/server") && !entrypoint.contains("ghp_abcdefghij"))
        #expect(ContainerExtractor.dockerfile("FROM scratch\nCOPY app /\n").images.isEmpty)

        let root = try makeFixtureRepo([
            "apps/billing/Dockerfile": "FROM node:20-alpine\nEXPOSE 3000\nCMD node server.js\n",
            "apps/billing/server.js": "require('http').createServer().listen(3000)\n",
            "docker-compose.yml": """
                services:
                  billing:
                    build: apps/billing
                  db:
                    image: postgres:16
                """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        let indexer = try await index(root, store: store)
        #expect(try await targets(indexer.fileID("apps/billing/Dockerfile"), "uses_image", store: store) == ["image:node"])
        #expect(try await targets(indexer.fileID("docker-compose.yml"), "uses_image", store: store) == ["image:postgres"])
        #expect(try await store.node("image:postgres")?.signature == "Container image postgres")
        let billing = try #require(try await store.node(ServiceExtractor.id(repo: indexer.repoID, name: "billing")))
        #expect(billing.signature == "Defined in apps/billing/Dockerfile, docker-compose.yml · port 3000 · runs node server.js")
    }

    // MARK: CI

    @Test func findsCIJobsAndWhatTheyDeploy() async throws {
        let root = try makeFixtureRepo([
            "apps/billing/helm/Chart.yaml": "apiVersion: v2\nname: billing\n",
            "apps/users/Dockerfile": "FROM golang:1.23\n",
            "apps/users/k8s/deployment.yaml": "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: users\n",
            ".github/workflows/deploy.yml": """
                name: Deploy
                on:
                  push:
                    branches: [main]
                  workflow_dispatch:
                jobs:
                  build:
                    runs-on: ubuntu-latest
                    container: golang:1.23
                    steps:
                      - uses: actions/checkout@v4
                      - name: Build
                        run: go build ./apps/billing/...
                  deploy:
                    needs: build
                    runs-on: ubuntu-latest
                    environment: production
                    steps:
                      - name: Deploy
                        run: |
                          helm upgrade --install billing apps/billing/helm --set apiKey=AKIAIOSFODNN7EXAMPLE
                          echo done
                """,
            ".circleci/config.yml": """
                version: 2.1
                jobs:
                  migrate:
                    docker:
                      - image: cimg/go:1.23
                    environment:
                      KUBE_NAME: users
                    steps:
                      - checkout
                      - run:
                          name: Migrate
                          command: ./scripts/migrate.sh
                workflows:
                  main:
                    jobs:
                      - lint
                      - acme/build:
                          name: build-users
                          root-path: ./apps/users
                          context: platform
                          requires:
                            - lint
                      - migrate:
                          requires: [build-users]
                          filters:
                            branches:
                              only: main
                """,
            ".gitlab-ci.yml": """
                stages: [deploy]
                .base:
                  image: alpine:3
                deploy_prod:
                  stage: deploy
                  image: alpine:3
                  environment: production
                  script:
                    - kubectl apply -f apps/users/k8s
                """,
        ], git: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        let indexer = try await index(root, store: store)
        let repo = indexer.repoID
        let jobs = try await store.nodes(kind: "ci_job", repo: repo).map(\.qualified).sorted()
        #expect(jobs == ["deploy/build", "deploy/deploy", "gitlab-ci/deploy_prod", "main/build-users", "main/lint", "main/migrate"])
        let billing = ServiceExtractor.id(repo: repo, name: "billing"), users = ServiceExtractor.id(repo: repo, name: "users")

        let build = try #require(try await store.node(CIExtractor.id(repo: repo, workflow: "deploy", job: "build")))
        #expect(build.signature == "GitHub Actions job build in deploy · on push (main), workflow_dispatch · runs on ubuntu-latest")
        #expect(build.summary == "Steps: (actions/checkout@v4); Build: go build ./apps/billing/....")
        #expect(build.language == "github-actions" && build.path == ".github/workflows/deploy.yml" && build.line == 7)
        #expect(try await targets(build.id, "uses_image", store: store) == ["image:golang"])
        #expect(try await targets(build.id, "about", store: store) == [billing])

        let deploy = try #require(try await store.node(CIExtractor.id(repo: repo, workflow: "deploy", job: "deploy")))
        #expect(deploy.signature == "GitHub Actions job deploy in deploy · on push (main), workflow_dispatch · runs on ubuntu-latest · environment production · needs build · deploys")
        #expect(deploy.summary.hasPrefix("Steps: Deploy: helm upgrade --install billing apps/billing/helm") && !deploy.summary.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(try await targets(deploy.id, "deploys", store: store) == [billing])

        let buildUsers = try #require(try await store.node(CIExtractor.id(repo: repo, workflow: "main", job: "build-users")))
        #expect(buildUsers.signature == "CircleCI job build-users in main · acme/build · context platform · needs lint")
        #expect(buildUsers.summary == "Steps: parameters root-path ./apps/users.")
        #expect(try await targets(buildUsers.id, "about", store: store) == [users])
        let migrate = try #require(try await store.node(CIExtractor.id(repo: repo, workflow: "main", job: "migrate")))
        #expect(migrate.signature == "CircleCI job migrate in main · only main · needs build-users")
        #expect(migrate.summary == "Steps: checkout; Migrate: ./scripts/migrate.sh.")
        #expect(try await targets(migrate.id, "uses_image", store: store) == ["image:cimg/go"])
        #expect(try await targets(migrate.id, "about", store: store) == [users])

        let gitlab = try #require(try await store.node(CIExtractor.id(repo: repo, workflow: "gitlab-ci", job: "deploy_prod")))
        #expect(gitlab.signature == "GitLab CI job deploy_prod in gitlab-ci · stage deploy · environment production · deploys")
        #expect(try await targets(gitlab.id, "deploys", store: store) == [users])
        #expect(try await targets(gitlab.id, "uses_image", store: store) == ["image:alpine"])

        // A job renamed: the old node goes with its edges.
        let workflow = root.appending(path: ".gitlab-ci.yml")
        try (try String(contentsOf: workflow, encoding: .utf8)).replacingOccurrences(of: "deploy_prod:", with: "release:").write(to: workflow, atomically: true, encoding: .utf8)
        _ = try await indexer.index()
        #expect(try await store.node(gitlab.id) == nil)
        #expect(try await store.node(CIExtractor.id(repo: repo, workflow: "gitlab-ci", job: "release")) != nil)
        #expect(try await store.neighbors(gitlab.id).isEmpty)
    }

    // MARK: Feature flags

    @Test func findsFeatureFlagsAndTheCodeCheckingThem() async throws {
        let root = try makeFixtureRepo([
            "go.mod": "module example.com/shop\n",
            "flags/flags.go": """
                package flags

                const (
                \tFlagNewCheckout = "new-checkout"
                \tProjectWeb      = "web"
                )

                func IsEnabledForUser(ctx context.Context, project, flag string) bool {
                \tv, _ := client.BoolVariation(flag, user(ctx), false)
                \treturn v
                }
                """,
            "api/checkout.go": """
                package api

                import (
                \tld "github.com/launchdarkly/go-server-sdk/v7"
                \t"example.com/shop/flags"
                )

                const portFlag = "port"

                func Checkout(ctx context.Context) {
                \tif flags.IsEnabledForUser(ctx, flags.ProjectWeb, flags.FlagNewCheckout) {
                \t\treturn
                \t}
                }

                func Legacy(client *ld.LDClient) {
                \tv, _ := client.BoolVariation("legacy-cart", user, false)
                \t// client.BoolVariation("commented-out", user, false)
                \tport, _ := cmd.Flags().GetString(portFlag)
                }
                """,
            "api/checkout_test.go": "package api\n\nfunc TestX() { client.BoolVariation(\"test-only\", u, false) }\n",
            "web/src/Banner.tsx": """
                import { OpenFeature } from '@openfeature/web-sdk';

                export function Banner() {
                  const dark = client.getBooleanValue('dark-mode', false);
                  if (isFeatureEnabled("beta-banner")) { setFeatureFlag("written", true); }
                  return unleash.isEnabled('promo');
                }
                """,
            "app/views.py": "def show(client):\n    if client.get_boolean_value(\"py-flag\", False):\n        return 1\n",
            "flags.flagd.json": #"{"flags": {"dark-mode": {"state": "ENABLED", "variants": {"on": true, "off": false}, "defaultVariant": "on"}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        let indexer = try await index(root, store: store)
        func checks(_ path: String, _ symbol: String) async throws -> Set<String> {
            try await targets("sym:\(root.path)/\(path)#\(symbol)", "checks_flag", store: store)
        }
        #expect(try await checks("api/checkout.go", "Checkout") == ["flag:new-checkout"])
        #expect(try await checks("api/checkout.go", "Legacy") == ["flag:legacy-cart"])
        #expect(try await checks("flags/flags.go", "IsEnabledForUser").isEmpty)
        #expect(try await checks("web/src/Banner.tsx", "Banner") == ["flag:dark-mode", "flag:beta-banner", "flag:promo"])
        #expect(try await checks("app/views.py", "show") == ["flag:py-flag"])
        let flags = try await store.nodes(kind: "flag").map(\.name).sorted()
        #expect(flags == ["beta-banner", "dark-mode", "legacy-cart", "new-checkout", "promo", "py-flag"])
        #expect(try await store.node("flag:legacy-cart")?.signature == "Feature flag legacy-cart (LaunchDarkly)")
        let dark = try #require(try await store.node("flag:dark-mode"))
        #expect(dark.signature == "Feature flag dark-mode (OpenFeature)" && dark.summary == "Defined in flags.flagd.json, enabled, variants off, on.")
        #expect(try await targets(dark.id, "defined_in", store: store) == [indexer.fileID("flags.flagd.json")])
    }

    // MARK: Config keys

    @Test func findsConfigKeysAndTheirReaders() async throws {
        let root = try makeFixtureRepo([
            "config/production.toml": """
                title = "billing"
                [Kafka]
                Brokers = ["kafka-a:80",
                  "kafka-b:80"]
                Topic = "events"
                [Postmark]
                ApiKey = "hunter2-postmark"
                """,
            "config/settings.yaml": "server:\n  port: 8080\n  tls: {}\nfeatures:\n  - search\n",
            "config/deploy.yaml": "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n",
            "appsettings.json": #"{"Logging": {"Level": "Info"}, "1": "x"}"#,
            "locales/en.json": #"{"greeting": "hello"}"#,
            "package.json": #"{"name": "billing", "version": "1.0.0"}"#,
            "internal/config/load.go": """
                package config

                import "github.com/spf13/viper"

                func Port() int { return viper.GetInt("server.port") }
                """,
            "internal/kafka/config.go": """
                package kafka

                type Config struct {
                \tBrokers []string `toml:"brokers"`
                \tTopic   string   `toml:"topic"`
                \tOther   string   `toml:"nothing_matches"`
                }
                """,
            "web/db.ts": "import config from 'config';\n\nexport function dbUrl() {\n  return config.get('database.url');\n}\n",
            "app/settings.py": "import configparser\n\ndef host(cfg):\n    return cfg.get(\"database\", \"host\")\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        let indexer = try await index(root, store: store)
        #expect(try await targets(indexer.fileID("config/production.toml"), "sets_config", store: store)
            == ["config:title", "config:kafka.brokers", "config:kafka.topic", "config:postmark.apikey"])
        #expect(try await targets(indexer.fileID("config/settings.yaml"), "sets_config", store: store) == ["config:server.port", "config:server.tls", "config:features"])
        #expect(try await targets(indexer.fileID("appsettings.json"), "sets_config", store: store) == ["config:logging.level"])
        for path in ["config/deploy.yaml", "locales/en.json", "package.json"] {
            #expect(try await targets(indexer.fileID(path), "sets_config", store: store).isEmpty)
        }
        #expect(try await store.node("config:kafka.brokers")?.name == "Kafka.Brokers")

        func readers(_ key: String) async throws -> Set<String> {
            Set(try await store.neighbors("config:" + key, kinds: ["reads_config"]).filter(\.incoming).map { "\($0.node.path)#\($0.node.name) \($0.edge.weight)" })
        }
        #expect(try await readers("server.port") == ["internal/config/load.go#Port 1.0"])
        #expect(try await readers("kafka.brokers") == ["internal/kafka/config.go#Config 0.8"])
        #expect(try await readers("kafka.topic") == ["internal/kafka/config.go#Config 0.8"])
        #expect(try await readers("database.url") == ["web/db.ts#dbUrl 1.0"])
        #expect(try await readers("database.host") == ["app/settings.py#host 1.0"])
        #expect(try await store.node("config:database.url")?.signature == "Config key database.url")

        // Values are never kept.
        let everything = try await store.nodes("SELECT * FROM nodes", []).flatMap { [$0.name, $0.signature, $0.summary] }
        #expect(!everything.contains { $0.contains("hunter2") || $0.contains("kafka-a") })
    }

    // MARK: Owners

    @Test func matchesCodeOwnersPatternsLikeGitHub() throws {
        func matches(_ pattern: String, _ path: String) throws -> Bool {
            let regex = try #require(OwnershipExtractor.regex(pattern))
            return regex.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
        }
        #expect(try matches("*", "apps/billing/main.go"))
        #expect(try matches("*.js", "web/src/app.js") && !matches("*.js", "web/src/app.ts"))
        #expect(try matches("/apps/billing/", "apps/billing/api/routes.go") && !matches("/apps/billing/", "tools/apps/billing/x.go"))
        #expect(try matches("apps/", "tools/apps/x.go"))
        #expect(try matches("docs/*", "docs/intro.md") && !matches("docs/*", "docs/guides/intro.md"))
        #expect(try matches("**/logs", "logs/a.txt") && matches("**/logs", "build/logs/a.txt"))
        #expect(try matches("apps/*/main.go", "apps/billing/main.go") && !matches("apps/*/main.go", "apps/billing/cmd/main.go"))
    }

    @Test func assignsCodeOwnersWithTheFewestEdges() async throws {
        let root = try makeFixtureRepo([
            ".github/CODEOWNERS": """
                # Default owners
                *                         @acme/platform
                /apps/billing/            @acme/billing ada@acme.com
                /apps/billing/legacy.go
                *.md                      @acme/docs
                """,
            "apps/billing/main.go": "package main\n",
            "apps/billing/api/routes.go": "package api\n",
            "apps/billing/legacy.go": "package main\n",
            "apps/users/main.go": "package main\n",
            "tools/gen.go": "package tools\n",
            "README.md": "# Shop\n",
        ], git: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        let indexer = try await index(root, store: store)
        func owns(_ owner: String) async throws -> Set<String> {
            Set(try await targets(OwnershipExtractor.id(owner), "owns", store: store).map { id in
                id.hasPrefix("dir:") ? String(id.dropFirst(("dir:" + root.path + "/").count)) + "/" : String(id.dropFirst(("file:" + root.path + "/").count))
            })
        }
        #expect(try await owns("@acme/platform") == [".github/", "apps/users/", "tools/"])
        #expect(try await owns("@acme/billing") == ["apps/billing/main.go", "apps/billing/api/"])
        #expect(try await owns("ada@acme.com") == ["apps/billing/main.go", "apps/billing/api/"])
        #expect(try await owns("@acme/docs") == ["README.md"])
        let team = try #require(try await store.node(OwnershipExtractor.id("@acme/billing")))
        #expect(team.signature == "Code owner @acme/billing" && team.language == "team")
        let person = try await store.query("SELECT dst FROM edges WHERE src = 'owner:ada@acme.com' AND kind = 'about'", limit: 5)
        #expect(person.compactMap { $0["dst"]?.string } == ["person:ada@acme.com"])

        // One owner for everything: a single edge to the repository.
        try "* @acme/platform\n".write(to: root.appending(path: ".github/CODEOWNERS"), atomically: true, encoding: .utf8)
        _ = try await indexer.index()
        #expect(try await targets(OwnershipExtractor.id("@acme/platform"), "owns", store: store) == [indexer.repoID])
        #expect(try await store.node(OwnershipExtractor.id("@acme/billing")) == nil)
    }

    // MARK: Docs

    @Test func indexesRepositoryDocsAndWhatTheyMention() async throws {
        let root = try makeFixtureRepo([
            "README.md": """
                # Billing API

                Charges customers. Start with [the routes](api/routes.go) and `api/`.
                `GET /invoices/:id` returns one invoice; `InvoiceStore.Find()` reads it. See `Handle`.

                ## Configuration
                Set `STRIPE_API_KEY=sk_live_abcdefghijklmnop1234` in production.

                ```go
                func Example() {}
                ```
                """,
            "api/README.adoc": "= API package\n\n== Routes\nThe `Handle` here serves `api/routes.go`.\n",
            "docs/runbook.rst": "Runbook\n=======\n\nRestarts\n--------\nCall POST /invoices to retry.\n",
            "CHANGELOG.md": "# Changelog\n\n## 1.0.0\nFirst release.\n",
            "api/routes.go": """
                package api

                import "github.com/go-chi/chi/v5"

                func Routes(r chi.Router) {
                \tr.Get("/invoices/{id}", Handle)
                }

                func Handle() {}
                """,
            "store/invoices.go": "package store\n\ntype InvoiceStore struct{}\n\nfunc (s InvoiceStore) Find() {}\n",
            "worker/handle.go": "package worker\n\nfunc Handle() {}\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(url: nil)
        let indexer = try await index(root, store: store)
        let readmeID = RepoDocExtractor.id(root: root.path, path: "README.md")
        let readme = try #require(try await store.node(readmeID))
        #expect(readme.kind == "doc" && readme.name == "Billing API" && readme.summary == "Sections: Configuration")
        #expect(readme.signature.contains("Charges customers") && !readme.signature.contains("sk_live_abcdefghijklmnop1234"))
        #expect(try await targets(readmeID, "documents", store: store) == [indexer.repoID])
        let dir = "dir:" + root.path + "/api"
        let about = try await targets(readmeID, "about", store: store)
        let invoices = try await store.definitions(repo: indexer.repoID, idPrefix: "endpoint:").map(\.id).filter { $0.hasPrefix("endpoint:GET /invoices") }
        #expect(invoices.count == 1)
        // `Handle` names two functions: no edge from the root; inside api/ it is the only one.
        #expect(about == Set([indexer.fileID("api/routes.go"), dir, "sym:" + root.path + "/store/invoices.go#InvoiceStore.Find"] + invoices))

        let package = RepoDocExtractor.id(root: root.path, path: "api/README.adoc")
        #expect(try await store.node(package)?.name == "API package")
        #expect(try await targets(package, "documents", store: store) == [dir])
        #expect(try await targets(package, "about", store: store) == [indexer.fileID("api/routes.go"), "sym:" + root.path + "/api/routes.go#Handle"])

        let runbook = try #require(try await store.node(RepoDocExtractor.id(root: root.path, path: "docs/runbook.rst")))
        #expect(runbook.name == "Runbook" && runbook.summary == "Sections: Restarts")
        #expect(try await store.node(RepoDocExtractor.id(root: root.path, path: "CHANGELOG.md")) == nil)

        try FileManager.default.removeItem(at: root.appending(path: "docs/runbook.rst"))
        _ = try await indexer.index()
        #expect(try await store.node(RepoDocExtractor.id(root: root.path, path: "docs/runbook.rst")) == nil)
    }

    // MARK: Dependencies

    @Test func readsDependencyManifests() {
        typealias Dependency = DependencyExtractor.Dependency
        #expect(DependencyExtractor.goRequires("module x\n\nrequire github.com/a/b v1.0.0\nrequire (\n\tgithub.com/c/d v0.2.0\n\tgithub.com/e/f v1.1.0 // indirect\n)\n")
            == [Dependency(name: "github.com/a/b", version: "v1.0.0"), Dependency(name: "github.com/c/d", version: "v0.2.0")])
        #expect(DependencyExtractor.requirements("# tools\nrequests[socks]>=2.31, <3  # http\n-r base.txt\nDjango==4.2\ngit+https://host/x.git\nboto3\n")
            == [Dependency(name: "requests", version: ">=2.31,<3"), Dependency(name: "Django", version: "==4.2"), Dependency(name: "boto3", version: "")])
        let pyproject = DependencyExtractor.pyproject("[project]\nname = \"billing\"\ndependencies = [\n  \"fastapi>=0.110\",\n  'pydantic',\n]\n[tool.poetry.dependencies]\npython = \"^3.12\"\nhttpx = { version = \"0.27\" }\n")
        #expect(pyproject.name == "billing" && pyproject.dependencies.map(\.name) == ["fastapi", "pydantic", "httpx"] && pyproject.dependencies.last?.version == "0.27")
        let cargo = DependencyExtractor.cargo("[package]\nname = \"billing-cli\"\n\n[dependencies]\nserde = { version = \"1.0\", features = [\"derive\"] }\nanyhow = \"1\"\n\n[dev-dependencies.tokio]\nversion = \"1.37\"\n")
        #expect(cargo.name == "billing-cli" && cargo.dependencies == [Dependency(name: "serde", version: "1.0"), Dependency(name: "anyhow", version: "1"), Dependency(name: "tokio", version: "1.37")])
        #expect(DependencyExtractor.swiftPackages(#"""
            dependencies: [
                .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
                .package(url: "https://github.com/acme/kit", .upToNextMajor(from: "2.0.0")),
                .package(url: "https://github.com/acme/edge", branch: "main"),
                .package(path: "../Local"),
            ]
            """#) == [Dependency(name: "swift-argument-parser", version: "1.3.0"), Dependency(name: "kit", version: "2.0.0"), Dependency(name: "edge", version: "branch main")])
    }

    @Test func linksRepositoriesThroughTheirDependencies() async throws {
        let shared = try makeFixtureRepo(["go.mod": "module github.com/acme/shared\n\ngo 1.22\n", "log/log.go": "package log\n"])
        let billing = try makeFixtureRepo([
            "go.mod": "module github.com/acme/billing-api\n\nrequire (\n\tgithub.com/acme/shared v1.2.0\n\tgithub.com/spf13/viper v1.9.1\n\tgolang.org/x/sys v0.1.0 // indirect\n)\n",
            "main.go": "package main\n\nimport \"github.com/spf13/viper\"\n\nfunc main() { viper.GetString(\"x\") }\n",
            "web/package.json": #"{"name": "@acme/web", "dependencies": {"express": "^4.19.0", "@acme/ui": "file:../ui"}, "devDependencies": {"jest": "29.7.0"}}"#,
            "web/tsconfig.json": "{}\n",
            "tools/requirements.txt": "requests==2.32.0\n",
        ])
        let users = try makeFixtureRepo(["go.mod": "module github.com/acme/users-api\n\nrequire github.com/spf13/viper v1.8.0\n"])
        defer { for root in [shared, billing, users] { try? FileManager.default.removeItem(at: root) } }
        let store = try KnowledgeStore(url: nil)
        _ = try await index(shared, store: store)
        let indexer = try await index(billing, store: store)
        _ = try await index(users, store: store)

        #expect(try await targets(indexer.repoID, "depends_on", store: store)
            == ["pkg:go:github.com/acme/shared", "pkg:go:github.com/spf13/viper", "repo:" + shared.path])
        #expect(try await targets("dir:" + billing.path + "/web", "depends_on", store: store) == ["pkg:typescript:express", "pkg:typescript:jest"])
        #expect(try await targets("dir:" + billing.path + "/tools", "depends_on", store: store) == ["pkg:python:requests"])
        #expect(try await targets("pkg:go:github.com/acme/shared", "defined_in", store: store) == ["file:" + shared.path + "/go.mod"])
        let viper = try #require(try await store.node("pkg:go:github.com/spf13/viper"))
        let names = [billing, users].map(\.lastPathComponent).sorted()
        let versions = ["v1.9.1 in " + billing.lastPathComponent, "v1.8.0 in " + users.lastPathComponent]
        #expect(viper.signature == "Go module · " + (names[0] == billing.lastPathComponent ? versions : versions.reversed()).joined(separator: ", "))
        #expect(try await store.node("pkg:typescript:jest")?.signature == "npm package · 29.7.0 (dev) in " + billing.lastPathComponent)
        // The import and the manifest name the same package.
        #expect(try await targets(indexer.fileID("main.go"), "imports", store: store) == ["pkg:go:github.com/spf13/viper"])

        try "module github.com/acme/billing-api\n".write(to: billing.appending(path: "go.mod"), atomically: true, encoding: .utf8)
        _ = try await indexer.index()
        #expect(try await targets(indexer.repoID, "depends_on", store: store).isEmpty)
        #expect(try await store.node("pkg:go:github.com/spf13/viper")?.signature == "Go module · v1.8.0 in " + users.lastPathComponent)
    }
}

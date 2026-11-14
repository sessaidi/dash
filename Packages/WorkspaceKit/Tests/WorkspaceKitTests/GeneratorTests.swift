import Foundation
import Testing
@testable import WorkspaceKit

struct GeneratorTests {
    static func deployment(_ name: String, env: String, volumes: String = "[]") -> JSON {
        try! JSON.parse(#"""
        {"metadata":{"name":"\#(name)","labels":{"app":"\#(name)","tags.datadoghq.com/env":"dev","argocd.argoproj.io/instance":"x"}},
         "spec":{"selector":{"matchLabels":{"name":"\#(name)"}},"replicas":4,
           "template":{"metadata":{"labels":{"name":"\#(name)","tags.datadoghq.com/env":"dev"}},
             "spec":{"serviceAccountName":"sa","nodeSelector":{"pool":"prod"},"volumes":\#(volumes),
               "containers":[{"name":"\#(name)","image":"gcr.io/x/\#(name):prod","imagePullPolicy":"IfNotPresent",
                 "ports":[{"containerPort":8080,"name":"http","protocol":"TCP"}],
                 "env":\#(env),
                 "readinessProbe":{"httpGet":{"path":"/health","port":8080,"scheme":"HTTP"},"periodSeconds":5},
                 "livenessProbe":{"exec":{"command":["true"]}},
                 "resources":{"limits":{"memory":"16G"}}}]}}}}
        """#)
    }

    static let source = WorkspaceGenerator.Source(
        deployments: [
            "common-api-gateway": deployment("common-api-gateway", env: #"[{"name":"SHADOW_COMPARE_ENABLED","value":"true"},{"name":"BUILD_SOURCE","value":"prod"}]"#),
            "services-presentation-api": deployment("services-presentation-api", env: #"""
                [{"name":"BASE_URL","value":"https://api.fubo.tv"},{"name":"ROUTE_DATA_SOURCE","value":"db"},
                 {"name":"DB_PASSWORD","valueFrom":{"secretKeyRef":{"name":"papi-db","key":"password"}}},
                 {"name":"FROM_CM","valueFrom":{"configMapKeyRef":{"name":"x","key":"y"}}},
                 {"name":"POD_IP","valueFrom":{"fieldRef":{"fieldPath":"status.podIP"}}}]
                """#, volumes: #"[{"name":"config","configMap":{"name":"papi-config","defaultMode":420}},{"name":"tmp","emptyDir":{}}]"#),
        ],
        services: [
            "common-api-gateway": try! JSON.parse(#"{"metadata":{"name":"common-api-gateway","labels":{"app":"capig"}},"spec":{"selector":{"name":"common-api-gateway"},"ports":[{"port":80,"targetPort":8080,"protocol":"TCP","name":"http"}]}}"#),
            "services-presentation-api": try! JSON.parse(#"{"metadata":{"name":"services-presentation-api"},"spec":{"selector":{"name":"services-presentation-api"},"ports":[{"port":80,"targetPort":8080,"protocol":"TCP","name":"http"}]}}"#),
        ],
        servicePorts: ["common-api-gateway": 80, "services-presentation-api": 80, "services-user": 8080],
        secrets: ["papi-db": try! JSON.parse(#"{"metadata":{"name":"papi-db","labels":{"x":"y"}},"type":"kubernetes.io/basic-auth","data":{"password":"czNjcjN0"}}"#)],
        configMaps: ["papi-config": try! JSON.parse(#"""
            {"metadata":{"name":"papi-config","namespace":"default"},"data":{
              "development.toml":"redis = \"rate-limit-redis-sentinel:26379\"",
              "services_config.json":"{\"services-presentation-api\":{\"host\":\"papi\",\"port\":\"1\"},\"common-api-gateway\":{\"host\":\"capig\"},\"services-user\":{\"host\":\"$SERVICES_USER_SERVICE_HOST\",\"timeout\":\"1s<2s\"},\"services-ad-tech\":{\"host\":\"adtech\"}}"}}
            """#)])

    @Test func generatesWhatUpToolboxDoes() throws {
        let options = WorkspaceGenerator.Options(name: "LAF-12", env: .dev, region: .us, username: "ada", services: WorkspaceGenerator.expand("capig,papi"),
                                                 now: ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z")!)
        let objects = try WorkspaceGenerator.manifests(Self.source, options: options)
        #expect(objects.map { "\($0["kind"]?.string ?? "")/\($0["metadata"]?["name"]?.string ?? "")" } == [
            "Namespace/laf-12", "Secret/papi-db", "ConfigMap/common-api-gateway-varnish-config", "ConfigMap/papi-config",
            "Service/common-api-gateway", "Service/services-presentation-api",
            "Deployment/common-api-gateway", "Deployment/services-presentation-api",
            "HTTPRoute/common-api-gateway-route", "HealthCheckPolicy/common-api-gateway-healthcheck",
        ])
        let namespace = objects[0]
        #expect(namespace["metadata"]?["labels"] == ["deployed_by": "ada", "workspace": "true", "region": "us"])
        #expect(objects[1]["stringData"] == ["password": "s3cr3t"] && objects[1]["type"] == "Opaque")
        #expect(objects[2]["data"]?["default.vcl"]?.string?.contains("var.set(\"country_code3\", \"FRA\");") == true)

        let config = objects[3]["data"]
        #expect(config?["development.toml"]?.string == #"redis = "rate-limit-redis-sentinel.default:26379""#)
        #expect(config?["services_config.json"]?.string == """
            {
              "common-api-gateway": {
                "host": "capig"
              },
              "services-ad-tech": {
                "host": "adtech"
              },
              "services-presentation-api": {
                "host": "localhost",
                "port": "80"
              },
              "services-user": {
                "host": "services-user.default",
                "port": "8080",
                "timeout": "1s\\u003c2s"
              }
            }
            """)

        let capigService = objects[4]
        #expect(capigService["spec"]?["ports"]?.array?.first?["targetPort"] == 8081)
        #expect(capigService["metadata"]?["annotations"]?["cloud.google.com/neg"]?.string == #"{"ingress": true, "exposed_ports": {"80":{}}}"#)

        let capig = objects[6]
        #expect(capig["metadata"]?["labels"] == ["app": "common-api-gateway", "tags.datadoghq.com/env": "dev-workspace", "tags.datadoghq.com/workspace": "laf-12"])
        let capigSpec = capig["spec"]?["template"]?["spec"]
        #expect(capigSpec?["containers"]?.array?.map { $0["name"]?.string ?? "" } == ["common-api-gateway", "varnish"])
        #expect(capigSpec?["containers"]?.array?.first?["env"] == [["name": "BUILD_SOURCE", "value": "laf-12"], ["name": "SHADOW_COMPARE_ENABLED", "value": "false"]])
        #expect(capigSpec?["serviceAccountName"] == nil && capigSpec?["nodeSelector"] == ["cloud.google.com/compute-class": "workspaces-cost-optimized"])
        #expect(capig["spec"]?["replicas"] == 1)

        let papi = objects[7]["spec"]?["template"]?["spec"]?["containers"]?.array?.first
        #expect(papi?["env"] == [
            ["name": "BASE_URL", "value": "https://laf-12.backend-workspace.dev-01.fubo.tv"],
            ["name": "ROUTE_DATA_SOURCE", "value": "static"],
            ["name": "DB_PASSWORD", "valueFrom": ["secretKeyRef": ["key": "password", "name": "papi-db"]]],
            ["name": "POD_IP", "valueFrom": ["fieldRef": ["apiVersion": "v1", "fieldPath": "status.podIP"]]],
        ])
        #expect(papi?["resources"] == ["requests": ["memory": "8G", "cpu": "500m"], "limits": ["memory": "8G", "cpu": "1"]])
        #expect(papi?["livenessProbe"] == nil && papi?["readinessProbe"]?["httpGet"]?["port"] == 8080)
        #expect(objects[7]["spec"]?["template"]?["spec"]?["volumes"] == [["name": "config", "configMap": ["name": "papi-config", "defaultMode": 420]], ["name": "tmp"]])

        #expect(objects[8]["spec"]?["hostnames"] == ["laf-12.backend-workspace.dev-01.fubo.tv"])
        #expect(WorkspaceGenerator.host(name: "x", env: .qa, region: .eu) == "x.backend-workspace-eu.qa-01.fubo.tv")
    }

    @Test func rejectsBadNames() {
        for name in ["default", "papi", "kube-x", "a_b", "-x", ""] {
            #expect(throws: WorkspaceGenerator.GeneratorError.self) { try WorkspaceGenerator.validate(name) }
        }
        #expect(throws: Never.self) { try WorkspaceGenerator.validate("laf-5680") }
    }
}

struct WorkspaceFolderTests {
    @Test func writesUpToolboxLayoutAndReadsItBack() throws {
        let options = WorkspaceGenerator.Options(name: "laf-12", env: .dev, region: .eu, username: "ada", services: WorkspaceGenerator.expand("capig,papi"))
        let objects = try WorkspaceGenerator.manifests(GeneratorTests.source, options: options)
        let parent = FileManager.default.temporaryDirectory.appending(path: "ws-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = WorkspaceFolder(url: WorkspaceFolder.url(in: parent, name: "laf-12", env: .dev, region: .eu))
        #expect(folder.url.lastPathComponent == "laf-12-dev-eu")
        try folder.write(objects)
        let files = try FileManager.default.subpathsOfDirectory(atPath: folder.url.path).sorted()
        #expect(files == [".gitignore", "common-api-gateway", "common-api-gateway/configmap-varnish.yaml", "common-api-gateway/deployment.yaml",
                          "common-api-gateway/healthcheck-policy.yaml", "common-api-gateway/httproute.yaml", "common-api-gateway/kustomization.yaml",
                          "common-api-gateway/service.yaml", "kustomization.yaml", "namespace.yaml", "services-presentation-api",
                          "services-presentation-api/configmap-papi-config.yaml", "services-presentation-api/deployment.yaml",
                          "services-presentation-api/kustomization.yaml", "services-presentation-api/secret-papi-db.yaml",
                          "services-presentation-api/service.yaml"])
        // YAML round-trips every object exactly (VCL and JSON configs included).
        let back = try folder.read()
        #expect(Set(back.map(\.line)) == Set(objects.map(\.line)))
        #expect(throws: (any Error).self) { try folder.write(objects) }
        try folder.write(objects, force: true)
    }

    @Test func diffsOnlyWhatTheFilesSet() {
        var differences: [String] = []
        let local: JSON = ["kind": "ConfigMap", "data": ["a.toml": "x = 2", "b": "same"]]
        let live: JSON = ["kind": "ConfigMap", "data": ["a.toml": "x = 1", "b": "same"], "metadata": ["uid": "1"]]
        WorkspaceClient.diff(local, live, path: "", into: &differences, secret: false)
        #expect(differences == ["data.a.toml"])
        differences = []
        WorkspaceClient.diff(["kind": "Secret", "stringData": ["p": "s3cr3t"]], ["kind": "Secret", "data": ["p": "czNjcjN0"]], path: "", into: &differences, secret: true)
        #expect(differences.isEmpty)
    }
}

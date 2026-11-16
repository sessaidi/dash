import Foundation

/// Services: what a repository deploys, `service:<repoID>:<name>`. Found in Dockerfiles (named
/// after their folder, the repository at its root), Helm charts (`Chart.yaml` name), Kubernetes
/// workloads with a literal name, Go `cmd/<name>` mains (and a root `main.go`), `package.json`
/// with a start script, and docker-compose services built from the repository. Each definition
/// adds `service —defined_in→ file` and a ref to the folder of code it runs (deployment folders
/// such as `helm/` or `deploy/` are walked up); the link pass adds `repo —deploys→ service`.
struct ServiceExtractor: CodeExtractor {
    let name = "services"

    /// Folders that hold how something is deployed rather than its code.
    static let deployFolders: Set<String> = [
        "helm", ".helm", "chart", "charts", "deploy", ".deploy", "deployment", "deployments", "k8s", "kube", "kubernetes",
        "manifests", "infra", "ops", "templates", "base", "overlays", "docker", ".docker", "dockerfiles", "ci", ".ci",
        "environments", "envs", "env", "values", "prod", "production", "staging", "stage", "dev", "development", "qa",
        "preprod", "sandbox", "local",
    ]
    static let workloadKinds: Set<String> = ["Deployment", "StatefulSet", "DaemonSet", "CronJob", "Job", "Rollout"]
    /// `Dockerfile.<suffix>` variants of the same image, not other services.
    static let variants: Set<String> = ["dev", "test", "local", "ci", "debug", "e2e", "build", "base", "prod", "production", "staging"]

    static func id(repo: String, name: String) -> String { "service:" + repo + ":" + name }

    func accepts(path: String, language: String) -> Bool {
        switch language {
        case "dockerfile", "yaml": true
        case "json": (path as NSString).lastPathComponent == "package.json"
        case "go": (path as NSString).lastPathComponent == "main.go" || Self.commandName(path) != nil
        default: false
        }
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        var found: [(name: String, folder: String?, line: Int, signature: String)] = []
        switch file.language {
        case "dockerfile":
            let parts = file.fileName.split(separator: ".", maxSplits: 1).map(String.init)
            let suffix = parts.count == 2 && parts[0] == "Dockerfile" ? parts[1].lowercased() : ""
            let folder = Self.codeFolder(of: file.directory, name: nil)
            let base = folder.isEmpty ? file.repoName : (folder as NSString).lastPathComponent
            let name = suffix.isEmpty || Self.variants.contains(suffix) ? base : base + "-" + suffix
            found.append((name, folder, 1, "Dockerfile"))
        case "yaml":
            found += yaml(file)
        case "json":
            if let data = file.text.data(using: .utf8), let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = package["name"] as? String, !name.isEmpty, (package["scripts"] as? [String: Any])?["start"] != nil {
                found.append((name, file.directory, 1, "package.json start script"))
            }
        case "go":
            guard file.text.range(of: #"(?m)^package main\b"#, options: .regularExpression) != nil,
                  let line = file.parsed.symbols.first(where: { $0.name == "main" && $0.container.isEmpty })?.line else { break }
            if let command = Self.commandName(file.path) {
                found.append((command, file.directory, line, "Go command"))
            } else if file.path == "main.go" {
                found.append((file.repoName, "", line, "Go command"))
            }
        default: break
        }
        var result = Extraction()
        for service in found where !service.name.isEmpty {
            let id = Self.id(repo: file.repoID, name: service.name)
            result.nodes.append(KnowledgeNode(id: id, kind: "service", name: service.name, qualified: service.name, repo: file.repoID,
                                              signature: service.signature, source: "code"))
            result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
            if let folder = service.folder { result.refs.append(KnowledgeRef(src: id, kind: "runs", names: [folder], line: service.line)) }
        }
        return result
    }

    /// `<name>` for a file directly in a `cmd/<name>/` folder.
    static func commandName(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[parts.count - 3] == "cmd", path.hasSuffix(".go") else { return nil }
        return parts[parts.count - 2]
    }

    /// The code folder a deployment file stands for: `apps/billing/helm` → `apps/billing`,
    /// `charts/billing` (named after the service) → the repository root.
    static func codeFolder(of folder: String, name: String?) -> String {
        var parts = folder.split(separator: "/").map(String.init)
        if let name, parts.last == name, parts.count >= 2, deployFolders.contains(parts[parts.count - 2].lowercased()) { parts.removeLast() }
        while let last = parts.last, deployFolders.contains(last.lowercased()) { parts.removeLast() }
        return parts.joined(separator: "/")
    }

    // MARK: YAML: charts, workloads, compose

    private func yaml(_ file: ExtractionInput) -> [(name: String, folder: String?, line: Int, signature: String)] {
        let name = file.fileName.lowercased()
        if name == "chart.yaml" {
            guard let chart = SourceScan.matches(#"(?m)^name:\s*["']?([\w.-]+)"#, in: file.text).first?[1],
                  file.text.range(of: #"(?m)^type:\s*library"#, options: .regularExpression) == nil else { return [] }
            return [(chart, Self.codeFolder(of: file.directory, name: chart), 1, "Helm chart")]
        }
        if name.hasPrefix("docker-compose") || name.hasPrefix("compose.") { return compose(file) }
        guard file.text.contains("kind:"), file.text.contains("apiVersion:") else { return [] }
        // Helm templates name things with {{ … }}: the chart stands for them.
        if file.path.contains("/templates/") && file.text.contains("{{") { return [] }
        var result: [(String, String?, Int, String)] = []
        let lines = file.text.components(separatedBy: "\n")
        var start = 0
        for index in 0...lines.count where index == lines.count || lines[index].hasPrefix("---") {
            defer { start = index + 1 }
            guard index > start else { continue }
            let document = lines[start..<index].joined(separator: "\n")
            guard let kind = SourceScan.matches(#"(?m)^kind:\s*["']?(\w+)"#, in: document).first?[1], Self.workloadKinds.contains(kind),
                  let workload = SourceScan.matches(#"(?m)^metadata:\s*\n(?:[ \t]+.*\n)*?[ \t]+name:\s*["']?([\w.-]+)["']?\s*$"#, in: document + "\n").first?[1]
            else { continue }
            let line = start + (lines[start..<index].firstIndex { $0.hasPrefix("kind:") }.map { $0 - start } ?? 0) + 1
            result.append((workload, Self.codeFolder(of: file.directory, name: workload), line, kind))
        }
        return result
    }

    /// docker-compose services built from the repository (`build:`), with their build context.
    private func compose(_ file: ExtractionInput) -> [(name: String, folder: String?, line: Int, signature: String)] {
        let lines = file.text.components(separatedBy: "\n")
        guard let top = lines.firstIndex(where: { $0.hasPrefix("services:") }) else { return [] }
        var result: [(String, String?, Int, String)] = []
        var current: (name: String, line: Int)?
        var serviceIndent: Int?
        func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        for index in (top + 1)..<lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if indentation(line) == 0 { break }
            if serviceIndent == nil { serviceIndent = indentation(line) }
            if indentation(line) == serviceIndent, let key = SourceScan.matches(#"^([\w.-]+):\s*$"#, in: trimmed).first?[1] {
                current = (key, index + 1)
                continue
            }
            guard let service = current, let context = SourceScan.matches(#"^(?:build|context):\s*["']?([^"'\s#]+)"#, in: trimmed).first?[1] else { continue }
            guard let folder = SourceScan.join(file.directory, context) else { continue }
            result.append((service.name, folder, service.line, "docker-compose service"))
            current = nil
        }
        return result
    }
}

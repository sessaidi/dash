import DashKit
import Foundation

/// CI jobs, `ci:<repoID>:<workflow>/<job>`: GitHub Actions workflows (`.github/workflows/*`),
/// CircleCI (`.circleci/config.yml`, one node per job a workflow runs) and GitLab CI
/// (`.gitlab-ci.yml`, workflow "gitlab-ci"). The signature says the system, workflow, triggers,
/// what the job needs and whether it deploys; the summary lists parameters and steps (commands
/// with secrets masked). Images it runs in → `ci_job —uses_image→ image`. Paths and service names
/// its parameters and commands mention → a `ci_targets` ref the link pass resolves to the
/// repository's services (`ci_job —deploys→ service` for a deploy job, `—about→` otherwise).
struct CIExtractor: CodeExtractor {
    let name = "ci"
    var sharedKinds: [String] { ["image"] }
    static let refKind = "ci_targets"

    static func id(repo: String, workflow: String, job: String) -> String { "ci:" + repo + ":" + workflow + "/" + job }

    func accepts(path: String, language: String) -> Bool {
        guard language == "yaml" else { return false }
        return Self.system(path) != nil
    }

    static func system(_ path: String) -> String? {
        if path.hasPrefix(".github/workflows/") && !path.dropFirst(18).contains("/") { return "github-actions" }
        if path == ".circleci/config.yml" || path == ".circleci/config.yaml" { return "circleci" }
        if path == ".gitlab-ci.yml" || path == ".gitlab-ci.yaml" { return "gitlab-ci" }
        return nil
    }

    struct Job {
        var workflow: String
        var name: String
        var line: Int
        var description: String
        var details: [String] = []
        var needs: [String] = []
        var steps: [String] = []
        var images: [String] = []
        /// Everything it says, for deploy commands, paths and names.
        var text: [String] = []
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        guard let system = Self.system(file.path), let root = YAMLTree.parse(file.text) else { return Extraction() }
        let jobs: [Job] = switch system {
        case "github-actions": Self.githubActions(root, file: file.fileName)
        case "circleci": Self.circleCI(root)
        default: Self.gitlab(root)
        }
        let label = ["github-actions": "GitHub Actions", "circleci": "CircleCI", "gitlab-ci": "GitLab CI"][system] ?? system
        let paths = Self.paths(file.files)
        var result = Extraction()
        for job in jobs where !job.name.isEmpty {
            let id = Self.id(repo: file.repoID, workflow: job.workflow, job: job.name)
            let deploys = Self.deploys(job)
            var signature = ["\(label) job \(job.name) in \(job.workflow)", job.description] + job.details
            if !job.needs.isEmpty { signature.append("needs " + job.needs.prefix(6).joined(separator: ", ")) }
            if deploys { signature.append("deploys") }
            let steps = job.steps.prefix(15).map { Sanitizer.clean($0) }
            let summary = steps.isEmpty ? "" : "Steps: " + steps.joined(separator: "; ") + (job.steps.count > 15 ? "; …" : "") + "."
            result.nodes.append(KnowledgeNode(id: id, kind: "ci_job", name: job.name, qualified: job.workflow + "/" + job.name, repo: file.repoID, path: file.path,
                                              line: job.line, language: system, signature: signature.filter { !$0.isEmpty }.joined(separator: " · "),
                                              summary: String(summary.prefix(2000)), source: "code"))
            result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
            for image in Set(job.images.compactMap(RuntimeExtractor.imageName)).sorted() {
                result.nodes.append(ContainerExtractor.imageNode(image))
                result.edges.append(KnowledgeEdge(src: id, dst: "image:" + image, kind: "uses_image"))
            }
            let targets = Self.targets(job.text, paths: paths)
            if !targets.isEmpty { result.refs.append(KnowledgeRef(src: id, kind: Self.refKind, names: [deploys ? "deploys" : "about"] + targets, line: job.line)) }
        }
        return result
    }

    // MARK: GitHub Actions

    static func githubActions(_ root: YAMLNode, file: String) -> [Job] {
        let workflow = (file as NSString).deletingPathExtension
        let triggers = triggerText(root["on"])
        return root["jobs"]?.entries.map { key, node in
            var job = Job(workflow: workflow, name: key, line: max(node.line - 1, 1), description: triggers.isEmpty ? "" : "on " + triggers)
            if let runner = node["runs-on"]?.strings, !runner.isEmpty { job.details.append("runs on " + runner.joined(separator: ", ")) }
            if let uses = node["uses"]?.string { job.details.append("uses " + uses) }
            if let environment = node["environment"]?.string ?? node["environment"]?["name"]?.string { job.details.append("environment " + environment) }
            job.needs = node["needs"]?.strings ?? []
            job.images = [node["container"]?.string ?? node["container"]?["image"]?.string].compactMap { $0 }
                + (node["services"]?.entries ?? []).compactMap { $0.node["image"]?.string }
            for step in node["steps"]?.items ?? [] {
                let name = step["name"]?.string
                if let uses = step["uses"]?.string { job.steps.append((name.map { $0 + " " } ?? "") + "(" + uses + ")") }
                if let run = step["run"]?.string { job.steps.append((name.map { $0 + ": " } ?? "") + firstLine(run)) }
            }
            job.text = scalars(node) + [key]
            return job
        } ?? []
    }

    /// `push`, `[push, pull_request]` or `{push: {branches: [main]}, schedule: [{cron: …}]}` → "push (main), schedule 0 3 * * *".
    static func triggerText(_ node: YAMLNode?) -> String {
        guard let node else { return "" }
        if !node.strings.isEmpty { return node.strings.joined(separator: ", ") }
        return node.entries.map { key, value in
            if key == "schedule" { return (["schedule"] + value.items.compactMap { $0["cron"]?.string }).joined(separator: " ") }
            let branches = value["branches"]?.strings ?? value["tags"]?.strings ?? []
            return branches.isEmpty ? key : key + " (" + branches.joined(separator: ", ") + ")"
        }.joined(separator: ", ")
    }

    // MARK: CircleCI

    static func circleCI(_ root: YAMLNode) -> [Job] {
        let definitions = Dictionary((root["jobs"]?.entries ?? []).map { ($0.key, $0.node) }, uniquingKeysWith: { first, _ in first })
        var jobs: [Job] = []
        for (workflow, node) in root["workflows"]?.entries ?? [] where node.isMap {
            let triggers = (node["triggers"]?.items ?? []).compactMap { $0.at("schedule", "cron")?.string }.map { "schedule " + $0 }
            for entry in node["jobs"]?.items ?? [] {
                let reference: String
                let parameters: YAMLNode?
                if let simple = entry.string {
                    (reference, parameters) = (simple, nil)
                } else if let first = entry.entries.first {
                    (reference, parameters) = (first.key, first.node)
                } else {
                    continue
                }
                let name = parameters?["name"]?.string ?? reference
                let definition = definitions[reference]
                var job = Job(workflow: workflow, name: name, line: entry.line, description: reference == name ? "" : reference)
                job.details += triggers
                if let context = parameters?["context"]?.strings, !context.isEmpty { job.details.append("context " + context.joined(separator: ", ")) }
                let branches = (parameters?.at("filters", "branches", "only")?.strings ?? []) + (parameters?.at("filters", "tags", "only")?.strings ?? [])
                if !branches.isEmpty { job.details.append("only " + branches.joined(separator: ", ")) }
                job.needs = parameters?["requires"]?.strings ?? []
                let reserved: Set<String> = ["name", "requires", "context", "filters", "matrix", "type", "pre-steps", "post-steps"]
                let values = (parameters?.entries ?? []).filter { !reserved.contains($0.key) }.compactMap { key, value in value.string.map { key + " " + $0 } }
                if !values.isEmpty { job.steps.append("parameters " + values.prefix(8).joined(separator: ", ")) }
                if let definition {
                    job.images = (definition["docker"]?.items ?? []).compactMap { $0["image"]?.string }
                    for step in definition["steps"]?.items ?? [] {
                        if let simple = step.string { job.steps.append(simple); continue }
                        guard let (command, body) = step.entries.first.map({ ($0.key, $0.node) }) else { continue }
                        if command == "run" {
                            let text = body.string ?? body["command"]?.string ?? ""
                            job.steps.append((body["name"]?.string.map { $0 + ": " } ?? "") + firstLine(text))
                        } else {
                            job.steps.append(command)
                        }
                    }
                    job.text = scalars(definition)
                }
                job.text += [name, reference] + (parameters.map { scalars($0) } ?? [])
                jobs.append(job)
            }
        }
        return jobs
    }

    // MARK: GitLab CI

    static let gitlabKeywords: Set<String> = ["stages", "variables", "include", "default", "workflow", "image", "services", "before_script", "after_script", "cache", "pages"]

    static func gitlab(_ root: YAMLNode) -> [Job] {
        root.entries.compactMap { key, node in
            guard !key.hasPrefix("."), !gitlabKeywords.contains(key), node.isMap,
                  node["script"] != nil || node["trigger"] != nil || node["extends"] != nil else { return nil }
            var job = Job(workflow: "gitlab-ci", name: key, line: max(node.line - 1, 1), description: node["stage"]?.string.map { "stage " + $0 } ?? "")
            if let environment = node["environment"]?.string ?? node["environment"]?["name"]?.string { job.details.append("environment " + environment) }
            if let extends = node["extends"]?.strings, !extends.isEmpty { job.details.append("extends " + extends.joined(separator: ", ")) }
            job.needs = node["needs"].map { needs in needs.strings + needs.items.compactMap { $0["job"]?.string } } ?? []
            job.images = [node["image"]?.string ?? node["image"]?["name"]?.string].compactMap { $0 }
            job.steps = (node["script"]?.strings ?? []).map(firstLine)
            job.text = scalars(node) + [key]
            return job
        }
    }

    // MARK: Deploys and targets

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let more = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count > 1
        let short = line.count > 120 ? String(line.prefix(119)) + "…" : line
        return more ? short + " …" : short
    }

    /// Every scalar under a node, "key: value" in mappings.
    static func scalars(_ node: YAMLNode, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        if let string = node.string { return [string] }
        return node.items.flatMap { scalars($0, depth: depth + 1) }
            + node.entries.flatMap { key, value in value.string.map { [key + ": " + $0] } ?? scalars(value, depth: depth + 1) }
    }

    static func deploys(_ job: Job) -> Bool {
        let pattern = #"(?i)(\bdeploy|\bhelm\s+(upgrade|install)\b|\bkubectl\s+(apply|rollout|set\s+image)\b|\bgcloud\s+(run|app|functions)\s+deploy\b|\bterraform\s+apply\b|\bargocd\s+app\s+sync\b|\bflux\s+reconcile\b|\bskaffold\s+(run|deploy)\b|\b(serverless|sls|cdk)\s+deploy\b)"#
        return ([job.name] + job.text).contains { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    /// The repository's directories (and files) a path in a job may name.
    static func paths(_ files: [String]) -> Set<String> {
        var result = Set(files)
        for file in files { result.formUnion(CodeIndexer.ancestors(of: file)) }
        return result
    }

    /// "path:<dir or file>" for paths of the repository the job mentions, "name:<word>" for what a
    /// deploy command or a `*_NAME` setting names.
    static func targets(_ text: [String], paths: Set<String>) -> [String] {
        var found: [String] = []
        func add(_ target: String) { if !found.contains(target) { found.append(target) } }
        for value in text {
            // A path of the repository: with a slash, or written "./x".
            for match in SourceScan.matches(#"(?:^|[\s="':,])(\./)?([\w.-]+(?:/[\w.-]+)*)/?"#, in: value) {
                let path = match[2].hasSuffix("/...") ? String(match[2].dropLast(4)) : match[2]
                if path.contains("/") || !match[1].isEmpty, paths.contains(path) { add("path:" + path) }
            }
            for match in SourceScan.matches(#"\b(?:helm\s+(?:upgrade|install)(?:\s+--install)?|gcloud\s+run\s+deploy|kubectl\s+rollout\s+restart\s+deployment/?)\s+([a-z0-9][\w.-]*)"#, in: value) {
                add("name:" + match[1])
            }
            for match in SourceScan.matches(#"\b[A-Z][A-Z0-9]*_(?:NAME|SERVICE|APP)\s*[:=]\s*["']?([a-z0-9][\w.-]*)"#, in: value) { add("name:" + match[1]) }
        }
        return found
    }
}

/// The link pass for CI jobs: the services a job's paths and names point at.
enum CILinks {
    static func link(repo: String, root: String, refs: [KnowledgeRef], runs: [KnowledgeEdge], store: KnowledgeStore) async throws -> [KnowledgeEdge] {
        guard !refs.isEmpty else { return [] }
        let definitions = try await store.definitions(repo: repo, idPrefix: "service:")
        let directory = "dir:" + root + "/"
        var folders: [(service: String, folder: String)] = runs.map { ($0.src, $0.dst == repo ? "" : String($0.dst.dropFirst(directory.count))) }
        folders += definitions.map { ($0.id, ($0.path as NSString).deletingLastPathComponent) }
        var edges: [KnowledgeEdge] = []
        for ref in refs {
            guard let mode = ref.names.first else { continue }
            var services = Set<String>()
            for target in ref.names.dropFirst() {
                if target.hasPrefix("name:") {
                    let id = ServiceExtractor.id(repo: repo, name: String(target.dropFirst(5)))
                    if definitions.contains(where: { $0.id == id }) { services.insert(id) }
                } else if target.hasPrefix("path:") {
                    let path = String(target.dropFirst(5))
                    if let file = definitions.first(where: { $0.path == path }) { services.insert(file.id); continue }
                    // The service whose folder is the deepest around the path (not the repository root).
                    let around = folders.filter { !$0.folder.isEmpty && (path == $0.folder || path.hasPrefix($0.folder + "/")) }
                    let depth = around.map { $0.folder.split(separator: "/").count }.max()
                    services.formUnion(around.filter { $0.folder.split(separator: "/").count == depth }.map(\.service))
                }
            }
            edges += services.sorted().map { KnowledgeEdge(src: ref.src, dst: $0, kind: mode == "deploys" ? "deploys" : "about", source: ExtractionLinks.source) }
        }
        return edges
    }
}

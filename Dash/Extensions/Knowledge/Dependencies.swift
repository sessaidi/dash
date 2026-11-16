import Foundation
import SQLite3

/// What a repository depends on, from its manifests: go.mod, package.json, requirements*.txt,
/// pyproject.toml, Package.swift and Cargo.toml. The manifest's folder (the repository at the root)
/// `—depends_on→ pkg:<language>:<name>`, the id import edges use (Go module path; npm packages under
/// typescript when a tsconfig.json sits next to package.json, else javascript; Python and Rust
/// names with `_` for `-`). The version is a `dependency` ref on the package; the package a
/// manifest declares itself `—defined_in→` the manifest. `ServiceLinks` turns these into package
/// signatures and `repo —depends_on→ repo`.
struct DependencyExtractor: CodeExtractor {
    let name = "dependencies"
    let sharedKinds = ["package"]
    static let refKind = "dependency"

    struct Dependency: Equatable {
        var name: String
        var version: String
    }

    func accepts(path: String, language: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return ["go.mod", "package.json", "pyproject.toml", "Package.swift", "Cargo.toml"].contains(name) || language == "requirements"
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        guard !SourceScan.isTest(file.path), !file.path.contains("node_modules/"), !file.path.contains("vendor/") else { return Extraction() }
        let manifest: (language: String, module: String?, dependencies: [Dependency])
        switch file.fileName {
        case "go.mod": manifest = ("go", Self.goModule(file.text), Self.goRequires(file.text))
        case "package.json":
            let typed = file.context.paths().files.contains(file.directory.isEmpty ? "tsconfig.json" : file.directory + "/tsconfig.json")
            let parsed = Self.packageJSON(file.text)
            manifest = (typed ? "typescript" : "javascript", parsed.name, parsed.dependencies)
        case "pyproject.toml":
            let parsed = Self.pyproject(file.text)
            manifest = ("python", parsed.name, parsed.dependencies)
        case "Package.swift": manifest = ("swift", SourceScan.matches(#"Package\s*\(\s*name:\s*"([^"]+)""#, in: file.text).first?[1], Self.swiftPackages(file.text))
        case "Cargo.toml":
            let parsed = Self.cargo(file.text)
            manifest = ("rust", parsed.name, parsed.dependencies)
        default: manifest = ("python", nil, Self.requirements(file.text))
        }
        let owner = file.directory.isEmpty ? file.repoID : file.directoryID(file.directory)
        var result = Extraction()
        var seen = Set<String>()
        for dependency in manifest.dependencies {
            let id = Self.id(language: manifest.language, name: dependency.name)
            guard seen.insert(id).inserted, id != manifest.module.map({ Self.id(language: manifest.language, name: $0) }) else { continue }
            result.nodes.append(Self.node(id: id, language: manifest.language))
            result.edges.append(KnowledgeEdge(src: owner, dst: id, kind: "depends_on"))
            if !dependency.version.isEmpty { result.refs.append(KnowledgeRef(src: id, kind: Self.refKind, names: [dependency.version])) }
        }
        if let module = manifest.module, !module.isEmpty {
            let id = Self.id(language: manifest.language, name: module)
            result.nodes.append(Self.node(id: id, language: manifest.language))
            result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
        }
        return result
    }

    static func id(language: String, name: String) -> String {
        let normalized = ["python", "rust"].contains(language) ? name.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: ".", with: "_") : name
        return "pkg:" + language + ":" + normalized
    }

    static func node(id: String, language: String) -> KnowledgeNode {
        let name = id.split(separator: ":", maxSplits: 2).last.map(String.init) ?? id
        return KnowledgeNode(id: id, kind: "package", name: name, qualified: name, language: language, source: "code")
    }

    // MARK: Manifests

    static func goModule(_ text: String) -> String? {
        SourceScan.matches(#"(?m)^module\s+"?([^\s"]+)"?"#, in: text).first?[1]
    }

    /// Direct requirements: `require x v1` and the lines of `require ( … )`, not `// indirect` ones.
    static func goRequires(_ text: String) -> [Dependency] {
        var result: [Dependency] = []
        var block = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("require (") || line == "require(" { block = true; continue }
            if block && line.hasPrefix(")") { block = false; continue }
            guard block || line.hasPrefix("require "), !line.contains("// indirect") else { continue }
            let body = block ? line : String(line.dropFirst("require ".count))
            let parts = body.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, !parts[0].hasPrefix("//") { result.append(Dependency(name: String(parts[0]), version: String(parts[1]))) }
        }
        return result
    }

    static func packageJSON(_ text: String) -> (name: String?, dependencies: [Dependency]) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return (nil, []) }
        var result: [Dependency] = []
        for (section, suffix) in [("dependencies", ""), ("peerDependencies", " (peer)"), ("optionalDependencies", ""), ("devDependencies", " (dev)")] {
            guard let map = object[section] as? [String: Any] else { continue }
            for name in map.keys.sorted() where !result.contains(where: { $0.name == name }) {
                let version = map[name] as? String ?? ""
                // Workspace and file links are other folders, not packages.
                if version.hasPrefix("file:") || version.hasPrefix("link:") { continue }
                result.append(Dependency(name: name, version: version.isEmpty ? "" : version + suffix))
            }
        }
        return (object["name"] as? String, result)
    }

    /// `name[extra]>=1.2; marker` lines; not options (`-r`, `-e`), URLs or comments.
    static func requirements(_ text: String) -> [Dependency] {
        text.components(separatedBy: "\n").compactMap(requirement)
    }

    static func requirement(_ raw: String) -> Dependency? {
        let line = raw.components(separatedBy: " #").first!.trimmingCharacters(in: .whitespaces)
        guard let match = SourceScan.matches(#"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*((?:[<>=!~]=?|===)\s*[^;,\s]+(?:\s*,\s*[<>=!~]=?\s*[^;,\s]+)*)?"#, in: line).first,
              !line.hasPrefix("-"), !line.contains("://") else { return nil }
        return Dependency(name: match[1], version: match[2].replacingOccurrences(of: " ", with: ""))
    }

    /// PEP 621 `[project]` name and dependencies, or Poetry's `[tool.poetry]` tables.
    static func pyproject(_ text: String) -> (name: String?, dependencies: [Dependency]) {
        var name: String?
        var result: [Dependency] = []
        var array = false
        func items(_ text: String) {
            for item in SourceScan.matches(#""([^"]+)"|'([^']+)'"#, in: text) {
                if let dependency = requirement(item[1].isEmpty ? item[2] : item[1]) { result.append(dependency) }
            }
        }
        for (section, line) in tomlLines(text) {
            if array {
                items(line)
                if line.contains("]") { array = false }
                continue
            }
            guard let (key, value) = keyValue(line) else { continue }
            switch section {
            case "project", "tool.poetry":
                if key == "name" { name = unquote(value) }
                if section == "project", key == "dependencies" {
                    items(value)
                    array = !value.contains("]")
                }
            case "tool.poetry.dependencies", "tool.poetry.dev-dependencies", "tool.poetry.group.dev.dependencies":
                if key != "python" { result.append(Dependency(name: key, version: version(value))) }
            default: break
            }
        }
        return (name, result)
    }

    static func cargo(_ text: String) -> (name: String?, dependencies: [Dependency]) {
        var name: String?
        var result: [Dependency] = []
        for (section, line) in tomlLines(text) {
            guard let (key, value) = keyValue(line) else { continue }
            if section == "package", key == "name" { name = unquote(value) }
            if ["dependencies", "dev-dependencies", "build-dependencies", "workspace.dependencies"].contains(section) {
                result.append(Dependency(name: key, version: version(value)))
            } else if let crate = SourceScan.matches(#"^(?:workspace\.)?(?:dev-|build-)?dependencies\.([\w-]+)$"#, in: section).first?[1], key == "version" {
                result.append(Dependency(name: crate, version: unquote(value)))
            }
        }
        return (name, result)
    }

    /// `.package(url: "https://host/owner/name.git", from: "1.0.0")` and its `exact:`, `branch:`,
    /// range and `.upToNextMajor(from:)` forms; not local `path:` packages.
    static func swiftPackages(_ text: String) -> [Dependency] {
        SourceScan.matches(#"\.package\s*\(\s*(?:name:\s*"[^"]*"\s*,\s*)?url:\s*"([^"]+)"\s*,\s*([^)]*\)?)"#, in: text).map { match in
            let name = ((match[1] as NSString).lastPathComponent as NSString).deletingPathExtension
            let version = SourceScan.matches(#"(from|exact|branch|revision):\s*"([^"]+)""#, in: match[2]).first.map { ($0[1] == "branch" || $0[1] == "revision" ? $0[1] + " " : "") + $0[2] }
                ?? SourceScan.matches(#""([^"]+)"\s*\.\.[.<]\s*"([^"]+)""#, in: match[2]).first.map { $0[1] + "..<" + $0[2] } ?? ""
            return Dependency(name: name, version: version)
        }
    }

    // MARK: TOML lines

    /// Each line without comments, with the `[section]` it's in.
    private static func tomlLines(_ text: String) -> [(section: String, line: String)] {
        var section = ""
        var result: [(String, String)] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let header = SourceScan.matches(#"^\[\[?\s*([^\]]+?)\s*\]\]?"#, in: line).first { section = header[1].replacingOccurrences(of: "\"", with: ""); continue }
            result.append((section, line))
        }
        return result
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let match = SourceScan.matches(#"^"?([\w.-]+)"?\s*=\s*(.*)$"#, in: line).first else { return nil }
        return (match[1], match[2].trimmingCharacters(in: .whitespaces))
    }

    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    /// `"1.0"` or `{ version = "1.0", features = […] }`.
    private static func version(_ value: String) -> String {
        if value.hasPrefix("{") { return SourceScan.matches(#"version\s*=\s*"([^"]+)""#, in: value).first?[1] ?? "" }
        return value.hasPrefix("\"") || value.hasPrefix("'") ? unquote(value) : ""
    }
}

extension KnowledgeStore {
    /// (package, repository, version) for every dependency a manifest declares.
    func dependencyVersions() throws -> [(package: String, repo: String, version: String)] {
        let statement = try prepare("SELECT src, repo, names FROM refs WHERE kind = ?1")
        defer { sqlite3_finalize(statement) }
        bind(statement, [DependencyExtractor.refKind])
        var result: [(String, String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append((text(statement, 0), text(statement, 1), text(statement, 2))) }
        return result
    }

    /// (dependent, dependency) repositories: one depends on a package a manifest of the other declares.
    func repositoryDependencies() throws -> [(src: String, dst: String)] {
        try pairs("""
            SELECT DISTINCT CASE WHEN a.kind = 'repo' THEN a.id ELSE a.repo END, f.repo
            FROM edges d JOIN nodes a ON a.id = d.src
            JOIN edges def ON def.src = d.dst AND def.kind = 'defined_in'
            JOIN nodes f ON f.id = def.dst
            WHERE d.kind = 'depends_on' AND d.dst >= 'pkg:' AND d.dst < 'pkg;' AND f.repo != ''
            """, []).filter { $0.src != $0.dst && !$0.src.isEmpty }
    }
}

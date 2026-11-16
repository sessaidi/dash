import Foundation

/// Configuration keys, `config:<dotted.key>` (lowercased; the name keeps the case written).
/// Config files set them (`file —sets_config→ config`): TOML files that aren't project manifests,
/// and YAML/JSON under a config/conf/settings folder or named config/settings/application/…, but
/// not Kubernetes manifests, Helm values, CI, compose, OpenAPI or translations. Leaf keys only, at
/// most 4 deep and 400 per file; values are never read. Code reads them
/// (`symbol —reads_config→ config`): viper and koanf getters, node-config/nconf `config.get`,
/// Spring `@Value("${a.b}")`, configparser `get("section", "key")`, dynaconf `settings.get`. A Go
/// struct field tagged `toml`/`mapstructure`/`koanf` (or `yaml` where the file decodes YAML) is a
/// `reads_config` ref the link pass resolves to the repository's keys ending in that name.
struct ConfigKeyExtractor: CodeExtractor {
    let name = "config"
    var sharedKinds: [String] { ["config"] }
    static let refKind = "reads_config"
    static let maxKeys = 400

    static func id(_ key: String) -> String { "config:" + key.lowercased() }

    static func node(_ key: String) -> KnowledgeNode {
        KnowledgeNode(id: id(key), kind: "config", name: key, qualified: key, signature: "Config key " + key, source: "code")
    }

    static let codeLanguages: Set<String> = ["go", "typescript", "javascript", "python", "java", "kotlin"]

    func accepts(path: String, language: String) -> Bool {
        ["toml", "yaml", "json"].contains(language) || (Self.codeLanguages.contains(language) && !SourceScan.isTest(path))
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        if Self.codeLanguages.contains(file.language) {
            var seen = Set<String>()
            for (key, line) in Self.reads(file) {
                let caller = file.symbol(at: line) ?? file.fileID
                guard seen.insert(caller + "\n" + key.lowercased()).inserted else { continue }
                if !result.nodes.contains(where: { $0.id == Self.id(key) }) { result.nodes.append(Self.node(key)) }
                result.edges.append(KnowledgeEdge(src: caller, dst: Self.id(key), kind: "reads_config"))
            }
            for (tag, line) in Self.tags(file) {
                result.refs.append(KnowledgeRef(src: file.symbol(at: line) ?? file.fileID, kind: Self.refKind, names: [tag], line: line))
            }
            return result
        }
        guard Self.isConfigFile(file.path, text: file.text) else { return result }
        var seen = Set<String>()
        for key in Self.keys(file.text, language: file.language).prefix(Self.maxKeys) where seen.insert(key.lowercased()).inserted {
            result.nodes.append(Self.node(key))
            result.edges.append(KnowledgeEdge(src: file.fileID, dst: Self.id(key), kind: "sets_config"))
        }
        return result
    }

    // MARK: Config files

    static let manifests: Set<String> = ["package.json", "composer.json", "cargo.toml", "pyproject.toml", "netlify.toml", "vercel.json", "rust-toolchain.toml",
                                         "renovate.json", "lerna.json", "nx.json", "turbo.json", "app.json", "manifest.json", "codecov.yml", "mkdocs.yml",
                                         "chart.yaml", "kustomization.yaml", "buf.yaml", "buf.gen.yaml", "pnpm-workspace.yaml", "deno.json", "bunfig.toml",
                                         "taplo.toml", "rustfmt.toml", "clippy.toml", "dependabot.yml", "mise.toml", "ruff.toml", ".python-version"]
    static let excludedFolders: Set<String> = [".github", ".circleci", ".vscode", ".idea", ".devcontainer", "i18n", "l10n", "locales", "locale",
                                               "translations", "lang", "langs", "messages", "fixtures", "testdata", "__snapshots__", "templates", "openapi", "swagger"]
    static let configFolders: Set<String> = ["config", "configs", "conf", "settings", "configuration"]

    static func isConfigFile(_ path: String, text: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let folders = lower.split(separator: "/").dropLast().map(String.init)
        if manifests.contains(name) || name.hasPrefix(".") || folders.contains(where: excludedFolders.contains) || SourceScan.isTest(path) { return false }
        if name.hasPrefix("tsconfig") || name.hasPrefix("jsconfig") || name.hasPrefix("values") || name.hasPrefix("docker-compose") || name.hasPrefix("compose.")
            || name.hasPrefix("openapi") || name.hasPrefix("swagger") || name.hasSuffix(".schema.json") || name.contains("translat")
            || name.range(of: #"^[a-z]{2}([-_][a-z]{2})?\.(json|ya?ml|toml)$"#, options: .regularExpression) != nil { return false }
        if name.hasSuffix(".toml") { return true }
        if text.contains("apiVersion:") && text.contains("kind:") { return false }
        if text.prefix(400).contains("\"openapi\"") || text.prefix(400).contains("\"swagger\"") || text.prefix(400).contains("\"$schema\"") { return false }
        return folders.contains(where: configFolders.contains)
            || name.range(of: #"^(config|settings|application|appsettings|default|production|development|staging|local)([._-][\w.-]*)?\.(ya?ml|json)$"#, options: .regularExpression) != nil
    }

    /// Leaf keys, dotted, in file order.
    static func keys(_ text: String, language: String) -> [String] {
        switch language {
        case "toml": return tomlKeys(text)
        case "yaml": return YAMLTree.parse(text).map { leaves($0) } ?? []
        default:
            guard text.utf8.count < 2_000_000, let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
            return jsonLeaves(object, prefix: "", depth: 0)
        }
    }

    static func isSegment(_ key: String) -> Bool { key.range(of: #"^[A-Za-z_][\w-]*$"#, options: .regularExpression) != nil }

    private static func leaves(_ node: YAMLNode, prefix: String = "", depth: Int = 0) -> [String] {
        node.entries.flatMap { key, value -> [String] in
            guard isSegment(key) else { return [] }
            let path = prefix.isEmpty ? key : prefix + "." + key
            return value.isMap && !value.entries.isEmpty && depth < 3 ? leaves(value, prefix: path, depth: depth + 1) : [path]
        }
    }

    private static func jsonLeaves(_ object: Any, prefix: String, depth: Int) -> [String] {
        guard let dictionary = object as? [String: Any] else { return prefix.isEmpty ? [] : [prefix] }
        if dictionary.isEmpty || depth > 3 { return prefix.isEmpty ? [] : [prefix] }
        return dictionary.keys.sorted().flatMap { key -> [String] in
            guard isSegment(key) else { return [] }
            return jsonLeaves(dictionary[key] as Any, prefix: prefix.isEmpty ? key : prefix + "." + key, depth: depth + 1)
        }
    }

    /// `[table]` / `[[table]]` headers and `key = value` lines, multi-line arrays and strings skipped.
    static func tomlKeys(_ text: String) -> [String] {
        var keys: [String] = []
        var table = ""
        var open: String?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let closing = open {
                if line.contains(closing) { open = nil }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let header = SourceScan.matches(#"^\[\[?\s*([^\]]+?)\s*\]\]?"#, in: line).first?[1] {
                table = header.split(separator: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }.joined(separator: ".")
                continue
            }
            guard let match = SourceScan.matches(#"^([A-Za-z0-9_\-."' ]+?)\s*=\s*(.*)$"#, in: line).first else { continue }
            let key = match[1].split(separator: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }.joined(separator: ".")
            let value = match[2]
            if value.hasPrefix("\"\"\"") && value.dropFirst(3).range(of: "\"\"\"") == nil { open = "\"\"\"" }
            else if value.hasPrefix("'''") && value.dropFirst(3).range(of: "'''") == nil { open = "'''" }
            else if value.hasPrefix("["), value.filter({ $0 == "[" }).count > value.filter({ $0 == "]" }).count { open = "]" }
            let full = table.isEmpty ? key : table + "." + key
            if full.split(separator: ".").allSatisfy({ isSegment(String($0)) }) { keys.append(full) }
        }
        return keys
    }

    // MARK: Readers

    static func reads(_ file: ExtractionInput) -> [(key: String, line: Int)] {
        var patterns: [(String, Int)] = []
        let text = file.text
        switch file.language {
        case "go":
            if text.contains("spf13/viper") { patterns.append((#"\.(?:Get\w*|IsSet|UnmarshalKey|Sub)\(\s*([^,()]+?)\s*[,)]"#, 1)) }
            if text.contains("knadh/koanf") { patterns.append((#"\.(?:String|Int|Int64|Bool|Float64|Duration|Strings|StringMap|Get|Exists|Unmarshal|MustString|MustInt|MustBool)\(\s*([^,()]+?)\s*[,)]"#, 1)) }
        case "typescript", "javascript":
            if text.range(of: #"(?:from\s+|require\()\s*["'](?:config|nconf)["']"#, options: .regularExpression) != nil {
                patterns.append((#"\b(?:config|nconf)\.(?:get|has)\(\s*([^,()]+?)\s*[,)]"#, 1))
            }
        case "python":
            if text.contains("configparser") || text.contains("ConfigParser") {
                patterns.append((#"\.get(?:int|float|boolean)?\(\s*(["'][\w.-]+["'])\s*,\s*(["'][\w.-]+["'])"#, 2))
            }
            if text.contains("dynaconf") || text.contains("from django.conf import settings") {
                patterns.append((#"\bsettings\.get\(\s*([^,()]+?)\s*[,)]"#, 1))
            }
        default:
            patterns.append((#"@Value\(\s*"\$\{([\w.-]+)(?::[^}"]*)?\}"\s*\)"#, 0))
        }
        var found: [(String, Int)] = []
        for (pattern, groups) in patterns {
            for match in SourceScan.regex(pattern).matches(in: text, range: NSRange(location: 0, length: file.string.length)) {
                let line = file.line(at: match.range.location)
                let parts: [String?] = switch groups {
                case 0: [file.text(match.range(at: 1))]
                case 2: [file.evaluate(file.text(match.range(at: 1))), file.evaluate(file.text(match.range(at: 2)))]
                default: [file.evaluate(file.text(match.range(at: 1)))]
                }
                guard parts.allSatisfy({ $0 != nil }) else { continue }
                let key = parts.compactMap { $0 }.joined(separator: ".").replacingOccurrences(of: ":", with: ".")
                if key.split(separator: ".").allSatisfy({ isSegment(String($0)) }) && !key.isEmpty { found.append((key, line)) }
            }
        }
        return found
    }

    /// Go struct tags naming config keys: `toml:"brokers"`, `mapstructure:"brokers"`, `koanf:"brokers"`
    /// (and `yaml:"…"` where the file decodes YAML).
    static func tags(_ file: ExtractionInput) -> [(tag: String, line: Int)] {
        guard file.language == "go", file.text.contains("`") else { return [] }
        let formats = file.text.contains("yaml.Unmarshal") || file.text.contains("yaml.NewDecoder") ? "toml|mapstructure|koanf|yaml" : "toml|mapstructure|koanf"
        return SourceScan.regex(#"\b(?:"# + formats + #"):"([A-Za-z_][\w-]*)[",]"#).matches(in: file.text, range: NSRange(location: 0, length: file.string.length)).map {
            (file.text($0.range(at: 1)), file.line(at: $0.range.location))
        }
    }
}

/// The link pass for struct tags: each to the repository's config keys ending in its name
/// (case aside): one at 0.8, two or three at 0.3 each.
enum ConfigLinks {
    static func link(repo: String, refs: [KnowledgeRef], store: KnowledgeStore) async throws -> [KnowledgeEdge] {
        guard !refs.isEmpty else { return [] }
        var byLast: [String: Set<String>] = [:]
        for id in try await store.configKeys(repo: repo) {
            let key = id.dropFirst("config:".count)
            byLast[String(key.split(separator: ".").last ?? key), default: []].insert(id)
        }
        var edges: [KnowledgeEdge] = []
        for ref in refs {
            guard let tag = ref.names.first?.lowercased(), let keys = byLast[tag], (1...3).contains(keys.count) else { continue }
            let weight = keys.count == 1 ? 0.8 : 0.3
            edges += keys.sorted().map { KnowledgeEdge(src: ref.src, dst: $0, kind: "reads_config", weight: weight, source: ExtractionLinks.source) }
        }
        return edges
    }
}

extension KnowledgeStore {
    /// Config keys the repository's files set.
    func configKeys(repo: String) throws -> [String] {
        try strings("SELECT DISTINCT e.dst FROM edges e JOIN nodes f ON f.id = e.src WHERE f.repo = ?1 AND f.kind = 'file' AND e.kind = 'sets_config'", [repo])
    }
}

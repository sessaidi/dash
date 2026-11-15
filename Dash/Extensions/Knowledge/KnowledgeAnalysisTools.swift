import DashKit
import Foundation

/// The knowledge graph's analysis tools: what a diff touches, everything needed to change a
/// symbol in one call, code health (hotspots, cycles, coverage), type hierarchies, modules,
/// flows, configuration, decisions, and read-only SQL over the graph.
extension KnowledgeExtension {
    private struct ChangesInput: Decodable { let repository: String; let base: String? }
    private struct EditInput: Decodable { let id: String; let intent: String?; let budget: Int? }
    private struct RepoInput: Decodable { let repository: String }
    private struct HierarchyInput: Decodable { let id: String; let direction: String? }
    private struct FlowsInput: Decodable { let repository: String?; let id: String? }
    private struct QueryInput: Decodable { let sql: String; let limit: Int? }
    private struct ConfigInput: Decodable { let name: String? }
    private struct DecisionsInput: Decodable { let id: String?; let query: String? }

    /// The indexed repository a name, path or owner/name stands for: its node id and folder.
    func repository(_ text: String) throws -> (id: String, path: String) {
        let wanted = (text as NSString).expandingTildeInPath
        guard let path = repositories.first(where: { $0 == wanted || ($0 as NSString).lastPathComponent == text
                || Self.remote(at: $0).map { text.hasSuffix($0.slug) } == true }) else {
            throw ToolError("Knowledge doesn't index “\(text)”. Indexed: \(repositories.map { Self.remote(at: $0)?.slug ?? ($0 as NSString).lastPathComponent }.joined(separator: ", ")).")
        }
        return ("repo:" + path, path)
    }

    var analysisTools: [DashiiTool] {
        [
            DashiiTool(
                name: "knowledge_changes",
                description: "What a change touches: the working tree's diff against a base (default HEAD, or a branch like main) mapped to the symbols it edits, whether each one's signature or only its body changed, their callers, the flows they're part of and the tests covering them. Use before reviewing or committing.",
                properties: ["repository": JSONSchema.string("A local checkout (name or path)."), "base": JSONSchema.string("Commit or branch to compare with (default HEAD).")],
                required: ["repository"]
            ) { [weak self] input in
                guard let self, let store else { return nil }
                let request = try input.toolInput(ChangesInput.self)
                let repo = try repository(request.repository)
                return try await changes(repo: repo, base: request.base ?? "HEAD", store: store)
            },
            DashiiTool(
                name: "knowledge_edit_context",
                description: "Everything needed to understand or change one symbol or file, in one call and within a token budget: its source, callers and callees (most certain first), tests, files that change with it, owners, linked tickets, decisions about it and the flows it's part of. intent orders what comes first: explain, modify, debug or review.",
                properties: ["id": JSONSchema.string("Symbol or file id from knowledge_search."),
                             "intent": JSONSchema.string("What you're about to do.", enum: ["explain", "modify", "debug", "review"]),
                             "budget": JSONSchema.integer("Rough token budget (default 4000).")],
                required: ["id"]
            ) { [weak self] input in
                guard let self, let store else { return nil }
                let request = try input.toolInput(EditInput.self)
                return try await editContext(request.id, intent: request.intent ?? "modify", budget: min(max(request.budget ?? 4000, 800), 20000), store: store)
            },
            DashiiTool(
                name: "knowledge_health",
                description: "A repository's health: hotspots (much called and often changed), import cycles, the largest modules, and index coverage (code files without symbols, files changed since the last index).",
                properties: ["repository": JSONSchema.string("Name, path or owner/name.")], required: ["repository"]
            ) { [weak self] input in
                guard let self, let store else { return nil }
                let repo = try repository(try input.toolInput(RepoInput.self).repository)
                return try await health(repo: repo, store: store)
            },
            DashiiTool(
                name: "knowledge_hierarchy",
                description: "A type's hierarchy: what it inherits from or conforms to (up), or what extends or implements it (down), several levels.",
                properties: ["id": JSONSchema.string("Type symbol id."), "direction": JSONSchema.string("up or down (default up).", enum: ["up", "down"])],
                required: ["id"]
            ) { [weak self] input in
                guard let store = self?.store else { return nil }
                let request = try input.toolInput(HierarchyInput.self)
                let steps = try await store.trace(request.id, kinds: ["inherits"], reverse: request.direction == "down", depth: 4)
                return .array(steps.map { var object = Self.json($0.node).object ?? [:]; object["depth"] = .number(Double($0.depth)); return .object(object) })
            },
            DashiiTool(
                name: "knowledge_clusters",
                description: "A repository's modules as the code shows them (files grouped by how they import, call and change together, not by folder): each with its size and main files.",
                properties: ["repository": JSONSchema.string("Name, path or owner/name.")], required: ["repository"]
            ) { [weak self] input in
                guard let self, let store else { return nil }
                let repo = try repository(try input.toolInput(RepoInput.self).repository)
                var result: [JSONValue] = []
                for cluster in try await store.nodes(kind: "cluster", repo: repo.id, limit: 200) {
                    let members = try await store.neighbors(cluster.id, kinds: ["member_of"], limit: 400).filter(\.incoming)
                    result.append(["id": .string(cluster.id), "name": .string(cluster.name), "files": .number(Double(members.count)),
                                   "main_files": .array(members.prefix(8).map { .string($0.node.path) }),
                                   "summary": cluster.summary.isEmpty ? .null : .string(cluster.summary)])
                }
                return .array(result.sorted { ($0["files"]?.double ?? 0) > ($1["files"]?.double ?? 0) })
            },
            DashiiTool(
                name: "knowledge_flows",
                description: "Execution flows: what each entry point (main, HTTP or CLI handler) sets in motion, as a chain of calls. Give a repository to list them, or a symbol id to see the flows it's part of.",
                properties: ["repository": JSONSchema.string("Name, path or owner/name."), "id": JSONSchema.string("A symbol id.")]
            ) { [weak self] input in
                guard let self, let store else { return nil }
                let request = try input.toolInput(FlowsInput.self)
                if let id = request.id {
                    let flows = try await store.neighbors(id, kinds: ["step"], limit: 50).filter(\.incoming)
                    return .array(flows.map { ["flow": .string($0.node.id), "entry": .string($0.node.name), "steps": .string($0.node.signature), "position": .number($0.edge.weight)] })
                }
                guard let name = request.repository else { throw ToolError("Give a repository or a symbol id.") }
                let repo = try repository(name)
                return .array(try await store.nodes(kind: "flow", repo: repo.id, limit: 200).map {
                    ["flow": .string($0.id), "entry": .string($0.qualified), "file": .string($0.path), "steps": .string($0.signature)]
                })
            },
            DashiiTool(
                name: "knowledge_query",
                description: """
                    Read-only SQL over the graph, for questions the other tools don't answer (at most 200 rows). Tables: \
                    nodes(id, kind, name, qualified, repo, path, line, end_line, language, signature, summary, url, source), \
                    edges(src, dst, kind, weight, source) with kinds contains, defines, imports, calls (weight = confidence 0.3–0.95), \
                    inherits, tests, authored, changes_with, touches, mentions, reads_env, sets_env, about, member_of, step; \
                    symbol_calls(src, name, repo). Node kinds: repo, directory, file, symbol, package, cluster, flow, env, decision, ticket, pr, person…
                    Recursive CTEs work (WITH RECURSIVE).
                    """,
                properties: ["sql": JSONSchema.string("A SELECT or WITH query."), "limit": JSONSchema.integer("Rows (default 100, max 200).")],
                required: ["sql"]
            ) { [weak self] input in
                guard let store = self?.store else { return nil }
                let request = try input.toolInput(QueryInput.self)
                let rows = try await store.query(request.sql, limit: min(max(request.limit ?? 100, 1), 200))
                return .array(rows.map { .object($0) })
            },
            DashiiTool(
                name: "knowledge_config",
                description: "Configuration across the code: environment variables, which files read each one (code) and which set it (Kubernetes/compose YAML, .env, Terraform). Give a name for one variable, or nothing for the most used.",
                properties: ["name": JSONSchema.string("A variable, e.g. DATABASE_URL.")]
            ) { [weak self] input in
                guard let store = self?.store else { return nil }
                let name = try input.toolInput(ConfigInput.self).name
                let variables = if let name { try await store.nodes(ids: ["env:" + name]) } else { try await store.nodes(kind: "env", limit: 2000) }
                var result: [JSONValue] = []
                for variable in variables {
                    let links = try await store.neighbors(variable.id, kinds: ["reads_env", "sets_env"], limit: 200).filter(\.incoming)
                    let files = { (kind: String) -> JSONValue in .array(links.filter { $0.edge.kind == kind }.map { .string((($0.node.repo as NSString).lastPathComponent) + "/" + $0.node.path) }) }
                    result.append(["name": .string(variable.name), "read_by": files("reads_env"), "set_in": files("sets_env"),
                                   "references": .number(Double(links.count))])
                }
                return .array(Array(result.sorted { ($0["references"]?.double ?? 0) > ($1["references"]?.double ?? 0) }.prefix(name == nil ? 40 : 1)))
            },
            DashiiTool(
                name: "knowledge_decisions",
                description: "Architecture decisions (ADRs and decision records in the repositories): about a file or directory id, matching some words, or all, with their status, date and what they're about.",
                properties: ["id": JSONSchema.string("A file or directory id."), "query": JSONSchema.string("Words to match.")]
            ) { [weak self] input in
                guard let store = self?.store else { return nil }
                let request = try input.toolInput(DecisionsInput.self)
                var decisions: [KnowledgeNode]
                if let id = request.id {
                    var ids = [id]
                    // A file's decisions include its directories'.
                    if let node = try await store.node(id), !node.path.isEmpty {
                        var directory = (node.path as NSString).deletingLastPathComponent
                        while !directory.isEmpty { ids.append("dir:" + String(node.repo.dropFirst(5)) + "/" + directory); directory = (directory as NSString).deletingLastPathComponent }
                    }
                    decisions = []
                    for target in ids { decisions += try await store.neighbors(target, kinds: ["about"], limit: 50).filter { $0.incoming && $0.node.kind == "decision" }.map(\.node) }
                } else if let query = request.query {
                    decisions = try await store.search(query, kinds: ["decision"], limit: 30)
                } else {
                    decisions = try await store.nodes(kind: "decision", limit: 200)
                }
                var result: [JSONValue] = []
                for decision in Dictionary(grouping: decisions, by: \.id).compactMap(\.value.first) {
                    let about = try await store.neighbors(decision.id, kinds: ["about"], limit: 30).filter { !$0.incoming }.map { JSONValue.string($0.node.path) }
                    result.append(["id": .string(decision.id), "title": .string(decision.name), "status": .string(decision.signature),
                                   "file": .string(decision.path), "about": .array(about), "excerpt": .string(String(decision.summary.prefix(300)))])
                }
                return .array(result)
            },
        ]
    }

    // MARK: Changes

    func changes(repo: (id: String, path: String), base: String, store: KnowledgeStore) async throws -> JSONValue {
        let root = URL(fileURLWithPath: repo.path)
        guard Self.remote(at: repo.path) == nil else { throw ToolError("\(repo.path) is read through an integration, without a checkout: there's no local diff.") }
        let safeBase = base.filter { $0.isLetter || $0.isNumber || "-_./~^".contains($0) }
        guard let diff = CodeIndexer.git(root, ["diff", "-U0", "--no-color", safeBase]) else { throw ToolError("git diff \(safeBase) failed in \(repo.path).") }
        var ranges: [String: [ClosedRange<Int>]] = [:]
        var current: String?
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("+++ ") { current = line.hasPrefix("+++ b/") ? String(line.dropFirst(6)) : nil; continue }
            guard line.hasPrefix("@@"), let current, let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) else { continue }
            let parts = plus.dropFirst().split(separator: ",")
            let start = Int(parts[0]) ?? 0, count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            ranges[current, default: []].append(start...max(start, start + max(count, 1) - 1))
        }
        var files: [JSONValue] = []
        var totalSymbols = 0
        for (path, edits) in ranges.sorted(by: { $0.key < $1.key }) {
            let symbols = try await store.symbols(repo: repo.id, path: path)
            let touched = symbols.filter { symbol in edits.contains { $0.overlaps(symbol.line...max(symbol.line, symbol.endLine)) } }
            // Signatures before the change, to tell an API change from a body change.
            var before: [String: String] = [:]
            if let language = CodeParser.language(of: path), let old = CodeIndexer.git(root, ["show", "\(safeBase):\(path)"]) {
                for symbol in CodeParser.parse(old, language: language).symbols {
                    before[symbol.container.isEmpty ? symbol.name : "\(symbol.container).\(symbol.name)"] = symbol.signature
                }
            }
            var entries: [JSONValue] = []
            for symbol in touched.prefix(40) {
                let callers = try await store.trace(symbol.id, kinds: ["calls"], reverse: true, depth: 2, minWeight: 0.5)
                let flows = try await store.neighbors(symbol.id, kinds: ["step"], limit: 20).filter(\.incoming).map { JSONValue.string($0.node.name) }
                let change = before[symbol.qualified] == nil ? "added" : before[symbol.qualified] == symbol.signature ? "body" : "signature"
                entries.append(["id": .string(symbol.id), "symbol": .string(symbol.qualified), "lines": .string("\(symbol.line)-\(symbol.endLine)"),
                                "change": .string(change), "callers": .number(Double(callers.count)),
                                "caller_files": .array(Array(Set(callers.map(\.node.path))).sorted().prefix(10).map { .string($0) }),
                                "flows": .array(flows)])
            }
            totalSymbols += touched.count
            let tests = try await store.neighbors("file:\(repo.path)/\(path)", kinds: ["tests"], limit: 20).filter(\.incoming).map { JSONValue.string($0.node.path) }
            files.append(["file": .string(path), "symbols": .array(entries), "tests": .array(tests)])
        }
        let symbols: [JSONValue] = files.flatMap { $0["symbols"]?.array ?? [] }
        let risky: [JSONValue] = symbols.filter { $0["change"] == "signature" && ($0["callers"]?.double ?? 0) > 0 }.map { $0["symbol"] ?? JSONValue.null }
        var result: [String: JSONValue] = [:]
        result["base"] = .string(safeBase)
        result["files_changed"] = .number(Double(ranges.count))
        result["symbols_touched"] = .number(Double(totalSymbols))
        result["signature_changes_with_callers"] = .array(risky)
        result["files"] = .array(files)
        result["note"] = "Edits outside any symbol (imports, config) are listed per file without symbols. Re-index after big changes for exact lines."
        return .object(result)
    }

    // MARK: Edit context

    func editContext(_ id: String, intent: String, budget: Int, store: KnowledgeStore) async throws -> JSONValue {
        guard let node = try await store.node(id) else { throw ToolError("No node \(id). Use knowledge_search.") }
        let fileID = node.kind == "file" ? node.id : "file:" + String(node.repo.dropFirst(5)) + "/" + node.path
        var sections: [(String, JSONValue)] = []
        // The source, from the checkout or mirror.
        let url = URL(fileURLWithPath: String(node.repo.dropFirst(5))).appending(path: node.path)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let range = node.kind == "symbol" ? max(node.line - 1, 0)..<min(max(node.endLine, node.line), lines.count) : 0..<min(lines.count, 200)
            sections.append(("source", .string(lines[range].joined(separator: "\n"))))
        }
        if node.kind == "symbol" {
            let callers = try await store.trace(node.id, kinds: ["calls"], reverse: true, depth: 1)
            let callees = try await store.trace(node.id, kinds: ["calls"], reverse: false, depth: 1)
            sections.append(("callers", .array(callers.prefix(15).map { .string("\($0.node.qualified) — \($0.node.path):\($0.node.line)") })))
            sections.append(("callees", .array(callees.prefix(15).map { .string("\($0.node.qualified) — \($0.node.path):\($0.node.line)") })))
            sections.append(("flows", .array(try await store.neighbors(node.id, kinds: ["step"], limit: 10).filter(\.incoming).map { .string($0.node.signature) })))
            sections.append(("hierarchy", .array(try await store.neighbors(node.id, kinds: ["inherits"], limit: 20).map { .string(($0.incoming ? "subtype " : "inherits ") + $0.node.qualified) })))
        }
        var tests: [JSONValue] = [], coChange: [JSONValue] = [], tickets: [JSONValue] = []
        for neighbor in try await store.neighbors(fileID, kinds: ["tests", "changes_with", "touches"], limit: 80) {
            switch neighbor.edge.kind {
            case "tests" where neighbor.incoming: tests.append(.string(neighbor.node.path))
            case "changes_with": coChange.append(.string(neighbor.node.path))
            case "touches" where neighbor.incoming: tickets.append(.string(neighbor.node.name))
            default: break
            }
        }
        sections.append(("tests", .array(tests)))
        sections.append(("changes_with", .array(Array(coChange.prefix(10)))))
        sections.append(("tickets", .array(Array(tickets.prefix(10)))))
        let experts = node.repo.isEmpty ? [] : try await store.experts(repo: node.repo, path: node.path, limit: 4)
        sections.append(("owners", .array(experts.map { .string("\($0.person.name) (\($0.commits) commits)") })))
        var decisions: [JSONValue] = []
        var directory = (node.path as NSString).deletingLastPathComponent
        var targets = [fileID]
        while !directory.isEmpty { targets.append("dir:" + String(node.repo.dropFirst(5)) + "/" + directory); directory = (directory as NSString).deletingLastPathComponent }
        for target in targets {
            decisions += try await store.neighbors(target, kinds: ["about"], limit: 10).filter { $0.incoming }.map { .string("\($0.node.name) [\($0.node.signature)] — \($0.node.path)") }
        }
        sections.append(("decisions", .array(decisions)))

        let order: [String] = switch intent {
        case "explain": ["source", "flows", "callees", "callers", "decisions", "hierarchy", "owners", "tests", "changes_with", "tickets"]
        case "debug": ["source", "callers", "callees", "flows", "tests", "tickets", "changes_with", "owners", "decisions", "hierarchy"]
        case "review": ["source", "callers", "tests", "decisions", "changes_with", "owners", "flows", "tickets", "callees", "hierarchy"]
        default: ["source", "callers", "tests", "callees", "changes_with", "decisions", "hierarchy", "flows", "owners", "tickets"]
        }
        var result: [String: JSONValue] = ["target": Self.json(node)]
        var used = result["target"]!.jsonString().count
        let limit = budget * 4
        var dropped: [String] = []
        for key in order {
            guard let value = sections.first(where: { $0.0 == key })?.1 else { continue }
            if case .array(let items) = value, items.isEmpty { continue }
            var size = value.jsonString().count
            var item = value
            if used + size > limit, case .string(let text) = value, key == "source", limit - used > 400 {
                item = .string(String(text.prefix(limit - used - 100)) + "\n… (cut to the budget)")
                size = item.jsonString().count
            }
            if used + size > limit { dropped.append(key); continue }
            result[key] = item
            used += size
        }
        if !dropped.isEmpty { result["left_out"] = .array(dropped.map { .string($0) }) }
        return .object(result)
    }

    // MARK: Health

    func health(repo: (id: String, path: String), store: KnowledgeStore) async throws -> JSONValue {
        let fanIn = try await store.perFile(repo: repo.id, edgeKind: "calls")
        let churn = try await store.perFile(repo: repo.id, edgeKind: "authored")
        let hotspots = fanIn.map { (path: $0.key, score: $0.value * (1 + (churn[$0.key] ?? 0)), calls: $0.value, commits: churn[$0.key] ?? 0) }
            .sorted { $0.score > $1.score }.prefix(15)
        let imports = try await store.query("""
            SELECT a.path AS a, b.path AS b FROM edges e JOIN nodes a ON a.id = e.src JOIN nodes b ON b.id = e.dst
            WHERE e.kind = 'imports' AND a.repo = '\(repo.id.replacingOccurrences(of: "'", with: "''"))' AND a.kind = 'file' AND b.kind = 'file'
            """, limit: 100_000)
        let cycles = KnowledgeAnalysis.cycles(imports.compactMap { row in row["a"]?.string.flatMap { a in row["b"]?.string.map { (a, $0) } } })
        // Coverage: code files without any symbol, and files edited since the last index.
        let files = try await store.nodes(kind: "file", repo: repo.id, limit: 100_000)
        let withSymbols = Set(try await store.query("SELECT DISTINCT path FROM nodes WHERE repo = '\(repo.id.replacingOccurrences(of: "'", with: "''"))' AND kind = 'symbol'", limit: 100_000)
            .compactMap { $0["path"]?.string })
        let code = files.filter { !CodeParser.structured.contains($0.language) && !$0.language.isEmpty }
        let empty = code.filter { !withSymbols.contains($0.path) }
        let indexed = try await store.meta("indexed:" + repo.id).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        let stale = files.filter { file in
            let modified = (try? URL(fileURLWithPath: repo.path).appending(path: file.path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (modified ?? .distantPast) > indexed
        }
        let clusters = try await store.nodes(kind: "cluster", repo: repo.id, limit: 20)
        return [
            "hotspots": .array(hotspots.map { ["file": .string($0.path), "incoming_calls": .number($0.calls), "commits": .number($0.commits)] }),
            "import_cycles": .array(cycles.prefix(10).map { .array($0.prefix(12).map { .string($0) }) }),
            "modules": .array(clusters.map { .string("\($0.name) (\($0.signature))") }),
            "coverage": ["files": .number(Double(files.count)), "code_files": .number(Double(code.count)),
                         "code_files_without_symbols": .array(empty.prefix(20).map { .string($0.path) }),
                         "changed_since_index": .number(Double(stale.count)), "indexed_at": .string(indexed.formatted(.iso8601))],
        ]
    }
}

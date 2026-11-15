import CryptoKit
import Foundation

/// Indexes one local repository into the knowledge graph, incrementally: only files whose
/// content changed are parsed again. Builds repository → directory → file → symbol nodes,
/// import edges, call edges (resolved by name), and, from git history, who changes which
/// files, which files change together, and which tickets touched them.
struct CodeIndexer: Sendable {
    let root: URL
    let store: KnowledgeStore
    var readHistory = true
    var historyDays = 180

    struct Report: Sendable, Equatable {
        var files = 0
        var parsed = 0
        var removed = 0
        var symbols = 0
    }

    var repoID: String { "repo:" + root.path }

    static let skippedDirectories: Set<String> = ["node_modules", "vendor", "Pods", ".build", "build", "dist", "DerivedData",
                                                  "target", ".git", ".worktrees", ".terraform", "__pycache__", ".venv", "venv", "third_party", "Carthage"]
    static let maxFileBytes = 1_000_000

    func index() async throws -> Report {
        var report = Report()
        // A mirror of a remote repository says where it comes from; a checkout has its origin.
        let mirror = RemoteRepository.marker(in: root)
        let remote = mirror?.slug ?? Self.remoteSlug(root)
        let repoNode = KnowledgeNode(id: repoID, kind: "repo", name: mirror.map { String($0.slug.split(separator: "/").last ?? "") } ?? root.lastPathComponent,
                                     qualified: remote ?? "", repo: repoID, path: "",
                                     url: mirror?.webURL ?? remote.map { "https://github.com/\($0)" } ?? "", source: "code")
        let files = listFiles()
        report.files = files.count
        // Call names are kept per symbol since v2 of the index: parse everything once to fill them.
        let callsStored = try await store.meta("calls-v2:" + repoID) != nil
        let known = callsStored ? try await store.fileHashes(repo: repoID) : [:]
        // Names defined in files that change or go: their callers elsewhere are resolved again.
        var touchedNames = Set<String>()
        let goModule = Self.goModule(root)

        // Phase 1: nodes, containment, definitions and imports of changed files.
        var changed: [(path: String, parsed: ParsedFile, symbolIDs: [String])] = []
        var touchedDirectories = Set<String>()
        // Written in batches, one transaction each.
        var batch: [KnowledgeStore.FileGraph] = []
        for path in files {
            let url = root.appending(path: path)
            guard let language = CodeParser.language(of: path),
                  let data = try? Data(contentsOf: url), data.count <= Self.maxFileBytes,
                  let text = String(data: data, encoding: .utf8) else { continue }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if known[path] == hash { continue }
            if known[path] != nil { touchedNames.formUnion(try await store.symbolNames(repo: repoID, path: path)) }
            let parsed = CodeParser.parse(text, language: language)
            var (nodes, edges, symbolIDs) = graph(for: path, parsed: parsed, hash: hash, goModule: goModule, files: files)
            let extra = configAndDecisions(text, path: path, language: language, files: files)
            nodes += extra.nodes
            edges += extra.edges
            batch.append(KnowledgeStore.FileGraph(path: path, nodes: nodes, edges: edges))
            if batch.count >= 200 {
                try await store.replaceFiles(repo: repoID, batch)
                batch.removeAll()
            }
            changed.append((path, parsed, symbolIDs))
            report.parsed += 1
            report.symbols += parsed.symbols.count
            touchedDirectories.formUnion(Self.ancestors(of: path))
        }
        let current = Set(files)
        for path in known.keys where !current.contains(path) {
            touchedNames.formUnion(try await store.symbolNames(repo: repoID, path: path))
            try await store.removeSymbolCalls(repo: repoID, path: root.path + "/" + path)
            batch.append(KnowledgeStore.FileGraph(path: path, nodes: [], edges: []))
            report.removed += 1
            touchedDirectories.formUnion(Self.ancestors(of: path))
        }
        try await store.replaceFiles(repo: repoID, batch)

        // Directories: new or changed ones get a fresh `updated` (so Claude looks again);
        // directories without files any more go.
        let liveDirectories = Set(files.filter { CodeParser.language(of: $0) != nil }.flatMap(Self.ancestors))
        let existingDirectories = try await store.nodes(kind: "directory", repo: repoID, limit: 100_000)
        for directory in existingDirectories where !liveDirectories.contains(directory.path) {
            try await store.removeNode(directory.id)
        }
        let existingPaths = Set(existingDirectories.map(\.path))
        var directoryNodes: [KnowledgeNode] = []
        var directoryEdges: [KnowledgeEdge] = []
        for path in liveDirectories where touchedDirectories.contains(path) || !existingPaths.contains(path) {
            directoryNodes.append(KnowledgeNode(id: directoryID(path), kind: "directory", name: (path as NSString).lastPathComponent,
                                                qualified: path, repo: repoID, path: path, source: "code"))
            let parent = (path as NSString).deletingLastPathComponent
            directoryEdges.append(KnowledgeEdge(src: parent.isEmpty ? repoID : directoryID(parent), dst: directoryID(path), kind: "contains", source: "code"))
        }
        try await store.upsert([repoNode] + directoryNodes)
        try await store.upsert(directoryEdges)

        // Phase 2: calls, resolved by name with a confidence (same file, imported file, same
        // directory, unique in the repository, ambiguous). The changed files' symbols are resolved,
        // and so is every symbol elsewhere that calls a name a changed file defines or dropped, so
        // edges never point at what was renamed or moved.
        for file in changed {
            try await store.replaceSymbolCalls(repo: repoID, path: root.path + "/" + file.path,
                                               zip(file.symbolIDs, file.parsed.symbols).map { ($0, Array($1.calls)) })
            touchedNames.formUnion(file.parsed.symbols.map(\.name))
        }
        var callers: [String: [String]] = [:]
        for file in changed { for (id, symbol) in zip(file.symbolIDs, file.parsed.symbols) { callers[id] = Array(symbol.calls) } }
        if !touchedNames.isEmpty {
            for (id, names) in try await store.symbolCalls(repo: repoID, calling: touchedNames) where callers[id] == nil { callers[id] = names }
        }
        let index = try await store.symbolIndex(repo: repoID)
        let imports = try await store.importTargets(repo: repoID)
        var callEdges: [KnowledgeEdge] = []
        for (id, names) in callers {
            callEdges += Self.resolveCalls(from: id, names: names, index: index, imports: imports, root: root.path)
        }
        try await store.replaceCallEdges(from: Set(callers.keys), callEdges)
        try await store.setMeta("calls-v2:" + repoID, "1")


        try await indexTests(files)
        if readHistory { try await indexHistory() }
        try await store.setMeta("indexed:" + repoID, ISO8601DateFormatter().string(from: .now))
        return report
    }

    /// The path of a symbol id "sym:<root>/<path>#<qualified>".
    static func path(ofSymbol id: String, root: String) -> String {
        let body = id.dropFirst(("sym:" + root + "/").count)
        return String(body.prefix { $0 != "#" })
    }

    /// Call edges from one symbol, weighted by how sure the match is: 0.95 same file, 0.85 a file or
    /// package the caller imports, 0.7 same directory (≤3 candidates), 0.6 the only one in the
    /// repository, 0.3 split between up to three; more candidates make no edge.
    static func resolveCalls(from id: String, names: [String], index: [String: [String]], imports: [String: Set<String>], root: String) -> [KnowledgeEdge] {
        let path = Self.path(ofSymbol: id, root: root)
        let directory = (path as NSString).deletingLastPathComponent
        let imported = imports["file:" + root + "/" + path] ?? []
        var edges: [KnowledgeEdge] = []
        for name in Set(names) {
            let candidates = (index[name] ?? []).filter { $0 != id }
            guard !candidates.isEmpty else { continue }
            func inFile(_ candidate: String) -> String { Self.path(ofSymbol: candidate, root: root) }
            let sameFile = candidates.filter { inFile($0) == path }
            let viaImport = candidates.filter { candidate in
                let file = inFile(candidate)
                return imported.contains("file:" + root + "/" + file) || imported.contains("dir:" + root + "/" + (file as NSString).deletingLastPathComponent)
            }
            let sameDirectory = candidates.filter { (inFile($0) as NSString).deletingLastPathComponent == directory }
            let (targets, confidence): ([String], Double) =
                !sameFile.isEmpty ? (sameFile, 0.95)
                : !viaImport.isEmpty && viaImport.count <= 3 ? (viaImport, 0.85)
                : !sameDirectory.isEmpty && sameDirectory.count <= 3 ? (sameDirectory, 0.7)
                : candidates.count == 1 ? (candidates, 0.6)
                : candidates.count <= 3 ? (candidates, 0.3)
                : ([], 0)
            for target in targets {
                edges.append(KnowledgeEdge(src: id, dst: target, kind: "calls", weight: targets.count == 1 ? confidence : confidence / Double(targets.count), source: "code"))
            }
        }
        return edges
    }

    /// Environment variables the file reads or sets, and, for a decision record, a `decision`
    /// node `about` the files it names. Replaced with the file, like its symbols.
    func configAndDecisions(_ text: String, path: String, language: String, files: [String]) -> (nodes: [KnowledgeNode], edges: [KnowledgeEdge]) {
        var nodes: [KnowledgeNode] = [], edges: [KnowledgeEdge] = []
        let file = fileID(path)
        let reads = CodeParser.structured.contains(language) ? [] : KnowledgeAnalysis.environmentReads(text)
        let sets = ["yaml", "toml", "terraform", "makefile"].contains(language) || (path as NSString).lastPathComponent.hasPrefix(".env")
            ? KnowledgeAnalysis.environmentSets(text, path: path) : []
        for name in reads.union(sets) { nodes.append(KnowledgeNode(id: "env:" + name, kind: "env", name: name, qualified: name, source: "code")) }
        for name in reads { edges.append(KnowledgeEdge(src: file, dst: "env:" + name, kind: "reads_env", source: "code")) }
        for name in sets { edges.append(KnowledgeEdge(src: file, dst: "env:" + name, kind: "sets_env", source: "code")) }
        if language == "markdown", KnowledgeAnalysis.isDecision(path: path, text: text) {
            let record = KnowledgeAnalysis.decision(text)
            let id = "decision:" + root.path + "/" + path
            nodes.append(KnowledgeNode(id: id, kind: "decision", name: record.title, qualified: record.title, repo: repoID, path: path,
                                       signature: [record.status, record.date].filter { !$0.isEmpty }.joined(separator: " · "),
                                       summary: String(text.prefix(600)), source: "code"))
            edges.append(KnowledgeEdge(src: id, dst: file, kind: "documented_in", source: "code"))
            for mention in record.mentions {
                if let match = files.first(where: { $0 == mention || $0.hasSuffix("/" + mention) }) {
                    edges.append(KnowledgeEdge(src: id, dst: fileID(match), kind: "about", source: "code"))
                } else if files.contains(where: { $0.hasPrefix(mention.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") }) {
                    edges.append(KnowledgeEdge(src: id, dst: directoryID(mention.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), kind: "about", source: "code"))
                }
            }
        }
        return (nodes, edges)
    }

    // MARK: Nodes for one file

    func fileID(_ path: String) -> String { "file:" + root.path + "/" + path }
    func directoryID(_ path: String) -> String { "dir:" + root.path + "/" + path }

    private func graph(for path: String, parsed: ParsedFile, hash: String, goModule: String?, files: [String])
        -> (nodes: [KnowledgeNode], edges: [KnowledgeEdge], symbolIDs: [String]) {
        let file = fileID(path)
        let directory = (path as NSString).deletingLastPathComponent
        var nodes = [KnowledgeNode(id: file, kind: "file", name: (path as NSString).lastPathComponent, qualified: path, repo: repoID,
                                   path: path, language: parsed.language, hash: hash, source: "code")]
        var edges = [KnowledgeEdge(src: directory.isEmpty ? repoID : directoryID(directory), dst: file, kind: "contains", source: "code")]
        var used = Set<String>()
        var symbolIDs: [String] = []
        let base = "sym:" + root.path + "/" + path + "#"
        for symbol in parsed.symbols {
            let qualified = symbol.container.isEmpty ? symbol.name : "\(symbol.container).\(symbol.name)"
            var id = base + qualified
            if !used.insert(id).inserted { id += "@\(symbol.line)" }
            symbolIDs.append(id)
            nodes.append(KnowledgeNode(id: id, kind: "symbol", name: symbol.name, qualified: qualified, repo: repoID, path: path,
                                       line: symbol.line, endLine: symbol.endLine, language: symbol.kind, signature: symbol.signature, source: "code"))
            // Members hang off their type when it's declared in the same file.
            let owner = symbol.container.isEmpty ? nil : nodes.first { $0.kind == "symbol" && $0.qualified == symbol.container }
            edges.append(KnowledgeEdge(src: owner?.id ?? file, dst: id, kind: "defines", source: "code"))
        }
        for name in parsed.imports {
            if let target = resolveImport(name, from: directory, language: parsed.language, goModule: goModule, files: files) {
                edges.append(KnowledgeEdge(src: file, dst: target, kind: "imports", source: "code"))
            } else {
                let package = "pkg:\(parsed.language):\(name)"
                nodes.append(KnowledgeNode(id: package, kind: "package", name: name, qualified: name, language: parsed.language, source: "code"))
                edges.append(KnowledgeEdge(src: file, dst: package, kind: "imports", source: "code"))
            }
        }
        return (nodes, edges, symbolIDs)
    }

    /// Imports that point inside the repository: relative JS/TS paths, and Go packages under
    /// the module in go.mod.
    private func resolveImport(_ name: String, from directory: String, language: String, goModule: String?, files: [String]) -> String? {
        if language == "go", let goModule, name == goModule || name.hasPrefix(goModule + "/") {
            let path = String(name.dropFirst(goModule.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.isEmpty ? repoID : directoryID(path)
        }
        // Relative paths: Markdown links, Terraform module sources, Makefile includes.
        if ["markdown", "terraform", "makefile"].contains(language), !name.hasPrefix("/"), !name.contains("://") {
            let joined = ((directory as NSString).appendingPathComponent(name.removingPercentEncoding ?? name) as NSString).standardizingPath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if files.contains(joined) { return fileID(joined) }
            if files.contains(where: { $0.hasPrefix(joined + "/") }) { return directoryID(joined) }
            return nil
        }
        if ["typescript", "javascript", "vue"].contains(language), name.hasPrefix(".") {
            let joined = ((directory as NSString).appendingPathComponent(name) as NSString).standardizingPath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let candidates = [joined] + ["ts", "tsx", "js", "jsx", "mjs", "vue"].flatMap { [joined + "." + $0, joined + "/index." + $0] }
            let known = Set(files)
            if let match = candidates.first(where: known.contains) { return fileID(match) }
        }
        return nil
    }

    // MARK: Tests

    /// Links each test file to the file it tests, by naming convention: Go `x_test.go`, Swift and
    /// Kotlin/Java `FooTests`/`FooTest`, TypeScript/JavaScript `x.test.ts`/`x.spec.ts` (also under
    /// `__tests__`), Python `test_x.py`/`x_test.py`.
    func indexTests(_ files: [String]) async throws {
        let edges = Self.testLinks(files).map { KnowledgeEdge(src: fileID($0.test), dst: fileID($0.subject), kind: "tests", source: "code-tests") }
        try await store.removeEdges(source: "code-tests", repo: repoID)
        try await store.upsert(edges)
    }

    nonisolated static func testLinks(_ files: [String]) -> [(test: String, subject: String)] {
        let present = Set(files)
        // Basename (without extension) → paths, for languages that name tests after a type.
        var byBase: [String: [String]] = [:]
        for path in files { byBase[((path as NSString).lastPathComponent as NSString).deletingPathExtension, default: []].append(path) }
        func sameFolder(_ path: String, _ name: String) -> String {
            let folder = (path as NSString).deletingLastPathComponent
            return folder.isEmpty ? name : folder + "/" + name
        }
        var links: [(String, String)] = []
        for path in files {
            let file = (path as NSString).lastPathComponent
            let ext = (file as NSString).pathExtension
            let base = (file as NSString).deletingPathExtension
            var candidates: [String] = []
            switch ext {
            case "go" where base.hasSuffix("_test"):
                candidates = [sameFolder(path, String(base.dropLast(5)) + ".go")]
            case "py" where base.hasPrefix("test_") || base.hasSuffix("_test"):
                let subject = base.hasPrefix("test_") ? String(base.dropFirst(5)) : String(base.dropLast(5))
                candidates = [sameFolder(path, subject + ".py")] + (byBase[subject] ?? []).filter { $0.hasSuffix(".py") }
            case "ts", "tsx", "js", "jsx", "mts", "mjs":
                for marker in [".test", ".spec"] where base.hasSuffix(marker) {
                    let subject = String(base.dropLast(marker.count))
                    let folder = (path as NSString).deletingLastPathComponent
                    let parent = (folder as NSString).lastPathComponent == "__tests__" ? (folder as NSString).deletingLastPathComponent : folder
                    for subjectExt in [ext, "ts", "tsx", "js", "jsx"] {
                        candidates.append(sameFolder(path, subject + "." + subjectExt))
                        candidates.append(parent.isEmpty ? subject + "." + subjectExt : parent + "/" + subject + "." + subjectExt)
                    }
                }
            case "swift", "kt", "java":
                for suffix in ["Tests", "Test", "Spec"] where base.hasSuffix(suffix) && base.count > suffix.count {
                    let subject = String(base.dropLast(suffix.count))
                    let matches = (byBase[subject] ?? []).filter { ($0 as NSString).pathExtension == ext }
                    // Only an unambiguous match: one file of that name.
                    if matches.count == 1 { candidates.append(matches[0]) }
                }
            default:
                break
            }
            if let subject = candidates.first(where: { present.contains($0) && $0 != path }) { links.append((path, subject)) }
        }
        return links
    }

    // MARK: Git history

    /// Who changes which files, which files change together, and which tickets (keys in commit
    /// subjects) touched them, over the last `historyDays`.
    func indexHistory() async throws {
        guard let log = Self.git(root, ["log", "--since=\(historyDays).days", "--no-merges", "-n", "3000",
                                        "--format=%x1e%an%x1f%ae%x1f%s", "--name-only"]) else { return }
        let indexed = try await store.fileHashes(repo: repoID)
        var authored: [String: [String: Int]] = [:]
        var names: [String: String] = [:]
        var together: [String: Int] = [:]
        var touched: [String: [String: Int]] = [:]
        for commit in log.split(separator: "\u{1e}") {
            let lines = commit.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { continue }
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            let person = "person:" + fields[1].lowercased()
            names[person] = fields[0]
            let paths = lines.dropFirst().map(String.init).filter { indexed[$0] != nil }
            for path in paths { authored[person, default: [:]][path, default: 0] += 1 }
            for key in KnowledgeLinker.ticketKeys(in: fields[2]) {
                for path in paths { touched["ticket:" + key, default: [:]][path, default: 0] += 1 }
            }
            if paths.count >= 2 && paths.count <= 20 {
                let sorted = paths.sorted()
                for i in sorted.indices { for j in sorted.indices where j > i { together[sorted[i] + "\n" + sorted[j], default: 0] += 1 } }
            }
        }
        try await store.removeEdges(source: "git", repo: repoID)
        try await store.ensure(names.map { KnowledgeNode(id: $0.key, kind: "person", name: $0.value, qualified: String($0.key.dropFirst(7)), source: "git") })
        try await store.ensure(touched.keys.map { KnowledgeNode(id: $0, kind: "ticket", name: String($0.dropFirst(7)), qualified: String($0.dropFirst(7)), source: "git") })
        var edges: [KnowledgeEdge] = []
        for (person, files) in authored {
            for (path, count) in files { edges.append(KnowledgeEdge(src: person, dst: fileID(path), kind: "authored", weight: Double(count), source: "git")) }
        }
        for (pair, count) in together where count >= 3 {
            let paths = pair.split(separator: "\n").map(String.init)
            edges.append(KnowledgeEdge(src: fileID(paths[0]), dst: fileID(paths[1]), kind: "changes_with", weight: Double(count), source: "git"))
        }
        for (ticket, files) in touched {
            for (path, count) in files { edges.append(KnowledgeEdge(src: ticket, dst: fileID(path), kind: "touches", weight: Double(count), source: "git")) }
        }
        try await store.upsert(edges)
    }

    // MARK: Files and git

    /// Tracked and untracked-but-not-ignored files (git), or a plain walk outside git.
    func listFiles() -> [String] {
        let listed = Self.git(root, ["ls-files", "-co", "--exclude-standard"])?
            .split(separator: "\n").map(String.init)
        let all = listed ?? walk()
        return all.filter { path in
            CodeParser.language(of: path) != nil
                && !path.split(separator: "/").dropLast().contains { Self.skippedDirectories.contains(String($0)) }
        }.sorted()
    }

    private func walk() -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var result: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            if Self.skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
            }
        }
        return result
    }

    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty {
            result.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        return result
    }

    /// "owner/name" from the origin remote (GitHub, GitLab, SSH or HTTPS).
    static func remoteSlug(_ root: URL) -> String? {
        guard let remote = git(root, ["config", "--get", "remote.origin.url"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remote.isEmpty else { return nil }
        var path = remote
        if let range = path.range(of: "://") { path = String(path[range.upperBound...]).split(separator: "/", maxSplits: 1).dropFirst().joined() }
        else if let colon = path.firstIndex(of: ":") { path = String(path[path.index(after: colon)...]) }
        if path.hasSuffix(".git") { path.removeLast(4) }
        return path.isEmpty ? nil : path
    }

    static func goModule(_ root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appending(path: "go.mod"), encoding: .utf8) else { return nil }
        return CodeParser.firstMatch(#"(?m)^module\s+(\S+)"#, in: text)
    }

    static func git(_ root: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

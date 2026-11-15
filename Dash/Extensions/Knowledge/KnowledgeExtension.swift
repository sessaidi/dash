import AppKit
import DashKit
import Foundation
import Observation
import SwiftUI

/// The knowledge graph: Dash's own index of the user's repositories (structure, symbols,
/// imports, calls, git history) joined with what extensions know (tickets, PRs, agent sessions,
/// meetings) and with notes, plus what Claude understood about each part, built bit by bit.
/// Dashii and agents query it through the `knowledge_*` tools.
@MainActor
@Observable
final class KnowledgeExtension: DashExtension {
    let id = "knowledge"
    let name = "Knowledge"
    let systemImage = "point.3.connected.trianglepath.dotted"
    let metadata = ExtensionMetadata(version: "1.0.0", summary: "A knowledge graph of your code, tickets, PRs, agents, meetings and notes that Dashii can query.",
                                     category: .ai, homepage: "https://github.com/sessaidi/dash")

    /// Local repositories to index (absolute paths).
    var repositories: [String] { didSet { defaults.set(repositories, forKey: "knowledge.repos") } }
    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "knowledge.refreshMinutes") } }
    var readHistory: Bool { didSet { defaults.set(readHistory, forKey: "knowledge.history") } }
    /// Index the repositories the GitHub and GitLab integrations watch (read from Dash's database).
    var followWatched: Bool { didSet { defaults.set(followWatched, forKey: "knowledge.followWatched") } }
    /// Watched repositories this extension added ("github:owner/name" → path), so it drops them when unwatched.
    private(set) var followed: [String: String] { didSet { defaults.set(followed, forKey: "knowledge.followed") } }
    /// Let Claude study directories in the background.
    var understand: Bool { didSet { defaults.set(understand, forKey: "knowledge.understand") } }
    /// Directories Claude studies per background pass, and how often a pass runs.
    var understandBudget: Int { didSet { defaults.set(understandBudget, forKey: "knowledge.budget") } }
    var understandHours: Int { didSet { defaults.set(understandHours, forKey: "knowledge.understandHours") } }

    private(set) var status = ""
    private(set) var isWorking = false
    private(set) var lastError: String?
    private(set) var lastRefresh: Date?
    private(set) var counts: [String: Int] = [:]
    /// Bumped after every write, so views reload.
    private(set) var revision = 0

    let store: KnowledgeStore?
    /// What Dashii learns from its conversations, kept in this graph.
    @ObservationIgnored private(set) lazy var memory: DashiiMemory? = store.map { store in DashiiMemory(store: store) { [weak self] in self?.host } }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastUnderstood: Date?
    /// Search vectors, loaded once per graph revision.
    @ObservationIgnored var vectorCache: (revision: Int, items: [(id: String, vector: [Float])]) = (-1, [])

    static var defaultURL: URL {
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appending(path: "dash-knowledge-\(UUID().uuidString).sqlite")
        }
        return URL.applicationSupportDirectory.appending(path: "Dash/knowledge.sqlite")
    }

    /// `url` nil keeps the graph in memory (tests).
    init(defaults: UserDefaults = DashDefaults.shared, url: URL? = KnowledgeExtension.defaultURL) {
        self.defaults = defaults
        store = try? KnowledgeStore(url: url)
        repositories = defaults.stringArray(forKey: "knowledge.repos") ?? []
        refreshMinutes = defaults.object(forKey: "knowledge.refreshMinutes") as? Int ?? 30
        readHistory = defaults.object(forKey: "knowledge.history") as? Bool ?? true
        followWatched = defaults.object(forKey: "knowledge.followWatched") as? Bool ?? true
        followed = defaults.dictionary(forKey: "knowledge.followed") as? [String: String] ?? [:]
        understand = defaults.object(forKey: "knowledge.understand") as? Bool ?? true
        understandBudget = defaults.object(forKey: "knowledge.budget") as? Int ?? 6
        understandHours = defaults.object(forKey: "knowledge.understandHours") as? Int ?? 4
    }

    func start(host: any ExtensionContext) {
        self.host = host
        Task {
            // The graph is the source of truth: a repository it indexed stays listed even if the
            // preference lost it (only removing a repository drops it from both).
            await restoreRepositories()
            counts = (try? await store?.counts()) ?? [:]
        }
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))  // after launch settles
            while !Task.isCancelled {
                await self?.refresh()
                if let self, understand, Date.now.timeIntervalSince(lastUnderstood ?? .distantPast) > Double(understandHours) * 3600 {
                    _ = await self.learn(budget: understandBudget)
                }
                try? await Task.sleep(for: .seconds(Double(max(self?.refreshMinutes ?? 30, 5)) * 60))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func settingsView() -> AnyView { AnyView(KnowledgeSettings(knowledge: self)) }

    // MARK: Building the graph

    /// Indexes every repository (only changed files) and re-reads what extensions know.
    func refresh() async {
        guard let store, !isWorking else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false; status = "" }
        await followWatchedRepositories()
        for path in repositories {
            status = "Indexing \((path as NSString).lastPathComponent)…"
            do {
                if let remote = Self.remote(at: path) {
                    status = "Fetching \(remote.slug)…"
                    if let host, try await remote.sync(host: host) == .unchanged, lastRefresh != nil { continue }
                }
                _ = try await Self.index(path, store: store, history: readHistory && Self.remote(at: path) == nil)
            } catch {
                lastError = "\((path as NSString).lastPathComponent): \(error.localizedDescription)"
            }
            revision += 1
        }
        await fetchDocs()
        status = "Linking tickets, PRs, docs and notes…"
        await ingestEntities()
        counts = (try? await store.counts()) ?? [:]
        lastRefresh = .now
        revision += 1
    }

    /// Off the main actor: parsing a large repository takes a while.
    nonisolated static func index(_ path: String, store: KnowledgeStore, history: Bool) async throws -> CodeIndexer.Report {
        try await Task.detached(priority: .utility) {
            var indexer = CodeIndexer(root: URL(fileURLWithPath: path), store: store)
            indexer.readHistory = history
            let report = try await indexer.index()
            // Modules, flows and vectors follow the code: recomputed when files changed (or never were).
            let analyzed = try await store.meta("analysis-v1:" + indexer.repoID) != nil
            if report.parsed > 0 || report.removed > 0 || !analyzed {
                try await KnowledgeAnalysis.analyze(repo: indexer.repoID, root: path, store: store)
            }
            return report
        }.value
    }

    /// The source an extension's entities are filed under. Knowledge's own writers are "code",
    /// "code-tests", "git" and "claude": an extension with one of those ids (the built-in Git
    /// integration is "git") must not replace their links when its entities are re-read.
    nonisolated static func entitySource(_ extensionID: String) -> String {
        ["code", "code-tests", "git", "claude"].contains(extensionID) ? "ext:" + extensionID : extensionID
    }

    /// Asks the Atlassian integration for the Confluence pages that mention each repository, at
    /// most once a day per repository (`force` now). They come back as `doc` entities at the next
    /// ingest, linked to the repository.
    func fetchDocs(force: Bool = false) async {
        guard let host, let store, host.fetchers.contains(where: { $0.name == "confluence.pages" }) else { return }
        for path in repositories {
            guard let node = try? await store.node("repo:" + path) else { continue }
            let slug = node.qualified.contains("/") ? node.qualified : nil
            let name = slug.map { String($0.split(separator: "/").last ?? "") } ?? (path as NSString).lastPathComponent
            let key = "knowledge.docsFetched." + path
            if !force, let last = DashDefaults.shared.object(forKey: key) as? Date, Date.now.timeIntervalSince(last) < 86_400 { continue }
            status = "Fetching Confluence pages about \(name)…"
            do {
                _ = try await host.fetch("confluence.pages", ["query": .string(name), "repo": slug.map(JSONValue.string) ?? .null])
                DashDefaults.shared.set(Date.now, forKey: key)
            } catch {
                lastError = "Confluence: \(error.localizedDescription)"
            }
        }
    }

    func ingestEntities() async {
        guard let host, let store else { return }
        for item in host.extensions where item.id != id && host.isEnabled(item) {
            let entities = item.knowledge
            do { try await KnowledgeLinker.ingest(entities, source: Self.entitySource(item.id), into: store) }
            catch { lastError = "\(item.name): \(error.localizedDescription)" }
        }
        if let notes = host.ext(NotesExtension.self) {
            try? await KnowledgeLinker.ingest(BuiltInKnowledge.notes(notes.store), source: "notes.vault", into: store)
        }
    }

    /// Where clones live (the Agents plugin's code folder, ~/Codes by default).
    static var codeRoot: URL {
        URL(fileURLWithPath: ((DashDefaults.shared.string(forKey: "agents.codeRoot") ?? "~/Codes") as NSString).expandingTildeInPath)
    }

    /// Git clones directly in a folder (worktrees under .worktrees aren't separate repositories).
    static func clones(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func addRepository(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !repositories.contains(path) else { return }
        repositories.append(path)
        Task { await refresh() }
    }

    /// Folders where people keep checkouts, searched three levels deep (the Agents code folder first).
    static var searchRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var seen = Set<String>()
        return ([codeRoot] + ["code", "Code", "Codes", "Developer", "dev", "src", "projects", "Projects", "workspace", "repos", "git", "GitHub"].map { home.appending(path: $0) })
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            // ~/code and ~/Code are one folder on a case-insensitive disk.
            .filter { seen.insert($0.resolvingSymlinksInPath().path.lowercased()).inserted }
    }

    /// Git checkouts under the search roots whose folder name contains `query` (all when empty).
    nonisolated static func findCheckouts(matching query: String, roots: [URL], depth: Int = 3) -> [URL] {
        let wanted = query.lowercased()
        var found: [URL] = []
        func walk(_ folder: URL, _ level: Int) {
            guard level <= depth, found.count < 200,
                  let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return }
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if FileManager.default.fileExists(atPath: child.appending(path: ".git").path) {
                    if wanted.isEmpty || child.lastPathComponent.lowercased().contains(wanted) { found.append(child) }
                } else if !["node_modules", "build", "vendor", "Pods", "DerivedData"].contains(child.lastPathComponent) {
                    walk(child, level + 1)
                }
            }
        }
        for root in roots { walk(root, 1) }
        return found.sorted { $0.path < $1.path }
    }

    /// `origin`'s URL of a checkout, from .git/config.
    nonisolated static func originURL(_ checkout: URL) -> String? {
        guard let config = try? String(contentsOf: checkout.appending(path: ".git/config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inOrigin = trimmed == "[remote \"origin\"]" }
            else if inOrigin, trimmed.hasPrefix("url") { return trimmed.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } }
        }
        return nil
    }

    /// Resolves what the user named: a path, a folder name found under the search roots, or
    /// "owner/name" (a local checkout of it, else a fresh clone into the code folder).
    /// Adds what the GitHub and GitLab integrations watch (the list they keep in Dash's database)
    /// and drops what they stopped watching, if this extension added it. A local checkout of a
    /// watched repository is used when there is one; otherwise it's read through the integration.
    func followWatchedRepositories() async {
        guard let host else { return }
        let watched = followWatched ? WatchedRepositories.all(in: host.synced) : []
        let wanted = Set(watched.map { "\($0.provider):\($0.slug)" })
        for (key, path) in followed where !wanted.contains(key) {
            followed[key] = nil
            if repositories.contains(path) { removeRepository(path) }
        }
        for repository in watched {
            let key = "\(repository.provider):\(repository.slug)"
            guard followed[key] == nil else { continue }
            do {
                let path = try await locate(repository).standardizedFileURL.path
                // Already indexed by hand: leave it the user's.
                guard !repositories.contains(path) else { continue }
                repositories.append(path)
                followed[key] = path
            } catch {
                lastError = "\(repository.slug): \(error.localizedDescription)"
            }
        }
    }

    /// A local checkout whose origin is the repository, else a mirror read through its integration.
    func locate(_ repository: WatchedRepositories.Repository) async throws -> URL {
        let name = String(repository.slug.split(separator: "/").last ?? "")
        let roots = Self.searchRoots
        let checkouts = await Task.detached { Self.findCheckouts(matching: name, roots: roots) }.value
        if let local = checkouts.first(where: { (Self.originURL($0) ?? "").lowercased().contains(repository.slug.lowercased()) }) {
            return local
        }
        guard let provider = RemoteRepository.Provider(rawValue: repository.provider) else { throw ToolError("Unknown provider \(repository.provider).") }
        return try await mirror(RemoteRepository(provider: provider, slug: repository.slug))
    }

    /// The remote a mirror folder stands for, nil for a local checkout.
    static func remote(at path: String) -> RemoteRepository? {
        guard path.hasPrefix(RemoteRepository.mirrorsRoot.path), let marker = RemoteRepository.marker(in: URL(fileURLWithPath: path)) else { return nil }
        return RemoteRepository(provider: marker.provider, slug: marker.slug, ref: marker.ref)
    }

    /// GitLab hosts the GitLab integration points at (for recognising its URLs).
    var gitlabHosts: [String] {
        ["gitlab.com"] + [host?.integration("gitlab")?.connection?.baseURL.host()].compactMap { $0 }
    }

    /// Reads a GitHub or GitLab repository through its integration into a mirror (no checkout).
    func mirror(_ remote: RemoteRepository) async throws -> URL {
        guard let host else { throw ToolError("Knowledge isn't running.") }
        status = "Fetching \(remote.slug)…"
        defer { status = "" }
        _ = try await remote.sync(host: host)
        return remote.mirror
    }

    func resolveRepository(_ text: String) async throws -> (url: URL, cloned: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let remote = RemoteRepository.parse(trimmed, gitlabHosts: gitlabHosts), trimmed.contains(":") {
            return (try await mirror(remote), false)
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            guard FileManager.default.fileExists(atPath: (expanded as NSString).appendingPathComponent(".git")) else {
                throw ToolError("\(expanded) isn't a git checkout.")
            }
            return (URL(fileURLWithPath: expanded), false)
        }
        let parts = trimmed.split(separator: "/").map(String.init)
        let name = parts.last ?? trimmed
        let roots = Self.searchRoots
        let local = await Task.detached { Self.findCheckouts(matching: name, roots: roots) }.value
        let exact = local.filter { $0.lastPathComponent.lowercased() == name.lowercased() }
        if parts.count == 2, let match = exact.first(where: { (Self.originURL($0) ?? "").lowercased().contains(trimmed.lowercased()) }) ?? exact.first {
            return (match, false)
        }
        if parts.count == 1 {
            if exact.count == 1 { return (exact[0], false) }
            if exact.count > 1 { throw ToolError("Several checkouts are named \(name): \(exact.map(\.path).joined(separator: ", ")). Give the path.") }
            throw ToolError("No checkout named \(name) under \(roots.map(\.path).joined(separator: ", ")). Give its path, or owner/name to clone it.")
        }
        guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else {
            throw ToolError("Give a path, a folder name or owner/name.")
        }
        // No checkout: read it through the GitHub integration when connected, else clone it.
        if host?.integration("github")?.connection != nil {
            return (try await mirror(RemoteRepository(provider: .github, slug: trimmed)), false)
        }
        return (try await Self.clone(owner: parts[0], name: parts[1], into: Self.codeRoot), true)
    }

    /// Clones github.com/owner/name with the user's git setup (SSH first, then HTTPS), into `<folder>/<name>`.
    nonisolated static func clone(owner: String, name: String, into folder: URL) async throws -> URL {
        let target = folder.appending(path: name)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ToolError("\(target.path) already exists and isn't a git checkout.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var failure = ""
        for url in ["git@github.com:\(owner)/\(name).git", "https://github.com/\(owner)/\(name).git"] {
            let (status, output) = await run(["/usr/bin/git", "clone", "--quiet", url, target.path], timeout: 600)
            if status == 0 { return target }
            failure = output
            try? FileManager.default.removeItem(at: target)
        }
        throw ToolError("Couldn't clone \(owner)/\(name): \(failure.suffix(400))")
    }

    nonisolated static func run(_ arguments: [String], timeout: TimeInterval) async -> (Int32, String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: arguments[0])
            process.arguments = Array(arguments.dropFirst())
            // The login shell's environment: ssh-agent socket, credential helpers, proxies.
            process.environment = ShellEnvironment.current.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            if process.isRunning { process.terminate() }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, output)
        }.value
    }

    func restoreRepositories() async {
        let indexed = (try? await store?.repositoryPaths()) ?? []
        let missing = indexed.filter { !repositories.contains($0) && FileManager.default.fileExists(atPath: $0) }
        if !missing.isEmpty { repositories += missing }
    }

    func removeRepository(_ path: String) {
        repositories.removeAll { $0 == path }
        // A mirror is Dash's own copy: it goes too (a checkout is left alone).
        if Self.remote(at: path) != nil { try? FileManager.default.removeItem(atPath: path) }
        Task {
            try? await store?.removeRepo("repo:" + path)
            counts = (try? await store?.counts()) ?? [:]
            revision += 1
        }
    }

    // MARK: Understanding (Claude)

    static let understandTask = AITask(
        id: "understand", title: "Understand the code",
        summary: "Reads one directory at a time (files, declarations, imports, sub-directory notes) and writes what it's for, its responsibilities and the concepts it deals with.",
        models: [.fast, .balanced, .strong], defaultModel: .balanced, efforts: [.low, .medium, .high], defaultEffort: .low)

    var aiTasks: [AITask] { [Self.understandTask] }
    var ai: AISettings { host?.aiSettings(.extension(id), tasks: aiTasks) ?? AISettings(tasks: aiTasks) }

    static let understandSchema: JSONValue = [
        "type": "object", "additionalProperties": false,
        "required": ["summary", "responsibilities", "concepts"],
        "properties": [
            "summary": ["type": "string", "description": "Two to four sentences: what this part of the code is for and how it works."],
            "responsibilities": ["type": "array", "items": ["type": "string"], "description": "Up to six things it is responsible for."],
            "concepts": [
                "type": "array", "description": "Up to five domain or technical concepts it deals with (e.g. \"subscription renewal\", \"rate limiting\").",
                "items": ["type": "object", "additionalProperties": false, "required": ["name", "description"],
                          "properties": ["name": ["type": "string"], "description": ["type": "string"]]],
            ],
        ],
    ]

    struct Understanding: Decodable {
        struct Concept: Decodable { let name: String; let description: String }
        let summary: String
        let responsibilities: [String]
        let concepts: [Concept]
    }

    /// Studies up to `budget` directories that are new or changed (the most substantial first),
    /// then the repositories whose directories it learnt about. Returns how many it studied.
    @discardableResult
    func learn(budget: Int, repo: String? = nil) async -> Int {
        guard let host, let store, ai.isEnabled(Self.understandTask.id) else { return 0 }
        lastUnderstood = .now
        var studied = 0
        var repos = Set<String>()
        let directories = (try? await store.directoriesToUnderstand(repo: repo, limit: budget)) ?? []
        for directory in directories {
            do {
                try await study(directory, host: host, store: store)
                studied += 1
                repos.insert(directory.repo)
            } catch {
                lastError = "Understanding \(directory.path): \(error.localizedDescription)"
                break
            }
        }
        for repo in repos { await learnRepository(repo) }
        status = ""
        counts = (try? await store.counts()) ?? [:]
        revision += 1
        return studied
    }

    /// Studies one directory now (the page's Understand button).
    func learnDirectory(_ directory: KnowledgeNode) async {
        guard let host, let store else { return }
        do { try await study(directory, host: host, store: store) }
        catch { lastError = "Understanding \(directory.path): \(error.localizedDescription)" }
        status = ""
        revision += 1
    }

    private func study(_ directory: KnowledgeNode, host: any ExtensionContext, store: KnowledgeStore) async throws {
        status = "Understanding \(directory.path)…"
        let context = try await Self.context(for: directory, store: store)
        let text = try await host.dashii.complete(
            task: Self.understandTask.id, settings: ai,
            system: "You study a codebase one directory at a time and write concise, factual notes another engineer (or AI) will rely on. Only state what the material shows.",
            prompt: context, outputSchema: Self.understandSchema)
        try await save(try JSONValue.parse(text).decode(Understanding.self), for: directory, store: store)
    }

    private func save(_ understanding: Understanding, for node: KnowledgeNode, store: KnowledgeStore) async throws {
        var text = understanding.summary
        if !understanding.responsibilities.isEmpty {
            text += "\n\nResponsibilities:\n" + understanding.responsibilities.map { "- \($0)" }.joined(separator: "\n")
        }
        try await store.setSummary(node.id, text)
        let concepts = understanding.concepts.prefix(5).map { concept in
            KnowledgeNode(id: "concept:" + node.repo + ":" + Self.slug(concept.name), kind: "concept", name: concept.name,
                          qualified: concept.name, repo: node.repo, signature: concept.description, source: "claude")
        }
        try await store.ensure(Array(concepts))
        try await store.upsert(concepts.map { KnowledgeEdge(src: node.id, dst: $0.id, kind: "about", source: "claude") })
    }

    /// A repository's overview from its top-level directories' notes and its README.
    private func learnRepository(_ repoID: String) async {
        guard let host, let store, let repo = try? await store.node(repoID) else { return }
        let top = ((try? await store.subdirectories(repo: repoID, directory: "")) ?? []).filter { !$0.summary.isEmpty }
        guard !top.isEmpty else { return }
        var prompt = "Repository: \(repo.qualified.isEmpty ? repo.name : repo.qualified)\n\nTop-level directories and what they do:\n"
        for directory in top { prompt += "\n## \(directory.path)\n\(directory.summary)\n" }
        if let readme = Self.readme(in: URL(fileURLWithPath: String(repoID.dropFirst(5)))) { prompt += "\nREADME (start):\n\(readme)\n" }
        prompt += "\nDescribe the whole repository: its purpose, main parts and how they fit together."
        if let text = try? await host.dashii.complete(task: Self.understandTask.id, settings: ai,
                                                      system: "You write concise, factual overviews of codebases.",
                                                      prompt: prompt, outputSchema: Self.understandSchema),
           let understanding = try? JSONValue.parse(text).decode(Understanding.self) {
            try? await save(understanding, for: repo, store: store)
        }
    }

    /// What Claude reads about one directory: its files' declarations, imports, the notes on
    /// its sub-directories and a README, within about 14 000 characters.
    static func context(for directory: KnowledgeNode, store: KnowledgeStore) async throws -> String {
        let root = String(directory.repo.dropFirst(5))
        var text = "Repository: \((root as NSString).lastPathComponent)\nDirectory: \(directory.path)\n"
        let files = try await store.files(repo: directory.repo, directory: directory.path)
        var imports = Set<String>()
        text += "\nFiles and their declarations:\n"
        for file in files.prefix(60) {
            text += "\n### \(file.name)\n"
            for symbol in try await store.symbols(repo: directory.repo, path: file.path).prefix(30) {
                text += "- \(symbol.signature)\n"
            }
            for neighbor in try await store.neighbors(file.id, kinds: ["imports"], limit: 40) where !neighbor.incoming {
                imports.insert(neighbor.node.name)
            }
            if text.count > 11_000 { text += "\n(more files not shown)\n"; break }
        }
        if !imports.isEmpty { text += "\nImports: " + imports.sorted().prefix(60).joined(separator: ", ") + "\n" }
        let subdirectories = try await store.subdirectories(repo: directory.repo, directory: directory.path)
        if !subdirectories.isEmpty {
            text += "\nSub-directories:\n"
            for sub in subdirectories.prefix(30) {
                text += "- \(sub.name)" + (sub.summary.isEmpty ? "" : ": " + (sub.summary.components(separatedBy: "\n").first ?? "")) + "\n"
            }
        }
        if let readme = readme(in: URL(fileURLWithPath: root).appending(path: directory.path)) { text += "\nREADME (start):\n\(readme)\n" }
        return String(text.prefix(14_000))
    }

    nonisolated static func readme(in folder: URL) -> String? {
        for name in ["README.md", "Readme.md", "readme.md", "README"] {
            if let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8) {
                return text.components(separatedBy: "\n").prefix(60).joined(separator: "\n")
            }
        }
        return nil
    }

    static func slug(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
    }

    // MARK: Claude tools

    private struct SearchInput: Decodable { let query: String; let kind: String?; let limit: Int? }
    private struct NodeInput: Decodable { let id: String }
    private struct TraceInput: Decodable { let id: String; let direction: String?; let depth: Int?; let min_confidence: Double? }
    private struct PathInput: Decodable { let from: String; let to: String }
    private struct LearnInput: Decodable { let directories: Int?; let repo: String? }
    private struct ImpactInput: Decodable { let id: String }
    private struct ExpertsInput: Decodable { let id: String }
    private struct ContextInput: Decodable { let question: String; let limit: Int? }
    private struct FindInput: Decodable { let query: String? }
    private struct RepositoryInput: Decodable { let repository: String }

    static func json(_ node: KnowledgeNode, full: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(node.id), "kind": .string(node.kind), "name": .string(node.name)]
        if !node.qualified.isEmpty && node.qualified != node.name { object["qualified"] = .string(node.qualified) }
        if !node.path.isEmpty {
            object["path"] = .string(node.path)
            if !node.repo.isEmpty { object["file"] = .string(String(node.repo.dropFirst(5)) + "/" + node.path) }
        }
        if node.line > 0 { object["lines"] = .string("\(node.line)-\(node.endLine)") }
        if !node.signature.isEmpty { object["signature"] = .string(full ? node.signature : String(node.signature.prefix(300))) }
        if !node.summary.isEmpty { object["summary"] = .string(full ? node.summary : String(node.summary.prefix(400))) }
        if !node.url.isEmpty { object["url"] = .string(node.url) }
        return .object(object)
    }

    /// Dashii's memory: remember what the user asks it to, recall, forget.
    private var memoryTools: [DashiiTool] {
        [
            DashiiTool(
                name: "memory_remember",
                description: "Remember a fact for later conversations (the user asked you to, or corrected you): one specific sentence, with the tickets, repos, people or concepts it's about. Never secrets.",
                properties: ["fact": JSONSchema.string("The fact, one sentence."),
                             "about": ["type": "array", "items": ["type": "string"], "description": "Names or keys it's about (KAN-123, owner/repo, a person)."]],
                required: ["fact"]
            ) { [weak self] input in
                guard let memory = self?.memory else { throw ToolError("Knowledge isn't available.") }
                let request = try input.toolInput(RememberInput.self)
                let id = try await memory.remember(.init(text: request.fact, about: request.about ?? [], confidence: .stated, durability: .stable,
                                                         evidence: "the user asked Dashii to remember it", scope: "global"))
                self?.bump()
                return ["remembered": .string(id)]
            },
            DashiiTool(
                name: "memory_recall",
                description: "What you learned in earlier conversations about something (facts with confidence, date and id). <what-i-know> already brings the most relevant ones; use this to look further.",
                properties: ["query": JSONSchema.string("What to recall; omit for the most recent facts.")]
            ) { [weak self] input in
                guard let memory = self?.memory else { throw ToolError("Knowledge isn't available.") }
                let query = try input.toolInput(RecallInput.self).query ?? ""
                let nodes = query.isEmpty ? Array(await memory.all(limit: 40).prefix(40)) : await memory.recall(query, limit: 20)
                return .array(nodes.map { ["id": .string($0.id), "fact": .string($0.signature), "how": .string($0.qualified), "updated": .string($0.updated.formatted(.iso8601))] })
            },
            DashiiTool(
                name: "memory_forget",
                description: "Forget a fact you learned (it was wrong or the user asked). Ids come from <what-i-know> or memory_recall.",
                properties: ["id": JSONSchema.string("obs:… id.")], required: ["id"]
            ) { [weak self] input in
                guard let memory = self?.memory else { throw ToolError("Knowledge isn't available.") }
                try await memory.forget(try input.toolInput(ForgetInput.self).id)
                self?.bump()
                return "forgotten"
            },
        ]
    }

    /// Views reload after a memory change.
    func bump() { revision += 1 }

    private struct RememberInput: Decodable { let fact: String; let about: [String]? }
    private struct ForgetInput: Decodable { let id: String }
    private struct RecallInput: Decodable { let query: String? }

    var tools: [DashiiTool] {
        memoryTools + analysisTools + [
            DashiiTool(
                name: "knowledge_search",
                description: "Search the knowledge graph of the user's code and work: repositories, directories, files, symbols (functions, types), modules, flows, decisions, configuration, concepts, docs (Confluence pages about the repositories), tickets, PRs, agent sessions, meetings, notes, people. Matches names, signatures and Dashii's notes, and by meaning (\"where do we retry payments\"). Start here to locate anything.",
                properties: ["query": JSONSchema.string("Words or a name, e.g. \"renew subscription\" or \"UserService\"."),
                             "kind": JSONSchema.string("Optional kind filter.", enum: ["repo", "directory", "file", "symbol", "package", "cluster", "flow", "decision", "env", "concept", "doc", "ticket", "pr", "agent", "meeting", "note", "person"]),
                             "limit": JSONSchema.integer("Max results (default 20).")],
                required: ["query"]
            ) { [weak self] input in
                guard let store = self?.store else { return [] }
                let request = try input.toolInput(SearchInput.self)
                let limit = min(request.limit ?? 20, 60)
                let kinds = request.kind.map { [$0] } ?? []
                let lexical = try await store.search(request.query, kinds: kinds, limit: limit)
                // By meaning too (on-device vectors), fused with the name/word matches.
                let semantic = await self?.semanticSearch(request.query, limit: limit) ?? []
                guard !semantic.isEmpty else { return .array(lexical.map { Self.json($0) }) }
                let ranked = KnowledgeAnalysis.fuse([lexical.map(\.id), semantic])
                var byID = Dictionary(lexical.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for node in try await store.nodes(ids: semantic.filter { byID[$0] == nil }) { byID[node.id] = node }
                let nodes = ranked.compactMap { byID[$0] }.filter { kinds.isEmpty || kinds.contains($0.kind) }
                return .array(nodes.prefix(limit).map { Self.json($0) })
            },
            DashiiTool(
                name: "knowledge_node",
                description: "One node of the knowledge graph with its neighbours grouped by relation (contains, defines, imports, calls, called by, authored, changes_with, touches, mentions, about…). Use it to walk the graph from a search result.",
                properties: ["id": JSONSchema.string("Node id from another knowledge_* result.")], required: ["id"]
            ) { [weak self] input in
                guard let store = self?.store else { return nil }
                let id = try input.toolInput(NodeInput.self).id
                guard let node = try await store.node(id) else { throw ToolError("No node \(id). Use knowledge_search.") }
                var groups: [String: [JSONValue]] = [:]
                for neighbor in try await store.neighbors(id, limit: 60) {
                    let relation = neighbor.incoming ? Self.inverse(neighbor.edge.kind) : neighbor.edge.kind
                    groups[relation, default: []].append(Self.json(neighbor.node))
                }
                var result = Self.json(node, full: true).object ?? [:]
                result["relations"] = .object(groups.mapValues { .array($0) })
                return .object(result)
            },
            DashiiTool(
                name: "knowledge_trace",
                description: "Who calls a symbol (direction in) or what it calls (direction out), several hops deep. Each call has a confidence: 0.95 same file, 0.85 an imported file, 0.7 same directory, 0.6 unique name, 0.3 ambiguous.",
                properties: ["id": JSONSchema.string("Symbol id."),
                             "direction": JSONSchema.string("in: callers, out: callees (default out).", enum: ["in", "out"]),
                             "depth": JSONSchema.integer("Hops, 1-4 (default 2)."),
                             "min_confidence": JSONSchema.number("Skip calls resolved with less confidence (0.3 ambiguous … 0.95 same file; default 0).")],
                required: ["id"]
            ) { [weak self] input in
                guard let store = self?.store else { return [] }
                let request = try input.toolInput(TraceInput.self)
                let steps = try await store.trace(request.id, kinds: ["calls"], reverse: request.direction == "in", depth: min(max(request.depth ?? 2, 1), 4),
                                                  minWeight: request.min_confidence ?? 0)
                return .array(steps.map { step in
                    var object = Self.json(step.node).object ?? [:]
                    object["depth"] = .number(Double(step.depth))
                    return .object(object)
                })
            },
            DashiiTool(
                name: "knowledge_path",
                description: "How two things are connected: the shortest chain of relations between two nodes (e.g. a ticket and a function, a person and a module).",
                properties: ["from": JSONSchema.string("Node id."), "to": JSONSchema.string("Node id.")],
                required: ["from", "to"]
            ) { [weak self] input in
                guard let store = self?.store else { return nil }
                let request = try input.toolInput(PathInput.self)
                guard let chain = try await store.path(from: request.from, to: request.to) else { return .string("No connection within 6 hops.") }
                return .array(chain.map { step in
                    ["relation": .string(step.incoming ? Self.inverse(step.edge.kind) : step.edge.kind), "node": Self.json(step.node)]
                })
            },
            DashiiTool(
                name: "knowledge_overview",
                description: "The indexed repositories with Dashii's overview of each and of their top-level directories, plus graph size. Call first when asked about a project as a whole.",
                properties: [:]
            ) { [weak self] _ in
                guard let store = self?.store else { return nil }
                var repos: [JSONValue] = []
                for repo in try await store.nodes(kind: "repo") {
                    var object = Self.json(repo, full: true).object ?? [:]
                    object["directories"] = .array(try await store.subdirectories(repo: repo.id, directory: "").map { Self.json($0) })
                    repos.append(.object(object))
                }
                let counts = try await store.counts()
                return ["repositories": .array(repos), "counts": .object(counts.mapValues { .number(Double($0)) })]
            },
            DashiiTool(
                name: "knowledge_snippet",
                description: "The source code of a symbol or the start of a file, read from disk.",
                properties: ["id": JSONSchema.string("Symbol or file id.")], required: ["id"]
            ) { [weak self] input in
                guard let store = self?.store else { return nil }
                let id = try input.toolInput(NodeInput.self).id
                guard let node = try await store.node(id), !node.repo.isEmpty, !node.path.isEmpty else { throw ToolError("\(id) has no source.") }
                let url = URL(fileURLWithPath: String(node.repo.dropFirst(5))).appending(path: node.path)
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                let start = max(node.line, 1)
                let end = node.kind == "symbol" ? min(max(node.endLine, start), start + 300) : min(lines.count, 200)
                return ["file": .string(url.path), "from": .number(Double(start)),
                        "code": .string(lines[(start - 1)..<min(end, lines.count)].joined(separator: "\n"))]
            },
            DashiiTool(
                name: "knowledge_find_repos",
                description: "Find git checkouts on this Mac (under ~/code, ~/Codes, ~/Developer, ~/src and similar, three levels deep) whose folder name contains some text, with their origin and whether Knowledge already indexes them. Read-only.",
                properties: ["query": JSONSchema.string("Part of the repository's folder name; empty lists them all.")]
            ) { [weak self] input in
                guard let self else { return nil }
                let query = try input.toolInput(FindInput.self).query ?? ""
                let roots = Self.searchRoots
                let found = await Task.detached { Self.findCheckouts(matching: query, roots: roots) }.value
                return ["searched": .array(roots.map { .string($0.path) }),
                        "checkouts": .array(found.prefix(60).map { url in
                            ["path": .string(url.path), "origin": Self.originURL(url).map(JSONValue.string) ?? .null,
                             "indexed": .bool(repositories.contains(url.standardizedFileURL.path))]
                        })]
            },
            DashiiTool(
                name: "knowledge_add_repository",
                description: "Add a repository to the knowledge graph and index it (structure, symbols, history; no Dashii usage). Give a local path, a folder name found by knowledge_find_repos, GitHub owner/name, or github:owner/name / gitlab:group/project (optionally @branch) or their web URL: a local checkout is used if there is one, otherwise the repository is read through the GitHub or GitLab integration (no clone; refreshed when the branch moves). Then knowledge_learn can study it.",
                properties: ["repository": JSONSchema.string("A path, a folder name, owner/name, github:owner/name, gitlab:group/project[@ref], or a repository URL.")],
                required: ["repository"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return nil }
                let (url, cloned) = try await resolveRepository(try input.toolInput(RepositoryInput.self).repository)
                let path = url.standardizedFileURL.path
                if repositories.contains(path) { return ["path": .string(path), "note": "Already indexed."] }
                repositories.append(path)
                guard let store else { throw ToolError("The knowledge graph couldn't be opened.") }
                status = "Indexing \(url.lastPathComponent)…"
                defer { status = "" }
                let report = try await Self.index(path, store: store, history: readHistory)
                counts = (try? await store.counts()) ?? [:]
                revision += 1
                return ["path": .string(path), "cloned": .bool(cloned), "indexed": .string(String(describing: report))]
            },
            DashiiTool(
                name: "knowledge_remove_repository",
                description: "Stop indexing a repository and drop it from the knowledge graph (the checkout on disk is left alone).",
                properties: ["repository": JSONSchema.string("Its path or folder name.")], required: ["repository"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return nil }
                let wanted = try input.toolInput(RepositoryInput.self).repository
                guard let path = repositories.first(where: { $0 == (wanted as NSString).expandingTildeInPath || ($0 as NSString).lastPathComponent == wanted
                    || Self.remote(at: $0).map { wanted.hasSuffix($0.slug) } == true }) else {
                    throw ToolError("Knowledge doesn't index “\(wanted)”. Indexed: \(repositories.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")).")
                }
                removeRepository(path)
                return ["removed": .string(path)]
            },
            DashiiTool(
                name: "knowledge_impact",
                description: "What a change to a symbol or file would affect: callers (three hops), files importing it, the tests covering it and its callers, files that usually change with it, and who knows it best. Use before changing or reviewing code.",
                properties: ["id": JSONSchema.string("Symbol or file id from knowledge_search.")], required: ["id"]
            ) { [weak self] input in
                guard let self, let store else { return nil }
                return try await impact(of: try input.toolInput(ImpactInput.self).id, store: store)
            },
            DashiiTool(
                name: "knowledge_experts",
                description: "Who knows a file, directory or whole repository best: the people who changed it most in the recent git history, with commit counts.",
                properties: ["id": JSONSchema.string("A repository, directory or file id.")], required: ["id"]
            ) { [weak self] input in
                guard let store = self?.store else { return nil }
                let id = try input.toolInput(ExpertsInput.self).id
                guard let node = try await store.node(id) else { throw ToolError("No node \(id). Use knowledge_search.") }
                let repo = node.kind == "repo" ? node.id : node.repo
                let experts = try await store.experts(repo: repo, path: node.kind == "repo" ? "" : node.path)
                if experts.isEmpty { return ["experts": [], "note": "No git history in the graph for this. Make sure history reading is on in Knowledge settings."] }
                return ["for": .string(node.kind == "repo" ? node.name : node.path),
                        "experts": .array(experts.map { ["name": .string($0.person.name), "email": .string($0.person.qualified), "commits": .number(Double($0.commits))] })]
            },
            DashiiTool(
                name: "knowledge_context",
                description: "Everything the graph knows that's relevant to a question, in one call: the best matching concepts, directories (with Dashii's notes), files and symbols, each with the summary of where it lives. Use it to ground an answer about how the code works before reading files.",
                properties: ["question": JSONSchema.string("The question, in plain words."), "limit": JSONSchema.integer("How many matches (default 12).")],
                required: ["question"]
            ) { [weak self] input in
                guard let self, let store else { return nil }
                let request = try input.toolInput(ContextInput.self)
                return try await context(for: request.question, limit: min(request.limit ?? 12, 30), store: store)
            },
            DashiiTool(
                name: "knowledge_status",
                description: "The state of the knowledge graph per repository: files and symbols indexed, how much Dashii has studied, whether git history is linked, when it was last indexed. Use it to tell the user what Knowledge can answer well.",
                properties: [:]
            ) { [weak self] _ in
                guard let self, let store else { return nil }
                var repos: [JSONValue] = []
                for repo in try await store.nodes(kind: "repo") {
                    let coverage = try await store.coverage(repo: repo.id)
                    repos.append(["repository": .string(repo.name), "id": .string(repo.id), "path": .string(String(repo.id.dropFirst(5))),
                                  "studied_directories": .string("\(coverage.studied)/\(coverage.directories)"),
                                  "history_links": .number(Double(try await store.edgeCount(kind: "authored", repo: repo.id))),
                                  "test_links": .number(Double(try await store.edgeCount(kind: "tests", repo: repo.id))),
                                  "last_indexed": (try await store.meta("indexed:" + repo.id)).map(JSONValue.string) ?? .null])
                }
                return ["repositories": .array(repos), "counts": .object((try await store.counts()).mapValues { .number(Double($0)) }),
                        "settings": ["history": .bool(readHistory), "background_study": .bool(understand),
                                     "directories_per_pass": .number(Double(understandBudget)), "hours_between_passes": .number(Double(understandHours))]]
            },
            DashiiTool(
                name: "knowledge_learn",
                description: "Have Dashii study more of the code now (directories not yet understood or changed since), improving later answers. Costs Dashii usage.",
                properties: ["directories": JSONSchema.integer("How many directories (default 5, max 20)."),
                             "repo": JSONSchema.string("Optional repository id to focus on.")],
                requiresApproval: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(LearnInput.self)
                let studied = await learn(budget: min(request.directories ?? 5, 20), repo: request.repo)
                return ["studied": .number(Double(studied))]
            },
        ]
    }

    /// Ids closest in meaning to `query` (on-device sentence vectors), best first; empty when the
    /// embedding isn't available or nothing is embedded yet. Vectors are cached until the graph changes.
    func semanticSearch(_ query: String, limit: Int) async -> [String] {
        guard let store, let vector = KnowledgeAnalysis.embed(KnowledgeAnalysis.words(query)) else { return [] }
        if vectorCache.revision != revision || vectorCache.items.isEmpty {
            vectorCache = (revision, (try? await store.vectors()) ?? [])
        }
        let items = vectorCache.items
        let scored = await Task.detached(priority: .userInitiated) {
            items.map { ($0.id, KnowledgeAnalysis.cosine(vector, $0.vector)) }.filter { $0.1 > 0.35 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        }.value
        return Array(scored)
    }

    // MARK: Impact and context

    func impact(of id: String, store: KnowledgeStore) async throws -> JSONValue {
        guard let node = try await store.node(id) else { throw ToolError("No node \(id). Use knowledge_search.") }
        guard node.kind == "symbol" || node.kind == "file" else { throw ToolError("Impact works on a symbol or a file; this is a \(node.kind).") }
        let fileID = node.kind == "file" ? node.id : (try await store.neighbors(node.id, kinds: ["defines"], limit: 5).first { $0.incoming }?.node.id ?? "")
        var callers: [JSONValue] = []
        var callerFiles = Set<String>()
        if node.kind == "symbol" {
            for step in try await store.trace(node.id, kinds: ["calls"], reverse: true, depth: 3).prefix(60) {
                var object = Self.json(step.node).object ?? [:]
                object["depth"] = .number(Double(step.depth))
                callers.append(.object(object))
                if !step.node.path.isEmpty { callerFiles.insert(step.node.repo + "|" + step.node.path) }
            }
        }
        var importers: [JSONValue] = [], coChanging: [JSONValue] = [], tests: [JSONValue] = []
        if !fileID.isEmpty {
            for neighbor in try await store.neighbors(fileID, kinds: ["imports", "changes_with", "tests"], limit: 120) {
                switch (neighbor.edge.kind, neighbor.incoming) {
                case ("imports", true): importers.append(Self.json(neighbor.node))
                case ("changes_with", _): coChanging.append(["file": .string(neighbor.node.path), "times": .number(neighbor.edge.weight)])
                case ("tests", true): tests.append(.string(neighbor.node.path))
                default: break
                }
            }
        }
        // Tests of the callers' files too: they exercise this code indirectly.
        var indirectTests = Set<String>()
        for entry in callerFiles.prefix(25) {
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            let callerFile = "file:" + String(parts[0].dropFirst(5)) + "/" + (parts.count > 1 ? parts[1] : "")
            for neighbor in try await store.neighbors(callerFile, kinds: ["tests"], limit: 10) where neighbor.incoming {
                indirectTests.insert(neighbor.node.path)
            }
        }
        let experts = node.repo.isEmpty ? [] : try await store.experts(repo: node.repo, path: node.path, limit: 5)
        let flows = node.kind == "symbol" ? try await store.neighbors(node.id, kinds: ["step"], limit: 20).filter(\.incoming).map { JSONValue.string($0.node.name + ": " + $0.node.signature) } : []
        let decisions = fileID.isEmpty ? [] : try await store.neighbors(fileID, kinds: ["about"], limit: 10).filter(\.incoming).map { JSONValue.string($0.node.name) }
        return ["target": Self.json(node), "callers": .array(callers), "importers": .array(Array(importers.prefix(40))),
                "flows": .array(flows), "decisions": .array(decisions),
                "tests": .array(tests), "tests_of_callers": .array(indirectTests.sorted().prefix(30).map { .string($0) }),
                "changes_with": .array(Array(coChanging.sorted { ($0["times"]?.double ?? 0) > ($1["times"]?.double ?? 0) }.prefix(15))),
                "experts": .array(experts.map { ["name": .string($0.person.name), "commits": .number(Double($0.commits))] })]
    }

    func context(for question: String, limit: Int, store: KnowledgeStore) async throws -> JSONValue {
        // Studied things first (concepts, directories with notes), then code.
        var seen = Set<String>()
        var picked: [KnowledgeNode] = []
        for kinds in [["concept"], ["directory", "repo"], ["doc"], ["file", "symbol"], ["ticket", "pr", "note", "meeting"]] {
            for node in try await store.search(question, kinds: kinds, limit: limit) where seen.insert(node.id).inserted {
                picked.append(node)
            }
        }
        // Prefer what Claude has summarized, keep the order otherwise.
        let ranked = picked.enumerated().sorted { a, b in
            let (sa, sb) = (a.element.summary.isEmpty ? 1 : 0, b.element.summary.isEmpty ? 1 : 0)
            return sa != sb ? sa < sb : a.offset < b.offset
        }.map(\.element).prefix(limit)
        var results: [JSONValue] = []
        var directorySummaries: [String: String] = [:]
        for node in ranked {
            var object = Self.json(node).object ?? [:]
            if node.kind == "file" || node.kind == "symbol", !node.repo.isEmpty {
                let folder = (node.path as NSString).deletingLastPathComponent
                let key = node.repo + "/" + folder
                if directorySummaries[key] == nil {
                    directorySummaries[key] = (try await store.node("dir:" + String(node.repo.dropFirst(5)) + "/" + folder))?.summary ?? ""
                }
                if let summary = directorySummaries[key], !summary.isEmpty { object["directory_summary"] = .string(String(summary.prefix(400))) }
            }
            results.append(.object(object))
        }
        let unstudied = ranked.contains { ($0.kind == "file" || $0.kind == "symbol") && $0.summary.isEmpty }
        return ["question": .string(question), "matches": .array(results),
                "note": unstudied ? "Some matches are in code Dashii hasn't studied yet; knowledge_learn on that repository improves answers." : .null]
    }

    /// The relation read from the other end: "calls" seen from the callee is "called_by".
    static func inverse(_ kind: String) -> String {
        switch kind {
        case "contains": "contained_in"
        case "defines": "defined_in"
        case "imports": "imported_by"
        case "calls": "called_by"
        case "authored": "authored_by"
        case "touches": "touched_by"
        case "mentions": "mentioned_by"
        case "about": "discussed_in"
        case "changes_with": "changes_with"
        default: kind + "_of"
        }
    }

    /// Commits in the indexed repositories, from git (yours: your git email in each repository).
    var activitySeries: [ActivitySeries] {
        let repositories = repositories
        func commits(_ interval: DateInterval, mine: Bool) async -> [Date: Double] {
            await Task.detached(priority: .utility) {
                var dates: [Date] = []
                for path in repositories {
                    let root = URL(fileURLWithPath: path)
                    var arguments = ["log", "--all", "--no-merges", "--since=\(Int(interval.start.timeIntervalSince1970))",
                                     "--until=\(Int(interval.end.timeIntervalSince1970))", "--format=%ct"]
                    if mine {
                        guard let email = CodeIndexer.git(root, ["config", "user.email"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !email.isEmpty else { continue }
                        arguments.append("--author=\(email)")
                    }
                    let output = CodeIndexer.git(root, arguments) ?? ""
                    dates += output.split(separator: "\n").compactMap { Double($0).map(Date.init(timeIntervalSince1970:)) }
                }
                return ActivitySeries.countPerDay(dates, in: interval)
            }.value
        }
        return [
            ActivitySeries(id: "commits.mine", title: "My commits", unit: "commits", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                await commits($0, mine: true)
            },
            ActivitySeries(id: "commits.all", title: "All commits", unit: "commits", systemImage: "point.3.connected.trianglepath.dotted") {
                await commits($0, mine: false)
            },
        ]
    }

    var defaultRules: String? {
        """
        Before answering questions about the user's code or projects, look in the knowledge graph \
        (knowledge_overview, knowledge_search, knowledge_node) instead of guessing. Cite files with \
        their path and line.
        """
    }
}

import DashKit
import Foundation
import Observation

/// Runs git or jj in a repository with the user's login-shell environment (PATH, ssh-agent,
/// credential helpers), never prompting, with a timeout and capped output.
enum VCSRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    /// Characters kept from a command's output before it's cut.
    static let limit = 60_000

    nonisolated static func run(_ executable: String, _ arguments: [String], in directory: URL, timeout: TimeInterval = 60) async -> Output {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = ShellEnvironment.current.merging([
                "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "PAGER": "cat", "NO_COLOR": "1", "JJ_EDITOR": "true", "GIT_EDITOR": "true",
            ]) { $1 }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return Output(status: -1, stdout: "", stderr: error.localizedDescription) }
            // Read while it runs so a full pipe can't block the process.
            async let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { process.terminate() }
            let (o, e) = await (stdout, stderr)
            return Output(status: process.terminationStatus, stdout: cut(String(decoding: o, as: UTF8.self)), stderr: cut(String(decoding: e, as: UTF8.self)))
        }.value
    }

    nonisolated static func cut(_ text: String) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n… (output cut at \(limit) characters)" : text
    }

    /// The first executable named `name` on the login shell's PATH (plus Homebrew and Cargo folders).
    nonisolated static func find(_ name: String) -> String? {
        let path = (ShellEnvironment.current["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.cargo/bin", "\(home)/.local/bin", "\(home)/.nix-profile/bin"]
        for folder in path + extra {
            let candidate = (folder as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// How the user likes version control done, globally and per repository. Claude and the agents
/// read the effective preferences of a repository before changing it.
@MainActor
@Observable
final class VCSPreferences {
    static let shared = VCSPreferences()

    enum Tool: String, Codable, CaseIterable, Sendable {
        /// jj where the repository has a .jj folder, git elsewhere.
        case auto, git, jj
        var title: String { self == .auto ? "Automatic (jj when the repository uses it)" : self == .git ? "git" : "jj (Jujutsu)" }
    }

    /// Bringing a branch up to date with its base.
    enum Update: String, Codable, CaseIterable, Sendable {
        case rebase, merge
        var title: String { self == .rebase ? "Rebase onto the base" : "Merge the base in" }
    }

    /// `git pull`.
    enum Pull: String, Codable, CaseIterable, Sendable {
        case fastForwardOnly = "ff-only", rebase, merge
        var title: String { self == .fastForwardOnly ? "Fast-forward only" : self == .rebase ? "Rebase" : "Merge" }
    }

    struct Settings: Codable, Equatable, Sendable {
        var tool: Tool?
        var update: Update?
        var pull: Pull?
        /// Stash (git) local changes around an update.
        var autostash: Bool?
        /// The base branch (main, master, develop…); nil asks the repository.
        var base: String?
        /// Free-form conventions for commits and branches ("conventional commits", "TICKET-123 prefix"…).
        var conventions: String?

        static let defaults = Settings(tool: .auto, update: .rebase, pull: .fastForwardOnly, autostash: true, base: nil, conventions: nil)

        /// These settings with gaps filled from `fallback`.
        func over(_ fallback: Settings) -> Settings {
            Settings(tool: tool ?? fallback.tool, update: update ?? fallback.update, pull: pull ?? fallback.pull,
                     autostash: autostash ?? fallback.autostash, base: base ?? fallback.base,
                     conventions: conventions?.isEmpty == false ? conventions : fallback.conventions)
        }
    }

    var global: Settings { didSet { save() } }
    /// Repository path → its overrides (unset fields follow `global`).
    var repositories: [String: Settings] { didSet { save() } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = DashDefaults.shared) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        global = defaults.data(forKey: "vcs.global").flatMap { try? decoder.decode(Settings.self, from: $0) } ?? .defaults
        repositories = defaults.data(forKey: "vcs.repositories").flatMap { try? decoder.decode([String: Settings].self, from: $0) } ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(global), forKey: "vcs.global")
        defaults.set(try? encoder.encode(repositories), forKey: "vcs.repositories")
    }

    /// What applies in `repository`: its overrides over the global settings over the defaults.
    func effective(for repository: URL?) -> Settings {
        let base = global.over(.defaults)
        guard let repository, let own = repositories[repository.standardizedFileURL.path] else { return base }
        return own.over(base)
    }

    /// git or jj for this repository.
    func tool(for repository: URL) -> Tool {
        switch effective(for: repository).tool ?? .auto {
        case .auto: FileManager.default.fileExists(atPath: repository.appending(path: ".jj").path) ? .jj : .git
        case let chosen: chosen
        }
    }

    func json(for repository: URL?) -> JSONValue {
        let settings = effective(for: repository)
        var result: [String: JSONValue] = [
            "update_strategy": .string(settings.update?.rawValue ?? "rebase"), "pull": .string(settings.pull?.rawValue ?? "ff-only"),
            "autostash": .bool(settings.autostash ?? true), "base": settings.base.map(JSONValue.string) ?? .null,
            "conventions": settings.conventions.map(JSONValue.string) ?? .null,
            "overridden_for_this_repository": .bool(repository.map { repositories[$0.standardizedFileURL.path] != nil } ?? false),
        ]
        if let repository { result["tool"] = .string(tool(for: repository).rawValue); result["repository"] = .string(repository.path) }
        return .object(result)
    }
}

/// Turns what the user or Claude names ("dash", "~/code/fubo/api", "fubotv/api") into a checkout.
@MainActor
enum VCSRepository {
    static func resolve(_ text: String?, host: (any ExtensionContext)?) async throws -> URL {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ToolError("Say which repository (a path or its folder name).")
        }
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            var url = URL(fileURLWithPath: expanded)
            // A path inside a checkout: walk up to its root.
            while url.path != "/" {
                if FileManager.default.fileExists(atPath: url.appending(path: ".git").path) || FileManager.default.fileExists(atPath: url.appending(path: ".jj").path) { return url }
                url.deleteLastPathComponent()
            }
            throw ToolError("\(expanded) isn't inside a git or jj repository.")
        }
        let name = text.split(separator: "/").last.map(String.init) ?? text
        let known = (host?.extensions.compactMap { $0 as? KnowledgeExtension }.first?.repositories ?? []).map { URL(fileURLWithPath: $0) }
        if let match = known.first(where: { $0.lastPathComponent.lowercased() == name.lowercased() }) { return match }
        let roots = KnowledgeExtension.searchRoots
        let found = await Task.detached { KnowledgeExtension.findCheckouts(matching: name, roots: roots) }.value
            .filter { $0.lastPathComponent.lowercased() == name.lowercased() }
        if found.count == 1 { return found[0] }
        if found.count > 1 {
            if text.contains("/"), let match = found.first(where: { (KnowledgeExtension.originURL($0) ?? "").lowercased().contains(text.lowercased()) }) { return match }
            throw ToolError("Several checkouts are named \(name): \(found.map(\.path).joined(separator: ", ")). Give the path.")
        }
        throw ToolError("No checkout named \(name). Give its path (knowledge_find_repos lists checkouts).")
    }
}


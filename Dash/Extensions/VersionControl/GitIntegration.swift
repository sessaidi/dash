import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// git on this Mac: read the state and history of any local checkout, and change it the way the
/// user prefers (rebase or merge, per repository). Nothing is pushed.
@MainActor
@Observable
final class GitIntegration: Integration {
    let id = "git"
    let name = "Git"
    let systemImage = "arrow.triangle.branch"
    let metadata = ExtensionMetadata(version: "1.0.0", summary: "Local git repositories: status, history, diffs, blame and search for Claude, plus branch updates the way you prefer.",
                                     category: .sourceControl, homepage: "https://github.com/sessaidi/dash")

    private(set) var executable: String?
    private(set) var version: String?
    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    let preferences: VCSPreferences

    init(preferences: VCSPreferences = .shared) {
        self.preferences = preferences
    }

    var isConnected: Bool { executable != nil && version != nil }
    var connectionState: ConnectionState {
        guard let executable else { return .failed("git isn't installed. Install the Xcode command-line tools: xcode-select --install") }
        return version.map { .connected("\($0) · \(executable)") } ?? .checking
    }
    var connection: IntegrationConnection? { nil }
    var exports: JSONValue {
        ["executable": executable.map(JSONValue.string) ?? .null, "version": version.map(JSONValue.string) ?? .null, "preferences": preferences.json(for: nil)]
    }

    func start(host: any ExtensionContext) {
        self.host = host
        Task { await check() }
    }

    func check() async {
        executable = VCSRunner.find("git")
        guard let executable else { version = nil; return }
        let output = await VCSRunner.run(executable, ["--version"], in: FileManager.default.homeDirectoryForCurrentUser, timeout: 10)
        version = output.ok ? output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func settingsView() -> AnyView { AnyView(VersionControlSettings(title: "git", state: connectionState, preferences: preferences, host: host) { await self.check() }) }

    // MARK: Running

    private func git(_ arguments: [String], in repository: URL, timeout: TimeInterval = 60) async throws -> String {
        guard let executable else { throw ToolError("git isn't installed.") }
        let output = await VCSRunner.run(executable, arguments, in: repository, timeout: timeout)
        guard output.ok else { throw ToolError("git \(arguments.first ?? "") failed: \(output.stderr.isEmpty ? output.stdout : output.stderr)") }
        return output.stdout
    }

    private func repository(_ input: JSONValue) async throws -> URL {
        let url = try await VCSRepository.resolve(input["repo"]?.string, host: host)
        guard FileManager.default.fileExists(atPath: url.appending(path: ".git").path) else { throw ToolError("\(url.path) isn't a git repository (jj without git?).") }
        return url
    }

    /// The repository's base branch: the preference, else origin's HEAD, else main or master.
    func baseBranch(_ repository: URL) async -> String {
        if let base = preferences.effective(for: repository).base, !base.isEmpty { return base }
        if let head = try? await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repository) {
            return head.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "origin/", with: "")
        }
        for name in ["main", "master", "develop"] where (try? await git(["rev-parse", "--verify", "--quiet", name], in: repository)) != nil { return name }
        return "main"
    }

    /// `git log` with one record per commit.
    static let logFormat = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%D%x1f%s%x1e"

    nonisolated static func parseLog(_ text: String) -> [JSONValue] {
        text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { return nil }
            return ["sha": .string(fields[1]), "author": .string(fields[2]), "email": .string(fields[3]), "date": .string(fields[4]),
                    "refs": fields[5].isEmpty ? .null : .string(fields[5]), "subject": .string(fields[6])]
        }
    }

    /// `git status --porcelain=v2 --branch` as branch, upstream, ahead/behind and files.
    nonisolated static func parseStatus(_ text: String) -> JSONValue {
        var branch: String?, upstream: String?, ahead = 0, behind = 0
        var files: [JSONValue] = []
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("# branch.head ") { branch = String(line.dropFirst(14)) }
            else if line.hasPrefix("# branch.upstream ") { upstream = String(line.dropFirst(18)) }
            else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst(12).split(separator: " ")
                ahead = Int(parts.first?.dropFirst() ?? "") ?? 0
                behind = Int(parts.last?.dropFirst() ?? "") ?? 0
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let parts = line.split(separator: " ", maxSplits: line.hasPrefix("1 ") ? 8 : 9).map(String.init)
                let xy = parts[1]
                let path = parts.last.map { $0.components(separatedBy: "\t").first ?? $0 } ?? ""
                files.append(["path": .string(path), "staged": .string(String(xy.first ?? ".")), "unstaged": .string(String(xy.last ?? "."))])
            } else if line.hasPrefix("? ") {
                files.append(["path": .string(String(line.dropFirst(2))), "staged": "?", "unstaged": "?"])
            } else if line.hasPrefix("u ") {
                files.append(["path": .string(String(line.split(separator: " ").last ?? "")), "staged": "U", "unstaged": "U", "conflict": true])
            }
        }
        return ["branch": branch.map(JSONValue.string) ?? .null, "upstream": upstream.map(JSONValue.string) ?? .null,
                "ahead": .number(Double(ahead)), "behind": .number(Double(behind)), "clean": .bool(files.isEmpty), "files": .array(files)]
    }

    // MARK: Tools

    var tools: [DashiiTool] {
        let repo = JSONSchema.string("The repository: a path, or its folder name.")
        return [
            DashiiTool(name: "vcs_preferences", description: "How the user wants version control done in a repository (or globally): git or jj, rebase or merge to update a branch, how to pull, autostash, base branch, commit and branch conventions. Read before changing a repository.",
                       properties: ["repo": JSONSchema.string("The repository; omit for the global preferences.")]) { [weak self] input in
                guard let self else { return nil }
                let url = input["repo"]?.string == nil ? nil : try await VCSRepository.resolve(input["repo"]?.string, host: host)
                return preferences.json(for: url)
            },
            DashiiTool(name: "vcs_identity", description: "Who commits and how: git's user name, email and signing settings (globally or in a repository), the SSH hosts in ~/.ssh/config with their identity files, the SSH public keys, whether an ssh-agent is running, and GPG secret keys when gpg is installed. Private keys are never read. Read-only.",
                       properties: ["repo": JSONSchema.string("A repository, for its own config; omit for the global one.")]) { [weak self] input in
                guard let self else { return nil }
                let url = input["repo"]?.string == nil ? nil : try await VCSRepository.resolve(input["repo"]?.string, host: host)
                return await VCSIdentity.json(repository: url)
            },
            DashiiTool(name: "git_status", description: "A git repository's branch, upstream, ahead/behind counts and changed files (staged, unstaged, untracked, conflicted). Read-only.",
                       properties: ["repo": repo], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                let url = try await repository(input)
                return Self.parseStatus(try await git(["status", "--porcelain=v2", "--branch"], in: url)).merging(["repository": .string(url.path)])
            },
            DashiiTool(name: "git_log", description: "Commits, newest first: of a revision or range (e.g. main..HEAD), touching a path, by an author, since a date. Read-only.",
                       properties: ["repo": repo, "revision": JSONSchema.string("Revision or range (default HEAD)."), "path": JSONSchema.string("Only commits touching this path."),
                                    "author": JSONSchema.string("Author name or email."), "since": JSONSchema.string("e.g. 2.weeks or 2026-11-01."),
                                    "limit": JSONSchema.integer("How many (default 30, max 200).")], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                let url = try await repository(input)
                var arguments = ["log", "--format=\(Self.logFormat)", "-n", String(min(input["limit"]?.int ?? 30, 200))]
                if let author = input["author"]?.string { arguments.append("--author=\(author)") }
                if let since = input["since"]?.string { arguments.append("--since=\(since)") }
                if let revision = input["revision"]?.string { arguments.append(revision) }
                if let path = input["path"]?.string { arguments += ["--", path] }
                return .array(Self.parseLog(try await git(arguments, in: url)))
            },
            DashiiTool(name: "git_diff", description: "A diff: working tree changes (default), staged changes, or between revisions (e.g. main...HEAD for a branch's changes). Optionally one path, or only the file stats. Read-only.",
                       properties: ["repo": repo, "revision": JSONSchema.string("A revision or range; omit for uncommitted changes."), "staged": JSONSchema.boolean("Staged changes only."),
                                    "path": JSONSchema.string("Only this path."), "stat": JSONSchema.boolean("Only files and line counts.")], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                let url = try await repository(input)
                var arguments = ["diff", "--no-color", "--no-ext-diff"]
                if input["stat"]?.bool == true { arguments.append("--stat") }
                if input["staged"]?.bool == true { arguments.append("--cached") }
                if let revision = input["revision"]?.string { arguments.append(revision) }
                if let path = input["path"]?.string { arguments += ["--", path] }
                return .string(try await git(arguments, in: url))
            },
            DashiiTool(name: "git_show", description: "One commit: message, author, files changed and its patch. Read-only.",
                       properties: ["repo": repo, "revision": JSONSchema.string("Commit, tag or branch (default HEAD).")], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                return .string(try await git(["show", "--no-color", "--stat", "--patch", input["revision"]?.string ?? "HEAD"], in: try await repository(input)))
            },
            DashiiTool(name: "git_branches", description: "Local and remote branches, most recently committed first, with their last commit and upstream tracking. Read-only.",
                       properties: ["repo": repo, "remote": JSONSchema.boolean("Include remote branches (default true).")], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                let url = try await repository(input)
                let refs = input["remote"]?.bool == false ? ["refs/heads"] : ["refs/heads", "refs/remotes"]
                let text = try await git(["for-each-ref", "--sort=-committerdate", "--count=100",
                                          "--format=%(refname:short)%1f%(objectname:short)%1f%(committerdate:iso-strict)%1f%(authorname)%1f%(upstream:short)%1f%(upstream:track)%1f%(HEAD)%1f%(contents:subject)"] + refs, in: url)
                return .array(text.split(separator: "\n").map { line in
                    let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 8 else { return .string(String(line)) }
                    return ["name": .string(f[0]), "sha": .string(f[1]), "date": .string(f[2]), "author": .string(f[3]),
                            "upstream": f[4].isEmpty ? .null : .string(f[4]), "tracking": f[5].isEmpty ? .null : .string(f[5]),
                            "current": .bool(f[6] == "*"), "subject": .string(f[7])]
                })
            },
            DashiiTool(name: "git_blame", description: "Who last changed each line of a file (a line range keeps it short), with the commit and date. Read-only.",
                       properties: ["repo": repo, "path": JSONSchema.string("File path in the repository."),
                                    "start": JSONSchema.integer("First line."), "end": JSONSchema.integer("Last line.")], required: ["repo", "path"]) { [weak self] input in
                guard let self else { return nil }
                var arguments = ["blame", "--date=short"]
                if let start = input["start"]?.int { arguments += ["-L", "\(start),\(input["end"]?.int ?? start + 40)"] }
                return .string(try await git(arguments + ["--", input["path"]?.string ?? ""], in: try await repository(input)))
            },
            DashiiTool(name: "git_grep", description: "Search tracked files for a pattern (git grep), with line numbers. Read-only.",
                       properties: ["repo": repo, "pattern": JSONSchema.string("Text or regular expression."), "path": JSONSchema.string("Only under this path."),
                                    "ignore_case": JSONSchema.boolean("Case-insensitive.")], required: ["repo", "pattern"]) { [weak self] input in
                guard let self else { return nil }
                var arguments = ["grep", "-n", "-I", "--no-color", "-E", "--max-count=20"]
                if input["ignore_case"]?.bool == true { arguments.append("-i") }
                arguments += ["-e", input["pattern"]?.string ?? ""]
                if let path = input["path"]?.string { arguments += ["--", path] }
                let url = try await repository(input)
                guard let executable else { throw ToolError("git isn't installed.") }
                let output = await VCSRunner.run(executable, arguments, in: url)
                // git grep exits 1 when nothing matches.
                return .string(output.status == 1 ? "No matches." : output.ok ? output.stdout : "git grep failed: \(output.stderr)")
            },
            DashiiTool(name: "git_fetch", description: "Fetch from the remotes (updates remote branches only; nothing local changes, nothing is pushed).",
                       properties: ["repo": repo], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                _ = try await git(["fetch", "--all", "--prune", "--quiet"], in: try await repository(input), timeout: 180)
                return "fetched"
            },
            DashiiTool(name: "git_update_branch", description: "Bring the current branch up to date with its base the way the user prefers for this repository (rebase onto, or merge, origin/<base>; see vcs_preferences). Fetches first. Stops and reports on conflicts. Nothing is pushed.",
                       properties: ["repo": repo, "base": JSONSchema.string("Base branch; default from the preferences or origin's HEAD.")],
                       required: ["repo"], requiresApproval: true) { [weak self] input in
                guard let self else { return nil }
                let url = try await repository(input)
                let settings = preferences.effective(for: url)
                let fallback = await baseBranch(url)
                let base = input["base"]?.string ?? fallback
                _ = try await git(["fetch", "--quiet", "origin", base], in: url, timeout: 180)
                let strategy = settings.update ?? .rebase
                var arguments = strategy == .rebase ? ["rebase"] : ["merge", "--no-edit"]
                if settings.autostash ?? true { arguments.append("--autostash") }
                arguments.append("origin/\(base)")
                guard let executable else { throw ToolError("git isn't installed.") }
                let output = await VCSRunner.run(executable, arguments, in: url, timeout: 300)
                if !output.ok {
                    let status = Self.parseStatus((try? await git(["status", "--porcelain=v2", "--branch"], in: url)) ?? "")
                    return ["ok": false, "strategy": .string(strategy.rawValue), "base": .string(base),
                            "message": .string(output.stderr.isEmpty ? output.stdout : output.stderr), "status": status,
                            "next": .string(strategy == .rebase ? "Resolve the conflicts then git rebase --continue, or git rebase --abort."
                                                                 : "Resolve the conflicts and commit, or git merge --abort.")]
                }
                return ["ok": true, "strategy": .string(strategy.rawValue), "base": .string(base), "output": .string(output.stdout)]
            },
            DashiiTool(name: "git_create_branch", description: "Create a branch and switch to it, from the base or a given revision. Follows the repository's branch conventions (vcs_preferences).",
                       properties: ["repo": repo, "name": JSONSchema.string("Branch name."), "from": JSONSchema.string("Start point (default: the current commit).")],
                       required: ["repo", "name"], requiresApproval: true) { [weak self] input in
                guard let self else { return nil }
                guard let name = input["name"]?.string, !name.isEmpty else { throw ToolError("Missing name") }
                var arguments = ["switch", "-c", name]
                if let from = input["from"]?.string { arguments.append(from) }
                _ = try await git(arguments, in: try await repository(input))
                return ["branch": .string(name)]
            },
            DashiiTool(name: "git_commit", description: "Commit changes: the given paths, or everything changed (including new files) when none are given. Follows the repository's commit conventions (vcs_preferences). Nothing is pushed. " + VCSAuthorship.rule,
                       properties: ["repo": repo, "message": JSONSchema.string("The commit message."),
                                    "paths": ["type": "array", "items": ["type": "string"], "description": "Files to commit; omit for all changes."]],
                       required: ["repo", "message"], requiresApproval: true) { [weak self] input in
                guard let self else { return nil }
                guard let message = input["message"].flatMap(\.string).map(VCSAuthorship.soleAuthor), !message.isEmpty else { throw ToolError("Missing message") }
                let url = try await repository(input)
                let paths = input["paths"]?.array?.compactMap(\.string) ?? []
                _ = try await git(paths.isEmpty ? ["add", "-A"] : ["add", "--"] + paths, in: url)
                _ = try await git(["commit", "-m", message], in: url)
                return .array(Self.parseLog(try await git(["log", "-1", "--format=\(Self.logFormat)"], in: url)))
            },
        ]
    }
}

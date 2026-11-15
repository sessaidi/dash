import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Jujutsu (jj) on this Mac: the change log, diffs, operations and bookmarks of jj repositories
/// for Claude, and new changes, descriptions and rebases the way the user prefers. Nothing is pushed.
@MainActor
@Observable
final class JujutsuIntegration: Integration {
    let id = "jj"
    let name = "Jujutsu"
    let systemImage = "point.topleft.down.to.point.bottomright.curvepath"
    let metadata = ExtensionMetadata(version: "1.0.0", summary: "Local jj repositories: changes, diffs, operation log and bookmarks for Claude, plus new changes and rebases the way you prefer.",
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
        guard let executable else { return .failed("jj isn't installed. brew install jj") }
        return version.map { .connected("\($0) · \(executable)") } ?? .checking
    }
    var connection: IntegrationConnection? { nil }
    var exports: JSONValue { ["executable": executable.map(JSONValue.string) ?? .null, "version": version.map(JSONValue.string) ?? .null] }

    func start(host: any ExtensionContext) {
        self.host = host
        Task { await check() }
    }

    func check() async {
        executable = VCSRunner.find("jj")
        guard let executable else { version = nil; return }
        let output = await VCSRunner.run(executable, ["--version"], in: FileManager.default.homeDirectoryForCurrentUser, timeout: 10)
        version = output.ok ? output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func settingsView() -> AnyView { AnyView(VersionControlSettings(title: "jj", state: connectionState, preferences: preferences, host: host) { await self.check() }) }

    private func jj(_ arguments: [String], in repository: URL, timeout: TimeInterval = 60) async throws -> String {
        guard let executable else { throw ToolError("jj isn't installed (brew install jj).") }
        let output = await VCSRunner.run(executable, ["--no-pager", "--color=never"] + arguments, in: repository, timeout: timeout)
        guard output.ok else { throw ToolError("jj \(arguments.first ?? "") failed: \(output.stderr.isEmpty ? output.stdout : output.stderr)") }
        return output.stdout
    }

    private func repository(_ input: JSONValue) async throws -> URL {
        let url = try await VCSRepository.resolve(input["repo"]?.string, host: host)
        guard FileManager.default.fileExists(atPath: url.appending(path: ".jj").path) else {
            throw ToolError("\(url.path) isn't a jj repository. Use the git tools, or run jj git init --colocate there first.")
        }
        return url
    }

    /// One record per change: change id, commit id, author, date, bookmarks, flags, first line.
    static let logTemplate = #"change_id.short() ++ "\x1f" ++ commit_id.short() ++ "\x1f" ++ author.email() ++ "\x1f" ++ author.timestamp() ++ "\x1f" ++ bookmarks.join(",") ++ "\x1f" ++ if(empty, "empty", "") ++ if(conflict, " conflict", "") ++ if(current_working_copy, " @", "") ++ "\x1f" ++ description.first_line() ++ "\x1e""#

    nonisolated static func parseLog(_ text: String) -> [JSONValue] {
        text.split(separator: "\u{1e}").compactMap { record in
            let f = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { return nil }
            let flags = f[5].split(separator: " ").map(String.init)
            return ["change": .string(f[0]), "commit": .string(f[1]), "author": .string(f[2]), "date": .string(f[3]),
                    "bookmarks": .array(f[4].split(separator: ",").map { .string(String($0)) }),
                    "empty": .bool(flags.contains("empty")), "conflict": .bool(flags.contains("conflict")), "working_copy": .bool(flags.contains("@")),
                    "description": f[6].isEmpty ? .null : .string(f[6])]
        }
    }

    var tools: [DashiiTool] {
        let repo = JSONSchema.string("The repository: a path, or its folder name.")
        return [
            DashiiTool(name: "jj_status", description: "The working-copy change, its parent and changed files, and any conflicts (jj status). Read-only.",
                       properties: ["repo": repo], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                return .string(try await jj(["status"], in: try await repository(input)))
            },
            DashiiTool(name: "jj_log", description: "Changes matching a revset (default: jj's default log), newest first, with change and commit ids, bookmarks, and empty/conflict flags. Read-only.",
                       properties: ["repo": repo, "revset": JSONSchema.string("e.g. ::@, trunk()..@, mine(), bookmarks()."), "limit": JSONSchema.integer("How many (default 30).")],
                       required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                let url = try await repository(input)
                var arguments = ["log", "--no-graph", "-n", String(min(input["limit"]?.int ?? 30, 200)), "-T", Self.logTemplate]
                if let revset = input["revset"]?.string { arguments += ["-r", revset] }
                do { return .array(Self.parseLog(try await jj(arguments, in: url))) }
                // Older jj without some template keywords: the plain log.
                catch { return .string(try await jj(["log", "--no-graph", "-n", "30"] + (input["revset"]?.string.map { ["-r", $0] } ?? []), in: url)) }
            },
            DashiiTool(name: "jj_diff", description: "A change's diff in git format (default the working copy @), optionally one path or only stats. Read-only.",
                       properties: ["repo": repo, "revision": JSONSchema.string("Change or revset (default @)."), "from": JSONSchema.string("Compare from this revision instead."),
                                    "path": JSONSchema.string("Only this path."), "stat": JSONSchema.boolean("Only files and line counts.")], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                var arguments = ["diff", input["stat"]?.bool == true ? "--stat" : "--git"]
                if let from = input["from"]?.string { arguments += ["--from", from, "--to", input["revision"]?.string ?? "@"] }
                else { arguments += ["-r", input["revision"]?.string ?? "@"] }
                if let path = input["path"]?.string { arguments.append(path) }
                return .string(try await jj(arguments, in: try await repository(input)))
            },
            DashiiTool(name: "jj_show", description: "One change: description, author and its diff. Read-only.",
                       properties: ["repo": repo, "revision": JSONSchema.string("Change id or revset (default @).")], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                return .string(try await jj(["show", "--git", input["revision"]?.string ?? "@"], in: try await repository(input)))
            },
            DashiiTool(name: "jj_op_log", description: "Recent jj operations (what changed the repository, undoable with jj undo). Read-only.",
                       properties: ["repo": repo, "limit": JSONSchema.integer("How many (default 20).")], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                return .string(try await jj(["op", "log", "--no-graph", "-n", String(min(input["limit"]?.int ?? 20, 100))], in: try await repository(input)))
            },
            DashiiTool(name: "jj_bookmarks", description: "Bookmarks (jj's branches), local and remote, with their targets and tracking. Read-only.",
                       properties: ["repo": repo], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                return .string(try await jj(["bookmark", "list", "--all-remotes"], in: try await repository(input)))
            },
            DashiiTool(name: "jj_fetch", description: "Fetch from the git remotes (jj git fetch). Nothing is pushed.",
                       properties: ["repo": repo], required: ["repo"]) { [weak self] input in
                guard let self else { return nil }
                return .string(try await jj(["git", "fetch"], in: try await repository(input), timeout: 180))
            },
            DashiiTool(name: "jj_new", description: "Start a new change (on @, or on the given revisions; several parents make a merge), optionally with a description. " + VCSAuthorship.rule,
                       properties: ["repo": repo, "parents": ["type": "array", "items": ["type": "string"], "description": "Parent revisions (default @)."],
                                    "message": JSONSchema.string("Description.")], required: ["repo"], requiresApproval: true) { [weak self] input in
                guard let self else { return nil }
                var arguments = ["new"] + (input["parents"]?.array?.compactMap(\.string) ?? [])
                if let message = input["message"]?.string { arguments += ["-m", VCSAuthorship.soleAuthor(message)] }
                return .string(try await jj(arguments, in: try await repository(input)))
            },
            DashiiTool(name: "jj_describe", description: "Set a change's description (default @). Follows the repository's commit conventions (vcs_preferences). " + VCSAuthorship.rule,
                       properties: ["repo": repo, "revision": JSONSchema.string("Change (default @)."), "message": JSONSchema.string("The description.")],
                       required: ["repo", "message"], requiresApproval: true) { [weak self] input in
                guard let self else { return nil }
                return .string(try await jj(["describe", "-r", input["revision"]?.string ?? "@", "-m", VCSAuthorship.soleAuthor(input["message"]?.string ?? "")], in: try await repository(input)))
            },
            DashiiTool(name: "jj_bookmark_set", description: "Point a bookmark at a change (default @), creating it if needed. Follows the repository's branch conventions.",
                       properties: ["repo": repo, "name": JSONSchema.string("Bookmark name."), "revision": JSONSchema.string("Change (default @).")],
                       required: ["repo", "name"], requiresApproval: true) { [weak self] input in
                guard let self else { return nil }
                return .string(try await jj(["bookmark", "set", input["name"]?.string ?? "", "-r", input["revision"]?.string ?? "@", "--allow-backwards"], in: try await repository(input)))
            },
            DashiiTool(name: "jj_update", description: "Bring the current work up to date with the base the way the user prefers (vcs_preferences): rebase the stack onto <base>@origin, or merge it in with a new change on both. Fetches first. Conflicts are recorded in the changes, not blocking.",
                       properties: ["repo": repo, "base": JSONSchema.string("Base bookmark (default from the preferences, else trunk()).")],
                       required: ["repo"], requiresApproval: true) { [weak self] input in
                guard let self else { return nil }
                let url = try await repository(input)
                _ = try await jj(["git", "fetch"], in: url, timeout: 180)
                let settings = preferences.effective(for: url)
                let base = input["base"]?.string ?? settings.base.map { "\($0)@origin" } ?? "trunk()"
                let strategy = settings.update ?? .rebase
                let output = strategy == .rebase
                    ? try await jj(["rebase", "-b", "@", "-d", base], in: url)
                    : try await jj(["new", "@", base, "-m", "Merge \(base)"], in: url)
                let conflicts = (try? await jj(["log", "--no-graph", "-r", "conflicts() & ::@", "-T", #"change_id.short() ++ "\n""#], in: url)) ?? ""
                return ["strategy": .string(strategy.rawValue), "base": .string(base), "output": .string(output),
                        "conflicted_changes": .array(conflicts.split(separator: "\n").map { .string(String($0)) })]
            },
        ]
    }
}

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

/// Turns what the user or Claude names ("dash", "~/code/acme/api", "acme/api") into a checkout.
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

/// Who commits and how: the SSH setup from ~/.ssh (config hosts and public keys; private keys are
/// never read) and commit signing (git's signing settings, and GPG secret keys when gpg is installed).
enum VCSIdentity {
    struct SSHHost: Equatable, Sendable {
        var patterns: [String]
        var hostName: String?
        var user: String?
        var port: String?
        var identityFiles: [String] = []
        var identitiesOnly: Bool?

        var json: JSONValue {
            ["host": .string(patterns.joined(separator: " ")), "hostname": hostName.map(JSONValue.string) ?? .null,
             "user": user.map(JSONValue.string) ?? .null, "port": port.map(JSONValue.string) ?? .null,
             "identity_files": .array(identityFiles.map { .string($0) }), "identities_only": identitiesOnly.map(JSONValue.bool) ?? .null]
        }
    }

    struct GPGKey: Equatable, Sendable {
        let id: String
        let algorithm: String
        let expires: Date?
        var users: [String]
    }

    static var sshFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh") }

    /// `Host` blocks of an ssh config (Include lines are followed one level, relative to ~/.ssh).
    nonisolated static func parseSSHConfig(_ text: String, include: (String) -> String? = { _ in nil }) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var current: SSHHost?
        func flush() { if let current { hosts.append(current) } }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // "Key value", "Key=value" or "Key = value".
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "=" || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " =\t\""))
            switch key {
            case "host":
                flush()
                current = SSHHost(patterns: value.split(separator: " ").map(String.init))
            case "match":
                flush()
                current = SSHHost(patterns: ["match " + value])
            case "include":
                for file in value.split(separator: " ") {
                    if let included = include(String(file)) { flush(); current = nil; hosts += parseSSHConfig(included) }
                }
            case "hostname": current?.hostName = value
            case "user": current?.user = value
            case "port": current?.port = value
            case "identityfile": current?.identityFiles.append(value)
            case "identitiesonly": current?.identitiesOnly = value.lowercased() == "yes"
            default: break
            }
        }
        flush()
        return hosts
    }

    static func sshHosts() -> [SSHHost] {
        guard let text = try? String(contentsOf: sshFolder.appending(path: "config"), encoding: .utf8) else { return [] }
        return parseSSHConfig(text) { file in
            let path = (file as NSString).expandingTildeInPath
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : sshFolder.appending(path: path)
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The public keys in ~/.ssh: file, type and comment (the private halves are left alone).
    static func sshPublicKeys() -> [JSONValue] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sshFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pub" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
            return ["file": .string(url.path), "type": .string(parts.first ?? "?"), "comment": parts.count > 2 ? .string(parts[2]) : .null]
        }
    }

    /// `gpg --list-secret-keys --with-colons`: secret keys with their user ids and expiry.
    nonisolated static func parseGPG(_ text: String) -> [GPGKey] {
        var keys: [GPGKey] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let kind = f.first else { continue }
            if kind == "sec", f.count > 6 {
                let algorithm = ["1": "RSA", "17": "DSA", "18": "ECDH", "19": "ECDSA", "22": "EdDSA"][f[3]] ?? f[3]
                keys.append(GPGKey(id: f[4], algorithm: algorithm, expires: Double(f[6]).map { Date(timeIntervalSince1970: $0) }, users: []))
            } else if kind == "uid", f.count > 9, !keys.isEmpty {
                keys[keys.count - 1].users.append(f[9])
            }
        }
        return keys
    }

    static func gpgKeys() async -> [GPGKey]? {
        guard let gpg = VCSRunner.find("gpg") else { return nil }
        let output = await VCSRunner.run(gpg, ["--list-secret-keys", "--with-colons"], in: FileManager.default.homeDirectoryForCurrentUser, timeout: 15)
        return output.ok ? parseGPG(output.stdout) : []
    }

    /// git's identity and signing settings, in a repository (its own config over the global one) or globally.
    static func gitSettings(in repository: URL?) async -> [String: String] {
        guard let git = VCSRunner.find("git") else { return [:] }
        var result: [String: String] = [:]
        for key in ["user.name", "user.email", "user.signingkey", "commit.gpgsign", "tag.gpgsign", "gpg.format", "gpg.ssh.allowedSignersFile", "pull.rebase", "rebase.autoStash", "init.defaultBranch"] {
            let arguments = (repository == nil ? ["config", "--global", "--get", key] : ["config", "--get", key])
            let output = await VCSRunner.run(git, arguments, in: repository ?? FileManager.default.homeDirectoryForCurrentUser, timeout: 10)
            if output.ok { result[key] = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return result
    }

    /// Everything above as one JSON object, for Claude.
    static func json(repository: URL?) async -> JSONValue {
        let git = await gitSettings(in: repository)
        let gpg = await gpgKeys()
        let signing: JSONValue = [
            "enabled": .bool(git["commit.gpgsign"] == "true"), "format": .string(git["gpg.format"] ?? "openpgp"),
            "key": git["user.signingkey"].map(JSONValue.string) ?? .null,
        ]
        return ["git": .object(git.mapValues(JSONValue.string)), "signing": signing,
                "ssh_hosts": .array(sshHosts().map(\.json)), "ssh_public_keys": .array(sshPublicKeys()),
                "ssh_agent": .bool(ShellEnvironment.current["SSH_AUTH_SOCK"] != nil),
                "gpg_keys": gpg.map { .array($0.map { key in
                    ["id": .string(key.id), "algorithm": .string(key.algorithm), "users": .array(key.users.map { .string($0) }),
                     "expires": key.expires.map { .string($0.formatted(.iso8601)) } ?? .null]
                }) } ?? "gpg isn't installed"]
    }
}

/// The user is the sole author of every commit Dash makes: no co-author trailers, no
/// "Generated with" attribution, whatever the message Claude wrote.
enum VCSAuthorship {
    /// Lines removed from commit messages (case-insensitive prefixes, after trimming).
    static let forbidden = ["co-authored-by:", "co-developed-by:", "generated-by:", "assisted-by:"]

    nonisolated static func soleAuthor(_ message: String) -> String {
        let kept = message.split(separator: "\n", omittingEmptySubsequences: false).filter { raw in
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if forbidden.contains(where: { line.hasPrefix($0) }) { return false }
            // "🤖 Generated with [Claude Code](…)" and the like.
            let plain = line.drop { !$0.isLetter }
            return !(plain.hasPrefix("generated with") && (plain.contains("claude") || plain.contains("ai")))
        }
        // Drop the blank lines the removed trailers leave at the end.
        var lines = kept.map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Said in every commit-making tool's description.
    static let rule = "The user is the sole author: never add Co-Authored-By or other attribution trailers, nor \"Generated with\" lines (they are removed anyway)."
}

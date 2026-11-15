import DashKit
import Foundation
import Testing
@testable import Dash

@MainActor
@Suite("Version control")
struct VersionControlTests {
    func temp() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "dash-vcs-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) async throws -> String {
        let output = await VCSRunner.run(try #require(VCSRunner.find("git")), arguments, in: directory)
        #expect(output.ok, "git \(arguments.joined(separator: " ")): \(output.stderr)")
        return output.stdout
    }

    @Test func parsesStatusAndLog() {
        let status = GitIntegration.parseStatus("""
            # branch.oid abc
            # branch.head feature/x
            # branch.upstream origin/feature/x
            # branch.ab +2 -1
            1 .M N... 100644 100644 100644 aaa bbb Sources/App.swift
            1 A. N... 000000 100644 100644 000 ccc New file.txt
            ? notes.md
            """)
        #expect(status["branch"] == "feature/x" && status["upstream"] == "origin/feature/x")
        #expect(status["ahead"] == 2 && status["behind"] == 1 && status["clean"] == false)
        #expect(status["files"]?.array?.compactMap { $0["path"]?.string } == ["Sources/App.swift", "New file.txt", "notes.md"])
        #expect(status["files"]?[1]?["staged"] == "A")
        let log = GitIntegration.parseLog("abc123\u{1f}abc\u{1f}Ada\u{1f}ada@x.io\u{1f}2026-11-14T10:00:00+01:00\u{1f}HEAD -> main\u{1f}Fix the thing\u{1e}\n")
        #expect(log.first?["subject"] == "Fix the thing" && log.first?["refs"] == "HEAD -> main")
        let jj = JujutsuIntegration.parseLog("kxyz\u{1f}1a2b\u{1f}ada@x.io\u{1f}2026-11-14\u{1f}main,feature\u{1f}empty @\u{1f}\u{1e}")
        #expect(jj.first?["bookmarks"] == ["main", "feature"] && jj.first?["empty"] == true && jj.first?["working_copy"] == true && jj.first?["description"] == .null)
    }

    @Test func readsSSHConfigAndGPG() {
        let hosts = VCSIdentity.parseSSHConfig("""
            # personal
            Host github.com
              HostName github.com
              User git
              IdentityFile ~/.ssh/id_ed25519
              IdentitiesOnly yes
            Host work-gh
                HostName=github.com
                IdentityFile = ~/.ssh/work
                Port 443
            Include extra
            """) { $0 == "extra" ? "Host bastion\n  HostName 10.0.0.1\n  User ops" : nil }
        #expect(hosts.map(\.patterns) == [["github.com"], ["work-gh"], ["bastion"]])
        #expect(hosts[0].user == "git" && hosts[0].identityFiles == ["~/.ssh/id_ed25519"] && hosts[0].identitiesOnly == true)
        #expect(hosts[1].hostName == "github.com" && hosts[1].port == "443" && hosts[1].identityFiles == ["~/.ssh/work"])
        #expect(hosts[2].hostName == "10.0.0.1")
        let keys = VCSIdentity.parseGPG("""
            sec:u:255:22:ABCDEF0123456789:1700000000:1800000000::u:::scESC:::+:::23::0:
            fpr:::::::::0123ABCDEF0123456789:
            uid:u::::1700000000::HASH::Ada Lovelace <ada@x.io>::::::::::0:
            """)
        #expect(keys.first?.id == "ABCDEF0123456789" && keys.first?.algorithm == "EdDSA" && keys.first?.users == ["Ada Lovelace <ada@x.io>"])
    }

    @Test func preferencesLayerPerRepository() throws {
        let preferences = VCSPreferences(defaults: UserDefaults(suiteName: "vcs-\(UUID())")!)
        let repo = temp(), jjRepo = temp()
        try FileManager.default.createDirectory(at: jjRepo.appending(path: ".jj"), withIntermediateDirectories: true)
        #expect(preferences.effective(for: repo).update == .rebase && preferences.tool(for: repo) == .git && preferences.tool(for: jjRepo) == .jj)
        preferences.global.update = .merge
        preferences.repositories[repo.path] = VCSPreferences.Settings(tool: .jj, update: .rebase, conventions: "conventional commits")
        #expect(preferences.effective(for: repo).update == .rebase && preferences.effective(for: jjRepo).update == .merge)
        #expect(preferences.tool(for: repo) == .jj)
        #expect(preferences.json(for: repo)["conventions"] == "conventional commits" && preferences.json(for: repo)["overridden_for_this_repository"] == true)
    }

    /// A clone with one local commit, behind its origin by one commit.
    func divergedClone() async throws -> (origin: URL, clone: URL) {
        let root = temp()
        let origin = root.appending(path: "origin.git"), seed = root.appending(path: "seed"), clone = root.appending(path: "work")
        try await git(["init", "--bare", "-b", "main", origin.path], in: root)
        try await git(["clone", "--quiet", origin.path, seed.path], in: root)
        for directory in [seed] { try await git(["config", "user.email", "t@x.io"], in: directory); try await git(["config", "user.name", "T"], in: directory) }
        try "one\n".write(to: seed.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: seed); try await git(["commit", "-qm", "one"], in: seed); try await git(["push", "-q", "origin", "main"], in: seed)
        try await git(["clone", "--quiet", origin.path, clone.path], in: root)
        try await git(["config", "user.email", "t@x.io"], in: clone); try await git(["config", "user.name", "T"], in: clone)
        try "upstream\n".write(to: seed.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: seed); try await git(["commit", "-qm", "upstream"], in: seed); try await git(["push", "-q", "origin", "main"], in: seed)
        return (origin, clone)
    }

    @Test(arguments: [VCSPreferences.Update.rebase, .merge])
    func toolsFollowTheUpdatePreference(strategy: VCSPreferences.Update) async throws {
        let preferences = VCSPreferences(defaults: UserDefaults(suiteName: "vcs-\(UUID())")!)
        let git = GitIntegration(preferences: preferences)
        await git.check()
        let (_, clone) = try await divergedClone()
        preferences.repositories[clone.path] = VCSPreferences.Settings(update: strategy)
        func tool(_ name: String) throws -> DashiiTool { try #require(git.tools.first { $0.name == name }) }

        try "mine\n".write(to: clone.appending(path: "c.txt"), atomically: true, encoding: .utf8)
        let status = try await tool("git_status").run(["repo": .string(clone.path)])
        #expect(status["branch"] == "main" && status["clean"] == false)
        let committed = try await tool("git_commit").run(["repo": .string(clone.path), "message": "mine\n\nCo-Authored-By: Claude <noreply@anthropic.com>"])
        #expect(committed[0]?["subject"] == "mine")
        let body = try await self.git(["log", "-1", "--format=%B"], in: clone)
        #expect(!body.lowercased().contains("co-authored-by"))

        let result = try await tool("git_update_branch").run(["repo": .string(clone.path)])
        #expect(result["ok"] == true && result["strategy"] == .string(strategy.rawValue) && result["base"] == "main")
        let subjects = try await tool("git_log").run(["repo": .string(clone.path)]).array?.compactMap { $0["subject"]?.string } ?? []
        if strategy == .rebase {
            #expect(subjects == ["mine", "upstream", "one"])
        } else {
            #expect(subjects.first?.hasPrefix("Merge") == true && subjects.contains("mine") && subjects.contains("upstream"))
        }
        let diff = try await tool("git_diff").run(["repo": .string(clone.path), "revision": "HEAD~1", "stat": true])
        #expect(diff.string?.isEmpty == false)
    }

    @Test func messagesKeepTheUserAsSoleAuthor() {
        let message = """
            feat: add retries to the client

            Backs off exponentially.

            🤖 Generated with [Claude Code](https://claude.com/claude-code)

            Co-Authored-By: Claude <noreply@anthropic.com>
            co-authored-by: Someone <s@x.io>
            """
        #expect(VCSAuthorship.soleAuthor(message) == "feat: add retries to the client\n\nBacks off exponentially.")
        // Ordinary lines that merely mention these words stay.
        #expect(VCSAuthorship.soleAuthor("docs: explain co-authored-by handling") == "docs: explain co-authored-by handling")
    }

    @Test func builtInAndOffered() throws {
        let ids = ExtensionHost.builtInExtensions().map(\.id)
        #expect(ids.contains("git") && ids.contains("jj"))
        let jj = JujutsuIntegration()
        #expect(jj.tools.filter(\.requiresApproval).map(\.name) == ["jj_new", "jj_describe", "jj_bookmark_set", "jj_update"])
        #expect(GitIntegration().tools.filter(\.requiresApproval).map(\.name) == ["git_update_branch", "git_create_branch", "git_commit"])
    }
}

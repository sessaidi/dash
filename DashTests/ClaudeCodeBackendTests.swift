import DashKit
import DashKitUI
import Foundation
import Testing
@testable import Dash

/// The Claude Code backend against the stream-json fake CLI (no real Claude).
@MainActor
@Suite(.serialized)
struct ClaudeCodeBackendTests {
    private func fakeCLI() throws -> String {
        let source = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake-claude.py")
        let target = FileManager.default.temporaryDirectory.appending(path: "fake-claude-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target.path
    }

    private func host() throws -> ExtensionHost {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!)
        settings.claudePath = try fakeCLI()
        return try ExtensionHost(settings: settings, extensions: ExtensionHost.builtInExtensions(), inMemory: true)
    }

    @Test func serviceReturnsStructuredOutput() async throws {
        let host = try host()
        #expect(host.claude is ClaudeCodeService)
        let text = try await host.claude.complete(system: "s", prompt: "ping", outputSchema: ["type": "object"])
        #expect(try JSONValue.parse(text) == ["echo": "ping"])
    }

    @Test func chatRunsDashToolsThroughMCP() async throws {
        let host = try host()
        host.dashboard.migrate()
        let chat = ChatSession(host: host)
        chat.send("hello")
        for _ in 0..<200 where chat.isRunning || chat.transcript.count < 2 { try await Task.sleep(for: .milliseconds(25)) }
        let texts = chat.transcript.compactMap { entry -> String? in if case .text(let text) = entry.kind { return text }; return nil }
        // The fake echoes the prompt: the activity digest leads it, the user's text ends it.
        #expect(texts.contains { $0.hasPrefix("echo: <dashboard-activity>") && $0.contains("Created page “Home”") && $0.hasSuffix("hello") })
        #expect(!chat.isRunning)
        #expect(chat.trace.last?.model.contains("Claude Code") == true)
    }

    /// Dashii and Dash agents get no shell, and remote-writing commands are denied on top.
    @Test func defaultsDenyShellAndRemoteWrites() throws {
        let options = ClaudeCodeDefaults.options(settings: try host().settings, system: "s")
        #expect(options.tools == [])
        for rule in ["Bash(gh:*)", "Bash(glab:*)", "Bash(curl:*)", "Bash(git push:*)"] { #expect(options.disallowedTools.contains(rule)) }
        #expect(options.arguments.contains("--disallowedTools"))
    }

    /// Opt-in: DASH_REAL_CLAUDE=1 runs one cheap turn through the installed Claude Code CLI.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DASH_REAL_CLAUDE"] == "1"))
    func realClaudeCodeUsesADashTool() async throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!)
        settings.model = "claude-haiku-5-5"
        settings.effort = "low"
        let host = try ExtensionHost(settings: settings, extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        host.dashboard.migrate()
        _ = host.dashboard.createPage(name: "On-call", systemImage: "bell")
        let chat = ChatSession(host: host)
        chat.send("Use the list_pages tool, then answer with only the number of pages.")
        for _ in 0..<1200 where chat.isRunning || chat.transcript.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
        let tools = chat.transcript.compactMap { entry -> String? in if case .tool(let name, _, let result, _) = entry.kind, result != nil { return name }; return nil }
        let answer = chat.transcript.compactMap { entry -> String? in if case .text(let text) = entry.kind { return text }; return nil }.last ?? ""
        print("REAL tools:", tools, "answer:", answer)
        #expect(tools.contains("list_pages"))
        #expect(answer.contains("2"))
    }
}

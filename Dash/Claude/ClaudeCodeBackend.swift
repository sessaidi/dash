import ClaudeCodeKit
import DashKit
import DashKitUI
import Foundation

extension JSONValue {
    /// The same JSON as ClaudeCodeKit's type.
    var claudeCode: ClaudeCodeKit.JSON { (try? ClaudeCodeKit.JSON.parse(jsonString())) ?? .null }
}

extension ClaudeCodeKit.JSON {
    var dash: JSONValue { (try? JSONValue.parse(line)) ?? .null }
}

/// Shared Claude Code options for Dash: no built-in tools, no user settings/hooks/CLAUDE.md,
/// no saved sessions, the configured model and effort, and the Claude login (not an API key).
@MainActor
enum ClaudeCodeDefaults {
    /// Commands that write to a forge or the network, denied even if a shell is ever allowed.
    static let remoteWriteRules = [
        "Bash(git push:*)", "Bash(git send-email:*)",
        "Bash(gh:*)", "Bash(glab:*)", "Bash(tea:*)", "Bash(hub:*)",
        "Bash(curl:*)", "Bash(wget:*)", "Bash(http:*)", "Bash(https:*)", "Bash(xh:*)",
    ]

    static func options(settings: AppSettings, system: String) -> ClaudeCodeOptions {
        var options = ClaudeCodeOptions()
        if !settings.claudePath.isEmpty { options.executable = URL(filePath: (settings.claudePath as NSString).expandingTildeInPath) }
        options.model = settings.model
        options.effort = settings.effort
        options.systemPrompt = .replace(system)
        options.tools = []
        options.disallowedTools = remoteWriteRules
        options.strictMCPConfig = true
        options.noSessionPersistence = true
        options.settingSources = ""
        options.removedEnvironment = ["ANTHROPIC_API_KEY"]
        options.cwd = FileManager.default.temporaryDirectory
        options.stderr = { text in DashLog.debug(text.trimmingCharacters(in: .whitespacesAndNewlines), category: "claude-code") }
        return options
    }
}

/// Dash's only `DashiiService`: Claude Code with the user's Claude login. PR reviews, meeting
/// summaries and plugins use it.
@MainActor
struct ClaudeCodeService: DashiiService {
    let settings: AppSettings

    var model: String { settings.model }

    /// `source` attributes the request in usage analytics; plugins calling without one show as "plugin".
    func complete(_ request: DashiiRequest) async throws -> String {
        let (system, prompt, outputSchema, effort, model, source) = (request.system, request.prompt, request.outputSchema, request.effort, request.model, request.source)
        // The user's rules: global ones, plus the calling extension's.
        let rules = source?.hasPrefix("hook.") == true ? nil : AutomationStore.shared.instructions(forSource: source)
        var options = ClaudeCodeDefaults.options(settings: settings, system: system + (rules.map { "\n\n" + $0 } ?? ""))
        if let effort { options.effort = effort }
        if let model { options.model = model }
        if let outputSchema { options.jsonSchema = outputSchema.claudeCode }
        let started = Date()
        for try await message in query(prompt, options: options) {
            guard case .result(let result) = message else { continue }
            DashLog.info("Claude Code \(options.model ?? settings.model) \(result.subtype) turns=\(result.numTurns) cost=$\(String(format: "%.4f", result.totalCostUSD)) in \(Int(Date().timeIntervalSince(started) * 1000))ms", category: "claude")
            ClaudeUsage.shared.record(source: source ?? "plugin", model: options.model ?? settings.model, effort: options.effort, result: result)
            if result.isError { throw ToolError("Claude Code: \(result.result ?? result.subtype)") }
            if let structured = result.structuredOutput { return structured.line }
            return result.result ?? ""
        }
        throw ToolError("Claude Code ended without a result.")
    }
}

/// Dash's tools, served to Claude Code as the in-process MCP server "dash".
struct DashMCPServer: MCPServer {
    let name = "dash"
    let tools: [ClaudeCodeKit.JSON]
    let call: @Sendable (String, ClaudeCodeKit.JSON) async -> MCPToolResult

    func listTools() async -> [ClaudeCodeKit.JSON] { tools }

    func callTool(name: String, arguments: ClaudeCodeKit.JSON) async -> MCPToolResult {
        await call(name, arguments)
    }
}

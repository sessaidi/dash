import Foundation

public enum PermissionMode: String, Sendable, CaseIterable {
    case `default`
    case acceptEdits
    case plan
    case bypassPermissions
}

public enum SystemPrompt: Sendable, Equatable {
    /// Replace Claude Code's system prompt.
    case replace(String)
    /// Keep Claude Code's system prompt and add to it.
    case append(String)
}

/// Options for a Claude Code run, modelled on the Agent SDK's `Options`.
public struct ClaudeCodeOptions: Sendable {
    /// The `claude` executable. `nil` searches PATH plus the usual install locations.
    public var executable: URL?
    public var cwd: URL?
    public var model: String?
    public var fallbackModel: String?
    public var permissionMode: PermissionMode?
    public var allowedTools: [String] = []
    public var disallowedTools: [String] = []
    public var systemPrompt: SystemPrompt?
    /// Resume a session by id.
    public var resume: String?
    /// Continue the most recent session in `cwd`.
    public var continueConversation = false
    /// With `resume`, branch into a new session id instead of appending.
    public var forkSession = false
    public var maxTurns: Int?
    public var addDirectories: [URL] = []
    /// Path to, or inline JSON of, an MCP server config.
    public var mcpConfig: String?
    public var settings: String?
    public var includePartialMessages = false
    /// Called for each tool call that is not already allowed. Enables `--permission-prompt-tool stdio`.
    public var canUseTool: CanUseTool?
    /// Extra environment variables for the CLI.
    public var environment: [String: String] = [:]
    /// Variables to remove from the inherited environment (e.g. `ANTHROPIC_API_KEY` to use the Claude login).
    public var removedEnvironment: Set<String> = []
    /// Extra flags passed verbatim.
    public var extraArguments: [String] = []
    /// Receives stderr lines.
    public var stderr: (@Sendable (String) -> Void)?
    /// In-process MCP servers (`type: "sdk"`): their tools reach Claude as `mcp__<server>__<tool>`.
    public var mcpServers: [any MCPServer] = []
    /// Use only `mcpServers`/`mcpConfig`, ignoring the user's configured MCP servers.
    public var strictMCPConfig = false
    /// Built-in tools to offer; `[]` disables them all (`--tools ""`), nil keeps the defaults.
    public var tools: [String]?
    /// JSON schema for structured output; the result's `structuredOutput` matches it.
    public var jsonSchema: JSON?
    /// low, medium, high, xhigh, max.
    public var effort: String?
    /// Don't save the session to disk.
    public var noSessionPersistence = false
    /// Which settings to load ("user,project,local"); "" loads none (no user hooks or CLAUDE.md).
    public var settingSources: String?

    public init() {}

    /// Command-line arguments for these options (streaming JSON in and out).
    public var arguments: [String] {
        var arguments = ["--output-format", "stream-json", "--input-format", "stream-json", "--verbose"]
        if let model { arguments += ["--model", model] }
        if let fallbackModel { arguments += ["--fallback-model", fallbackModel] }
        if let permissionMode { arguments += ["--permission-mode", permissionMode.rawValue] }
        if !allowedTools.isEmpty { arguments += ["--allowedTools", allowedTools.joined(separator: ",")] }
        if !disallowedTools.isEmpty { arguments += ["--disallowedTools", disallowedTools.joined(separator: ",")] }
        switch systemPrompt {
        case .replace(let prompt): arguments += ["--system-prompt", prompt]
        case .append(let prompt): arguments += ["--append-system-prompt", prompt]
        case nil: break
        }
        if let resume { arguments += ["--resume", resume] }
        if continueConversation { arguments.append("--continue") }
        if forkSession { arguments.append("--fork-session") }
        if let maxTurns { arguments += ["--max-turns", String(maxTurns)] }
        for directory in addDirectories { arguments += ["--add-dir", directory.path] }
        if !mcpServers.isEmpty {
            let servers = JSON.object(Dictionary(uniqueKeysWithValues: mcpServers.map { ($0.name, JSON.object(["type": "sdk", "name": .string($0.name)])) }))
            arguments += ["--mcp-config", JSON.object(["mcpServers": servers]).line]
        }
        if let mcpConfig { arguments += ["--mcp-config", mcpConfig] }
        if strictMCPConfig { arguments.append("--strict-mcp-config") }
        if let tools { arguments += ["--tools", tools.joined(separator: ",")] }
        if let jsonSchema { arguments += ["--json-schema", jsonSchema.line] }
        if let effort { arguments += ["--effort", effort] }
        if noSessionPersistence { arguments.append("--no-session-persistence") }
        if let settingSources { arguments += ["--setting-sources", settingSources] }
        if let settings { arguments += ["--settings", settings] }
        if includePartialMessages { arguments.append("--include-partial-messages") }
        if canUseTool != nil { arguments += ["--permission-prompt-tool", "stdio"] }
        return arguments + extraArguments
    }
}

public enum ClaudeCodeError: LocalizedError, Equatable {
    case executableNotFound
    case processExited(status: Int32, stderr: String)
    case controlRequestFailed(String)
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: "The claude CLI was not found. Install Claude Code or set ClaudeCodeOptions.executable."
        case .processExited(let status, let stderr): "claude exited with status \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .controlRequestFailed(let message): "Claude Code control request failed: \(message)"
        case .notRunning: "The Claude Code session is not running."
        }
    }
}

enum Locator {
    static var searchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"] + inherited + ["/usr/bin", "/bin"]
    }

    static func claude() -> URL? {
        for directory in searchPath {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

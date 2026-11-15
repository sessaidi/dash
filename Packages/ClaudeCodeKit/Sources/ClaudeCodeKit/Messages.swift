import Foundation

/// A message from the CLI's `stream-json` output, mirroring the Agent SDK's `SDKMessage`.
public enum Message: Sendable, Equatable {
    case system(SystemMessage)
    case assistant(AssistantMessage)
    case user(UserMessage)
    case result(ResultMessage)
    /// Raw Messages API stream event; only sent with `includePartialMessages`.
    case streamEvent(JSON)
    /// Any message type this library does not model yet.
    case other(JSON)

    public init(_ json: JSON) {
        switch json["type"]?.string {
        case "system": self = .system(SystemMessage(json))
        case "assistant": self = .assistant(AssistantMessage(json))
        case "user": self = .user(UserMessage(json))
        case "result": self = .result(ResultMessage(json))
        case "stream_event": self = .streamEvent(json["event"] ?? .null)
        default: self = .other(json)
        }
    }

    public var sessionID: String? {
        switch self {
        case .system(let message): message.sessionID
        case .assistant(let message): message.sessionID
        case .user(let message): message.sessionID
        case .result(let message): message.sessionID
        case .streamEvent, .other: nil
        }
    }
}

public struct SystemMessage: Sendable, Equatable {
    /// "init" for the first message of a run.
    public let subtype: String
    public let sessionID: String?
    public let model: String?
    public let cwd: String?
    public let tools: [String]
    public let permissionMode: String?
    /// The MCP servers' status at the start of a run: "connected", "failed", "pending"… by name.
    public let mcpServers: [String: String]
    public let raw: JSON

    init(_ json: JSON) {
        subtype = json["subtype"]?.string ?? ""
        sessionID = json["session_id"]?.string
        model = json["model"]?.string
        cwd = json["cwd"]?.string
        tools = json["tools"]?.array?.compactMap(\.string) ?? []
        permissionMode = json["permissionMode"]?.string
        mcpServers = Dictionary((json["mcp_servers"]?.array ?? []).compactMap { server in
            server["name"]?.string.map { ($0, server["status"]?.string ?? "") }
        }, uniquingKeysWith: { _, last in last })
        raw = json
    }
}

public struct AssistantMessage: Sendable, Equatable {
    public let sessionID: String?
    public let content: [ContentBlock]
    /// Set when the message comes from a subagent's tool call.
    public let parentToolUseID: String?
    public let raw: JSON

    init(_ json: JSON) {
        sessionID = json["session_id"]?.string
        content = json["message"]?["content"]?.array?.map(ContentBlock.init) ?? []
        parentToolUseID = json["parent_tool_use_id"]?.string
        raw = json
    }

    public var text: String {
        content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
    }
}

public struct UserMessage: Sendable, Equatable {
    public let sessionID: String?
    public let content: [ContentBlock]
    public let parentToolUseID: String?
    public let raw: JSON

    init(_ json: JSON) {
        sessionID = json["session_id"]?.string
        let content = json["message"]?["content"]
        if let text = content?.string {
            self.content = [.text(text)]
        } else {
            self.content = content?.array?.map(ContentBlock.init) ?? []
        }
        parentToolUseID = json["parent_tool_use_id"]?.string
        raw = json
    }
}

public struct ResultMessage: Sendable, Equatable {
    /// "success", "error_max_turns", "error_during_execution", ...
    public let subtype: String
    public let isError: Bool
    public let result: String?
    public let sessionID: String?
    public let totalCostUSD: Double
    public let durationMS: Int
    public let numTurns: Int
    public let usage: JSON?
    /// With `jsonSchema`: the structured output.
    public let structuredOutput: JSON?
    public let raw: JSON

    init(_ json: JSON) {
        structuredOutput = json["structured_output"].flatMap { $0 == .null ? nil : $0 }
        subtype = json["subtype"]?.string ?? ""
        isError = json["is_error"]?.bool ?? (subtype != "success")
        result = json["result"]?.string
        sessionID = json["session_id"]?.string
        totalCostUSD = json["total_cost_usd"]?.double ?? 0
        durationMS = json["duration_ms"]?.int ?? 0
        numTurns = json["num_turns"]?.int ?? 0
        usage = json["usage"]
        raw = json
    }
}

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: JSON)
    case toolResult(toolUseID: String, content: JSON, isError: Bool)
    case other(JSON)

    init(_ json: JSON) {
        switch json["type"]?.string {
        case "text": self = .text(json["text"]?.string ?? "")
        case "thinking": self = .thinking(json["thinking"]?.string ?? "")
        case "tool_use": self = .toolUse(id: json["id"]?.string ?? "", name: json["name"]?.string ?? "", input: json["input"] ?? .object([:]))
        case "tool_result":
            self = .toolResult(toolUseID: json["tool_use_id"]?.string ?? "", content: json["content"] ?? .null, isError: json["is_error"]?.bool ?? false)
        default: self = .other(json)
        }
    }
}

// MARK: - Permissions

/// A tool call the CLI asks the host to approve (`can_use_tool`).
public struct ToolPermissionRequest: Sendable, Equatable {
    public let toolName: String
    public let input: JSON
    /// Permission rule updates the CLI suggests, e.g. "always allow `npm test`".
    public let suggestions: JSON?
    public let toolUseID: String?
}

public enum PermissionDecision: Sendable, Equatable {
    /// Run the tool, optionally with edited input.
    case allow(updatedInput: JSON? = nil)
    /// Refuse; `message` is shown to Claude. `interrupt` also stops the turn.
    case deny(message: String, interrupt: Bool = false)

    func json(originalInput: JSON) -> JSON {
        switch self {
        case .allow(let updated): ["behavior": "allow", "updatedInput": updated ?? originalInput]
        case .deny(let message, let interrupt): ["behavior": "deny", "message": .string(message), "interrupt": .bool(interrupt)]
        }
    }
}

public typealias CanUseTool = @Sendable (ToolPermissionRequest) async -> PermissionDecision

// MARK: - In-process MCP servers

/// The result of an MCP tool call.
public struct MCPToolResult: Sendable, Equatable {
    public let text: String
    public let isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// An MCP server that runs inside the host process (the Agent SDK's `createSdkMcpServer`).
/// Claude Code talks to it over the control channel; its tools appear as `mcp__<name>__<tool>`.
public protocol MCPServer: Sendable {
    var name: String { get }
    /// The tool descriptions when they're known up front: the handshake is then answered on the
    /// spot, without waiting for a free thread (the CLI gives up after 30 seconds).
    var toolList: [JSON]? { get }
    /// MCP tool descriptions: `{"name", "description", "inputSchema"}`.
    func listTools() async -> [JSON]
    func callTool(name: String, arguments: JSON) async -> MCPToolResult
}

extension MCPServer {
    public var toolList: [JSON]? { nil }

    /// The answer to a message that needs no work (the handshake, notifications, the tool list
    /// when known), or nil when it must go through `handle`.
    func immediateAnswer(_ message: JSON) -> JSON? {
        let method = message["method"]?.string ?? ""
        guard method == "initialize" || method.hasPrefix("notifications/") || (method == "tools/list" && toolList != nil) else { return nil }
        let id = message["id"] ?? .null
        switch method {
        case "initialize":
            return ["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": message["params"]?["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(name), "version": "1.0.0"],
            ]]
        case "tools/list":
            return ["jsonrpc": "2.0", "id": id, "result": ["tools": .array(toolList ?? [])]]
        default:
            return ["jsonrpc": "2.0", "id": id, "result": [:]]
        }
    }

    /// Answers one JSON-RPC message from Claude Code.
    func handle(_ message: JSON) async -> JSON {
        let id = message["id"] ?? .null
        func result(_ value: JSON) -> JSON { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch message["method"]?.string {
        case "initialize":
            return result([
                "protocolVersion": message["params"]?["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(name), "version": "1.0.0"],
            ])
        case "tools/list":
            return result(["tools": .array(await listTools())])
        case "tools/call":
            let outcome = await callTool(name: message["params"]?["name"]?.string ?? "", arguments: message["params"]?["arguments"] ?? .object([:]))
            return result(["content": [["type": "text", "text": .string(outcome.text)]], "isError": .bool(outcome.isError)])
        case let method? where method.hasPrefix("notifications/"):
            return result([:])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Method not found")]]
        }
    }
}

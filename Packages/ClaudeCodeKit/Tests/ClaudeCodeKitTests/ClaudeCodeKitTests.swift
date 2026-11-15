import Foundation
import Testing
@testable import ClaudeCodeKit

/// Copies the fake CLI to a temp file and makes it executable (bundle copies drop the mode bit).
private func fakeClaude() throws -> URL {
    let source = try #require(Bundle.module.url(forResource: "fake-claude", withExtension: "py", subdirectory: "Fixtures"))
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    return target
}

private func options(_ configure: (inout ClaudeCodeOptions) -> Void = { _ in }) throws -> ClaudeCodeOptions {
    var options = ClaudeCodeOptions()
    options.executable = try fakeClaude()
    configure(&options)
    return options
}

struct OptionsTests {
    @Test func buildsArgumentsInTheCLIsFlagNames() {
        var options = ClaudeCodeOptions()
        options.model = "claude-opus-5-5"
        options.permissionMode = .plan
        options.allowedTools = ["Read", "Bash(go test:*)"]
        options.disallowedTools = ["Bash(git push:*)"]
        options.systemPrompt = .append("Use TDD.")
        options.resume = "abc"
        options.maxTurns = 4
        let arguments = options.arguments
        #expect(arguments.starts(with: ["--output-format", "stream-json", "--input-format", "stream-json", "--verbose"]))
        #expect(arguments.contains("--permission-mode") && arguments.contains("plan"))
        #expect(arguments.contains("Read,Bash(go test:*)"))
        #expect(arguments.contains("--append-system-prompt"))
        #expect(arguments.contains("--resume") && arguments.contains("abc"))
        #expect(!arguments.contains("--permission-prompt-tool"))
    }

    @Test func permissionCallbackSwitchesOnStdioPrompts() {
        var options = ClaudeCodeOptions()
        options.canUseTool = { _ in .allow() }
        #expect(options.arguments.suffix(2) == ["--permission-prompt-tool", "stdio"])
    }
}

struct MessageTests {
    @Test func parsesAssistantBlocks() throws {
        let json = try JSON.parse(#"{"type":"assistant","session_id":"s","message":{"content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"a.swift"}}]}}"#)
        guard case .assistant(let message) = Message(json) else { Issue.record("not assistant"); return }
        #expect(message.text == "hi")
        #expect(message.content[1] == .toolUse(id: "t1", name: "Edit", input: ["file_path": "a.swift"]))
        #expect(Message(json).sessionID == "s")
    }

    @Test func parsesResult() throws {
        let json = try JSON.parse(#"{"type":"result","subtype":"error_max_turns","session_id":"s","total_cost_usd":0.5,"num_turns":3}"#)
        guard case .result(let result) = Message(json) else { Issue.record("not result"); return }
        #expect(result.isError)
        #expect(result.totalCostUSD == 0.5)
        #expect(result.numTurns == 3)
    }
}

struct SessionTests {
    @Test func queryStreamsInitAssistantAndResult() async throws {
        var kinds: [String] = []
        for try await message in query("hello", options: try options()) {
            switch message {
            case .system(let system): kinds.append("system:\(system.subtype)")
            case .assistant(let reply): kinds.append("assistant:\(reply.text)")
            case .result(let result): kinds.append("result:\(result.subtype)")
            default: kinds.append("other")
            }
        }
        #expect(kinds == ["system:init", "assistant:echo: hello", "result:success"])
    }

    @Test func multiTurnSessionKeepsTheProcess() async throws {
        let session = try ClaudeCodeSession(options: try options())
        try session.send("one")
        var results = 0
        for try await message in session.messages {
            guard case .result(let result) = message else { continue }
            results += 1
            #expect(result.numTurns == results)
            if results == 1 { try session.send("two") } else { session.endInput() }
        }
        #expect(results == 2)
        #expect(session.sessionID == "fake-session")
    }

    @Test func controlRequestsGetResponses() async throws {
        let session = try ClaudeCodeSession(options: try options())
        try await session.interrupt()
        try await session.setPermissionMode(.acceptEdits)
        session.terminate()
    }

    @Test func permissionCallbackDecidesToolUse() async throws {
        let asked = Box()
        let opts = try options { options in
            options.canUseTool = { request in
                asked.set(request.toolName + " " + (request.input["command"]?.string ?? ""))
                return .deny(message: "not now")
            }
        }
        var final: String?
        for try await message in query("run ls", options: opts) {
            if case .result(let result) = message { final = result.result }
        }
        #expect(asked.value == "Bash ls")
        #expect(final == "decision: deny")
    }

    @Test func inProcessMCPServerAnswersListAndCall() async throws {
        let opts = try options { $0.mcpServers = [EchoServer()]; $0.strictMCPConfig = true; $0.tools = [] }
        #expect(opts.arguments.contains("--strict-mcp-config"))
        #expect(opts.arguments.contains(#"{"mcpServers":{"dash":{"name":"dash","type":"sdk"}}}"#))
        var final: String?
        for try await message in query("pineapple", options: opts) {
            if case .result(let result) = message { final = result.result }
        }
        #expect(final == "decision: tools=1 tool says echo: pineapple")
    }

    @Test func structuredOutputIsParsed() async throws {
        let opts = try options { $0.jsonSchema = ["type": "object"] }
        var structured: JSON?
        for try await message in query("hi", options: opts) {
            if case .result(let result) = message { structured = result.structuredOutput }
        }
        #expect(structured == ["echo": "hi"])
    }

    @Test func missingExecutableThrows() {
        var options = ClaudeCodeOptions()
        options.executable = URL(fileURLWithPath: "/nonexistent/claude")
        #expect(throws: (any Error).self) { try ClaudeCodeSession(options: options) }
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
}

private struct EchoServer: MCPServer {
    let name = "dash"
    func listTools() async -> [JSON] {
        [["name": "echo", "description": "Echoes", "inputSchema": ["type": "object", "properties": ["word": ["type": "string"]]]]]
    }
    func callTool(name: String, arguments: JSON) async -> MCPToolResult {
        MCPToolResult("echo: \(arguments["word"]?.string ?? "")")
    }
}

/// The in-process MCP handshake is answered without waiting, and the run's MCP status is read.
struct MCPHandshakeTests {
    struct Server: MCPServer {
        let name = "dash"
        var toolList: [JSON]? { [["name": "ping"]] }
        func listTools() async -> [JSON] { [] }
        func callTool(name: String, arguments: JSON) async -> MCPToolResult { MCPToolResult("") }
    }

    @Test func handshakeAndToolListNeedNoWork() {
        let server = Server()
        #expect(server.immediateAnswer(["jsonrpc": "2.0", "id": 1, "method": "initialize"])?["result"]?["serverInfo"]?["name"] == "dash")
        #expect(server.immediateAnswer(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"]?["tools"] == [["name": "ping"]])
        #expect(server.immediateAnswer(["jsonrpc": "2.0", "id": 3, "method": "tools/call"]) == nil)
    }

    @Test func initReportsEachServersStatus() {
        let message = SystemMessage(["type": "system", "subtype": "init", "mcp_servers": [["name": "dash", "status": "failed"]]])
        #expect(message.mcpServers == ["dash": "failed"])
    }
}

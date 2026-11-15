import Foundation

/// A long-lived, multi-turn Claude Code process (`--input-format stream-json`).
///
/// Send user turns with `send(_:)` while reading `messages`. The process keeps
/// its context between turns; it exits after `endInput()` once the current turn
/// finishes, or immediately on `terminate()`.
///
/// ```swift
/// var options = ClaudeCodeOptions()
/// options.cwd = repo
/// options.permissionMode = .plan
/// let session = try ClaudeCodeSession(options: options)
/// try session.send("Propose a plan for KAN-123")
/// for try await message in session.messages {
///     if case .assistant(let reply) = message { print(reply.text) }
///     if case .result = message { break }
/// }
/// ```
public final class ClaudeCodeSession: @unchecked Sendable {
    /// Every message the CLI prints, in order. Finishes when the process exits.
    public let messages: AsyncThrowingStream<Message, Error>

    private let output: AsyncThrowingStream<Message, Error>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    private var nextRequest = 0
    private var inputClosed = false
    private var terminatedByUs = false
    private var _sessionID: String?
    private var stderrText = ""
    private let canUseTool: CanUseTool?
    private let mcpServers: [String: any MCPServer]

    /// The CLI's session id, known after the first `system/init` message. Pass it to `resume` later.
    public var sessionID: String? { lock.withLock { _sessionID } }

    public var isRunning: Bool { process.isRunning }

    public init(options: ClaudeCodeOptions) throws {
        guard let executable = options.executable ?? Locator.claude() else { throw ClaudeCodeError.executableNotFound }
        canUseTool = options.canUseTool
        mcpServers = Dictionary(uniqueKeysWithValues: options.mcpServers.map { ($0.name, $0) })
        (messages, output) = AsyncThrowingStream<Message, Error>.makeStream()

        process.executableURL = executable
        process.arguments = options.arguments
        if let cwd = options.cwd { process.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Locator.searchPath.joined(separator: ":")
        for key in options.removedEnvironment { environment.removeValue(forKey: key) }
        environment.merge(options.environment) { _, new in new }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let stderrSink = options.stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            self?.lock.withLock { self?.stderrText += text }
            stderrSink?(text)
        }

        Task.detached { [self] in
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    guard let json = try? JSON.parse(line) else { continue }
                    handle(json)
                }
            } catch {
                output.finish(throwing: error)
                failPending(error)
                return
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            let errors = lock.withLock { stderrText }
            failPending(ClaudeCodeError.notRunning)
            if status != 0, !lock.withLock({ terminatedByUs }) {
                output.finish(throwing: ClaudeCodeError.processExited(status: status, stderr: errors))
            } else {
                output.finish()
            }
        }

        output.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.terminate() }
        }
    }

    // MARK: Sending

    /// Sends a user turn as plain text.
    public func send(_ text: String) throws {
        try send(content: [["type": "text", "text": .string(text)]])
    }

    /// Sends a user turn with arbitrary content blocks (text, images).
    public func send(content: [JSON]) throws {
        try write([
            "type": "user",
            "message": ["role": "user", "content": .array(content)],
            "parent_tool_use_id": nil,
            "session_id": .string(sessionID ?? ""),
        ])
    }

    /// Stops the current turn. The CLI answers with a `result` message.
    public func interrupt() async throws {
        _ = try await control(["subtype": "interrupt"])
    }

    public func setPermissionMode(_ mode: PermissionMode) async throws {
        _ = try await control(["subtype": "set_permission_mode", "mode": .string(mode.rawValue)])
    }

    public func setModel(_ model: String?) async throws {
        _ = try await control(["subtype": "set_model", "model": model.map(JSON.string) ?? .null])
    }

    /// Closes stdin: the CLI finishes the current turn and exits.
    public func endInput() {
        let shouldClose = lock.withLock { () -> Bool in
            defer { inputClosed = true }
            return !inputClosed
        }
        if shouldClose { try? input.fileHandleForWriting.close() }
    }

    /// Kills the process now.
    public func terminate() {
        lock.withLock { terminatedByUs = true }
        endInput()
        if process.isRunning { process.terminate() }
    }

    // MARK: Protocol

    private func write(_ json: JSON) throws {
        try lock.withLock {
            guard !inputClosed, process.isRunning else { throw ClaudeCodeError.notRunning }
            try input.fileHandleForWriting.write(contentsOf: Data((json.line + "\n").utf8))
        }
    }

    private func control(_ request: JSON) async throws -> JSON {
        let id = lock.withLock { () -> String in
            nextRequest += 1
            return "req_\(nextRequest)_\(UUID().uuidString.prefix(8))"
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            do {
                try write(["type": "control_request", "request_id": .string(id), "request": request])
            } catch {
                lock.withLock { pending[id] = nil }
                continuation.resume(throwing: error)
            }
        }
    }

    private func failPending(_ error: Error) {
        let waiting = lock.withLock { () -> [CheckedContinuation<JSON, Error>] in
            defer { pending = [:] }
            return Array(pending.values)
        }
        for continuation in waiting { continuation.resume(throwing: error) }
    }

    private func handle(_ json: JSON) {
        switch json["type"]?.string {
        case "control_response":
            let response = json["response"] ?? .null
            guard let id = response["request_id"]?.string,
                  let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
            if response["subtype"]?.string == "error" {
                continuation.resume(throwing: ClaudeCodeError.controlRequestFailed(response["error"]?.string ?? "unknown error"))
            } else {
                continuation.resume(returning: response["response"] ?? .null)
            }
        case "control_request":
            answer(json)
        case "control_cancel_request":
            break
        default:
            let message = Message(json)
            if let id = message.sessionID { lock.withLock { _sessionID = id } }
            output.yield(message)
        }
    }

    /// Answers the CLI's own control requests (tool permission prompts).
    private func answer(_ json: JSON) {
        guard let id = json["request_id"]?.string else { return }
        let request = json["request"] ?? .null
        if request["subtype"]?.string == "mcp_message" {
            let server = mcpServers[request["server_name"]?.string ?? ""]
            let message = request["message"] ?? .null
            Task { [weak self] in
                let response: JSON = await server?.handle(message)
                    ?? ["jsonrpc": "2.0", "id": message["id"] ?? .null, "error": ["code": -32601, "message": "Unknown MCP server"]]
                try? self?.write(["type": "control_response", "response": [
                    "subtype": "success", "request_id": .string(id), "response": ["mcp_response": response],
                ]])
            }
            return
        }
        guard request["subtype"]?.string == "can_use_tool" else {
            try? write(["type": "control_response", "response": [
                "subtype": "error", "request_id": .string(id), "error": .string("Unsupported control request \(request["subtype"]?.string ?? "")"),
            ]])
            return
        }
        let input = request["input"] ?? .object([:])
        let permission = ToolPermissionRequest(
            toolName: request["tool_name"]?.string ?? "",
            input: input,
            suggestions: request["permission_suggestions"],
            toolUseID: request["tool_use_id"]?.string)
        let canUseTool = canUseTool
        Task { [weak self] in
            let decision = await canUseTool?(permission) ?? .deny(message: "No permission handler is configured.")
            try? self?.write(["type": "control_response", "response": [
                "subtype": "success", "request_id": .string(id), "response": decision.json(originalInput: input),
            ]])
        }
    }
}

/// One-shot run: sends `prompt`, streams every message, and ends after the `result`.
///
/// ```swift
/// for try await message in query("Summarise README.md", options: options) {
///     if case .result(let result) = message { print(result.result ?? "") }
/// }
/// ```
public func query(_ prompt: String, options: ClaudeCodeOptions = .init()) -> AsyncThrowingStream<Message, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let session = try ClaudeCodeSession(options: options)
                try session.send(prompt)
                for try await message in session.messages {
                    continuation.yield(message)
                    if case .result = message { session.endInput() }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

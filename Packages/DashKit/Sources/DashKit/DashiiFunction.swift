import CryptoKit
import Foundation

/// One job Dashii does for an extension, as a typed function: instructions and an output schema
/// fixed in one place, the input encoded for it, the answer decoded and checked.
///
///     static let summarize = DashiiFunction<Transcript, MeetingSummary>(
///         name: "meeting.summary", task: "summary",
///         instructions: "Summarize the meeting: decisions, then action items with owners.",
///         outputSchema: MeetingSummary.schema)
///
///     let summary = try await Self.summarize.run(transcript, dashii: host.dashii, settings: ai)
///
/// - An answer that isn't valid JSON for `Output` (or fails `check`) is asked for once more, with
///   what was wrong; a second miss throws.
/// - `cacheFor` reuses an answer for the same input, model and `version` (bump `version` when the
///   instructions change).
/// - Usage is attributed to the task (or `name`), so analytics show which job spent what.
public struct DashiiFunction<Input: Encodable & Sendable, Output: Decodable & Sendable>: Sendable {
    public enum InputFormat: Sendable {
        /// Minified JSON.
        case json
        /// `CompactFormat`: about 40% fewer tokens on rows of the same fields.
        case compact
    }

    public let name: String
    /// What it does, for other extensions, Dashii and agents choosing a function.
    public let summary: String
    public let version: Int
    /// The `AITask` id whose model and effort the user picks, when there is one.
    public let task: String?
    public let instructions: String
    /// The input's JSON schema, for callers that pass JSON (Dashii, agents, other extensions).
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue
    public let model: DashiiModel?
    public let effort: DashiiEffort?
    public let inputFormat: InputFormat
    public let cacheFor: Duration?
    let prompt: @Sendable (_ input: String) -> String
    let check: @Sendable (Output) throws -> Void

    /// `prompt` wraps the encoded input (by default in `<input>` tags); `check` rejects answers
    /// that decode but make no sense (throw a `ToolError` saying why).
    public init(name: String, summary: String = "", version: Int = 1, task: String? = nil, instructions: String,
                inputSchema: JSONValue = ["type": "object"], outputSchema: JSONValue,
                model: DashiiModel? = nil, effort: DashiiEffort? = nil, inputFormat: InputFormat = .json, cacheFor: Duration? = nil,
                prompt: @escaping @Sendable (_ input: String) -> String = { "<input>\n\($0)\n</input>" },
                check: @escaping @Sendable (Output) throws -> Void = { _ in }) {
        self.name = name
        self.summary = summary
        self.version = version
        self.task = task
        self.instructions = instructions
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.model = model
        self.effort = effort
        self.inputFormat = inputFormat
        self.cacheFor = cacheFor
        self.prompt = prompt
        self.check = check
    }

    /// Runs it with the user's choices for `task` in `settings` (else this function's defaults).
    @MainActor
    public func run(_ input: Input, dashii: any DashiiService, settings: AISettings? = nil) async throws -> Output {
        let value = try JSONValue(encoding: input)
        let text = inputFormat == .compact ? CompactFormat.encode(value) : value.jsonString()
        let model = (task.flatMap { id in settings.map { $0.model(id) } } ?? model)?.rawValue
        let effort = (task.flatMap { id in settings?.effort(id) } ?? effort)?.rawValue
        let job = task ?? name
        let source = settings?.scope.map { "\($0)/\(job)" } ?? "function.\(job)"

        let key = [name, String(version), model ?? dashii.model, effort ?? "", Self.digest(text)].joined(separator: "|")
        if let cacheFor, let cached = DashiiFunctionCache.shared.value(for: key, maxAge: cacheFor), let output = try? decode(cached) {
            return output
        }

        let system = instructions + (inputFormat == .compact ? "\n\n" + CompactFormat.legend : "")
        var request = DashiiRequest(system: system, prompt: prompt(text), outputSchema: outputSchema, effort: effort, model: model, source: source)
        for attempt in 1...2 {
            let reply = try await dashii.complete(request)
            do {
                let answer = try JSONValue.parse(Self.json(in: reply))
                let output = try decode(answer)
                if cacheFor != nil { DashiiFunctionCache.shared.store(answer, for: key) }
                return output
            } catch where attempt == 1 {
                request.prompt = prompt(text) + "\n\nYour previous answer couldn't be used (\(Self.reason(error))). Reply with only JSON matching the schema."
            } catch {
                throw ToolError("Dashii's answer for \(name) couldn't be used: \(Self.reason(error))")
            }
        }
        throw ToolError("Dashii gave no answer for \(name).")
    }

    private func decode(_ answer: JSONValue) throws -> Output {
        let output = try answer.decode(Output.self)
        try check(output)
        return output
    }

    /// The JSON in a reply: as is, inside a ``` fence, or from the first `{`/`[` to the last `}`/`]`.
    static func json(in reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.drop { $0 != "\n" }.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("```") { text = String(text.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let first = text.first, first != "{", first != "[",
              let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = text.lastIndex(where: { $0 == "}" || $0 == "]" }), start < end else { return text }
        return String(text[start...end])
    }

    private static func reason(_ error: any Error) -> String {
        switch error {
        case let error as ToolError: error.message
        case DecodingError.keyNotFound(let key, _): "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            (context.codingPath.map(\.stringValue).joined(separator: ".") + " " + context.debugDescription).trimmingCharacters(in: .whitespaces)
        default: error.localizedDescription
        }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Answers `DashiiFunction`s may reuse, newest 200 kept, in memory only.
@MainActor
final class DashiiFunctionCache {
    static let shared = DashiiFunctionCache()

    private var entries: [String: (date: Date, value: JSONValue)] = [:]
    private let limit = 200

    func value(for key: String, maxAge: Duration, now: Date = .now) -> JSONValue? {
        guard let entry = entries[key], now.timeIntervalSince(entry.date) < Double(maxAge.components.seconds) else { return nil }
        return entry.value
    }

    func store(_ value: JSONValue, for key: String, now: Date = .now) {
        entries[key] = (now, value)
        guard entries.count > limit else { return }
        for (key, _) in entries.sorted(by: { $0.value.date < $1.value.date }).prefix(entries.count - limit) { entries[key] = nil }
    }

    func removeAll() { entries = [:] }
}

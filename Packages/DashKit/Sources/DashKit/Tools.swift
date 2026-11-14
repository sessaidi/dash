import Foundation

/// A client-side tool exposed to Claude in the chat panel.
@MainActor
public struct ClaudeTool {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    /// Tools that write to an outside system or delete data ask the user first.
    public var requiresApproval: Bool
    public let run: @MainActor (JSONValue) async throws -> JSONValue

    public init(
        name: String, description: String, properties: [String: JSONValue] = [:], required: [String] = [],
        requiresApproval: Bool = false, run: @escaping @MainActor (JSONValue) async throws -> JSONValue
    ) {
        self.name = name
        self.description = description
        self.inputSchema = ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
        self.requiresApproval = requiresApproval
        self.run = run
    }

    /// The Messages API tool definition. Streamed requests use eager input streaming; inputs are validated on decode.
    public var definition: JSONValue {
        ["name": .string(name), "description": .string(description), "input_schema": inputSchema, "eager_input_streaming": true]
    }
}

/// An error whose message is shown to the user and returned to Claude as a tool error.
public struct ToolError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension JSONValue {
    /// Decodes a tool input, turning decoding failures into messages Claude can fix.
    public func toolInput<T: Decodable>(_ type: T.Type) throws -> T {
        do { return try decode(T.self) } catch let error as DecodingError { throw ToolError(error.readableDescription) }
    }
}

/// Builds JSON-schema property fragments for tool definitions.
public enum JSONSchema {
    public static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map { .string($0) }) }
        return .object(schema)
    }
    public static func integer(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }
    public static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }
    public static func object(_ description: String) -> JSONValue { ["type": "object", "description": .string(description)] }
}

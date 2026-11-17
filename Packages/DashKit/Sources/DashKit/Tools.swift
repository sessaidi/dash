import Foundation

/// Something Dashii can do: a name, a description it reads to decide when to use it, an input
/// schema, and the function that runs it.
@MainActor
public struct DashiiTool {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    /// Tools that write to an outside system or delete data ask the user first.
    public var requiresApproval: Bool
    /// Tools that change a remote system (a forge, a tracker, a cluster). Dash never gives them
    /// to Dashii: remotely it may only read. They also ask the user first.
    public var writesRemotely: Bool
    /// Tools that call a service (an API, a socket, a CLI that reaches one). Other extensions may
    /// run them; Dash never gives them to Dashii, agents or hooks, which read Dash's database and
    /// ask integrations to fetch (`DataFetcher`). DashKit 2.4.
    public var callsService: Bool = false
    public let run: @MainActor (JSONValue) async throws -> JSONValue

    public init(
        name: String, description: String, properties: [String: JSONValue] = [:], required: [String] = [],
        requiresApproval: Bool = false, writesRemotely: Bool = false, run: @escaping @MainActor (JSONValue) async throws -> JSONValue
    ) {
        self.name = name
        self.description = description
        self.inputSchema = ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
        self.requiresApproval = requiresApproval || writesRemotely
        self.writesRemotely = writesRemotely
        self.run = run
    }

    /// A tool that calls its service: for other extensions only (see `callsService`).
    public init(
        name: String, description: String, properties: [String: JSONValue] = [:], required: [String] = [],
        requiresApproval: Bool = false, writesRemotely: Bool = false, callsService: Bool,
        run: @escaping @MainActor (JSONValue) async throws -> JSONValue
    ) {
        self.init(name: name, description: description, properties: properties, required: required,
                  requiresApproval: requiresApproval, writesRemotely: writesRemotely, run: run)
        self.callsService = callsService
    }

    /// Whether Dash may give it to Dashii and agents: it neither writes remotely nor calls a service.
    public var isForDashii: Bool { !writesRemotely && !callsService }

    /// The Messages API tool definition. Streamed requests use eager input streaming; inputs are validated on decode.
    public var definition: JSONValue {
        ["name": .string(name), "description": .string(description), "input_schema": inputSchema, "eager_input_streaming": true]
    }
}

/// An error whose message is shown to the user and returned to Dashii as a tool error.
public struct ToolError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension JSONValue {
    /// Decodes a tool input, turning decoding failures into messages Dashii can fix.
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
    public static func number(_ description: String) -> JSONValue { ["type": "number", "description": .string(description)] }
    public static func array(_ description: String, of items: JSONValue) -> JSONValue {
        ["type": "array", "description": .string(description), "items": items]
    }
    /// An object with these properties; `required` lists the ones that must be there.
    public static func object(_ description: String = "", properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string))]
        if !description.isEmpty { schema["description"] = .string(description) }
        return .object(schema)
    }
}

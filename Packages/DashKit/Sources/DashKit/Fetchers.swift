import Foundation

/// Something an integration can fetch from its service into Dash's database, on request.
///
/// Dashii and agents never call a service's API themselves: they read what Dash has stored
/// (datasets, the knowledge graph) and, when it's missing or stale, ask the integration to fetch
/// it with `data_fetch`. The integration calls the API, stores the result, and answers with a
/// short receipt: what it stored and where to read it.
@MainActor
public struct DataFetcher {
    /// "<extension>.<what>", e.g. "confluence.pages".
    public let name: String
    /// What it fetches, for Dashii: when to ask for it and what lands where.
    public let summary: String
    public let inputSchema: JSONValue
    /// Calls the service, stores the result and returns the receipt.
    public let fetch: @MainActor (JSONValue) async throws -> JSONValue

    public init(name: String, summary: String, properties: [String: JSONValue] = [:], required: [String] = [],
                fetch: @escaping @MainActor (JSONValue) async throws -> JSONValue) {
        self.name = name
        self.summary = summary
        self.inputSchema = ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
        self.fetch = fetch
    }
}

extension ExtensionContext {
    /// Every enabled extension's fetchers.
    public var fetchers: [DataFetcher] {
        extensions.filter { isEnabled($0) }.flatMap(\.fetchers)
    }

    /// Asks the integration that owns `name` to fetch into Dash's database; returns its receipt.
    public func fetch(_ name: String, _ input: JSONValue = [:]) async throws -> JSONValue {
        guard let fetcher = fetchers.first(where: { $0.name == name }) else {
            throw ToolError("Nothing fetches “\(name)”. Available: \(fetchers.map(\.name).joined(separator: ", ")).")
        }
        return try await fetcher.fetch(input)
    }
}

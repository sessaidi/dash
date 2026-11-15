import DashKit
import Foundation

/// `data_fetch`: how Dashii and agents get fresh data. They never call a service; they ask the
/// integration that owns it to fetch into Dash's database, then read it there (DashQL datasets,
/// the knowledge graph).
enum FetchTools {
    @MainActor
    static func tools(host: ExtensionHost) -> [DashiiTool] {
        let fetchers = host.fetchers
        guard !fetchers.isEmpty else { return [] }
        let catalog = fetchers.map { fetcher in
            "- \(fetcher.name): \(fetcher.summary) Input: \(fetcher.inputSchema["properties"]?.jsonString() ?? "{}")"
        }.joined(separator: "\n")
        return [DashiiTool(
            name: "data_fetch",
            description: """
                Ask an integration to fetch fresh data from its service into Dash's database. You never call services \
                yourself: read what Dash has (DashQL, knowledge search) and fetch only when it's missing or stale. The \
                answer says what was stored and where to read it.

                \(catalog)
                """,
            properties: ["fetcher": JSONSchema.string("Which fetcher.", enum: fetchers.map(\.name)),
                         "input": JSONSchema.object("The fetcher's input.")],
            required: ["fetcher"]
        ) { input in
            guard let name = input["fetcher"]?.string else { throw ToolError("Name a fetcher.") }
            return try await host.fetch(name, input["input"] ?? [:])
        }]
    }
}

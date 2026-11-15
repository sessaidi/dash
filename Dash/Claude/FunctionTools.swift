import DashKit
import Foundation

/// Dashii functions as tools: DashKit's shared ones (summarize, classify, logs.digest,
/// root_cause…) and those enabled extensions publish. Each is one call to a smaller model with
/// a fixed output shape, so the lead model can hand off narrow jobs cheaply.
@MainActor
enum FunctionTools {
    /// `limit` caps how many functions one run may call (agents get a budget; chat doesn't).
    static func tools(host: ExtensionHost, limit: Int? = nil) -> [DashiiTool] {
        let budget = Budget(limit: limit)
        return [
            DashiiTool(name: "functions_list", description: "Dashii functions you can hand narrow jobs to (each one a call to a smaller model with a fixed JSON answer): name, summary, input and output schemas.") { _ in
                .array(host.functions.map(\.json))
            },
            DashiiTool(name: "function_run", description: "Run a Dashii function by name (functions_list): summarize, classify, extract, rank, logs.digest, compare, root_cause, or an extension's. Give `input` matching its input schema; returns its JSON answer.",
                       properties: ["name": JSONSchema.string("Function name."), "input": JSONSchema.object("Input matching the function's input schema.")],
                       required: ["name", "input"]) { input in
                guard let name = input["name"]?.string else { throw ToolError("Give the function name.") }
                try budget.spend()
                return try await host.runFunction(name, input: input["input"] ?? [:])
            },
        ]
    }

    /// How many function calls a run has left.
    final class Budget {
        let limit: Int?
        private var used = 0

        init(limit: Int?) { self.limit = limit }

        func spend() throws {
            used += 1
            if let limit, used > limit {
                throw ToolError("This run already used its \(limit) function calls; continue with the read tools.")
            }
        }
    }
}

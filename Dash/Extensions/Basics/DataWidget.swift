import Charts
import DashKit
import DashKitUI
import SwiftUI

/// Any DashQL dataset as a widget, with no plugin code: pods, tickets, PRs, releases, monitors,
/// activity… shown as a table, a list, counts, one number or bars. Dashii makes them on the fly
/// ("high-risk PRs on my tickets, as a table"). Its rows can be selected, so other widgets can
/// follow the selection.
struct DataWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// The dataset (`pods`, `jira`, `prs`, `activity`, `widget`…).
        var dataset: String
        /// For datasets that take one (`widget "Failing pods"`, `knowledge "auth"`).
        var argument: String?
        /// DashQL stages after the source: `where … | sort … | take …`, or a `count by` for counts and bars.
        var query: String
        /// table, list, counts, number, bars.
        var view: String
        /// Columns for table, in order; empty shows the first few fields.
        var columns: [String]
        /// Row title and subtitle for list.
        var titleField: String?
        var subtitleField: String?
        /// Refresh period in seconds.
        var refreshSeconds: Int

        init(dataset: String = "activity", argument: String? = nil, query: String = "", view: String = "table",
             columns: [String] = [], titleField: String? = nil, subtitleField: String? = nil, refreshSeconds: Int = 60) {
            self.dataset = dataset
            self.argument = argument
            self.query = query
            self.view = view
            self.columns = columns
            self.titleField = titleField
            self.subtitleField = subtitleField
            self.refreshSeconds = refreshSeconds
        }
    }

    static let kind = "dash.data"
    static let displayName = "Data"
    static let summary = "Any DashQL dataset (pods, tickets, PRs, releases, monitors, activity…) as a table, list, counts, a number or bars; select a row to drive linked widgets."
    static let systemImage = "tablecells"
    static let defaultConfig = Config()
    static let defaultSize: WidgetSize = .medium
    static let sizeLimits = GridLimits(minW: 2, minH: 3, maxW: 12, maxH: 24)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "dataset": ["type": "string", "description": "DashQL dataset name (dashql_schema lists them)."],
            "argument": ["type": "string", "description": "For datasets that take one, e.g. a widget title."],
            "query": ["type": "string", "description": "Stages after the source: where … | sort … | take … ; for counts/bars end with count by <field>. May use $selected(\"Widget\").field to follow another widget's selection."],
            "view": ["type": "string", "enum": ["table", "list", "counts", "number", "bars"]],
            "columns": ["type": "array", "items": ["type": "string"], "description": "Table columns in order."],
            "titleField": ["type": "string"], "subtitleField": ["type": "string"],
            "refreshSeconds": ["type": "integer", "minimum": 15],
        ],
        "required": ["dataset", "view"],
    ]
    static let actions = [
        WidgetAction(name: "select", description: "Select a row (by its position from 1, or a value of its first column) so linked widgets follow it.",
                     properties: ["row": JSONSchema.string("Position or value.")], required: ["row"]),
        WidgetAction(name: "clear_selection", description: "Clear the selection."),
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        DataWidgetView(config: config.wrappedValue, context: context)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Form {
            TextField("Dataset", text: config.dataset)
            TextField("Argument", text: Binding(get: { config.wrappedValue.argument ?? "" }, set: { config.wrappedValue.argument = $0.isEmpty ? nil : $0 }))
            TextField("Query", text: config.query, axis: .vertical).font(.callout.monospaced()).lineLimit(1...4)
            Picker("Show as", selection: config.view) {
                ForEach(["table", "list", "counts", "number", "bars"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            Text("Easier: ask Dashii, e.g. “show my high-risk PRs as a table”.").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func preview(config: Config) -> some View {
        DataWidgetPreview(config: config)
    }

    @MainActor
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let host = context.host as? ExtensionHost else { return .null }
        do {
            let result = try await run(config, host: host)
            return ["dataset": .string(config.dataset), "query": .string(config.query), "view": .string(config.view), "rows": .array(result.rows),
                    "total": .number(Double(result.total))]
        } catch {
            return ["error": .string(error.localizedDescription)]
        }
    }

    /// The configured query, with its links to other widgets' selections filled in.
    @MainActor
    static func run(_ config: Config, host: ExtensionHost) async throws -> QueryEngine.Result {
        var source = "from \(config.dataset)"
        if let argument = config.argument, !argument.isEmpty { source += " " + DashQL.literal(.string(argument)) }
        let stages = config.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = stages.isEmpty ? source : stages.hasPrefix("|") ? "\(source) \(stages)" : "\(source) | \(stages)"
        let linked = DashQL.resolveSelections(text, host: host)
        guard linked.waiting.isEmpty else { throw QueryError("Select something in \(linked.waiting.joined(separator: ", ")).") }
        return try await DashQL.engine(host: host).run(linked.text)
    }
}

private struct DataWidgetView: View {
    let config: DataWidget.Config
    let context: WidgetContext
    @State private var rows: [JSONValue] = []
    @State private var total = 0
    @State private var error: String?
    @State private var loaded = false
    @State private var selected: Int?

    private var host: ExtensionHost? { context.host as? ExtensionHost }

    /// What re-runs the query: its config, and the selections it links to.
    private var trigger: String {
        guard let host else { return "" }
        return "\(config.dataset)|\(config.argument ?? "")|\(config.query)|\(DashQL.resolveSelections(config.query, host: host).text)"
    }

    var body: some View {
        Group {
            if let error {
                StateView(.empty(title: error.hasPrefix("Select something") ? "Waiting for a selection" : "Can't show this",
                                 systemImage: error.hasPrefix("Select something") ? "hand.point.up.left" : "exclamationmark.triangle", message: error))
            } else if !loaded {
                StateView(.loading())
            } else if rows.isEmpty {
                StateView(.empty(title: "Nothing matches", systemImage: "tablecells"))
            } else {
                DataWidgetContent(config: config, rows: rows, total: total, selected: $selected)
            }
        }
        .task(id: trigger) { await load(periodic: true) }
        .reportsSelection(selected.flatMap { rows.indices.contains($0) ? rows[$0] : nil })
        .reportsWidgetState(["rows": .number(Double(rows.count)), "total": .number(Double(total)),
                             "selected": selected.flatMap { rows.indices.contains($0) ? rows[$0] : nil } ?? .null])
        .handlesWidgetActions { name, input in
            switch name {
            case "select":
                let wanted = input["row"]?.string ?? input["row"].flatMap { $0.int.map(String.init) } ?? ""
                if let position = Int(wanted), rows.indices.contains(position - 1) {
                    selected = position - 1
                } else if let index = rows.firstIndex(where: { row in row.jsonString().localizedCaseInsensitiveContains(wanted) }) {
                    selected = index
                } else {
                    throw ToolError("No row matches “\(wanted)”.")
                }
                return ["selected": rows[selected!]]
            case "clear_selection":
                selected = nil
                return "cleared"
            default:
                throw ToolError("Unknown action \(name).")
            }
        }
    }

    private func load(periodic: Bool) async {
        guard let host else { return }
        repeat {
            do {
                let result = try await DataWidget.run(config, host: host)
                if result.rows != rows { selected = nil }
                rows = result.rows
                total = result.total
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            loaded = true
            try? await Task.sleep(for: .seconds(max(config.refreshSeconds, 15)))
        } while periodic && !Task.isCancelled
    }
}

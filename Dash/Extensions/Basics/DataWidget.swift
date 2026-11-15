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
        VStack(alignment: .leading, spacing: 6) {
            ForEach(["api-1 · CrashLoopBackOff · 12", "worker-1 · Error · 4", "db-0 · Running · 1"], id: \.self) {
                Text($0).font(.caption.monospaced())
            }
        }
        .padding(8)
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
    @Environment(\.widgetLayout) private var layout

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
                switch config.view {
                case "number": number
                case "counts": counts
                case "bars": bars
                case "list": list
                default: table
                }
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

    // MARK: Views

    private var columns: [String] {
        if !config.columns.isEmpty { return config.columns }
        guard case .object(let fields)? = rows.first else { return ["value"] }
        let preferred = ["name", "key", "title", "summary", "status", "namespace", "repo", "restarts", "risk", "updated", "count"]
        let ordered = preferred.filter { fields[$0] != nil } + fields.keys.sorted().filter { !preferred.contains($0) && !Self.isNested(fields[$0]) }
        return Array(ordered.prefix(layout.family == .narrow ? 2 : layout.family == .medium ? 4 : 6))
    }

    private static func isNested(_ value: JSONValue?) -> Bool {
        if case .object = value { return true }
        if case .array(let items) = value, items.contains(where: { if case .object = $0 { true } else { false } }) { return true }
        return false
    }

    private var table: some View {
        let columns = self.columns
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(columns, id: \.self) { column in
                    Text(column.replacingOccurrences(of: "_", with: " ").capitalized)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 10) {
                            ForEach(columns, id: \.self) { column in
                                Text(Self.display(row.value(at: column)))
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(selected == index ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                        .onTapGesture { selected = selected == index ? nil : index }
                        Divider().opacity(0.4)
                    }
                }
            }
            footer
        }
    }

    private var list: some View {
        let title = config.titleField ?? columns.first ?? "name"
        let subtitle = config.subtitleField ?? columns.dropFirst().first
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.display(row.value(at: title))).font(.callout).lineLimit(2)
                        if let subtitle { Text(Self.display(row.value(at: subtitle))).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected == index ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.3)), in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                    .onTapGesture { selected = selected == index ? nil : index }
                }
            }
        }
    }

    /// Rows from `count by x` (or any rows with a number): label and value.
    private var pairs: [(label: String, value: Double, index: Int)] {
        rows.enumerated().compactMap { index, row in
            guard case .object(let fields) = row else { return nil }
            let numberKey = fields["count"] != nil ? "count" : fields.first { $0.value.double != nil }?.key
            guard let numberKey, let value = fields[numberKey]?.double else { return nil }
            let label = fields.filter { $0.key != numberKey }.sorted { $0.key < $1.key }.map { Self.display($0.value) }.joined(separator: " · ")
            return (label.isEmpty ? numberKey : label, value, index)
        }
    }

    private var counts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
            ForEach(pairs, id: \.index) { pair in
                VStack(spacing: 2) {
                    Text(Self.number(pair.value)).font(.title2.weight(.semibold).monospacedDigit())
                    Text(pair.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(selected == pair.index ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.35)), in: .rect(cornerRadius: 10))
                .onTapGesture { selected = selected == pair.index ? nil : pair.index }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var number: some View {
        let value = pairs.first?.value ?? Double(total)
        return VStack(spacing: 4) {
            Text(Self.number(value)).font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
            Text(pairs.first?.label ?? config.dataset).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bars: some View {
        Chart(pairs, id: \.index) { pair in
            BarMark(x: .value("Count", pair.value), y: .value("Group", pair.label))
                .foregroundStyle(selected == pair.index ? Color.accentColor : Color.accentColor.opacity(0.55))
        }
        .chartOverlay { _ in Color.clear }
        .padding(.trailing, 4)
    }

    private var footer: some View {
        HStack {
            Text(total > rows.count ? "\(rows.count) of \(total)" : "\(rows.count) rows").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            if selected != nil { Text("Selected · linked widgets follow").font(.caption2).foregroundStyle(.tint) }
        }
        .padding(.horizontal, 8).padding(.top, 4)
    }

    static func display(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?:
            if let date = QueryEngine.date(.string(text)), text.count >= 10, text.contains("T") { return date.formatted(.relative(presentation: .named)) }
            return text
        case .number(let number)?: return Self.number(number)
        case .bool(let flag)?: return flag ? "yes" : "no"
        case .array(let items)?: return items.map { display($0) }.joined(separator: ", ")
        case .object?: return "…"
        default: return "—"
        }
    }

    static func number(_ value: Double) -> String {
        Int(exactly: value).map { $0.formatted() } ?? value.formatted(.number.precision(.fractionLength(1)))
    }
}

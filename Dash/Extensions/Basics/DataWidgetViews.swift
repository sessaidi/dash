import Charts
import DashKit
import DashKitUI
import SwiftUI

/// What a Data widget shows for its rows, per size family. The live widget and the gallery
/// preview both draw this, so the preview matches the dashboard at every size.
///
/// - narrow: a headline (row count, total or top group) over compact rows.
/// - medium: the configured view (table, list, counts, number, bars).
/// - wide: more columns, a two-column list, or the chart beside a summary.
/// - large: the view beside a detail panel (the selected row, or a breakdown).
struct DataWidgetContent: View {
    let config: DataWidget.Config
    let rows: [JSONValue]
    let total: Int
    @Binding var selected: Int?
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        let family = layout.family
        switch config.view {
        case "number": number(family)
        case "counts": counts(family)
        case "bars": bars(family)
        case "list": list(family)
        default: table(family)
        }
    }

    // MARK: Shared pieces

    private var selectedRow: JSONValue? { selected.flatMap { rows.indices.contains($0) ? rows[$0] : nil } }

    private func toggle(_ index: Int) { selected = selected == index ? nil : index }

    private func highlight(_ index: Int, idle: AnyShapeStyle = AnyShapeStyle(.clear)) -> AnyShapeStyle {
        selected == index ? AnyShapeStyle(.tint.opacity(0.18)) : idle
    }

    /// Columns to show: the configured ones, or the first few fields (more on wider cards).
    func columns(for family: WidgetLayout.Family) -> [String] {
        let limit = switch family {
        case .narrow: 2
        case .wide: 6
        case .large: 5
        default: 4
        }
        if !config.columns.isEmpty { return Array(config.columns.prefix(family == .narrow ? 2 : config.columns.count)) }
        return Array(Self.fields(of: rows).prefix(limit))
    }

    /// Every flat field of the rows, the usual identifying ones first.
    static func fields(of rows: [JSONValue]) -> [String] {
        guard case .object(let fields)? = rows.first else { return ["value"] }
        let preferred = ["name", "key", "title", "summary", "status", "namespace", "repo", "restarts", "risk", "updated", "count"]
        return preferred.filter { fields[$0] != nil } + fields.keys.sorted().filter { !preferred.contains($0) && !isNested(fields[$0]) }
    }

    private static func isNested(_ value: JSONValue?) -> Bool {
        if case .object = value { return true }
        if case .array(let items) = value, items.contains(where: { if case .object = $0 { true } else { false } }) { return true }
        return false
    }

    private static func heading(_ column: String) -> String {
        column.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// "12 pods", "3 of 40 jira".
    private var countLine: String {
        total > rows.count ? "\(rows.count) of \(total)" : "\(rows.count) \(rows.count == 1 ? "row" : "rows")"
    }

    private func headline(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1)
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Text(total > rows.count ? "\(rows.count) of \(total)" : "\(rows.count) rows").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            if selected != nil { Text("Selected · linked widgets follow").font(.caption2).foregroundStyle(.tint) }
        }
        .padding(.horizontal, 8).padding(.top, 4)
    }

    // MARK: Table

    @ViewBuilder
    private func table(_ family: WidgetLayout.Family) -> some View {
        switch family {
        case .narrow:
            compactRows(title: columns(for: .narrow).first ?? "value", detail: columns(for: .narrow).dropFirst().first)
        case .large:
            HStack(alignment: .top, spacing: 14) {
                grid(columns: columns(for: .large))
                detailPanel.frame(width: 240)
            }
        default:
            grid(columns: columns(for: family))
        }
    }

    /// A table with a header row; rows can be selected.
    private func grid(columns: [String]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(columns, id: \.self) { column in
                    Text(Self.heading(column)).frame(maxWidth: .infinity, alignment: .leading)
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
                        .background(highlight(index), in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                        .onTapGesture { toggle(index) }
                        Divider().opacity(0.4)
                    }
                }
            }
            footer
        }
    }

    /// Narrow: how many, then one line per row (its title, and one value on the right).
    private func compactRows(title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            headline("\(total > rows.count ? total : rows.count)", total > rows.count ? "\(config.dataset) · \(rows.count) shown" : config.dataset)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 6) {
                            Text(Self.display(row.value(at: title))).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let detail {
                                Text(Self.display(row.value(at: detail))).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(highlight(index), in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                        .onTapGesture { toggle(index) }
                    }
                }
            }
        }
    }

    /// Large: the selected row's every field, or what's here when nothing is selected.
    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let row = selectedRow {
                let fields = Self.fields(of: [row])
                HStack {
                    Text(Self.display(row.value(at: fields.first ?? "value"))).font(.headline).lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Clear", systemImage: "xmark.circle.fill") { selected = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                ScrollView {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        ForEach(fields.dropFirst(), id: \.self) { field in
                            GridRow {
                                Text(Self.heading(field)).font(.caption).foregroundStyle(.secondary)
                                Text(Self.display(row.value(at: field))).font(.callout).lineLimit(3).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                Text("Linked widgets follow this row.").font(.caption2).foregroundStyle(.tint)
            } else {
                headline("\(total > rows.count ? total : rows.count)", config.dataset)
                Text(countLine).font(.caption).foregroundStyle(.secondary)
                if !pairs.isEmpty && config.view != "table" {
                    breakdown
                } else {
                    Label("Select a row to see all its fields here; linked widgets follow it.", systemImage: "hand.point.up.left")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    // MARK: List

    @ViewBuilder
    private func list(_ family: WidgetLayout.Family) -> some View {
        let title = config.titleField ?? columns(for: family).first ?? "name"
        let subtitle = config.subtitleField ?? columns(for: family).dropFirst().first
        switch family {
        case .narrow:
            compactRows(title: title, detail: nil)
        case .wide:
            cards(title: title, subtitle: subtitle, columns: 2)
        case .large:
            HStack(alignment: .top, spacing: 14) {
                cards(title: title, subtitle: subtitle, columns: 1)
                detailPanel.frame(width: 260)
            }
        default:
            cards(title: title, subtitle: subtitle, columns: 1)
        }
    }

    private func cards(title: String, subtitle: String?, columns: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: columns), spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.display(row.value(at: title))).font(.callout).lineLimit(2)
                        if let subtitle { Text(Self.display(row.value(at: subtitle))).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlight(index, idle: AnyShapeStyle(.quaternary.opacity(0.3))), in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                    .onTapGesture { toggle(index) }
                }
            }
        }
    }

    // MARK: Counts, number, bars

    /// Rows from `count by x` (or any rows with a number): label and value.
    var pairs: [(label: String, value: Double, index: Int)] { Self.pairs(rows) }

    static func pairs(_ rows: [JSONValue]) -> [(label: String, value: Double, index: Int)] {
        rows.enumerated().compactMap { index, row in
            guard case .object(let fields) = row else { return nil }
            let numberKey = fields["count"] != nil ? "count" : fields.first { $0.value.double != nil }?.key
            guard let numberKey, let value = fields[numberKey]?.double else { return nil }
            let label = fields.filter { $0.key != numberKey }.sorted { $0.key < $1.key }.map { display($0.value) }.joined(separator: " · ")
            return (label.isEmpty ? numberKey : label, value, index)
        }
    }

    @ViewBuilder
    private func counts(_ family: WidgetLayout.Family) -> some View {
        switch family {
        case .narrow:
            VStack(alignment: .leading, spacing: 6) {
                headline(Self.number(pairs.reduce(0) { $0 + $1.value }), "total")
                pairRows(limit: nil)
            }
        case .large:
            VStack(spacing: 12) {
                tiles(minimum: 130)
                chart(limit: nil).frame(minHeight: 120)
            }
        default:
            tiles(minimum: family == .wide ? 130 : 110)
        }
    }

    private func tiles(minimum: CGFloat) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 8)], spacing: 8) {
                ForEach(pairs, id: \.index) { pair in
                    VStack(spacing: 2) {
                        Text(Self.number(pair.value)).font(.title2.weight(.semibold).monospacedDigit())
                        Text(pair.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(highlight(pair.index, idle: AnyShapeStyle(.quaternary.opacity(0.35))), in: .rect(cornerRadius: 10))
                    .contentShape(.rect)
                    .onTapGesture { toggle(pair.index) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Label, value and share, one per line; the first `limit` only.
    private func pairRows(limit: Int?) -> some View {
        let sum = max(pairs.reduce(0) { $0 + $1.value }, 1)
        let shown = limit.map { Array(pairs.prefix($0)) } ?? pairs
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(shown, id: \.index) { pair in
                    HStack(spacing: 6) {
                        Text(pair.label).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Self.number(pair.value)).monospacedDigit()
                        Text("\(Int((pair.value / sum * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(highlight(pair.index), in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                    .onTapGesture { toggle(pair.index) }
                }
            }
        }
    }

    private var breakdown: some View { pairRows(limit: nil) }

    @ViewBuilder
    private func number(_ family: WidgetLayout.Family) -> some View {
        let value = pairs.first?.value ?? Double(total)
        let size: CGFloat = switch family {
        case .narrow: 34
        case .wide, .large: 56
        default: 44
        }
        let big = VStack(spacing: 4) {
            Text(Self.number(value)).font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(pairs.first?.label ?? config.dataset).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Wider cards: the other numbers the query returned, beside the main one.
        if (family == .wide || family == .large) && pairs.count > 1 {
            HStack(spacing: 16) {
                big
                pairRows(limit: nil).frame(maxWidth: 280)
            }
        } else {
            big
        }
    }

    @ViewBuilder
    private func bars(_ family: WidgetLayout.Family) -> some View {
        switch family {
        case .narrow:
            VStack(alignment: .leading, spacing: 6) {
                if let top = pairs.max(by: { $0.value < $1.value }) {
                    headline(Self.number(top.value), top.label)
                }
                chart(limit: 5, axes: false)
            }
        case .wide, .large:
            HStack(alignment: .top, spacing: 16) {
                chart(limit: nil)
                VStack(alignment: .leading, spacing: 8) {
                    headline(Self.number(pairs.reduce(0) { $0 + $1.value }), "total")
                    Text("\(pairs.count) groups").font(.caption).foregroundStyle(.secondary)
                    pairRows(limit: family == .wide ? 6 : nil)
                }
                .frame(width: family == .wide ? 220 : 260)
            }
        default:
            chart(limit: nil)
        }
    }

    private func chart(limit: Int?, axes: Bool = true) -> some View {
        let shown = limit.map { Array(pairs.prefix($0)) } ?? pairs
        return Chart(shown, id: \.index) { pair in
            BarMark(x: .value("Count", pair.value), y: .value("Group", pair.label))
                .foregroundStyle(selected == pair.index ? Color.accentColor : Color.accentColor.opacity(0.55))
                .annotation(position: .trailing, alignment: .leading) {
                    if !axes { Text(Self.number(pair.value)).font(.caption2).foregroundStyle(.secondary) }
                }
        }
        .chartXAxis(axes ? .automatic : .hidden)
        .chartOverlay { _ in Color.clear }
        .padding(.trailing, 4)
    }

    // MARK: Formatting

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

/// The gallery preview: the same view over sample rows that fit the configured view.
struct DataWidgetPreview: View {
    let config: DataWidget.Config
    @State private var selected: Int?

    var body: some View {
        DataWidgetContent(config: config, rows: Self.rows(for: config.view), total: Self.rows(for: config.view).count, selected: $selected)
    }

    static func rows(for view: String) -> [JSONValue] {
        switch view {
        case "counts", "bars":
            return [["status": "Running", "count": 24], ["status": "Pending", "count": 6], ["status": "CrashLoopBackOff", "count": 3], ["status": "Error", "count": 1]]
        case "number":
            return [["count": 17]]
        default:
            return [
                ["name": "api-1", "namespace": "prod", "status": "CrashLoopBackOff", "restarts": 12, "node": "pool-a-1", "age": "2d"],
                ["name": "worker-1", "namespace": "prod", "status": "Error", "restarts": 4, "node": "pool-a-2", "age": "5h"],
                ["name": "db-0", "namespace": "data", "status": "Running", "restarts": 1, "node": "pool-b-1", "age": "12d"],
                ["name": "cache-2", "namespace": "prod", "status": "Running", "restarts": 0, "node": "pool-a-1", "age": "3d"],
                ["name": "web-7", "namespace": "edge", "status": "Pending", "restarts": 0, "node": "—", "age": "1m"],
            ]
        }
    }
}

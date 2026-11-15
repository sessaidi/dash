import DashKit
import Foundation
import SQLite3
import SwiftUI

/// Read-only access to Dash's SQLite files for the Debug window: tables with row counts, rows of
/// one table, and SELECT queries. Opened read-only, so nothing here can change data; SQLite
/// itself refuses reads of secret tables, and values are passed through the sanitizer.
final class DebugDatabase: @unchecked Sendable {
    struct Table: Identifiable, Hashable {
        let name: String
        let rows: Int
        var id: String { name }
    }

    struct Rows: Equatable {
        var columns: [String] = []
        var values: [[String]] = []
        var error: String?
    }

    let url: URL
    private var db: OpaquePointer?

    /// Longest value shown; longer ones end with "…".
    static let maxValueLength = 2000
    /// Rows a filtered query reads at most while looking for matches.
    static let maxScannedRows = 50_000

    /// Tables whose content is never shown (secrets, even encrypted).
    static func isSecret(_ table: String) -> Bool {
        let lower = table.lowercased()
        return lower.contains("secret") || lower.contains("vault")
    }

    /// Tables left out of the list: secrets and SQLite's own.
    static func isHidden(_ table: String) -> Bool {
        isSecret(table) || table.lowercased().hasPrefix("sqlite_")
    }

    init(url: URL) throws {
        self.url = url
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            db = nil
            throw ToolError("\(url.lastPathComponent): \(message)")
        }
        sqlite3_busy_timeout(db, 2000)
        // SQLite refuses any statement that reads a secret table, however it's named in the query,
        // and attaching other files (which would escape this check and outlive the query).
        sqlite3_set_authorizer(db, { _, action, table, _, _, _ in
            switch action {
            case SQLITE_ATTACH, SQLITE_DETACH: return SQLITE_DENY
            case SQLITE_READ:
                guard let table else { return SQLITE_OK }
                return DebugDatabase.isSecret(String(cString: table)) ? SQLITE_DENY : SQLITE_OK
            default: return SQLITE_OK
            }
        }, nil)
    }

    deinit { sqlite3_close(db) }

    func tables() -> [Table] {
        let names = run("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", limit: 2000).values.compactMap(\.first)
        return names.filter { !Self.isHidden($0) }.map { name in
            let count = Int(run("SELECT COUNT(*) FROM \(Self.quoted(name))", limit: 1).values.first?.first ?? "0") ?? 0
            return Table(name: name, rows: count)
        }
    }

    /// A page of a table; with a filter, the page of the rows where any column contains it.
    func rows(of table: String, filter: String = "", limit: Int = 200, offset: Int = 0) -> Rows {
        guard !Self.isSecret(table) else { return Rows(error: "Hidden: this table holds secrets.") }
        var sql = "SELECT * FROM \(Self.quoted(table))"
        var bindings: [String] = []
        if !filter.isEmpty {
            let columns = run("SELECT name FROM pragma_table_info(?1)", limit: 2000, bindings: [table]).values.compactMap(\.first)
            if !columns.isEmpty {
                sql += " WHERE " + columns.map { "CAST(\(Self.quoted($0)) AS TEXT) LIKE ?1 ESCAPE '\\'" }.joined(separator: " OR ")
                bindings = ["%" + Self.escapeLike(filter) + "%"]
            }
        }
        return run(sql + " LIMIT \(limit) OFFSET \(offset)", limit: limit, bindings: bindings)
    }

    /// A read-only query (SELECT/WITH/PRAGMA that reads); anything that writes is refused by SQLite
    /// itself, the file being open read-only. `filter` keeps the rows where any value contains it.
    func run(_ sql: String, limit: Int = 500, filter: String = "", bindings: [String] = []) -> Rows {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            return Rows(error: message.contains("prohibited") ? "Hidden: that table holds secrets." : message)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else { return Rows(error: "Read-only: only queries that read are allowed.") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        var result = Rows()
        let count = sqlite3_column_count(statement)
        result.columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        let needle = filter.lowercased()
        var scanned = 0
        while result.values.count < limit, scanned < Self.maxScannedRows {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { result.error = String(cString: sqlite3_errmsg(db)); break }
            scanned += 1
            let row = (0..<count).map { column -> String in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: return "∅"
                case SQLITE_BLOB: return "<\(sqlite3_column_bytes(statement, column)) bytes>"
                case SQLITE_FLOAT:
                    let value = sqlite3_column_double(statement, column)
                    if Self.isCoreDataDate(result.columns[Int(column)]) {
                        return Date(timeIntervalSinceReferenceDate: value).formatted(date: .abbreviated, time: .standard)
                    }
                    return String(value)
                default:
                    let text = Sanitizer.clean(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
                    return text.count > Self.maxValueLength ? String(text.prefix(Self.maxValueLength)) + "…" : text
                }
            }
            if needle.isEmpty || row.contains(where: { $0.lowercased().contains(needle) }) { result.values.append(row) }
        }
        if scanned == Self.maxScannedRows, result.values.count < limit {
            result.error = "Stopped after reading \(Self.maxScannedRows) rows; narrow the query."
        }
        return result
    }

    /// Core Data columns ("ZCREATEDAT", "ZDATE") hold seconds since 2001; other files (the
    /// knowledge graph) use their own epochs and are shown as numbers.
    static func isCoreDataDate(_ column: String) -> Bool {
        let upper = column.uppercased()
        return upper.hasPrefix("Z") && (upper.contains("DATE") || upper.hasSuffix("AT"))
    }

    private static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}

/// Debug › Database: pick a database, a table, browse rows (filtered), or run a query.
struct DatabasePane: View {
    @State private var source = Source.dash
    @State private var database: DebugDatabase?
    @State private var tables: [DebugDatabase.Table] = []
    @State private var table: String?
    @State private var rows = DebugDatabase.Rows()
    @State private var filter = ""
    @State private var page = 0
    @State private var query = ""
    @State private var error: String?
    let refresh: Int

    enum Source: String, CaseIterable, Identifiable {
        case dash = "Dash store", knowledge = "Knowledge graph"
        var id: String { rawValue }
        @MainActor var url: URL? {
            switch self {
            case .dash: try? ExtensionHost.storeURL()
            case .knowledge: KnowledgeExtension.defaultURL
            }
        }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Database", selection: $source) { ForEach(Source.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().padding(8)
                List(tables, selection: $table) { item in
                    HStack {
                        Text(item.name).font(.callout.monospaced()).lineLimit(1)
                        Spacer()
                        Text("\(item.rows)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(item.name)
                }
                if let url = database?.url {
                    Text(url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(2).padding(8).textSelection(.enabled)
                }
            }
            .frame(minWidth: 220, idealWidth: 260)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("SELECT … (read-only)", text: $query, axis: .vertical)
                        .font(.callout.monospaced()).lineLimit(1...4).textFieldStyle(.roundedBorder)
                        .onSubmit(runQuery)
                    Button("Run", action: runQuery).keyboardShortcut(.return, modifiers: .command).disabled(query.isEmpty)
                }
                HStack {
                    TextField("Filter rows", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Spacer()
                    if table != nil, query.isEmpty {
                        Button("Previous", systemImage: "chevron.left") { page -= 1; load() }.disabled(page == 0)
                        Text(rows.values.isEmpty ? "no rows" : "rows \(page * 200 + 1)–\(page * 200 + rows.values.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Next", systemImage: "chevron.right") { page += 1; load() }.disabled(rows.values.count < 200)
                    }
                }
                .labelStyle(.iconOnly)
                if let message = error ?? rows.error {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                RowsTable(rows: rows)
            }
            .padding(10)
            .frame(minWidth: 480)
        }
        .onChange(of: source, initial: true) { open() }
        .onChange(of: table) { page = 0; query = ""; load() }
        .onChange(of: filter) { page = 0; load() }
        .onChange(of: refresh) { tables = database?.tables() ?? []; load() }
    }

    private func open() {
        error = nil
        table = nil
        rows = DebugDatabase.Rows()
        database = nil
        tables = []
        guard let url = source.url, FileManager.default.fileExists(atPath: url.path) else { error = "No database file yet."; return }
        do {
            database = try DebugDatabase(url: url)
            tables = database?.tables() ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() {
        guard let database else { return }
        if !query.isEmpty { runQuery(); return }
        guard let table else { return }
        rows = database.rows(of: table, filter: filter, offset: page * 200)
    }

    private func runQuery() {
        guard let database, !query.isEmpty else { return }
        rows = database.run(query, filter: filter)
    }
}

/// Rows in a native table (resizable columns, one line per row, full value on hover), and the
/// selected row's fields in full below it.
private struct RowsTable: View {
    let rows: DebugDatabase.Rows
    @State private var selection: Int?

    struct Row: Identifiable {
        let id: Int
        let values: [String]
    }

    struct Column: Identifiable {
        let id: Int
        let name: String
    }

    var body: some View {
        // Another table, page or query: the selected index would point at a different row.
        content.onChange(of: rows) { selection = nil }
    }

    @ViewBuilder private var content: some View {
        if rows.columns.isEmpty {
            ContentUnavailableView("Pick a table", systemImage: "tablecells", description: Text("Or run a read-only query above."))
        } else {
            let items = rows.values.enumerated().map { Row(id: $0, values: $1) }
            let columns = rows.columns.enumerated().map { Column(id: $0, name: $1) }
            VSplitView {
                Table(items, selection: $selection) {
                    TableColumnForEach(columns) { column in
                        TableColumn(column.name) { (row: Row) in
                            let value = column.id < row.values.count ? row.values[column.id] : ""
                            Text(value.replacingOccurrences(of: "\n", with: " ⏎ "))
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .foregroundStyle(value == "∅" ? .tertiary : .primary)
                                .help(value)
                        }
                        .width(min: 40, ideal: Self.idealWidth(column.name, items.prefix(50).map { column.id < $0.values.count ? $0.values[column.id] : "" }))
                    }
                }
                .frame(minHeight: 180)
                if let selection, selection < items.count {
                    ScrollView {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(columns) { column in
                                GridRow(alignment: .firstTextBaseline) {
                                    Text(column.name).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                                    Text(items[selection].values[column.id]).font(.caption.monospaced()).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120)
                }
            }
            Text("\(rows.values.count) rows\(selection == nil ? " · select one to see it in full" : "")").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Wide enough for the header and typical values, capped.
    static func idealWidth(_ name: String, _ values: [String]) -> CGFloat {
        let longest = max(name.count, values.map { min($0.count, 60) }.max() ?? 0)
        return min(max(CGFloat(longest) * 7 + 16, 50), 420)
    }
}

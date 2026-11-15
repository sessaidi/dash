import DashKit
import DashKitUI
import Foundation
import SwiftData
import SwiftUI

/// A user-made page in the sidebar, with its own widget grid.
@Model
final class DashboardPage {
    @Attribute(.unique) var id: UUID
    var name: String
    var systemImage: String
    var order: Int
    /// The sidebar section the page sits in; nil is the built-in "Pages" section.
    var sectionID: UUID? = nil
    /// Shows the Home header (greeting, ask bar, suggestions, brief) above the widgets.
    var showsHome: Bool = false
    /// A layout Dashii suggested: shown with Keep / Change / Discard until the user decides.
    var isDraft: Bool = false
    /// Why Dashii laid it out this way, shown on the draft.
    var draftRationale: String = ""

    init(name: String, systemImage: String, order: Int, sectionID: UUID? = nil) {
        id = UUID()
        self.name = name
        self.systemImage = systemImage
        self.order = order
        self.sectionID = sectionID
    }
}

/// A user-made group of pages in the sidebar, like Slack's custom sections: renameable and
/// reorderable.
@Model
final class SidebarSection {
    @Attribute(.unique) var id: UUID
    var name: String
    var order: Int
    /// No longer used (sections can't be folded); kept so existing stores open unchanged.
    var collapsed: Bool = false

    init(name: String, order: Int) {
        id = UUID()
        self.name = name
        self.order = order
    }
}

/// A widget placed on the dashboard.
@Model
final class WidgetRecord {
    @Attribute(.unique) var id: UUID
    var kind: String
    var title: String
    var sizeRaw: String
    var configData: Data
    var order: Int
    /// Grid cell position and size; gridX < 0 means not placed yet (older stores).
    var gridX: Int = -1
    var gridY: Int = 0
    var gridW: Int = 4
    var gridH: Int = 6
    /// Its DashQL query (the query bar): filter, sort, take on its rows.
    var query: String = ""
    /// The page it sits on; nil only in stores that predate pages.
    var pageID: UUID?

    init(id: UUID = UUID(), kind: String, title: String, size: WidgetSize, config: JSONValue, order: Int) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sizeRaw = size.rawValue
        self.configData = (try? config.data()) ?? Data("{}".utf8)
        self.order = order
    }

    var size: WidgetSize {
        get { WidgetSize(rawValue: sizeRaw) ?? .medium }
        set { sizeRaw = newValue.rawValue }
    }

    var frame: GridFrame {
        get { GridFrame(x: gridX, y: gridY, w: gridW, h: gridH) }
        set {
            if gridX != newValue.x { gridX = newValue.x }
            if gridY != newValue.y { gridY = newValue.y }
            if gridW != newValue.w { gridW = newValue.w }
            if gridH != newValue.h { gridH = newValue.h }
        }
    }

    var config: JSONValue {
        get { (try? JSONValue.parse(configData)) ?? .object([:]) }
        set { if let data = try? newValue.data(), data != configData { configData = data } }
    }
}

/// Pages and their widget grids, shared by the UI and Claude's tools.
@MainActor
final class DashboardStore {
    private unowned let host: ExtensionHost
    private var context: ModelContext { host.context }

    /// Gravity to the top: after a move or resize, widgets in the way move down, then every
    /// widget rises (keeping its size) to fill the empty space above it.
    let engine = GridEngine(columns: 12, minSize: (2, 3), compacts: true)

    /// Each widget's resize limits, from its type.
    func limits(on pageID: UUID?) -> [UUID: GridLimits] {
        Dictionary(uniqueKeysWithValues: widgets(on: pageID).compactMap { record in
            host.widgetType(record.kind).map { (record.id, $0.sizeLimits) }
        })
    }
    /// SF Symbols offered for pages, grouped for the icon picker.
    static let pageIconGroups: [(name: String, symbols: [String])] = [
        ("General", ["house", "square.grid.2x2", "star", "heart", "flag", "bookmark", "tag", "pin", "bell", "bolt", "sparkles",
                     "flame", "leaf", "sun.max", "moon", "globe", "map", "location", "lightbulb", "graduationcap"]),
        ("Work", ["briefcase", "calendar", "clock", "checklist", "list.bullet.rectangle", "tray", "folder", "doc.text",
                  "book", "books.vertical", "archivebox", "paperclip", "envelope", "bubble.left.and.bubble.right", "phone",
                  "video", "mic", "person", "person.2", "person.3"]),
        ("Engineering", ["hammer", "wrench.and.screwdriver", "terminal", "chevron.left.forwardslash.chevron.right",
                         "curlybraces", "ladybug", "ant", "testtube.2", "cpu", "memorychip", "server.rack", "externaldrive",
                         "cylinder.split.1x2", "network", "point.3.connected.trianglepath.dotted", "arrow.triangle.branch",
                         "arrow.triangle.pull", "shippingbox", "cube", "puzzlepiece.extension"]),
        ("Ops", ["cloud", "icloud", "antenna.radiowaves.left.and.right", "wifi", "lock", "lock.shield", "key", "shield.checkered",
                 "exclamationmark.triangle", "stethoscope", "waveform.path.ecg", "gauge.with.dots.needle.67percent", "speedometer",
                 "thermometer.medium", "powerplug", "battery.100", "arrow.clockwise", "arrow.up.circle", "rocket", "airplane"]),
        ("Data", ["chart.bar", "chart.line.uptrend.xyaxis", "chart.pie", "chart.xyaxis.line", "tablecells", "function",
                  "percent", "number", "sum", "dollarsign.circle", "creditcard", "cart", "bag", "gift", "trophy",
                  "medal", "target", "scope", "magnifyingglass", "eye"]),
    ]

    static var pageIcons: [String] { pageIconGroups.flatMap(\.symbols) }

    init(host: ExtensionHost) {
        self.host = host
    }

    // MARK: Pages

    /// The first page gets the Home header once, on the first launch that has it.
    func seedHome() {
        guard !DashDefaults.shared.bool(forKey: "home.seeded"), let first = pages().first else { return }
        DashDefaults.shared.set(true, forKey: "home.seeded")
        if !pages().contains(where: \.showsHome) { first.showsHome = true }
        try? context.save()
    }

    func pages() -> [DashboardPage] {
        (try? context.fetch(FetchDescriptor<DashboardPage>(sortBy: [SortDescriptor(\.order)]))) ?? []
    }

    func page(_ id: UUID) throws -> DashboardPage {
        guard let page = pages().first(where: { $0.id == id }) else { throw ToolError("No page with id \(id). Call list_pages.") }
        return page
    }

    /// The page new widgets go to: the one on screen, else the first.
    var currentPageID: UUID? { host.selectedPageID.flatMap { id in pages().first { $0.id == id }?.id } ?? pages().first?.id }

    @discardableResult
    func createPage(name: String, systemImage: String = "square.grid.2x2", section sectionID: UUID? = nil) -> DashboardPage {
        let page = DashboardPage(name: name, systemImage: systemImage, order: (pages().last?.order ?? -1) + 1, sectionID: sectionID)
        context.insert(page)
        try? context.save()
        host.activity.emit("page.created", source: "dashboard", title: "Created page “\(name)”")
        return page
    }

    func updatePage(_ id: UUID, name: String? = nil, systemImage: String? = nil, showsHome: Bool? = nil) throws {
        let page = try page(id)
        if let name, !name.isEmpty { page.name = name }
        if let systemImage { page.systemImage = systemImage }
        if let showsHome { page.showsHome = showsHome }
        try context.save()
    }

    /// Reorders pages within a section (`source`/`destination` index that section's pages).
    func movePages(in sectionID: UUID?, from source: IndexSet, to destination: Int) {
        let all = pages()
        var inSection = all.filter { $0.sectionID == sectionID }
        inSection.move(fromOffsets: source, toOffset: destination)
        // Keep other sections' pages where they are; renumber this section's in its slots.
        let slots = all.enumerated().filter { $0.element.sectionID == sectionID }.map(\.offset)
        var ordered = all
        for (slot, page) in zip(slots, inSection) { ordered[slot] = page }
        for (index, page) in ordered.enumerated() where page.order != index { page.order = index }
        try? context.save()
    }

    // MARK: Sidebar sections

    /// The built-in section for pages not in a custom one. Its name is the user's to change.
    static let defaultSectionKey = "dash.defaultSection"
    var defaultSectionName: String {
        get { DashDefaults.shared.string(forKey: Self.defaultSectionKey + ".name") ?? "Pages" }
        set { DashDefaults.shared.set(newValue, forKey: Self.defaultSectionKey + ".name") }
    }

    func sections() -> [SidebarSection] {
        (try? context.fetch(FetchDescriptor<SidebarSection>(sortBy: [SortDescriptor(\.order)]))) ?? []
    }

    @discardableResult
    func createSection(name: String) -> SidebarSection {
        let section = SidebarSection(name: name, order: (sections().last?.order ?? -1) + 1)
        context.insert(section)
        try? context.save()
        return section
    }

    /// Renames a custom section, or the built-in one when `id` is nil.
    func renameSection(_ id: UUID?, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let id {
            sections().first { $0.id == id }?.name = name
            try? context.save()
        } else {
            defaultSectionName = name
        }
    }

    /// Deletes a section; its pages go back to the built-in section.
    func deleteSection(_ id: UUID) {
        for page in pages() where page.sectionID == id { page.sectionID = nil }
        if let section = sections().first(where: { $0.id == id }) { context.delete(section) }
        try? context.save()
    }

    /// Moves a page into a section (nil: the built-in one): just before `target` when given,
    /// otherwise at the end of the section.
    func movePage(_ pageID: UUID, toSection sectionID: UUID?, before target: UUID? = nil) {
        var ordered = pages()
        guard let index = ordered.firstIndex(where: { $0.id == pageID }) else { return }
        let page = ordered.remove(at: index)
        if target == nil, page.sectionID == sectionID { return }
        page.sectionID = sectionID
        let destination = target.flatMap { id in ordered.firstIndex { $0.id == id } } ?? ordered.endIndex
        ordered.insert(page, at: destination)
        for (order, page) in ordered.enumerated() where page.order != order { page.order = order }
        try? context.save()
    }

    func moveSections(from source: IndexSet, to destination: Int) {
        var ordered = sections()
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, section) in ordered.enumerated() where section.order != index { section.order = index }
        try? context.save()
    }

    /// Deletes a page and its widgets. The last page can't be deleted.
    /// Sets a widget's DashQL query (empty clears it). Throws when it doesn't parse or the widget
    /// has no query bar.
    func setQuery(_ id: UUID, _ text: String) throws {
        let record = try widget(id)
        guard let type = host.widgetType(record.kind) else { throw ToolError("Unknown widget kind \"\(record.kind)\".") }
        guard !type.queryFields.isEmpty || text.isEmpty else { throw ToolError("\(type.displayName) has no query bar.") }
        // Links to other widgets' selections are checked with a stand-in value.
        let checked = text.replacing(/\$selected\("[^"]+"\)(?:\.[\w.]+)?/) { _ in "\"x\"" }
        do { _ = try WidgetQuery(checked, fields: type.queryFields) } catch let error as QueryError { throw ToolError(error.message) }
        record.query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try context.save()
    }

    /// A page for a suggested layout, marked as a draft until the user keeps it.
    func createDraftPage(name: String, systemImage: String, rationale: String) -> DashboardPage {
        let page = createPage(name: name, systemImage: systemImage)
        page.isDraft = true
        page.draftRationale = rationale
        try? context.save()
        return page
    }

    /// The user keeps a suggested layout: it becomes an ordinary page.
    func keepDraft(_ id: UUID) throws {
        let page = try page(id)
        page.isDraft = false
        page.draftRationale = ""
        try context.save()
    }

    func deletePage(_ id: UUID) throws {
        guard pages().count > 1 else { throw ToolError("Keep at least one page.") }
        let page = try page(id)
        for record in widgets(on: id) { context.delete(record) }
        host.activity.emit("page.deleted", source: "dashboard", title: "Deleted page “\(page.name)”", importance: .notable)
        context.delete(page)
        try context.save()
        if host.selectedPageID == id { host.selectedPageID = pages().first?.id }
    }

    // MARK: Widgets

    private func allWidgets() -> [WidgetRecord] {
        (try? context.fetch(FetchDescriptor<WidgetRecord>(sortBy: [SortDescriptor(\.order)]))) ?? []
    }

    /// Widgets on a page (all pages when nil), in reading order.
    func widgets(on pageID: UUID? = nil) -> [WidgetRecord] {
        let pageOrder = Dictionary(uniqueKeysWithValues: pages().map { ($0.id, $0.order) })
        return allWidgets()
            .filter { pageID == nil || $0.pageID == pageID }
            .sorted { a, b in
                let pa = a.pageID.flatMap { pageOrder[$0] } ?? 0, pb = b.pageID.flatMap { pageOrder[$0] } ?? 0
                return pa != pb ? pa < pb : engine.order(a.frame, b.frame)
            }
    }

    func frames(on pageID: UUID?) -> [UUID: GridFrame] {
        // Hidden widgets (extension missing or off) don't take part in layout.
        Dictionary(uniqueKeysWithValues: widgets(on: pageID)
            .filter { $0.gridX >= 0 && $0.pageID == pageID && host.isWidgetAvailable($0.kind) }
            .map { ($0.id, $0.frame) })
    }

    /// Saves a layout from the grid (after a drag or resize).
    func apply(_ layout: [UUID: GridFrame]) {
        var moved: [String] = []
        for record in allWidgets() {
            if let frame = layout[record.id], frame != record.frame {
                record.frame = frame
                moved.append(record.title)
            }
        }
        if !moved.isEmpty {
            host.activity.emit("layout.changed", source: "dashboard", title: "Rearranged a page", detail: "moved: \(moved.joined(separator: ", "))")
        }
        renumber()
        try? context.save()
    }

    /// Keeps `order` in reading order across pages.
    private func renumber() {
        for (index, record) in widgets().enumerated() where record.order != index { record.order = index }
    }

    /// Older stores: create a Home page, put page-less widgets on it, place unplaced ones on the grid.
    func migrate() {
        if pages().isEmpty { createPage(name: "Home", systemImage: "house") }
        guard let home = pages().first?.id else { return }
        for record in allWidgets() where record.pageID == nil { record.pageID = home }
        for page in pages() {
            var layout = frames(on: page.id)
            for record in widgets(on: page.id) where record.gridX < 0 {
                let frame = engine.firstFit(w: record.size.cells.w, h: record.size.cells.h, in: layout)
                record.frame = frame
                layout[record.id] = frame
            }
        }
        try? context.save()
    }

    func widget(_ id: UUID) throws -> WidgetRecord {
        let descriptor = FetchDescriptor<WidgetRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else { throw ToolError("No widget with id \(id).") }
        return record
    }

    @discardableResult
    func add(kind: String, title: String? = nil, size: WidgetSize? = nil, config patch: JSONValue? = nil, page pageID: UUID? = nil) throws -> WidgetRecord {
        guard let type = host.widgetType(kind) else {
            throw ToolError("No installed, enabled extension provides the widget kind \"\(kind)\". Available kinds: \(host.widgetTypes.map(\.kind).joined(separator: ", ")). Install or turn on its plugin first.")
        }
        if pages().isEmpty { migrate() }
        guard let page = pageID ?? currentPageID else { throw ToolError("No page to add to.") }
        _ = try self.page(page)
        let config = try type.normalize(type.defaultConfig.merging(patch ?? .object([:])))
        let preset = size ?? type.defaultSize
        let record = WidgetRecord(kind: kind, title: title ?? type.displayName, size: preset, config: config, order: allWidgets().count)
        record.pageID = page
        let fitted = engine.clamp(GridFrame(x: 0, y: 0, w: preset.cells.w, h: preset.cells.h), limits: type.sizeLimits)
        record.frame = engine.firstFit(w: fitted.w, h: fitted.h, in: frames(on: page))
        context.insert(record)
        try context.save()
        host.activity.emit("widget.added", source: "dashboard", title: "Added widget “\(record.title)” (\(kind))")
        return record
    }

    func update(_ id: UUID, title: String? = nil, size: WidgetSize? = nil, config patch: JSONValue? = nil) throws {
        let record = try widget(id)
        if let patch {
            guard let type = host.widgetType(record.kind) else { throw ToolError("Unknown widget kind \"\(record.kind)\".") }
            record.config = try type.normalize(record.config.merging(patch))
        }
        if let title { record.title = title }
        if let size {
            record.size = size
            var frame = record.frame
            (frame.w, frame.h) = size.cells
            apply(engine.layout(frames(on: record.pageID), moving: record.id, to: frame, limits: limits(on: record.pageID)))
        }
        try context.save()
    }

    /// Moves and/or resizes a widget on its page's grid, or moves it to another page.
    func place(_ id: UUID, x: Int? = nil, y: Int? = nil, w: Int? = nil, h: Int? = nil, page newPage: UUID? = nil) throws {
        let record = try widget(id)
        if let newPage, newPage != record.pageID {
            _ = try page(newPage)
            let old = record.pageID
            record.pageID = newPage
            record.frame = engine.firstFit(w: record.gridW, h: record.gridH, in: frames(on: newPage).filter { $0.key != id })
            apply(engine.compact(frames(on: old)))
        }
        var frame = record.frame
        frame.x = x ?? frame.x
        frame.y = y ?? frame.y
        frame.w = w ?? frame.w
        frame.h = h ?? frame.h
        apply(engine.layout(frames(on: record.pageID), moving: id, to: frame, limits: limits(on: record.pageID)))
    }

    func remove(_ id: UUID) throws {
        let record = try widget(id)
        let page = record.pageID
        host.activity.emit("widget.removed", source: "dashboard", title: "Removed widget “\(record.title)”")
        context.delete(record)
        try context.save()
        host.clearAIChoices(.widget(id))
        // Close the gap it leaves.
        apply(engine.compact(frames(on: page)))
    }

    func configBinding(for record: WidgetRecord) -> Binding<JSONValue> {
        Binding(get: { record.config }, set: { record.config = $0 })
    }

    func describe(_ record: WidgetRecord) -> JSONValue {
        ["id": .string(record.id.uuidString), "page_id": record.pageID.map { .string($0.uuidString) } ?? .null,
         "kind": .string(record.kind), "title": .string(record.title),
         "size": .string(record.sizeRaw), "x": .number(Double(record.gridX)), "y": .number(Double(record.gridY)),
         "w": .number(Double(record.gridW)), "h": .number(Double(record.gridH)), "config": record.config,
         "query": record.query.isEmpty ? .null : .string(record.query)]
    }

    func describe(_ page: DashboardPage) -> JSONValue {
        ["id": .string(page.id.uuidString), "name": .string(page.name), "icon": .string(page.systemImage),
         "widgets": .number(Double(widgets(on: page.id).count)), "on_screen": .bool(page.id == currentPageID),
         "draft": .bool(page.isDraft)]
    }

    func snapshot(_ id: UUID) async throws -> JSONValue {
        let record = try widget(id)
        guard let type = host.widgetType(record.kind) else { throw ToolError("Unknown widget kind \"\(record.kind)\".") }
        let live = host.live(id)
        live.attention = .now
        let data = await type.snapshot(record.config, WidgetContext(widgetID: id, host: host, aiTasks: type.aiTasks, queryText: record.query))
        // What it is, what's on screen beyond its config, and what Dashii can do with it.
        return describe(record).merging([
            "type": ["name": .string(type.displayName), "summary": .string(type.summary)],
            "data": data,
            "on_screen": .bool(live.handler != nil || live.state != .null),
            "ui_state": live.state,
            "actions": .array(type.actions.map(\.json)),
            "query_fields": .array(type.queryFields.map { .string($0.name + ($0.aliases.isEmpty ? "" : " (" + $0.aliases.joined(separator: ", ") + ")")) }),
        ])
    }

    /// First launch: a Home page with one widget per extension.
    func seedIfEmpty() {
        migrate()
        guard allWidgets().isEmpty else { return }
        for kind in ["jira.board", "github.pulls", "agents.sessions", "workspaces.list", "zoom.meeting", "note"] where host.widgetType(kind) != nil {
            _ = try? add(kind: kind)
        }
    }
}

import DashKit
import Foundation

/// What the user is looking at, for Claude: a one-line summary sent with every message, and
/// tools to read the view in detail and to change it.
@MainActor
enum ViewContext {
    /// One line for <current-view>: the page and its widgets, or the open note.
    static func summary(host: ExtensionHost) -> String {
        switch host.mainView {
        case "notes":
            guard let notes = host.ext(NotesExtension.self), let title = notes.openNote else { return "Notes, no note open." }
            let note = notes.store.note(titled: title)
            let parent = note.flatMap { notes.store.parent(of: $0) }.map { ", a sub-note of “\($0.title)”" } ?? ""
            let children = note.map { notes.store.children(of: $0).map(\.title) } ?? []
            return "Notes: the note “\(title)” is open\(parent), \(notes.openNoteEditing ? "in the editor" : "in preview")"
                + (children.isEmpty ? "." : "; its sub-notes: \(children.map { "“\($0)”" }.joined(separator: ", ")).")
        case "knowledge":
            return "The Knowledge view."
        default:
            guard let store = host.dashboard, let page = store.pages().first(where: { $0.id == store.currentPageID }) else { return "A dashboard page." }
            let widgets = store.widgets(on: page.id).filter { $0.gridX >= 0 && host.isWidgetAvailable($0.kind) }
                .sorted { ($0.gridY, $0.gridX) < ($1.gridY, $1.gridX) }
            let list = widgets.prefix(24).map { "\($0.title) [\($0.kind), id \($0.id.uuidString)]" }.joined(separator: "; ")
            return "The page “\(page.name)” (id \(page.id.uuidString))\(host.layoutEditing ? ", layout being edited" : ""), "
                + (widgets.isEmpty ? "empty." : "with widgets in reading order: \(list).")
        }
    }

    private struct ShowInput: Decodable { let page: String?; let note: String?; let view: String? }

    static func tools(host: ExtensionHost) -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "view_current",
                description: "What the user is looking at right now, in detail: on a page, every widget with its live data; in Notes, the open note's full Markdown. \"This\", \"here\" and \"these\" usually mean this view."
            ) { _ in
                switch host.mainView {
                case "notes":
                    guard let notes = host.ext(NotesExtension.self), let title = notes.openNote, let note = notes.store.note(titled: title) else {
                        return ["view": "notes", "note": .null]
                    }
                    return ["view": "notes", "note": .string(title), "editing": .bool(notes.openNoteEditing),
                            "parent": notes.store.parent(of: note).map { .string($0.title) } ?? .null,
                            "sub_notes": .array(notes.store.children(of: note).map { .string($0.title) }),
                            "markdown": .string(notes.store.read(note))]
                case "knowledge":
                    return ["view": "knowledge"]
                default:
                    guard let store = host.dashboard, let page = store.pages().first(where: { $0.id == store.currentPageID }) else { return ["view": "page"] }
                    var widgets: [JSONValue] = []
                    for record in store.widgets(on: page.id) where record.gridX >= 0 && host.isWidgetAvailable(record.kind) {
                        var described = (try? await store.snapshot(record.id)) ?? store.describe(record)
                        // Keep a page of many widgets readable.
                        if described.jsonString().count > 6000, case .object(var fields) = described {
                            fields["data"] = .string(String(fields["data"]?.jsonString().prefix(6000) ?? "") + "… (cut; read_widget for all of it)")
                            described = .object(fields)
                        }
                        widgets.append(described)
                    }
                    return ["view": "page", "page": store.describe(page), "editing_layout": .bool(host.layoutEditing), "widgets": .array(widgets)]
                }
            },
            ClaudeTool(
                name: "view_show",
                description: "Change what's on screen: open a dashboard page (by name or id), open a note in Notes (by title), or go to Notes or Knowledge. Use it to show the user what you're talking about or what you just made.",
                properties: ["page": JSONSchema.string("Page name or id."), "note": JSONSchema.string("Note title to open in Notes."),
                             "view": JSONSchema.string("A view without a page or note.", enum: ["notes", "knowledge"])]
            ) { input in
                let request = try input.toolInput(ShowInput.self)
                if let title = request.note {
                    guard let notes = host.ext(NotesExtension.self), notes.store.note(titled: title) != nil else { throw ToolError("No note titled “\(title)”.") }
                    host.mainView = "notes"
                    notes.openRequest = title
                } else if let name = request.page {
                    guard let store = host.dashboard else { throw ToolError("No dashboard.") }
                    let pages = store.pages()
                    guard let page = pages.first(where: { $0.id.uuidString == name }) ?? pages.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
                            ?? pages.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
                        throw ToolError("No page named “\(name)”. Pages: \(pages.map(\.name).joined(separator: ", ")).")
                    }
                    host.mainView = "page"
                    host.selectedPageID = page.id
                } else if let view = request.view {
                    host.mainView = view
                } else {
                    throw ToolError("Say which page, note or view to show.")
                }
                return .string(summary(host: host))
            },
        ]
    }
}

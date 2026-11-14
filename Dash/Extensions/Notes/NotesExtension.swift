import AppKit
import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Notes: Markdown files with native components and AI help, reachable from the sidebar,
/// from Claude (search, read, create, append) and from plugins (`host.createNote`), e.g. a
/// meeting plugin writing its notes.
@MainActor
@Observable
final class NotesExtension: DashExtension {
    let id = "notes"
    let name = "Notes"
    let systemImage = "note.text"
    let metadata = ExtensionMetadata(version: "1.0.0", summary: "Markdown notes with native components, links, backlinks and AI help.",
                                     category: .productivity, homepage: "https://github.com/sessaidi/dash")

    let store: NotesStore
    /// The note open in the Notes view (so Claude knows what "this note" is), and whether it's being edited.
    var openNote: String?
    var openNoteEditing = false
    /// Set to a title to have the Notes view open that note (Claude's view_show).
    var openRequest: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var host: (any ExtensionContext)?

    init(defaults: UserDefaults = DashDefaults.shared, vault: URL? = nil) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "notes.vault").map { URL(fileURLWithPath: $0, isDirectory: true) }
        store = NotesStore(vault: vault ?? saved ?? NotesStore.defaultVault)
    }

    func start(host: any ExtensionContext) {
        self.host = host
        store.reload()
    }

    func setVault(_ url: URL) {
        defaults.set(url.path(percentEncoded: false), forKey: "notes.vault")
        store.setVault(url)
    }

    func settingsView() -> AnyView { AnyView(NotesSettings(notes: self)) }

    /// Notes by the day they were last changed.
    var activitySeries: [ActivitySeries] {
        [ActivitySeries(id: "edited", title: "Notes edited", unit: "notes", systemImage: "note.text") { [weak self] interval in
            ActivitySeries.countPerDay(self?.store.notes.map(\.modified) ?? [], in: interval)
        }]
    }

    /// The built-in note components (`@Callout`, `@Columns`, `@Widget`…).
    var components: [MarkdownComponentType] { CoreComponents.all }

    // MARK: AI

    enum Action: String, CaseIterable, Identifiable {
        case summarize, continueWriting, actionItems
        var id: String { rawValue }
        var title: String {
            switch self {
            case .summarize: "Summarize"
            case .continueWriting: "Continue Writing"
            case .actionItems: "Extract Action Items"
            }
        }
        var systemImage: String {
            switch self {
            case .summarize: "text.badge.star"
            case .continueWriting: "text.append"
            case .actionItems: "checklist"
            }
        }
    }

    static let assistTask = AITask(
        id: "assist", title: "Writing help",
        summary: "Summarizes, continues and extracts action items from a note.",
        models: [.sonnet, .haiku, .opus], defaultModel: .sonnet, efforts: [.low, .medium, .high], defaultEffort: .low,
        templates: [
            AITemplate(id: Action.summarize.rawValue, title: "Summarize",
                       defaultText: "Summarize this note in 3 to 5 bullet points. Reply with Markdown only.\n\n# {{title}}\n{{text}}",
                       variables: ["title": "Note title", "text": "Note text"], multiline: true),
            AITemplate(id: Action.continueWriting.rawValue, title: "Continue writing",
                       defaultText: "Continue this note in the same voice and format, adding one or two paragraphs. Reply with only the new text.\n\n# {{title}}\n{{text}}",
                       variables: ["title": "Note title", "text": "Note text"], multiline: true),
            AITemplate(id: "selection", title: "Selected text",
                       defaultText: "{{instruction}} Reply with only the replacement text, in Markdown, no preamble.\n\nFrom the note “{{title}}”:\n\n{{selection}}",
                       variables: ["instruction": "What to do (rewrite, translate…)", "title": "Note title", "selection": "The selected text"], multiline: true),
            AITemplate(id: Action.actionItems.rawValue, title: "Action items",
                       defaultText: "List the action items in this note as a Markdown checklist (- [ ] …), with owners when named. Reply with the checklist only.\n\n# {{title}}\n{{text}}",
                       variables: ["title": "Note title", "text": "Note text"], multiline: true),
        ])

    var aiTasks: [AITask] { [Self.assistTask] }

    /// Runs an AI action on a note's text and returns Markdown to insert.
    func run(_ action: Action, title: String, text: String) async throws -> String {
        guard let host else { throw ToolError("Notes isn't running.") }
        let settings = host.aiSettings(.extension(id), tasks: aiTasks)
        let prompt = settings.render(Self.assistTask.id, action.rawValue, ["title": title, "text": text])
        return try await host.claude.complete(task: Self.assistTask.id, settings: settings,
                                              system: "You help write notes. Reply with Markdown only, no preamble.", prompt: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs an AI action on selected text and returns the replacement.
    func run(_ action: NoteSelectionAction, selection: String, title: String) async throws -> String {
        guard let host else { throw ToolError("Notes isn't running.") }
        let settings = host.aiSettings(.extension(id), tasks: aiTasks)
        let prompt = settings.render(Self.assistTask.id, "selection", ["instruction": action.instruction, "title": title, "selection": selection])
        return try await host.claude.complete(task: Self.assistTask.id, settings: settings,
                                              system: "You edit text in notes. Reply with Markdown only, no preamble.", prompt: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Claude tools

    private struct SearchInput: Decodable { let query: String? }
    private struct TitleInput: Decodable { let title: String }
    private struct CreateInput: Decodable { let title: String; let markdown: String; let folder: String? }
    private struct AppendInput: Decodable { let title: String; let markdown: String }

    /// How to write a Dash note, put into the writing tools' descriptions so Claude uses the
    /// components without being asked (and without an extra notes_components call).
    static func writingGuide(_ components: [MarkdownComponentType]) -> String {
        let examples = components.map { "- \($0.name): \($0.summary) e.g. `\($0.example.replacingOccurrences(of: "\n", with: " "))`" }
        return """
            Write a rich Dash note, not plain Markdown: Markdown plus component directives, used where they help the reader. \
            Typically: @TOC right under the title when the note has 3 or more sections; @Callout(style: tip|note|warning|danger, title: "…") { … } \
            for tips, warnings and gotchas; @Tabs with @Tab(title: …) for alternatives (per OS, per environment); @Columns for side-by-side \
            comparisons; @Toggle for checklists; @Ask(label:, prompt:) for a follow-up the reader may want; [[Other note]] to link notes. \
            Code goes in fenced blocks with a language. A directive with a body uses braces on its own lines.
            Components:
            \(examples.joined(separator: "\n"))
            """
    }

    var tools: [ClaudeTool] {
        let components = host.map { host in host.extensions.filter { host.isEnabled($0) }.flatMap(\.components) } ?? CoreComponents.all
        let guide = Self.writingGuide(components)
        return [
            ClaudeTool(name: "notes_search", description: "Search the user's notes by title and text; returns titles, folders and dates (newest first).",
                       properties: ["query": JSONSchema.string("Words to look for; empty lists recent notes.")]) { [weak self] input in
                guard let self else { return nil }
                let query = try input.toolInput(SearchInput.self).query ?? ""
                return .array(store.search(query).prefix(30).map { note in
                    ["title": .string(note.title), "folder": .string(note.folder), "modified": .string(note.modified.formatted(.iso8601))]
                })
            },
            ClaudeTool(name: "notes_read", description: "Read one note's Markdown by title.",
                       properties: ["title": JSONSchema.string("Note title (file name without .md).")], required: ["title"]) { [weak self] input in
                guard let self else { return nil }
                let title = try input.toolInput(TitleInput.self).title
                guard let note = store.note(titled: title) else { throw ToolError("No note titled “\(title)”. Use notes_search.") }
                return .string(store.read(note))
            },
            ClaudeTool(name: "notes_components", description: "List the components notes can use (MDX-like block directives such as @Callout or @Widget) with their parameters and an example each. Call before writing a note with components.") { [weak self] _ in
                guard let host = self?.host else { return [] }
                let all = host.extensions.filter { host.isEnabled($0) }.flatMap(\.components)
                return .array(all.map { component in
                    ["name": .string(component.name), "summary": .string(component.summary),
                     "children": .bool(component.acceptsChildren), "example": .string(component.example),
                     "parameters": .array(component.parameters.map { parameter in
                         ["name": .string(parameter.name), "type": .string(parameter.type), "summary": .string(parameter.summary),
                          "required": .bool(parameter.required), "options": .array(parameter.options.map { .string($0) })]
                     })]
                })
            },
            ClaudeTool(name: "notes_create", description: "Create a new note in the user's vault. To change a note that exists, use notes_update instead of creating another.\n\n" + guide,
                       properties: ["title": JSONSchema.string("Title (becomes the file name)."), "markdown": JSONSchema.string("Content."),
                                    "folder": JSONSchema.string("Optional sub-folder, e.g. Meetings.")],
                       required: ["title", "markdown"], requiresApproval: true) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(CreateInput.self)
                if store.note(titled: request.title) != nil {
                    throw ToolError("A note titled “\(request.title)” already exists. Use notes_update to rewrite it, or pick another title.")
                }
                return .string(try store.create(title: request.title, markdown: request.markdown, folder: request.folder).title)
            },
            ClaudeTool(name: "notes_update", description: "Replace an existing note's whole content (read it first with notes_read). Use this to rewrite or restructure a note.\n\n" + guide,
                       properties: ["title": JSONSchema.string("Note title."), "markdown": JSONSchema.string("The note's new full content.")],
                       required: ["title", "markdown"], requiresApproval: true) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(AppendInput.self)
                guard let note = store.note(titled: request.title) else { throw ToolError("No note titled “\(request.title)”. Use notes_create.") }
                try store.write(request.markdown.hasSuffix("\n") ? request.markdown : request.markdown + "\n", to: note)
                return .string("updated")
            },
            ClaudeTool(name: "notes_append", description: "Append to the end of an existing note, using the same note syntax:\n\n" + guide,
                       properties: ["title": JSONSchema.string("Note title."), "markdown": JSONSchema.string("Text to add.")],
                       required: ["title", "markdown"], requiresApproval: true) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(AppendInput.self)
                guard let note = store.note(titled: request.title) else { throw ToolError("No note titled “\(request.title)”.") }
                let text = store.read(note)
                try store.write(text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + "\n" + request.markdown + "\n", to: note)
                return .string("appended")
            },
        ]
    }
}

private struct NotesSettings: View {
    let notes: NotesExtension

    var body: some View {
        Form {
            Section {
                LabeledContent("Vault") {
                    Text(notes.store.vault.path(percentEncoded: false)).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("Choose Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Use as Vault"
                        if panel.runModal() == .OK, let url = panel.url { notes.setVault(url) }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.open(notes.store.vault) }
                    Spacer()
                    Text("\(notes.store.notes.count) notes").foregroundStyle(.secondary)
                }
            } header: {
                Text("Vault")
            } footer: {
                Text("Plain Markdown files, so a sync plugin (git) or any editor can use them. Link notes with [[Title]].")
            }
        }
    }
}

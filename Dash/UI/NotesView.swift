import DashKit
import DashKitUI
import SwiftUI

/// Notes: a tree of notes on the left (sub-notes under their parent, folders as groups; a flat
/// list while searching), the selected note on the right with an edit/preview toggle,
/// components, `[[links]]`, backlinks and AI. Right-click works on notes in the list and on
/// selected text in the editor. Edits save as you type.
struct NotesView: View {
    let notes: NotesExtension
    @Environment(ExtensionHost.self) private var host
    @Environment(ChatSession.self) private var chat
    @State private var selection: NoteFile?
    @State private var search = ""
    /// The document kind being asked for (its topic sheet is open).
    @State private var drafting: DocKind?
    @State private var text = ""
    @State private var title = ""
    @State private var preview = false
    @State private var saveTask: Task<Void, Never>?
    @State private var working: String?
    @State private var error: String?
    @State private var exporting = false
    @State private var exportTarget: NoteFile?
    /// The row a page is being dragged over, and where it would land.
    @State private var dropTarget: (path: String, placement: NotesStore.Placement)?

    private var store: NotesStore { notes.store }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 260)
            Divider()
            if let selection {
                editor(selection)
            } else {
                ContentUnavailableView {
                    Label("No note selected", systemImage: "note.text")
                } description: {
                    Text("Write Markdown with components (@Columns, @Callout, @TOC…), link notes with [[Title]], and nest notes under others.")
                } actions: {
                    Button("New Note", systemImage: "square.and.pencil") { newNote() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            store.reload()
            if selection == nil, let first = store.notes.first { open(first) }
        }
        .onDisappear {
            flush()
            notes.openNote = nil
        }
        // Claude asked to show a note.
        .task(id: notes.openRequest) {
            guard let title = notes.openRequest else { return }
            notes.openRequest = nil
            if let note = store.note(titled: title) { open(note) }
        }
        .onChange(of: preview, initial: true) { notes.openNoteEditing = !preview }
        .sheet(isPresented: $exporting) { NoteExportSheet(store: store, current: exportTarget) }
    }

    private func exportPDF(_ note: NoteFile?) {
        flush()
        exportTarget = note
        exporting = true
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes", text: $search).textFieldStyle(.plain)
                Menu {
                    ForEach(DocKind.allCases) { kind in
                        Button(kind.title, systemImage: kind.systemImage) { drafting = kind }
                    }
                } label: {
                    Image(systemName: "sparkles.rectangle.stack")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Write a how-to, runbook, postmortem, meeting notes or daily note from what Dash knows")
                Button("New Note", systemImage: "square.and.pencil") { newNote() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .help("New note (⌥⌘N)")
            }
            .sheet(item: $drafting) { kind in
                DocRequestSheet(kind: kind) { topic in
                    drafting = nil
                    host.askClaude(kind.prompt(topic: topic))
                } cancel: { drafting = nil }
            }
            .padding(10)
            Divider()
            List(selection: Binding(get: { selection?.url.path }, set: { path in
                if let path, let note = store.notes.first(where: { $0.url.path == path }) { open(note) }
            })) {
                if search.trimmingCharacters(in: .whitespaces).isEmpty {
                    OutlineGroup(store.tree, children: \.children) { node in
                        row(node)
                    }
                } else {
                    ForEach(store.search(search)) { note in
                        row(NoteNode(id: note.url.path, title: note.title, note: note, children: nil))
                    }
                }
            }
            .listStyle(.sidebar)
            // A drag that ends anywhere (or changes the tree) leaves no stale drop marker.
            .onChange(of: store.notes) { dropTarget = nil }
            .onDrop(of: [.text], isTargeted: Binding(get: { false }, set: { if !$0 { dropTarget = nil } })) { providers in
                dropTarget = nil
                // Dropped on empty space: to the end of the top level.
                guard search.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                return NoteDropDelegate.load(providers, store: store) { note in
                    attempt { open(try store.move(note, toFolder: "", at: Int.max)) }
                }
            }
            .contextMenu {
                Button("New Note", systemImage: "square.and.pencil") { newNote() }
                Button("Export All as PDF…", systemImage: "doc.richtext") { exportPDF(nil) }
            }
        }
        .background(.background.secondary)
    }

    @ViewBuilder
    private func row(_ node: NoteNode) -> some View {
        if let note = node.note {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).lineLimit(1)
                Text(note.modified.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .tag(note.url.path)
            .help(note.title)
            .contextMenu { noteMenu(note) }
            .draggable(note.url.path) {
                Label(note.title, systemImage: "doc.text").padding(6).background(.background.secondary, in: .rect(cornerRadius: 6))
            }
            .onDrop(of: [.text], delegate: NoteDropDelegate(target: note, store: store, dropTarget: $dropTarget) { dragged, placement in
                attempt { open(try store.move(dragged, placement, note)) }
            })
            .overlay(alignment: dropTarget?.placement == .after ? .bottom : .top) {
                if let dropTarget, dropTarget.path == note.url.path, dropTarget.placement != .inside {
                    Rectangle().fill(.tint).frame(height: 2).offset(y: dropTarget.placement == .after ? 4 : -4)
                }
            }
            .background {
                if let dropTarget, dropTarget.path == note.url.path, dropTarget.placement == .inside {
                    RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.2)).padding(-3)
                }
            }
        } else {
            Label(node.title, systemImage: "folder")
                .foregroundStyle(.secondary)
                .selectionDisabled()
        }
    }

    @ViewBuilder
    private func noteMenu(_ note: NoteFile) -> some View {
        Button("New Sub-note", systemImage: "plus.rectangle.on.rectangle") { newSubNote(of: note) }
            .disabled(!store.canHaveChildren(note))
        Button("Duplicate", systemImage: "plus.square.on.square") { attempt { open(try store.duplicate(note)) } }
        Menu("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
            let siblings = store.siblingTitles(in: note.folder)
            let index = siblings.firstIndex(of: note.title) ?? 0
            Button("Move Up", systemImage: "arrow.up") { attempt { open(try store.move(note, toFolder: note.folder, at: index - 1)) } }
                .disabled(index == 0)
            Button("Move Down", systemImage: "arrow.down") { attempt { open(try store.move(note, toFolder: note.folder, at: index + 1)) } }
                .disabled(index >= siblings.count - 1)
            if let parent = store.parent(of: note) {
                Button("Move Out of “\(parent.title)”", systemImage: "arrow.up.left") { attempt { open(try store.move(note, .after, parent)) } }
            } else if !note.folder.isEmpty {
                Button("Move to Top Level", systemImage: "arrow.up.left") { attempt { open(try store.move(note, toFolder: "", at: Int.max)) } }
            }
            let targets = store.notes.filter { $0.folder == note.folder && $0 != note && store.canHaveChildren($0) }
            if !targets.isEmpty {
                Menu("Make Sub-page of") {
                    ForEach(store.arranged(targets, in: note.folder) { $0.title }) { target in
                        Button(target.title) { attempt { open(try store.move(note, .inside, target)) } }
                    }
                }
            }
            Divider()
            Button("Sort This Level A–Z") { store.resetOrder(of: note.folder) }
        }
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("[[\(note.title)]]", forType: .string)
        }
        Divider()
        Menu("AI", systemImage: "sparkles") {
            ForEach(NotesExtension.Action.allCases) { action in
                Button(action.title, systemImage: action.systemImage) { open(note); run(action, on: note) }
            }
            Button("Ask \(host.persona.name) About It") { askAbout(note) }
        }
        Button("Export as PDF…", systemImage: "doc.richtext") { open(note); exportPDF(note) }
        Divider()
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
        Button("Move to Trash", systemImage: "trash", role: .destructive) { delete(note) }
    }

    // MARK: Editor

    private func editor(_ note: NoteFile) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if let parent = store.parent(of: note) {
                        Button { open(parent) } label: { Label(parent.title, systemImage: "chevron.left").font(.caption) }
                            .buttonStyle(.link)
                    }
                    // Wraps instead of being cut off when the toolbar leaves little room; Return renames.
                    TextField("Title", text: $title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title2.bold())
                        .lineLimit(1...3)
                        .onChange(of: title) {
                            if title.contains("\n") {
                                title = title.replacingOccurrences(of: "\n", with: "")
                                renameIfNeeded(note)
                            }
                        }
                        .onSubmit { renameIfNeeded(note) }
                }
                Spacer()
                if let working { ProgressView().controlSize(.small).help("\(working)…") }
                Menu {
                    ForEach(inserts, id: \.name) { component in
                        Button(component.name) {
                            preview = false
                            text += (text.isEmpty || text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n") + component.example + "\n"
                            scheduleSave(note)
                        }
                    }
                } label: {
                    Label("Insert", systemImage: "plus.square.on.square")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Insert a component (also in the editor's right-click menu)")
                Menu {
                    ForEach(NotesExtension.Action.allCases) { action in
                        Button(action.title, systemImage: action.systemImage) { run(action, on: note) }
                    }
                    Divider()
                    Button("New Sub-note", systemImage: "plus.rectangle.on.rectangle") { newSubNote(of: note) }
                        .disabled(!store.canHaveChildren(note))
                    Button("Ask \(host.persona.name) About This Note", systemImage: "bubble.left.and.text.bubble.right") { askAbout(note) }
                } label: {
                    Label("AI", systemImage: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(working != nil)
                Button("Export PDF", systemImage: "doc.richtext") { exportPDF(note) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Export as PDF")
                Picker("Mode", selection: $preview) {
                    Image(systemName: "pencil").tag(false).help("Edit")
                    Image(systemName: "eye").tag(true).help("Preview")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20)
            }
            Divider()
            if preview {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            // Markdown plus components; task boxes and interactive components edit the note.
                            NoteRenderer(source: text, noteTitle: note.title) { updated in
                                text = updated
                                save(updated, to: note)
                            }
                            backlinks(note)
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 20)
                        // A readable column, centred in whatever width the window gives.
                        .frame(maxWidth: 880, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        switch url.scheme {
                        case "dash-note":
                            openLink(url.host(percentEncoded: false) ?? url.absoluteString.replacingOccurrences(of: "dash-note://", with: "").removingPercentEncoding ?? "")
                            return .handled
                        case "dash-heading":
                            withAnimation { proxy.scrollTo(url.host(percentEncoded: false) ?? "", anchor: .top) }
                            return .handled
                        default:
                            return .systemAction
                        }
                    })
                }
            } else {
                NoteTextEditor(text: $text, inserts: inserts) { action, selected in
                    await apply(action, to: selected, in: note)
                }
                .onChange(of: text) { scheduleSave(note) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Components to insert: Dash's and the installed plugins' (not the ones only used inside others).
    private var inserts: [(name: String, example: String)] {
        host.extensions.filter { host.isEnabled($0) }.flatMap(\.components)
            .filter { !["Column", "Tab"].contains($0.name) }
            .map { ($0.name, $0.example) }
    }

    @ViewBuilder
    private func backlinks(_ note: NoteFile) -> some View {
        let links = store.backlinks(to: note)
        let children = store.children(of: note)
        if !links.isEmpty || !children.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                if !children.isEmpty {
                    Text("Sub-notes").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(children) { child in Button(child.title) { open(child) }.buttonStyle(.link) }
                }
                if !links.isEmpty {
                    Text("Linked from").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(links) { link in Button(link.title) { open(link) }.buttonStyle(.link) }
                }
            }
        }
    }

    // MARK: Actions

    private func open(_ note: NoteFile) {
        flush()
        selection = note
        notes.openNote = note.title
        text = store.read(note)
        title = note.title
        error = nil
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { self.error = error.localizedDescription }
    }

    private func newNote() {
        attempt {
            open(try store.create(title: "Untitled", markdown: ""))
            preview = false
        }
    }

    private func newSubNote(of parent: NoteFile) {
        attempt {
            open(try store.createChild(of: parent))
            preview = false
        }
    }

    private func delete(_ note: NoteFile) {
        attempt {
            try store.delete(note)
            if selection == note { selection = nil; text = "" }
        }
    }

    private func renameIfNeeded(_ note: NoteFile) {
        guard title != note.title else { return }
        do {
            flush()
            let renamed = try store.rename(note, to: title)
            selection = renamed
            title = renamed.title
        } catch {
            self.error = error.localizedDescription
            title = note.title
        }
    }

    /// `[[Title]]` in preview: open it, or create it when it doesn't exist yet.
    private func openLink(_ target: String) {
        let target = target.trimmingCharacters(in: .whitespaces)
        if let note = store.note(titled: target) {
            open(note)
        } else {
            attempt {
                open(try store.create(title: target, markdown: ""))
                preview = false
            }
        }
    }

    private func scheduleSave(_ note: NoteFile) {
        saveTask?.cancel()
        let snapshot = text
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            save(snapshot, to: note)
        }
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        if let selection, store.read(selection) != text { save(text, to: selection) }
    }

    private func save(_ snapshot: String, to note: NoteFile) {
        do { try store.write(snapshot, to: note) } catch { self.error = error.localizedDescription }
    }

    /// The editor's right-click actions on selected text.
    private func apply(_ action: NoteSelectionAction, to selected: String, in note: NoteFile) async -> String? {
        if let formatted = action.format(selected) { return formatted }
        switch action {
        case .explain:
            chat.isPanelVisible = true
            chat.send("In my note “\(note.title)”, explain this:\n\n\(selected)")
            return nil
        case .extractSubNote:
            let firstLine = selected.split(separator: "\n").first.map(String.init) ?? "Untitled"
            let childTitle = String(firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#*-> ")).prefix(60))
            do {
                let child = try store.createChild(of: note, title: childTitle.isEmpty ? "Untitled" : childTitle, markdown: selected)
                return "[[\(child.title)]]"
            } catch {
                self.error = error.localizedDescription
                return nil
            }
        default:
            working = action.title
            defer { working = nil }
            do {
                return try await notes.run(action, selection: selected, title: note.title)
            } catch {
                self.error = error.localizedDescription
                return nil
            }
        }
    }

    private func run(_ action: NotesExtension.Action, on note: NoteFile) {
        working = action.title
        error = nil
        let current = text
        Task {
            defer { working = nil }
            do {
                let result = try await notes.run(action, title: note.title, text: current)
                switch action {
                case .summarize: text = "> [!summary]\n" + result.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n\n" + text
                case .continueWriting: text += (text.hasSuffix("\n") ? "\n" : "\n\n") + result + "\n"
                case .actionItems: text += (text.hasSuffix("\n") ? "\n" : "\n\n") + "## Action items\n" + result + "\n"
                }
                save(text, to: note)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func askAbout(_ note: NoteFile) {
        flush()
        chat.isPanelVisible = true
        chat.send("Read my note “\(note.title)” (notes_read) and tell me what stands out, what's missing, and what I should do next.")
    }
}

/// Drop on a page row: the top quarter places before it, the bottom quarter after it,
/// the middle makes the dragged page its sub-page.
private struct NoteDropDelegate: DropDelegate {
    let target: NoteFile
    let store: NotesStore
    @Binding var dropTarget: (path: String, placement: NotesStore.Placement)?
    let perform: (NoteFile, NotesStore.Placement) -> Void

    /// Row height used to split it into zones; sidebar rows here are about this tall.
    static let rowHeight: CGFloat = 36

    static func placement(y: CGFloat, height: CGFloat = rowHeight, canNest: Bool) -> NotesStore.Placement {
        if !canNest { return y < height / 2 ? .before : .after }
        if y < height * 0.25 { return .before }
        if y > height * 0.75 { return .after }
        return .inside
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropTarget = (target.url.path, Self.placement(y: info.location.y, canNest: store.canHaveChildren(target)))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTarget?.path == target.url.path { dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let placement = Self.placement(y: info.location.y, canNest: store.canHaveChildren(target))
        dropTarget = nil
        return Self.load(info.itemProviders(for: [.text]), store: store) { note in
            guard note != target else { return }
            perform(note, placement)
        }
    }

    /// Reads the dragged page's path and finds the note.
    static func load(_ providers: [NSItemProvider], store: NotesStore, then action: @escaping @MainActor (NoteFile) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let path = object as? String else { return }
            Task { @MainActor in
                if let note = store.notes.first(where: { $0.url.path == path }) { action(note) }
            }
        }
        return true
    }
}

/// Asks what a generated document should be about, then hands it to Dashii.
private struct DocRequestSheet: View {
    let kind: DocKind
    let start: (String) -> Void
    let cancel: () -> Void
    @State private var topic = ""
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New \(kind.title)", systemImage: kind.systemImage).font(.title3.weight(.semibold))
            Text("\(host.persona.name) gathers the facts from the knowledge graph, what it learned, your activity and the connected integrations, then writes the note.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(kind.topicPrompt, text: $topic, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { if canStart { start(topic) } }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Write It", systemImage: "sparkles") { start(topic) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Meeting and daily notes default to the latest; the others need a topic.
    private var canStart: Bool { [.meetingNotes, .dailyNote].contains(kind) || !topic.trimmingCharacters(in: .whitespaces).isEmpty }
}

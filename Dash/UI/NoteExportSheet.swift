import AppKit
import DashKit
import SwiftUI
import UniformTypeIdentifiers

/// Export notes as a PDF: this note (optionally with its sub-notes), chosen notes, or all.
struct NoteExportSheet: View {
    let store: NotesStore
    let current: NoteFile?
    @Environment(ExtensionHost.self) private var host
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, CaseIterable, Identifiable {
        case note, withSubNotes, chosen, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .note: "This note"
            case .withSubNotes: "This note and its sub-notes"
            case .chosen: "Chosen notes"
            case .all: "All notes"
            }
        }
    }

    @State private var scope = Scope.note
    @State private var chosen: Set<URL> = []
    @State private var options = NotePDFOptions()
    @State private var openAfter = true
    @State private var working = false
    @State private var error: String?
    @State private var rendered: URL?
    @State private var choosingPlace = false

    var body: some View {
        Form {
            Section("Notes") {
                Picker("Export", selection: $scope) {
                    ForEach(Scope.allCases.filter { current != nil || ($0 != .note && $0 != .withSubNotes) }) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if scope == .chosen {
                    List(store.notes, id: \.url) { note in
                        Toggle(isOn: Binding(get: { chosen.contains(note.url) },
                                             set: { if $0 { chosen.insert(note.url) } else { chosen.remove(note.url) } })) {
                            Text(note.folder.isEmpty ? note.title : "\(note.folder)/\(note.title)")
                        }
                    }
                    .frame(height: 160)
                }
                Text("\(selected.count) note\(selected.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            Section("Document") {
                TextField("Title", text: $options.title)
                TextField("Subtitle", text: $options.subtitle, prompt: Text("optional"))
                TextField("Author", text: $options.author)
                Picker("Page size", selection: $options.pageSize) {
                    ForEach(NotePDFOptions.PageSize.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Cover page", isOn: $options.cover)
                Toggle("Contents page (several notes)", isOn: $options.contents)
                Toggle("End page", isOn: $options.endPage)
                Toggle("Open when done", isOn: $openAfter)
            }
            Section {
                Text("Blocks are never split across pages; a table taller than a page continues on the next with its header repeated. Interactive components print frozen: add frozen: hide, frozen: snapshot, or frozen: \"text\" to any of them.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button {
                        export()
                    } label: {
                        if working { ProgressView().controlSize(.small) } else { Text("Export PDF…") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || working)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fileMover(isPresented: $choosingPlace, file: rendered, onCompletion: saved)
        .onAppear {
            options.title = current?.title ?? "Notes"
            options.author = host.ext(HomeExtension.self)?.userName ?? ""
            if let current { chosen = [current.url] } else { scope = .all }
        }
    }

    /// The notes to export, in reading order (a parent before its sub-notes).
    private var selected: [NoteFile] {
        switch scope {
        case .note: return current.map { [$0] } ?? []
        case .withSubNotes:
            guard let current else { return [] }
            return [current] + descendants(of: current)
        case .chosen: return ordered(store.notes.filter { chosen.contains($0.url) })
        case .all: return ordered(store.notes)
        }
    }

    private func descendants(of note: NoteFile) -> [NoteFile] {
        store.children(of: note).flatMap { [$0] + descendants(of: $0) }
    }

    private func ordered(_ notes: [NoteFile]) -> [NoteFile] {
        notes.sorted { ($0.folder.isEmpty ? $0.title : "\($0.folder)/\($0.title)").localizedStandardCompare(
            $1.folder.isEmpty ? $1.title : "\($1.folder)/\($1.title)") == .orderedAscending }
    }

    /// Renders to a temporary file, then the save dialog (attached to this sheet) moves it
    /// where the user picks.
    private func export() {
        working = true
        error = nil
        // Let the sheet show the spinner before the (main-thread) layout work.
        DispatchQueue.main.async {
            do {
                let name = (options.title.isEmpty ? "Notes" : NotesStore.fileName(options.title)) + ".pdf"
                let folder = FileManager.default.temporaryDirectory.appending(path: "dash-export-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: name)
                try NotePDFExporter(host: host, options: options).export(selected.map { ($0.title, store.read($0)) }, to: url)
                rendered = url
                choosingPlace = true
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func saved(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            host.activity.emit("notes.exported", source: "notes", title: "Exported \(selected.count) note(s) to PDF", detail: url.path)
            if openAfter { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            dismiss()
        case .failure(let failure):
            if (failure as? CocoaError)?.code != .userCancelled { error = failure.localizedDescription }
        }
    }
}

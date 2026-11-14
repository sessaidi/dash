import DashKit
import Foundation
import Observation

/// A row of the notes tree: a note (maybe with sub-notes) or a plain folder.
struct NoteNode: Identifiable, Hashable {
    let id: String
    let title: String
    let note: NoteFile?
    let children: [NoteNode]?
}

/// One Markdown file in the vault.
struct NoteFile: Identifiable, Hashable {
    let url: URL
    let modified: Date
    var id: URL { url }
    /// File name without `.md`: what `[[wikilinks]]` refer to.
    var title: String { url.deletingPathExtension().lastPathComponent }
    /// The folder inside the vault ("" at the top level).
    let folder: String
}

/// The notes vault: plain Markdown files in a folder (easy to sync with git), linked with
/// `[[Title]]`. Dash reads and writes the files directly; nothing is kept elsewhere.
@MainActor
@Observable
final class NotesStore {
    private(set) var vault: URL
    private(set) var notes: [NoteFile] = []
    /// Hand-arranged order of each folder's pages (folder → titles), from `.dash/order.json`.
    /// Pages not listed come after, alphabetically.
    private(set) var order: [String: [String]] = [:]

    init(vault: URL) {
        self.vault = vault
    }

    static var defaultVault: URL {
        // Tests never touch the real vault.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appending(path: "dash-test-vault-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Dash Notes", directoryHint: .isDirectory)
    }

    func setVault(_ url: URL) {
        vault = url
        reload()
    }

    /// Re-reads the vault (every `.md`, newest first). Hidden files and folders (`.git`) are skipped.
    func reload() {
        // The vault folder is created by the first note, not by looking.
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var found: [NoteFile] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            // Compare resolved paths (/var vs /private/var and the like).
            let root = vault.resolvingSymlinksInPath().pathComponents
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
            let folder = parent.starts(with: root) ? parent.dropFirst(root.count).joined(separator: "/") : ""
            found.append(NoteFile(url: url, modified: values.contentModificationDate ?? .distantPast, folder: folder))
        }
        notes = found.sorted { $0.modified > $1.modified }
        order = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: orderURL))) ?? [:]
    }

    // MARK: Order

    /// Hidden, so the vault's notes stay plain Markdown (the enumerator skips it).
    private var orderURL: URL { vault.appending(path: ".dash/order.json") }

    private func saveOrder() {
        // Drop entries for pages that no longer exist.
        var cleaned: [String: [String]] = [:]
        for (folder, titles) in order {
            let present = Set(notes.filter { $0.folder == folder }.map(\.title)).union(plainFolders(in: folder))
            let kept = titles.filter(present.contains)
            if !kept.isEmpty { cleaned[folder] = kept }
        }
        order = cleaned
        do {
            try FileManager.default.createDirectory(at: orderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(cleaned).write(to: orderURL, options: .atomic)
        } catch {}
    }

    /// Sorts a folder's rows: arranged ones first in their order, then the rest by title.
    func arranged<T>(_ items: [T], in folder: String, title: (T) -> String) -> [T] {
        let ranks = Dictionary((order[folder] ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.sorted {
            let (a, b) = (ranks[title($0)] ?? Int.max, ranks[title($1)] ?? Int.max)
            return a != b ? a < b : title($0).localizedStandardCompare(title($1)) == .orderedAscending
        }
    }

    /// The titles of a folder's rows in display order (notes and plain folders).
    func siblingTitles(in folder: String) -> [String] {
        let titles = Set(notes.filter { $0.folder == folder }.map(\.title)).union(plainFolders(in: folder))
        return arranged(Array(titles), in: folder) { $0 }
    }

    /// Folders under `folder` that aren't a note's sub-notes (e.g. "Meetings").
    private func plainFolders(in folder: String) -> Set<String> {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let titles = Set(notes.filter { $0.folder == folder }.map(\.title))
        return Set(notes.compactMap { note -> String? in
            guard note.folder.hasPrefix(prefix), note.folder != folder else { return nil }
            return note.folder.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        }).subtracting(titles)
    }

    /// Puts `title` at `index` in its folder's order (clamped), writing the whole order down.
    private func arrange(_ title: String, in folder: String, at index: Int) {
        var titles = siblingTitles(in: folder).filter { $0 != title }
        titles.insert(title, at: min(max(index, 0), titles.count))
        order[folder] = titles
    }

    /// Where a drop lands relative to another row.
    enum Placement: Equatable {
        case before, after, inside
    }

    /// Moves `note` next to `target` (same folder as it) or inside it as a sub-page.
    @discardableResult
    func move(_ note: NoteFile, _ placement: Placement, _ target: NoteFile) throws -> NoteFile {
        guard note != target else { return note }
        switch placement {
        case .inside:
            guard canHaveChildren(target) else {
                throw ToolError("Notes nest at most \(Self.maxDepth) levels deep; “\(target.title)” is already at level \(depth(target)).")
            }
            let folder = childFolder(target)
            return try move(note, toFolder: folder, at: siblingTitles(in: folder).count)
        case .before, .after:
            var titles = siblingTitles(in: target.folder)
            if note.folder == target.folder { titles.removeAll { $0 == note.title } }
            let index = (titles.firstIndex(of: target.title) ?? titles.count) + (placement == .after ? 1 : 0)
            return try move(note, toFolder: target.folder, at: index)
        }
    }

    /// Moves `note` (with its sub-pages) into `folder` ("" is the top level) at position `index`.
    @discardableResult
    func move(_ note: NoteFile, toFolder folder: String, at index: Int) throws -> NoteFile {
        if folder == note.folder {
            arrange(note.title, in: folder, at: index)
            saveOrder()
            return note
        }
        let own = childFolder(note)
        guard folder != own, !folder.hasPrefix(own + "/") else { throw ToolError("A page can't go inside one of its own sub-pages.") }
        let newDepth = folder.isEmpty ? 1 : folder.split(separator: "/").count + 1
        guard newDepth + subtreeHeight(note) - 1 <= Self.maxDepth else {
            throw ToolError("That would nest “\(note.title)” or its sub-pages more than \(Self.maxDepth) levels deep.")
        }
        let directory = folder.isEmpty ? vault : vault.appending(path: folder, directoryHint: .isDirectory)
        let destination = directory.appending(path: "\(note.title).md")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolError("“\(folder.isEmpty ? "The top level" : folder)” already has a page named “\(note.title)”.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: note.url, to: destination)
        let children = childFolderURL(note)
        let newOwn = folder.isEmpty ? note.title : "\(folder)/\(note.title)"
        if FileManager.default.fileExists(atPath: children.path) {
            try FileManager.default.moveItem(at: children, to: directory.appending(path: note.title, directoryHint: .isDirectory))
        }
        // The sub-pages' arrangement moves with them.
        for key in order.keys where key == own || key.hasPrefix(own + "/") {
            order[newOwn + key.dropFirst(own.count)] = order.removeValue(forKey: key)
        }
        order[note.folder]?.removeAll { $0 == note.title }
        reload(keepingOrder: true)
        arrange(note.title, in: folder, at: index)
        saveOrder()
        return notes.first { $0.url.standardizedFileURL == destination.standardizedFileURL } ?? note
    }

    /// Levels in a note's subtree, counting itself (1 when it has no sub-pages).
    func subtreeHeight(_ note: NoteFile) -> Int {
        let own = childFolder(note)
        let deepest = notes.filter { $0.folder == own || $0.folder.hasPrefix(own + "/") }.map { depth($0) }.max()
        return deepest.map { $0 - depth(note) + 1 } ?? 1
    }

    /// Sorts a folder alphabetically again (forgets its hand-arranged order).
    func resetOrder(of folder: String) {
        order[folder] = nil
        saveOrder()
    }

    private func reload(keepingOrder: Bool) {
        let kept = order
        reload()
        if keepingOrder { order = kept }
    }

    func read(_ note: NoteFile) -> String {
        (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
    }

    func write(_ text: String, to note: NoteFile) throws {
        try text.write(to: note.url, atomically: true, encoding: .utf8)
        reload()
    }

    /// A new note; the title is made safe for a file name and kept unique within its folder.
    @discardableResult
    func create(title: String, markdown: String = "", folder: String? = nil) throws -> NoteFile {
        let directory = folder.map { vault.appending(path: $0, directoryHint: .isDirectory) } ?? vault
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = Self.fileName(title.isEmpty ? "Untitled" : title)
        var url = directory.appending(path: "\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(base) \(counter).md")
            counter += 1
        }
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        reload()
        return notes.first { $0.url.standardizedFileURL == url.standardizedFileURL }
            ?? NoteFile(url: url, modified: .now, folder: folder ?? "")
    }

    func rename(_ note: NoteFile, to title: String) throws -> NoteFile {
        let name = Self.fileName(title)
        guard !name.isEmpty, name != note.title else { return note }
        let url = note.url.deletingLastPathComponent().appending(path: "\(name).md")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ToolErrorMessage("A note named “\(name)” already exists.") }
        try FileManager.default.moveItem(at: note.url, to: url)
        // Its sub-notes' folder follows.
        let children = childFolderURL(note)
        if FileManager.default.fileExists(atPath: children.path) {
            try FileManager.default.moveItem(at: children, to: url.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory))
        }
        // Keep its place, and its sub-pages' arrangement.
        let own = childFolder(note)
        let renamed = note.folder.isEmpty ? name : "\(note.folder)/\(name)"
        for key in order.keys where key == own || key.hasPrefix(own + "/") {
            order[renamed + key.dropFirst(own.count)] = order.removeValue(forKey: key)
        }
        order[note.folder] = order[note.folder]?.map { $0 == note.title ? name : $0 }
        reload(keepingOrder: true)
        saveOrder()
        return notes.first { $0.url.standardizedFileURL == url.standardizedFileURL } ?? note
    }

    /// Moves the note, and its sub-notes, to the Trash (recoverable).
    func delete(_ note: NoteFile) throws {
        let children = childFolderURL(note)
        try FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        if FileManager.default.fileExists(atPath: children.path) { try FileManager.default.trashItem(at: children, resultingItemURL: nil) }
        reload()
    }

    @discardableResult
    func duplicate(_ note: NoteFile) throws -> NoteFile {
        try create(title: "\(note.title) copy", markdown: read(note), folder: note.folder.isEmpty ? nil : note.folder)
    }

    // MARK: Nesting

    /// A note's sub-notes live in a folder named after it, next to it: `Plan.md` and `Plan/`.
    func childFolder(_ note: NoteFile) -> String {
        note.folder.isEmpty ? note.title : "\(note.folder)/\(note.title)"
    }

    private func childFolderURL(_ note: NoteFile) -> URL {
        note.url.deletingLastPathComponent().appending(path: note.title, directoryHint: .isDirectory)
    }

    /// Notes nest at most this deep (a top-level note is level 1).
    static let maxDepth = 4

    /// 1 for a top-level note, 2 for its sub-notes…
    func depth(_ note: NoteFile) -> Int {
        note.folder.isEmpty ? 1 : note.folder.split(separator: "/").count + 1
    }

    func canHaveChildren(_ note: NoteFile) -> Bool { depth(note) < Self.maxDepth }

    @discardableResult
    func createChild(of parent: NoteFile, title: String = "Untitled", markdown: String = "") throws -> NoteFile {
        guard canHaveChildren(parent) else {
            throw ToolError("Notes nest at most \(Self.maxDepth) levels deep; “\(parent.title)” is already at level \(depth(parent)).")
        }
        return try create(title: title, markdown: markdown, folder: childFolder(parent))
    }

    func children(of note: NoteFile) -> [NoteFile] {
        let folder = childFolder(note)
        return arranged(notes.filter { $0.folder == folder }, in: folder) { $0.title }
    }

    func parent(of note: NoteFile) -> NoteFile? {
        guard !note.folder.isEmpty else { return nil }
        let parts = note.folder.split(separator: "/").map(String.init)
        let folder = parts.dropLast().joined(separator: "/")
        return notes.first { $0.folder == folder && $0.title == parts.last }
    }

    /// The vault as a tree: notes with their sub-notes, and plain folders (without a note of
    /// their own) as groups.
    var tree: [NoteNode] { nodes(in: "") }

    private func nodes(in folder: String) -> [NoteNode] {
        let here = notes.filter { $0.folder == folder }
        let noteTitles = Set(here.map(\.title))
        var result = here.map { note in
            let children = nodes(in: childFolder(note))
            return NoteNode(id: note.url.path, title: note.title, note: note, children: children.isEmpty ? nil : children)
        }
        // Folders that aren't a note's sub-notes (e.g. "Meetings", "Automations").
        let prefix = folder.isEmpty ? "" : folder + "/"
        let subfolders = Set(notes.compactMap { note -> String? in
            guard note.folder.hasPrefix(prefix), note.folder != folder else { return nil }
            return note.folder.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        })
        for name in subfolders.sorted() where !noteTitles.contains(name) {
            let children = nodes(in: prefix + name)
            result.append(NoteNode(id: "folder:" + prefix + name, title: name, note: nil, children: children))
        }
        // Hand-arranged rows first, then notes before plain folders, by title.
        let ranks = Dictionary((order[folder] ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return result.sorted {
            let a = (ranks[$0.title] ?? Int.max, $0.note == nil ? 1 : 0, $0.title.lowercased())
            let b = (ranks[$1.title] ?? Int.max, $1.note == nil ? 1 : 0, $1.title.lowercased())
            return a < b
        }
    }

    /// Notes whose title or text contains `query` (case-insensitive), newest first.
    func search(_ query: String) -> [NoteFile] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return notes }
        return notes.filter { $0.title.localizedCaseInsensitiveContains(query) || read($0).localizedCaseInsensitiveContains(query) }
    }

    func note(titled title: String) -> NoteFile? {
        notes.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    /// Notes that link to `note` with `[[Title]]` (or `[[Title|alias]]`).
    func backlinks(to note: NoteFile) -> [NoteFile] {
        notes.filter { $0 != note && Self.links(in: read($0)).contains { $0.caseInsensitiveCompare(note.title) == .orderedSame } }
    }

    /// The targets of `[[wikilinks]]` in a text.
    nonisolated static func links(in text: String) -> [String] {
        text.matches(of: /\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]/).map { String($0.output.1).trimmingCharacters(in: .whitespaces) }
    }

    /// `[[Title]]` and `[[Title|alias]]` as Markdown links Dash can open (`dash-note://Title`).
    nonisolated static func linkified(_ text: String) -> String {
        text.replacing(/\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]/) { match in
            let target = String(match.output.1).trimmingCharacters(in: .whitespaces)
            let label = match.output.2.map(String.init) ?? target
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            return "[\(label)](dash-note://\(encoded))"
        }
    }

    nonisolated static func fileName(_ title: String) -> String {
        title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ToolErrorMessage: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

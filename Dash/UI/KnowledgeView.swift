import AppKit
import DashKit
import SwiftUI

/// The Knowledge page: search the graph, open a node to see what Claude understood about it
/// and everything connected to it, and walk from there.
struct KnowledgeView: View {
    let knowledge: KnowledgeExtension
    @State private var query = ""
    @State private var kind = ""
    @State private var results: [KnowledgeNode] = []
    @State private var selected: KnowledgeNode?
    @State private var history: [KnowledgeNode] = []

    static let kinds = ["", "repo", "directory", "file", "symbol", "concept", "ticket", "pr", "agent", "meeting", "note", "person", "package"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search code, tickets, PRs, notes…", text: $query).textFieldStyle(.plain)
                        .onSubmit { Task { await search() } }
                }
                .padding(10)
                Picker("Kind", selection: $kind) {
                    ForEach(Self.kinds, id: \.self) { Text($0.isEmpty ? "Everything" : $0.capitalized).tag($0) }
                }
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                Divider()
                List(results, selection: Binding(get: { selected?.id }, set: { id in select(results.first { $0.id == id }) })) { node in
                    KnowledgeRow(node: node).tag(node.id)
                }
                .listStyle(.sidebar)
                .overlay {
                    if results.isEmpty { overview }
                }
            }
            .frame(width: 300)
            .background(.background.secondary)
            Divider()
            Group {
                if let selected {
                    KnowledgeDetail(knowledge: knowledge, node: selected, canGoBack: !history.isEmpty,
                                    onOpen: { select($0, remember: true) }, onBack: back)
                        .id(selected.id)
                } else {
                    ContentUnavailableView("Knowledge", systemImage: knowledge.systemImage,
                                           description: Text("Search, or ask Dashii about your projects: it reads this graph."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: query) { Task { await search() } }
        .onChange(of: kind) { Task { await search() } }
    }

    /// Repositories and graph size when nothing is searched.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if knowledge.repositories.isEmpty {
                Text("No repositories yet.").font(.headline)
                let found = KnowledgeExtension.clones(in: KnowledgeExtension.codeRoot)
                if found.isEmpty {
                    Text("Add the folders of your projects in Settings › Knowledge.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("\(found.count) repositories in \((KnowledgeExtension.codeRoot.path as NSString).abbreviatingWithTildeInPath).").font(.callout).foregroundStyle(.secondary)
                    Button("Index Them") { found.forEach(knowledge.addRepository) }
                }
            } else {
                Text("Repositories").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(knowledge.repositories, id: \.self) { path in
                    Button {
                        Task { if let node = try? await knowledge.store?.node("repo:" + path) { select(node) } }
                    } label: {
                        Label((path as NSString).lastPathComponent, systemImage: "shippingbox")
                    }
                    .buttonStyle(.plain)
                }
                let counts = knowledge.counts
                if !counts.isEmpty {
                    Text(["symbol", "file", "concept", "ticket", "pr"].compactMap { key in counts[key].map { "\($0) \(key)s" } }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if knowledge.isWorking { ProgressView(knowledge.status).controlSize(.small).font(.caption) }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let store = knowledge.store else { results = []; return }
        results = (try? await store.search(text, kinds: kind.isEmpty ? [] : [kind], limit: 80)) ?? []
    }

    private func select(_ node: KnowledgeNode?, remember: Bool = false) {
        if remember, let selected { history.append(selected) }
        selected = node
    }

    private func back() {
        selected = history.popLast()
    }
}

struct KnowledgeRow: View {
    let node: KnowledgeNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.icon(node.kind)).foregroundStyle(.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.kind == "symbol" ? node.qualified : node.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        if !node.path.isEmpty { return node.line > 0 ? "\(node.path):\(node.line)" : node.path }
        if !node.summary.isEmpty { return node.summary }
        return node.kind
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "repo": "shippingbox"
        case "directory": "folder"
        case "file": "doc.text"
        case "symbol": "function"
        case "package": "cube"
        case "concept": "lightbulb"
        case "ticket": "checklist"
        case "pr": "arrow.triangle.pull"
        case "agent": "hammer"
        case "meeting": "video"
        case "note": "note.text"
        case "person": "person"
        default: "circle"
        }
    }
}

/// One node: Claude's notes, the declaration or text, actions, and its relations.
private struct KnowledgeDetail: View {
    let knowledge: KnowledgeExtension
    let node: KnowledgeNode
    let canGoBack: Bool
    let onOpen: (KnowledgeNode) -> Void
    let onBack: () -> Void
    @State private var neighbors: [KnowledgeNeighbor] = []
    @State private var learning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    if canGoBack {
                        Button("Back", systemImage: "chevron.left", action: onBack).labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    Image(systemName: KnowledgeRow.icon(node.kind)).foregroundStyle(.tint)
                    Text(node.kind == "symbol" ? node.qualified : node.name).font(.title2.bold()).textSelection(.enabled)
                    Text(node.kind == "symbol" ? node.language : node.kind).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    actions
                }
                if !node.path.isEmpty {
                    Text(node.line > 0 ? "\(node.path):\(node.line)–\(node.endLine)" : node.path)
                        .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !node.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("What Claude understood", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(node.summary).textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.tint.opacity(0.08), in: .rect(cornerRadius: 10))
                }
                if !node.signature.isEmpty {
                    Text(node.signature)
                        .font(node.kind == "symbol" ? .callout.monospaced() : .callout)
                        .lineLimit(node.kind == "symbol" ? nil : 12)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                }
                ForEach(groups, id: \.relation) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.relation.replacingOccurrences(of: "_", with: " ").capitalized + " (\(group.nodes.count))")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(group.nodes.prefix(40), id: \.id) { other in
                            Button { onOpen(other) } label: { KnowledgeRow(node: other) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: knowledge.revision) { neighbors = (try? await knowledge.store?.neighbors(node.id, limit: 120)) ?? [] }
    }

    private var groups: [(relation: String, nodes: [KnowledgeNode])] {
        Dictionary(grouping: neighbors) { $0.incoming ? KnowledgeExtension.inverse($0.edge.kind) : $0.edge.kind }
            .map { ($0.key, $0.value.map(\.node)) }
            .sorted { $0.relation < $1.relation }
    }

    @ViewBuilder private var actions: some View {
        if let file = fileURL {
            Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(file) }
            Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                .labelStyle(.iconOnly)
        }
        if let url = URL(string: node.url), !node.url.isEmpty {
            Button("Open Link", systemImage: "safari") { NSWorkspace.shared.open(url) }.labelStyle(.iconOnly)
        }
        if node.kind == "directory" || node.kind == "repo" {
            Button {
                learning = true
                Task {
                    if node.kind == "repo" { await knowledge.learn(budget: 5, repo: node.id) }
                    else { await knowledge.learnDirectory(node) }
                    learning = false
                }
            } label: {
                if learning { ProgressView().controlSize(.small) } else { Label(node.summary.isEmpty ? "Understand" : "Understand Again", systemImage: "sparkles") }
            }
            .disabled(learning)
        }
        Button("Ask Dashii", systemImage: "bubble.left") {
            knowledge.host?.askClaude("Using the knowledge graph (node id \(node.id)), explain \(node.kind == "symbol" ? node.qualified : node.name): what it is, how it fits in, and what's connected to it.")
        }
    }

    private var fileURL: URL? {
        guard !node.repo.isEmpty else { return nil }
        let root = URL(fileURLWithPath: String(node.repo.dropFirst(5)))
        return node.path.isEmpty ? root : root.appending(path: node.path)
    }
}

struct KnowledgeSettings: View {
    @Bindable var knowledge: KnowledgeExtension

    var body: some View {
        Form {
            Section {
                if knowledge.repositories.isEmpty { Text("No repositories yet.").foregroundStyle(.secondary) }
                ForEach(knowledge.repositories, id: \.self) { path in
                    HStack {
                        Label((path as NSString).lastPathComponent, systemImage: "shippingbox")
                        Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { knowledge.removeRepository(path) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Button("Add Repository…", systemImage: "plus") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    panel.prompt = "Index"
                    if panel.runModal() == .OK { panel.urls.forEach(knowledge.addRepository) }
                }
                Stepper("Re-index changed files every \(knowledge.refreshMinutes) min", value: $knowledge.refreshMinutes, in: 5...240, step: 5)
                Toggle("Read git history (authors, files changed together, tickets in commits)", isOn: $knowledge.readHistory)
            } header: {
                Text("Repositories")
            } footer: {
                Text("Indexed on this Mac: Swift, Go, TypeScript/JavaScript, Python, Rust, Kotlin and Java. Nothing leaves it except what Claude reads below.")
            }
            Section {
                Toggle("Let Claude study the code in the background", isOn: $knowledge.understand)
                Stepper("\(knowledge.understandBudget) directories per pass", value: $knowledge.understandBudget, in: 1...30)
                    .disabled(!knowledge.understand)
                Stepper("A pass every \(knowledge.understandHours) h", value: $knowledge.understandHours, in: 1...48)
                    .disabled(!knowledge.understand)
            } header: {
                Text("Understanding")
            } footer: {
                Text("Claude reads one directory at a time (declarations, imports, README) and notes what it's for, changed and larger directories first. Model and effort: the AI tab.")
            }
            Section {
                if !knowledge.counts.isEmpty {
                    Text(knowledge.counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let error = knowledge.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(2)
                    } else if knowledge.isWorking {
                        ProgressView(knowledge.status).controlSize(.small)
                    } else if let last = knowledge.lastRefresh {
                        Text("Updated \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Understand More") { Task { await knowledge.learn(budget: knowledge.understandBudget) } }
                        .disabled(knowledge.isWorking)
                    Button("Index Now") { Task { await knowledge.refresh() } }.disabled(knowledge.isWorking)
                }
            }
        }
        .formStyle(.grouped)
    }
}

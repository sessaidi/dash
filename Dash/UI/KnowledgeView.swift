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
                // Opaque: the window behind shouldn't show through these panes.
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .controlBackgroundColor))
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
                    KnowledgeHome(knowledge: knowledge) { select($0, remember: false) }
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
                    RepositoryRow(path: path, knowledge: knowledge) {
                        Task { if let node = try? await knowledge.store?.node("repo:" + path) { select(node) } }
                    }
                }
                let counts = knowledge.counts
                if !counts.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                        ForEach(["symbol", "file", "concept", "ticket", "pr"].filter { counts[$0] != nil }, id: \.self) { key in
                            VStack(spacing: 1) {
                                Text((counts[key] ?? 0).formatted(.number.notation(.compactName))).font(.callout.weight(.semibold).monospacedDigit())
                                Text(key == "pr" ? "PRs" : key + "s").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                        }
                    }
                    .padding(.top, 4)
                }
            }
            if knowledge.memory != nil { LearnedSection(knowledge: knowledge) }
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
            VStack(alignment: .leading, spacing: 18) {
                header
                if !node.summary.isEmpty { SummaryCard(text: node.summary) }
                if !node.signature.isEmpty {
                    Text(node.signature)
                        .font(node.kind == "symbol" ? .callout.monospaced() : .callout)
                        .lineLimit(node.kind == "symbol" ? nil : 12)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                }
                ForEach(groups, id: \.relation) { group in
                    RelationSection(title: group.relation.replacingOccurrences(of: "_", with: " ").capitalized,
                                    nodes: group.nodes, onOpen: onOpen)
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: knowledge.revision) { neighbors = (try? await knowledge.store?.neighbors(node.id, limit: 120)) ?? [] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                if canGoBack {
                    Button("Back", systemImage: "chevron.left", action: onBack).labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                Image(systemName: KnowledgeRow.icon(node.kind))
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(.tint.opacity(0.12), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.kind == "symbol" ? node.qualified : node.name)
                        .font(.title2.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(node.kind == "symbol" ? node.language : node.kind)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                        if !node.path.isEmpty {
                            Text(node.line > 0 ? "\(node.path):\(node.line)–\(node.endLine)" : node.path)
                                .font(.caption.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) { actions }
                .controlSize(.small)
        }
    }

    private var groups: [(relation: String, nodes: [KnowledgeNode])] {
        Dictionary(grouping: neighbors) { $0.incoming ? KnowledgeExtension.inverse($0.edge.kind) : $0.edge.kind }
            .map { ($0.key, $0.value.map(\.node)) }
            .sorted { $0.relation < $1.relation }
    }

    @ViewBuilder private var actions: some View {
        if let file = fileURL {
            Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(file) }
            Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
        if let url = URL(string: node.url), !node.url.isEmpty {
            Button("Open Link", systemImage: "safari") { NSWorkspace.shared.open(url) }
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
            knowledge.host?.askDashii("Using the knowledge graph (node id \(node.id)), explain \(node.kind == "symbol" ? node.qualified : node.name): what it is, how it fits in, and what's connected to it.")
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
                        if let remote = KnowledgeExtension.remote(at: path) {
                            Label(remote.slug, systemImage: "cloud")
                            Text(remote.provider == .github ? "GitHub, no checkout" : "GitLab, no checkout").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label((path as NSString).lastPathComponent, systemImage: "shippingbox")
                            Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
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
                Toggle(isOn: $knowledge.followWatched) {
                    Text("Index the repositories GitHub and GitLab watch")
                    Text("The ones picked in those integrations' settings: a local checkout if you have one, else read through the integration without cloning.")
                }
            } header: {
                Text("Repositories")
            } footer: {
                Text("Indexed on this Mac: Swift, Go, TypeScript/JavaScript, Python, Rust, Kotlin and Java. Nothing leaves it except what Dashii reads below.")
            }
            Section {
                Toggle("Let Dashii study the code in the background", isOn: $knowledge.understand)
                Stepper("\(knowledge.understandBudget) directories per pass", value: $knowledge.understandBudget, in: 1...30)
                    .disabled(!knowledge.understand)
                Stepper("A pass every \(knowledge.understandHours) h", value: $knowledge.understandHours, in: 1...48)
                    .disabled(!knowledge.understand)
            } header: {
                Text("Understanding")
            } footer: {
                Text("Dashii reads one directory at a time (declarations, imports, README) and notes what it's for, changed and larger directories first. Model and effort: the AI tab.")
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

/// A repository in the Knowledge overview: how much is known about it, and a way to learn more.
private struct RepositoryRow: View {
    let path: String
    let knowledge: KnowledgeExtension
    let open: () -> Void
    @State private var coverage: (studied: Int, directories: Int)?
    @State private var history = 0
    @State private var studying = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: KnowledgeExtension.remote(at: path) == nil ? "shippingbox" : "cloud").foregroundStyle(.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button(action: open) {
                        Text(KnowledgeExtension.remote(at: path)?.slug ?? (path as NSString).lastPathComponent)
                            .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help(path)
                    if history == 0 {
                        Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange).font(.caption)
                            .help("No git history linked yet (authors, files that change together, tickets). It comes back at the next refresh.")
                    }
                }
                if let coverage, coverage.directories > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(coverage.studied), total: Double(coverage.directories))
                            .progressViewStyle(.linear)
                        Text("\(Int((Double(coverage.studied) / Double(coverage.directories) * 100).rounded()))% studied")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .help("Dashii has read and summarised \(coverage.studied) of \(coverage.directories) directories (the code itself is always fully indexed)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if studying {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Study More", systemImage: "sparkles") {
                        studying = true
                        Task {
                            _ = await knowledge.learn(budget: 10, repo: "repo:" + path)
                            await load()
                            studying = false
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Study more: Dashii reads the next 10 directories (uses Dashii usage)")
                }
            }
            .frame(width: 22)
        }
        .padding(.vertical, 2)
        .task(id: knowledge.revision) { await load() }
    }

    private func load() async {
        guard let store = knowledge.store else { return }
        coverage = try? await store.coverage(repo: "repo:" + path)
        history = (try? await store.edgeCount(kind: "authored", repo: "repo:" + path)) ?? 0
    }
}

/// Claude's summary: paragraphs, with "- " lines shown as a bulleted list and "Title:" lines as headings.
private struct SummaryCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What Dashii understood", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let title):
                    Text(title).font(.callout.weight(.semibold)).padding(.top, 4)
                case .bullet(let item):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(.tint).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(LocalizedStringKey(item)).fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let body):
                    Text(LocalizedStringKey(body)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .lineSpacing(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.07), in: .rect(cornerRadius: 12))
    }

    enum Block { case heading(String), bullet(String), paragraph(String) }

    var blocks: [Block] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { line in
            if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") { return .bullet(String(line.dropFirst(2))) }
            if line.hasSuffix(":"), line.count < 60 { return .heading(String(line.dropLast())) }
            return .paragraph(line)
        }
    }
}

/// One relation (e.g. "About"): its nodes as compact tiles in a grid, the first dozen until expanded.
private struct RelationSection: View {
    let title: String
    let nodes: [KnowledgeNode]
    let onOpen: (KnowledgeNode) -> Void
    @State private var expanded = false

    private static let collapsed = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Text("\(nodes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: .capsule)
                Spacer()
                if nodes.count > Self.collapsed {
                    Button(expanded ? "Show less" : "Show all") { withAnimation(.snappy) { expanded.toggle() } }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(nodes.prefix(expanded ? 200 : Self.collapsed), id: \.id) { other in
                    Button { onOpen(other) } label: { RelationTile(node: other) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct RelationTile: View {
    let node: KnowledgeNode
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: KnowledgeRow.icon(node.kind)).foregroundStyle(.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.kind == "symbol" ? node.qualified : node.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.35)), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .help(node.summary.isEmpty ? node.name : node.summary)
    }

    /// The path, else the start of the summary; the kind only adds noise when the section groups one kind.
    private var detail: String? {
        if !node.path.isEmpty { return node.line > 0 ? "\(node.path):\(node.line)" : node.path }
        if !node.summary.isEmpty { return node.summary }
        return nil
    }
}

/// What Dashii learned from conversations: each fact with how sure it is, forgettable one by one.
private struct LearnedSection: View {
    let knowledge: KnowledgeExtension
    @State private var facts: [KnowledgeNode] = []
    @State private var enabled = true
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What \(DashDefaults.shared.string(forKey: "persona.name") ?? "Dashii") learned").font(.caption.bold()).foregroundStyle(.secondary)
                Text("\(facts.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).background(.quaternary, in: .capsule)
                Spacer()
                Toggle("Learn", isOn: $enabled)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(enabled ? "Learning from conversations is on" : "Learning is paused")
                    .onChange(of: enabled) { _, on in knowledge.memory?.isEnabled = on }
            }
            if facts.isEmpty {
                Text(enabled ? "Facts from your conversations show up here." : "Learning is paused.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(facts.prefix(expanded ? 200 : 5), id: \.id) { fact in
                LearnedRow(fact: fact) {
                    Task {
                        try? await knowledge.memory?.forget(fact.id)
                        knowledge.bump()
                    }
                }
            }
            if facts.count > 5 {
                Button(expanded ? "Show less" : "Show all \(facts.count)") { withAnimation(.snappy) { expanded.toggle() } }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.top, 8)
        .task(id: knowledge.revision) {
            enabled = knowledge.memory?.isEnabled ?? false
            facts = await knowledge.memory?.all() ?? []
        }
    }
}

private struct LearnedRow: View {
    let fact: KnowledgeNode
    let forget: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(.tint).frame(width: 14)
                .help(confidence == "stated" ? "You said it" : confidence == "observed" ? "Seen in your data" : "Inferred")
            Text(fact.signature).font(.caption).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 4)
            Button("Forget", systemImage: "xmark.circle", action: forget)
                .labelStyle(.iconOnly).buttonStyle(.borderless).font(.caption)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }

    private var confidence: String { fact.qualified.split(separator: "|").first.map(String.init) ?? "inferred" }
    private var icon: String { confidence == "stated" ? "person.fill.checkmark" : confidence == "observed" ? "eye" : "sparkle" }
}

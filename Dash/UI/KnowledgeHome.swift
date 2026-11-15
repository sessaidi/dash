import DashKit
import DashKitUI
import SwiftUI

/// What the Knowledge page shows before anything is opened: each repository with what Dashii
/// understood about it and its main concepts (click one to open it), and questions to ask.
struct KnowledgeHome: View {
    let knowledge: KnowledgeExtension
    let open: (KnowledgeNode) -> Void
    @State private var repos: [RepoOverview] = []

    struct RepoOverview: Identifiable {
        let node: KnowledgeNode
        let concepts: [KnowledgeNode]
        var id: String { node.id }
        var title: String { node.qualified.isEmpty ? node.name : node.qualified }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your projects").font(.title2.weight(.semibold))
                    Text("What Dashii understood about your repositories. Open a concept, search on the left, or ask.")
                        .foregroundStyle(.secondary)
                }
                if repos.isEmpty {
                    ContentUnavailableView("Nothing studied yet", systemImage: knowledge.systemImage,
                                           description: Text("Add repositories on the left, then Study More: Dashii reads them and writes what it understood."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(repos) { repo in RepoCard(repo: repo, open: open, ask: ask) }
                    }
                    AskStrip(repos: repos.map(\.title), ask: ask)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: knowledge.revision) { await load() }
    }

    private func ask(_ prompt: String) {
        knowledge.host?.askDashii(prompt)
    }

    private func load() async {
        guard let store = knowledge.store else { return }
        var result: [RepoOverview] = []
        for path in knowledge.repositories {
            guard let node = try? await store.node("repo:" + path) else { continue }
            let concepts = (try? await store.nodes(kind: "concept", repo: node.id, limit: 8)) ?? []
            result.append(RepoOverview(node: node, concepts: concepts))
        }
        repos = result
    }
}

/// A repository: Dashii's summary, its concepts as chips, and a question to ask about it.
private struct RepoCard: View {
    let repo: KnowledgeHome.RepoOverview
    let open: (KnowledgeNode) -> Void
    let ask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { open(repo.node) } label: {
                Label(repo.title, systemImage: "shippingbox").font(.headline).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Open \(repo.title)")
            if repo.node.summary.isEmpty {
                Text("Not summarised yet: Study More on the left.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(Self.firstParagraph(repo.node.summary)).font(.callout).lineLimit(5).foregroundStyle(.primary)
            }
            if !repo.concepts.isEmpty {
                FlowChips(items: repo.concepts, open: open)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Explain Its Architecture", systemImage: "sparkles") {
                    ask("Explain the architecture of \(repo.title) from the knowledge graph: its main parts, how a request flows through them, and what it talks to.")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(.tint).frame(width: 4)
        }
    }

    /// The summary's first paragraph, without the "Title:" headings the detail view draws.
    static func firstParagraph(_ summary: String) -> String {
        summary.components(separatedBy: "\n\n").first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? summary
    }
}

/// Concepts as wrapping chips.
private struct FlowChips: View {
    let items: [KnowledgeNode]
    let open: (KnowledgeNode) -> Void

    var body: some View {
        ChipFlow(spacing: 6) {
            ForEach(items) { concept in
                Button(concept.name) { open(concept) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.12), in: .capsule)
                    .help(concept.summary.isEmpty ? concept.name : concept.summary)
            }
        }
    }
}

/// Questions across the projects, one click to ask Dashii.
private struct AskStrip: View {
    let repos: [String]
    let ask: (String) -> Void

    var body: some View {
        let first = repos.first ?? "this project"
        let second = repos.dropFirst().first
        let questions = [
            second.map { "How does \(first) communicate with \($0)?" },
            "Where would I start to change something in \(first)?",
            "What are the riskiest parts of \(first), and why?",
            "Which of my projects share code or depend on each other?",
        ].compactMap { $0 }
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask Dashii", systemImage: "sparkles").font(.headline)
            ChipFlow(spacing: 8) {
                ForEach(questions, id: \.self) { question in
                    Button(question) { ask(question) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Lays children out left to right, wrapping to new lines.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

import DashKit
import DashKitUI
import SwiftUI

/// Draws a note: Markdown blocks natively, and `@Component(…)` directives with the components
/// Dash and the plugins provide. Task boxes and interactive components edit the source through
/// `onChange` (nil: read-only).
struct NoteRenderer: View {
    let source: String
    var noteTitle: String?
    /// How many embeds deep this is (embedded notes stop at 2).
    var depth = 0
    var onChange: ((String) -> Void)?
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        let document = NoteDocument(source)
        NoteBlocks(blocks: document.blocks, context: NoteRenderContext(
            host: host, source: source, lineOffset: document.bodyLineOffset, noteTitle: noteTitle, depth: depth, printing: false, onChange: onChange))
    }
}

/// What every block needs to render and to edit the source.
struct NoteRenderContext {
    let host: ExtensionHost
    let source: String
    let lineOffset: Int
    let noteTitle: String?
    let depth: Int
    /// Drawing for a PDF: components show their frozen state.
    var printing = false
    let onChange: ((String) -> Void)?

    @MainActor var components: [String: MarkdownComponentType] {
        var byName: [String: MarkdownComponentType] = [:]
        for item in host.extensions where host.isEnabled(item) {
            for component in item.components where byName[component.name] == nil { byName[component.name] = component }
        }
        return byName
    }
}

struct NoteBlocks: View {
    let blocks: [NoteBlock]
    let context: NoteRenderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                NoteBlockView(block: block, context: context)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoteBlockView: View {
    let block: NoteBlock
    let context: NoteRenderContext

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(level == 1 ? .largeTitle.bold() : level == 2 ? .title2.bold() : level == 3 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
                // A table of contents scrolls here (`dash-heading://slug`).
                .id(NoteOutline.slug(String(text.characters)))
        case .paragraph(let text):
            Text(text).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let checked = item.checked {
                            Button {
                                guard let onChange = context.onChange else { return }
                                onChange(NoteEdits.toggleTask(in: context.source, line: item.line + context.lineOffset))
                            } label: {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            }
                            .buttonStyle(.plain)
                            .disabled(context.onChange == nil)
                        } else {
                            Text(ordered ? "\(start + index)." : "•").foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                        }
                        NoteBlocks(blocks: item.blocks, context: context)
                            .opacity(item.checked == true ? 0.55 : 1)
                    }
                }
            }
        case .quote(let callout, let title, let blocks):
            if let callout {
                CalloutBox(style: callout, title: title) { NoteBlocks(blocks: blocks, context: context) }
            } else {
                NoteBlocks(blocks: blocks, context: context)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
            }
        case .code(let language, let text):
            // Mermaid flowcharts draw natively; other diagrams stay as code.
            if language?.lowercased() == "mermaid", let graph = MermaidGraph.parse(text) {
                MermaidView(graph: graph)
            } else {
                CodeBlockView(language: language, text: text, printing: context.printing)
            }
        case .rule:
            Divider()
        case .table(let header, let rows):
            NoteTable(header: header, rows: rows)
        case .component(let component):
            NoteComponentView(component: component, context: context)
        case .html(let html):
            Text(html).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}

private struct NoteComponentView: View {
    let component: NoteComponent
    let context: NoteRenderContext

    var body: some View {
        // In a PDF: `frozen: hide` leaves it out, `frozen: "text"` prints the text instead,
        // anything else (or nothing) prints the component's still version.
        if context.printing, let frozen = component.arguments["frozen"], frozen != "snapshot" {
            if frozen != "hide" { Text(frozen).italic() }
        } else if let type = context.components[component.name] {
            type.render(MarkdownComponentContext(
                host: context.host, arguments: component.arguments,
                children: AnyView(NoteBlocks(blocks: component.children.filter { if case .component = $0 { return false }; return true }, context: context)),
                childComponents: component.children.compactMap { block in
                    guard case .component(let child) = block else { return nil }
                    return (child.name, child.arguments, AnyView(NoteComponentView(component: child, context: context)))
                },
                childSource: component.childSource, noteTitle: context.noteTitle, noteSource: context.source,
                isPrinting: context.printing,
                set: { name, value in
                    guard let onChange = context.onChange else { return }
                    onChange(NoteEdits.setArgument(in: context.source, line: component.line + context.lineOffset, name: name, value: value))
                }))
        } else {
            Label("Unknown component @\(component.name). Is its plugin installed?", systemImage: "puzzlepiece.extension")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 8))
        }
    }
}

/// A coloured box with an icon and a title (`@Callout`, and `> [!note]` quotes).
struct CalloutBox<Content: View>: View {
    let style: String
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title ?? style.capitalized, systemImage: icon).font(.headline).foregroundStyle(color)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 6) }
    }

    private var icon: String {
        switch style {
        case "warning", "caution": "exclamationmark.triangle.fill"
        case "danger", "error", "bug": "xmark.octagon.fill"
        case "tip", "success", "check", "done": "checkmark.seal.fill"
        case "question", "help", "faq": "questionmark.circle.fill"
        case "summary", "abstract", "tldr": "text.badge.star"
        case "todo": "checklist"
        case "quote": "quote.opening"
        default: "info.circle.fill"
        }
    }

    private var color: Color {
        switch style {
        case "warning", "caution": .orange
        case "danger", "error", "bug": .red
        case "tip", "success", "check", "done": .green
        case "question", "help", "faq": .purple
        case "summary", "abstract", "tldr": .teal
        default: .blue
        }
    }
}

/// A note's headings, for tables of contents.
enum NoteOutline {
    struct Heading: Hashable {
        let level: Int
        let title: String
        var slug: String { NoteOutline.slug(title) }
    }

    /// `#` headings outside code fences and the frontmatter.
    static func headings(in source: String) -> [Heading] {
        let body = NoteDocument.splitFrontmatter(source).body
        var inFence = false
        var result: [Heading] = []
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, let match = line.firstMatch(of: /^(#{1,6})\s+(.+?)\s*#*\s*$/) else { continue }
            result.append(Heading(level: match.output.1.count, title: String(match.output.2)))
        }
        return result
    }

    static func slug(_ title: String) -> String {
        "h-" + title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }
}

/// A Markdown table. Columns share the width by how long their longest cell is, and each row
/// is as tall as its tallest wrapped cell, so its height is the same on screen and on paper.
struct NoteTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        let weights = (0..<header.count).map { column in
            Double(min(max(([header] + rows).map { $0.indices.contains(column) ? $0[column].characters.count : 0 }.max() ?? 0, 3), 40))
        }
        VStack(alignment: .leading, spacing: 6) {
            TableRowLayout(weights: weights) { ForEach(Array(header.enumerated()), id: \.offset) { Text($0.element).bold() } }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                TableRowLayout(weights: weights) {
                    ForEach(header.indices, id: \.self) { column in Text(row.indices.contains(column) ? row[column] : AttributedString()) }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
    }
}

/// Lays cells out side by side at widths proportional to `weights`, top-aligned.
struct TableRowLayout: Layout {
    let weights: [Double]
    var spacing: Double = 16

    private func widths(_ total: Double, count: Int) -> [Double] {
        let used = Array(weights.prefix(count)) + Array(repeating: 3, count: max(count - weights.count, 0))
        let sum = max(used.reduce(0, +), 1)
        let free = max(total - spacing * Double(max(count - 1, 0)), 0)
        return used.map { free * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 600
        let height = zip(subviews, widths(total, count: subviews.count))
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }
}

/// A fenced code block: language label, a copy button, and long lines scrolling sideways
/// (with a visible scroller) instead of being cut off.
private struct CodeBlockView: View {
    let language: String?
    let text: String
    let printing: Bool
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    private var highlighted: AttributedString { SyntaxHighlighter.highlight(text, language: language, scheme: printing ? .light : colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let language, !language.isEmpty { Text(language).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                if !printing {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                    .help("Copy code")
                }
            }
            if printing {
                Text(highlighted).font(.callout.monospaced())
            } else {
                ScrollView(.horizontal) {
                    Text(highlighted).font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                        .padding(.bottom, 6)
                }
                .scrollIndicators(.visible)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

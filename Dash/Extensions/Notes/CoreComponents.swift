import DashKit
import DashKitUI
import SwiftUI

/// The components every note can use. Plugins add their own (`DashExtension.components`).
@MainActor
enum CoreComponents {
    static var all: [MarkdownComponentType] {
        [toc, children, callout, columns, column, tabs, tab, badge, stat, progress, toggle, ask, dashii, embed, widget]
    }

    static let toc = MarkdownComponentType(
        name: "TOC", summary: "Table of contents of this note's headings; click to jump.",
        parameters: [.init("depth", "number", "Deepest heading level shown (default 3).")],
        example: "@TOC") { context in
        let depth = Int(context.number("depth") ?? 3)
        let headings = NoteOutline.headings(in: context.noteSource).filter { $0.level <= depth }
        let top = headings.map(\.level).min() ?? 1
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            Label("Contents", systemImage: "list.bullet.indent").font(.caption.bold()).foregroundStyle(.secondary)
            if headings.isEmpty {
                Text("No headings yet. Lines starting with #, ## or ### show up here.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                Group {
                    if context.isPrinting { Text(heading.title) } else {
                        Link(heading.title, destination: URL(string: "dash-heading://\(heading.slug)")!)
                    }
                }
                .padding(.leading, CGFloat(heading.level - top) * 14)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10)))
    }

    static let children = MarkdownComponentType(
        name: "Children", summary: "Lists this note's sub-notes as links.",
        example: "@Children") { context in
        AnyView(ChildrenComponent(title: context.noteTitle))
    }

    static let callout = MarkdownComponentType(
        name: "Callout", summary: "A coloured box around Markdown.",
        parameters: [.init("style", "enum", "Look of the box.", options: ["note", "tip", "warning", "danger", "question", "summary"]),
                     .init("title", "string", "Heading; defaults to the style.")],
        acceptsChildren: true, example: "@Callout(style: warning, title: \"Deploy freeze\") {\n  Until **Friday**.\n}") { context in
        AnyView(CalloutBox(style: context.string("style") ?? "note", title: context.string("title")) { context.children })
    }

    static let columns = MarkdownComponentType(
        name: "Columns", summary: "Side-by-side columns; put @Column blocks inside.",
        acceptsChildren: true, example: "@Columns {\n  @Column { Left }\n  @Column { Right }\n}") { context in
        AnyView(HStack(alignment: .top, spacing: 16) {
            ForEach(Array(context.childComponents.enumerated()), id: \.offset) { _, child in
                child.view.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        })
    }

    static let column = MarkdownComponentType(
        name: "Column", summary: "One column of @Columns.", acceptsChildren: true, example: "@Column { Text }") { context in
        AnyView(context.children)
    }

    static let tabs = MarkdownComponentType(
        name: "Tabs", summary: "Tabs; put @Tab(title:) blocks inside. Interactive.",
        acceptsChildren: true, example: "@Tabs {\n  @Tab(title: Plan) { … }\n  @Tab(title: Notes) { … }\n}") { context in
        let tabs = context.childComponents.map { ($0.arguments["title"] ?? $0.name, $0.view) }
        // Printed: every tab, one after another.
        if context.isPrinting {
            return AnyView(VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                    Text(tab.0).font(.headline)
                    tab.1
                }
            })
        }
        return AnyView(TabsComponent(tabs: tabs))
    }

    static let tab = MarkdownComponentType(
        name: "Tab", summary: "One tab of @Tabs.", parameters: [.init("title", "string", "Tab label.", required: true)],
        acceptsChildren: true, example: "@Tab(title: Plan) { … }") { context in
        AnyView(context.children)
    }

    static let badge = MarkdownComponentType(
        name: "Badge", summary: "A small coloured label.",
        parameters: [.init("text", "string", "Label.", required: true),
                     .init("tone", "enum", "Colour.", options: ["neutral", "info", "success", "warning", "danger", "accent"])],
        example: "@Badge(text: \"In review\", tone: info)") { context in
        AnyView(Badge(context.string("text") ?? "", tone: tone(context.string("tone"))))
    }

    static let stat = MarkdownComponentType(
        name: "Stat", summary: "A big number with a label.",
        parameters: [.init("value", "string", "The number or text.", required: true), .init("label", "string", "What it is."),
                     .init("tone", "enum", "Colour.", options: ["neutral", "info", "success", "warning", "danger"])],
        example: "@Stat(value: 12, label: \"open PRs\")") { context in
        AnyView(MetricView(context.string("value") ?? "", label: context.string("label") ?? "", tone: tone(context.string("tone"))))
    }

    static let progress = MarkdownComponentType(
        name: "Progress", summary: "A progress bar.",
        parameters: [.init("value", "number", "Done so far.", required: true), .init("total", "number", "Out of (default 100)."),
                     .init("label", "string", "Caption.")],
        example: "@Progress(value: 7, total: 10, label: \"Migration\")") { context in
        let total = context.number("total") ?? 100
        let value = min(context.number("value") ?? 0, total)
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(context.string("label") ?? "Progress").font(.callout)
                Spacer()
                Text("\(Int(value / max(total, 1) * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: value, total: max(total, 1))
        })
    }

    static let toggle = MarkdownComponentType(
        name: "Toggle", summary: "A switch whose state is saved in the note. Interactive.",
        parameters: [.init("label", "string", "What it controls.", required: true), .init("checked", "boolean", "On or off.")],
        example: "@Toggle(label: \"Shipped\", checked: false)") { context in
        if context.isPrinting {
            return AnyView(Label(context.string("label") ?? "", systemImage: context.bool("checked") == true ? "checkmark.square" : "square"))
        }
        return AnyView(Toggle(context.string("label") ?? "", isOn: Binding(
            get: { context.bool("checked") ?? false },
            set: { context.set("checked", $0 ? "true" : "false") })))
    }

    static let ask = MarkdownComponentType(
        name: "Ask", summary: "A button that asks Dashii something. Interactive.",
        parameters: [.init("prompt", "string", "The question.", required: true), .init("label", "string", "Button text.")],
        example: "@Ask(label: \"What's blocking us?\", prompt: \"Read this note and list the blockers\")") { context in
        // A button means nothing on paper.
        if context.isPrinting { return AnyView(EmptyView()) }
        return AnyView(Button(context.string("label") ?? context.string("prompt") ?? "Ask", systemImage: "sparkles") {
            context.host.askDashii(context.string("prompt") ?? "")
        }
        .buttonStyle(.bordered))
    }

    static let dashii = MarkdownComponentType(
        name: "Dashii",
        summary: "A request to Dashii inside the note: Dashii does it with all its tools (workspaces, PRs, Jira, clusters…) and writes the answer into the block. Also written as a line starting with @Dashii. Interactive.",
        parameters: [.init("ask", "string", "What to do or answer.", required: true), .init("id", "string", "Set by Dashii when it answers.")],
        acceptsChildren: true,
        example: "@Dashii(ask: \"Look at the workspaces for LAF-1234 and give me a report\")") { context in
        AnyView(DashiiBlockView(context: context))
    }

    static let embed = MarkdownComponentType(
        name: "Embed", summary: "Shows another note inline.",
        parameters: [.init("note", "string", "The note's title.", required: true)],
        example: "@Embed(note: \"Team rituals\")") { context in
        AnyView(EmbedComponent(title: context.string("note") ?? ""))
    }

    static let widget = MarkdownComponentType(
        name: "Widget", summary: "Any dashboard widget, live, inside the note. Other parameters become its config.",
        parameters: [.init("kind", "string", "Widget kind, e.g. kubernetes.pods (see list_widget_types).", required: true),
                     .init("height", "number", "Height in points (default 260).")],
        example: "@Widget(kind: \"github.pulls\", height: 320)") { context in
        AnyView(WidgetComponent(arguments: context.arguments))
    }

    static func tone(_ name: String?) -> Tone {
        switch name {
        case "info": .info
        case "success": .success
        case "warning": .warning
        case "danger": .danger
        case "accent": .accent
        default: .neutral
        }
    }
}

private struct TabsComponent: View {
    let tabs: [(String, AnyView)]
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Tabs", selection: $selected) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in Text(tab.0).tag(index) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if tabs.indices.contains(selected) { tabs[selected].1 }
        }
    }
}

private struct EmbedComponent: View {
    let title: String
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        let store = host.ext(NotesExtension.self)?.store
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "doc.text").font(.caption.bold()).foregroundStyle(.secondary)
            if let store, let note = store.note(titled: title) {
                // Embeds are read-only and don't nest more than two deep.
                NoteRenderer(source: store.read(note), noteTitle: note.title, depth: 1)
            } else {
                Text("No note titled “\(title)”.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

private struct WidgetComponent: View {
    let arguments: [String: String]
    @Environment(ExtensionHost.self) private var host
    @State private var config: JSONValue?
    @State private var widgetID = UUID()

    var body: some View {
        let kind = arguments["kind"] ?? ""
        if let type = host.widgetType(kind) {
            VStack(alignment: .leading, spacing: 8) {
                Label(type.displayName, systemImage: type.systemImage).font(.headline)
                type.content(Binding(get: { config ?? initialConfig(type) }, set: { config = $0 }),
                             WidgetContext(widgetID: widgetID, host: host, aiTasks: type.aiTasks))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(14)
            .frame(height: CGFloat(Double(arguments["height"] ?? "") ?? 260), alignment: .top)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
        } else {
            Label("No installed plugin provides the widget “\(kind)”.", systemImage: "puzzlepiece.extension")
                .font(.callout).foregroundStyle(.orange)
        }
    }

    /// The widget's default config with the directive's other parameters on top.
    private func initialConfig(_ type: WidgetType) -> JSONValue {
        var object = type.defaultConfig.object ?? [:]
        for (key, value) in arguments where key != "kind" && key != "height" {
            if let number = Double(value) { object[key] = .number(number) }
            else if ["true", "false"].contains(value.lowercased()) { object[key] = .bool(value.lowercased() == "true") }
            else { object[key] = .string(value) }
        }
        return (try? type.normalize(.object(object))) ?? type.defaultConfig
    }
}

private struct ChildrenComponent: View {
    let title: String?
    @Environment(ExtensionHost.self) private var host

    var body: some View {
        let store = host.ext(NotesExtension.self)?.store
        let parent = title.flatMap { store?.note(titled: $0) }
        let children = parent.map { store?.children(of: $0) ?? [] } ?? []
        VStack(alignment: .leading, spacing: 6) {
            Label("Sub-notes", systemImage: "rectangle.stack").font(.caption.bold()).foregroundStyle(.secondary)
            if children.isEmpty {
                Text("No sub-notes yet. Right-click the note in the list › New Sub-note.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(children) { child in
                Link(destination: URL(string: "dash-note://" + (child.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? child.title))!) {
                    Label(child.title, systemImage: "doc.text")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }
}

/// A @Dashii block: the question, an Ask button that hands it to Dashii in the chat, and the
/// answer Dashii wrote back (the block's body).
private struct DashiiBlockView: View {
    let context: MarkdownComponentContext
    @State private var asked = false

    private var ask: String { context.string("ask") ?? "" }
    private var answered: Bool { !context.childSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(ask).font(.callout.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !context.isPrinting {
                    if asked {
                        Label("Dashii is on it", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(answered ? "Ask Again" : "Ask Dashii") { run() }
                        .controlSize(.small)
                        .disabled(ask.isEmpty || context.noteTitle == nil)
                }
            }
            if answered {
                context.children
            } else if !context.isPrinting {
                Text("Not answered yet. Dashii will write its answer here.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.06), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.25)))
        .onChange(of: context.childSource) { asked = false }
    }

    private func run() {
        guard let title = context.noteTitle else { return }
        asked = true
        let reference = context.string("id") ?? ask
        context.host.askDashii("""
            In my note “\(title)”, a @Dashii block asks: \(ask)

            Do it with your tools, then write your answer into that block with notes_answer \
            (title: “\(title)”, block: “\(reference)”), as a rich note section (components welcome, no # title). \
            Here in the chat, just say in one line that it's done.
            """)
    }
}

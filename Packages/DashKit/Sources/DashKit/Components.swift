import SwiftUI

/// A SwiftUI component notes can use, MDX-style but native. In Markdown it's a block directive:
///
///     @Callout(style: warning, title: "Heads up") {
///       Deploy freeze until **Friday**.
///     }
///     @JiraIssue(key: "PROJ-12")
///
/// Parameters are literal strings, numbers and booleans (plus `{{frontmatter}}` values); nothing
/// is evaluated. Children are ordinary Markdown, rendered by Dash. Components can be interactive
/// and write their parameters back into the note (`context.set`).
@MainActor
public struct MarkdownComponentType: Identifiable {
    public struct Parameter: Sendable, Hashable {
        public let name: String
        /// "string", "number", "boolean" or "enum"; shown to Claude and in the catalog.
        public let type: String
        public let summary: String
        public let required: Bool
        public let options: [String]

        public init(_ name: String, _ type: String = "string", _ summary: String, required: Bool = false, options: [String] = []) {
            self.name = name
            self.type = type
            self.summary = summary
            self.required = required
            self.options = options
        }
    }

    /// The directive name, e.g. "Callout" for `@Callout(…)`.
    public let name: String
    public let summary: String
    public let parameters: [Parameter]
    /// Takes Markdown children (`@Callout { … }`).
    public let acceptsChildren: Bool
    /// A ready-to-paste example, for Claude and the component catalog.
    public let example: String
    public let render: (MarkdownComponentContext) -> AnyView

    public nonisolated var id: String { name }

    public init(name: String, summary: String, parameters: [Parameter] = [], acceptsChildren: Bool = false, example: String,
                render: @escaping (MarkdownComponentContext) -> AnyView) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.acceptsChildren = acceptsChildren
        self.example = example
        self.render = render
    }
}

/// What a component gets when it's drawn.
@MainActor
public struct MarkdownComponentContext {
    public let host: any ExtensionContext
    /// Parameters as written, with `{{frontmatter}}` values filled in.
    public let arguments: [String: String]
    /// The children, rendered (empty for components without children).
    public let children: AnyView
    /// Child directives (e.g. the `@Column`s inside `@Columns`), each rendered.
    public let childComponents: [(name: String, arguments: [String: String], view: AnyView)]
    /// The children's Markdown source.
    public let childSource: String
    /// The note's title, when rendering a note.
    public let noteTitle: String?
    /// The whole note's Markdown (e.g. for a table of contents).
    public let noteSource: String
    /// Drawing for a PDF: show a still, complete version (no buttons; every tab; the state as
    /// it is). The user can also set `frozen: hide`, `frozen: snapshot` or `frozen: "text"`.
    public let isPrinting: Bool
    /// Writes a parameter back into the note's source (e.g. a toggle's state) and saves it.
    public let set: (_ name: String, _ value: String) -> Void

    public init(host: any ExtensionContext, arguments: [String: String], children: AnyView,
                childComponents: [(name: String, arguments: [String: String], view: AnyView)] = [], childSource: String = "",
                noteTitle: String? = nil, noteSource: String = "", isPrinting: Bool = false,
                set: @escaping (String, String) -> Void = { _, _ in }) {
        self.host = host
        self.arguments = arguments
        self.children = children
        self.childComponents = childComponents
        self.childSource = childSource
        self.noteTitle = noteTitle
        self.noteSource = noteSource
        self.isPrinting = isPrinting
        self.set = set
    }

    public func string(_ name: String) -> String? { arguments[name] }
    public func number(_ name: String) -> Double? { arguments[name].flatMap(Double.init) }
    public func bool(_ name: String) -> Bool? {
        arguments[name].map { ["true", "yes", "1", "on"].contains($0.lowercased()) }
    }
}

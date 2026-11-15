import Foundation
import Markdown

/// A note parsed for rendering: frontmatter values, then blocks (Markdown and components).
/// Built with swift-markdown (CommonMark, GitHub tables and task lists, block directives).
struct NoteDocument: Equatable {
    /// `key: value` lines of a leading `---` block.
    let values: [String: String]
    let blocks: [NoteBlock]
    /// Lines before the body (the frontmatter), so block line numbers map back to the source.
    let bodyLineOffset: Int

    init(_ source: String) {
        let (values, body, offset) = Self.splitFrontmatter(source)
        self.values = values
        bodyLineOffset = offset
        // Windows line endings (GitHub sends PR descriptions with them) make swift-markdown's
        // directive parser index out of range, a trap that can't be caught: plain newlines only,
        // and directive parsing only when there's a directive.
        let text = DashiiBlocks.normalized(NotesStore.linkified(body.replacingOccurrences(of: "\r\n", with: "\n")))
        let document = Document(parsing: text, options: Self.hasDirective(text) ? [.parseBlockDirectives] : [])
        blocks = document.children.compactMap { NoteBlock($0, values: values, source: body) }
    }

    /// A line starting with `@Name`: a block directive (`@Component(…)`).
    static func hasDirective(_ text: String) -> Bool {
        text.contains(/(?m)^\s*@[A-Za-z]/)
    }

    static func splitFrontmatter(_ source: String) -> (values: [String: String], body: String, offset: Int) {
        let lines = source.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], source, 0)
        }
        var values: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty { values[key] = value }
        }
        return (values, lines[(end + 1)...].joined(separator: "\n"), end + 1)
    }

    /// Fills `{{key}}` with frontmatter values.
    static func fill(_ text: String, _ values: [String: String]) -> String {
        values.isEmpty ? text : text.replacing(/\{\{\s*([A-Za-z0-9_.\-]+)\s*\}\}/) { values[String($0.output.1)] ?? "" }
    }
}

/// One rendered block. Line numbers are 1-based within the body.
indirect enum NoteBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, start: Int, items: [NoteListItem])
    /// A quote; `callout` is set for Obsidian-style `> [!note] Title` quotes.
    case quote(callout: String?, title: String?, blocks: [NoteBlock])
    case code(language: String?, text: String)
    case rule
    case table(header: [AttributedString], rows: [[AttributedString]])
    case component(NoteComponent)
    case html(String)

    init?(_ markup: Markup, values: [String: String], source: String) {
        switch markup {
        case let heading as Heading:
            self = .heading(level: heading.level, text: NoteInline.text(heading))
        case let paragraph as Paragraph:
            self = .paragraph(NoteInline.text(paragraph))
        case let list as UnorderedList:
            self = .list(ordered: false, start: 1, items: list.listItems.map { NoteListItem($0, values: values, source: source) })
        case let list as OrderedList:
            self = .list(ordered: true, start: Int(list.startIndex), items: list.listItems.map { NoteListItem($0, values: values, source: source) })
        case let quote as BlockQuote:
            var blocks = quote.children.compactMap { NoteBlock($0, values: values, source: source) }
            var callout: String?
            var title: String?
            // `> [!warning] Title` callouts: the marker and title are the first line of the first
            // paragraph; the rest of that paragraph is the body's start.
            if let paragraph = quote.child(at: 0) as? Paragraph, let first = paragraph.child(at: 0) as? Markdown.Text,
               let match = first.string.firstMatch(of: /^\[!([A-Za-z]+)\][+-]?\s*(.*)/) {
                callout = String(match.output.1).lowercased()
                title = String(match.output.2).trimmingCharacters(in: .whitespaces)
                if title?.isEmpty == true { title = nil }
                var rest = AttributedString()
                var afterFirstLine = false
                for child in paragraph.children.dropFirst() {
                    if !afterFirstLine { if child is SoftBreak || child is LineBreak { afterFirstLine = true }; continue }
                    rest += NoteInline.text(child, wrapped: true)
                }
                blocks.removeFirst()
                if !rest.characters.isEmpty { blocks.insert(.paragraph(rest), at: 0) }
            }
            self = .quote(callout: callout, title: title, blocks: blocks)
        case let code as CodeBlock:
            self = .code(language: code.language, text: code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code)
        case is ThematicBreak:
            self = .rule
        case let table as Markdown.Table:
            let header = table.head.cells.map { NoteInline.text($0) }
            let rows: [[AttributedString]] = table.body.rows.map { row in row.cells.map { NoteInline.text($0) } }
            self = .table(header: Array(header), rows: rows)
        case let directive as BlockDirective:
            self = .component(NoteComponent(directive, values: values, source: source))
        case let html as HTMLBlock:
            self = .html(html.rawHTML)
        default:
            return nil
        }
    }
}

struct NoteListItem: Equatable {
    /// nil: not a task; true/false: a `- [x]` / `- [ ]` task.
    let checked: Bool?
    let line: Int
    let blocks: [NoteBlock]

    init(_ item: ListItem, values: [String: String], source: String) {
        checked = item.checkbox.map { $0 == .checked }
        line = item.range?.lowerBound.line ?? 0
        blocks = item.children.compactMap { NoteBlock($0, values: values, source: source) }
    }
}

struct NoteComponent: Equatable {
    let name: String
    let arguments: [String: String]
    let children: [NoteBlock]
    let childSource: String
    let line: Int

    init(_ directive: BlockDirective, values: [String: String], source: String) {
        name = directive.name
        var arguments: [String: String] = [:]
        for argument in directive.argumentText.parseNameValueArguments() {
            arguments[argument.name] = NoteDocument.fill(argument.value, values)
        }
        self.arguments = arguments
        children = directive.children.compactMap { NoteBlock($0, values: values, source: source) }
        line = directive.range?.lowerBound.line ?? 0
        // The children's source: the lines between the directive's braces.
        if let range = directive.range, directive.childCount > 0 {
            let lines = source.components(separatedBy: "\n")
            let start = range.lowerBound.line, end = range.upperBound.line
            childSource = start < end - 1 ? lines[start..<min(end - 1, lines.count)].joined(separator: "\n") : ""
        } else {
            childSource = ""
        }
    }
}

/// Inline Markdown to an AttributedString SwiftUI's Text draws.
enum NoteInline {
    static func text(_ markup: Markup) -> AttributedString {
        var result = AttributedString()
        for child in markup.children { result += inline(child) }
        return result
    }

    /// One inline node (rather than a container's children).
    static func text(_ markup: Markup, wrapped: Bool) -> AttributedString { inline(markup) }

    private static func inline(_ markup: Markup) -> AttributedString {
        switch markup {
        case let text as Markdown.Text:
            return AttributedString(text.string)
        case let strong as Strong:
            var part = Self.text(strong)
            part.inlinePresentationIntent = (part.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            return part
        case let emphasis as Emphasis:
            var part = Self.text(emphasis)
            part.inlinePresentationIntent = (part.inlinePresentationIntent ?? []).union(.emphasized)
            return part
        case let code as InlineCode:
            var part = AttributedString(code.code)
            part.inlinePresentationIntent = .code
            return part
        case let strike as Strikethrough:
            var part = Self.text(strike)
            part.strikethroughStyle = .single
            return part
        case let link as Markdown.Link:
            var part = Self.text(link)
            if let destination = link.destination, let url = URL(string: destination) { part.link = url }
            return part
        case let image as Markdown.Image:
            return AttributedString("🖼 " + (image.plainText.isEmpty ? (image.source ?? "") : image.plainText))
        case is SoftBreak:
            return AttributedString(" ")
        case is LineBreak:
            return AttributedString("\n")
        case let html as InlineHTML:
            return AttributedString(html.rawHTML)
        default:
            return Self.text(markup)
        }
    }
}

/// Edits a note's source for interactive components and task boxes.
enum NoteEdits {
    /// Ticks or unticks the task on `line` (1-based, absolute).
    static func toggleTask(in source: String, line: Int) -> String {
        var lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return source }
        let text = lines[line - 1]
        if let range = text.range(of: "[ ]") {
            lines[line - 1] = text.replacingCharacters(in: range, with: "[x]")
        } else if let range = text.range(of: "[x]") ?? text.range(of: "[X]") {
            lines[line - 1] = text.replacingCharacters(in: range, with: "[ ]")
        }
        return lines.joined(separator: "\n")
    }

    /// Sets `name: value` in the directive that starts on `line` (1-based, absolute), adding it
    /// when missing. Values with spaces or punctuation are quoted.
    static func setArgument(in source: String, line: Int, name: String, value: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return source }
        let text = lines[line - 1]
        let quoted = value.range(of: #"^[A-Za-z0-9_.\-]+$"#, options: .regularExpression) != nil
            ? value : "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else {
            // No arguments yet: `@Name` or `@Name {`.
            if let at = text.range(of: #"@[A-Za-z][A-Za-z0-9]*"#, options: .regularExpression) {
                lines[line - 1] = text.replacingCharacters(in: at, with: text[at] + "(\(name): \(quoted))")
            }
            return lines.joined(separator: "\n")
        }
        let inside = String(text[text.index(after: open)..<close])
        let pattern = "(^|,\\s*)" + NSRegularExpression.escapedPattern(for: name) + "\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|[^,]*)"
        let updated: String
        if let range = inside.range(of: pattern, options: .regularExpression) {
            let prefix = inside[range].hasPrefix(",") ? String(inside[range].prefix { $0 == "," || $0 == " " }) : ""
            updated = inside.replacingCharacters(in: range, with: "\(prefix)\(name): \(quoted)")
        } else {
            updated = inside.trimmingCharacters(in: .whitespaces).isEmpty ? "\(name): \(quoted)" : "\(inside), \(name): \(quoted)"
        }
        lines[line - 1] = String(text[...open]) + updated + String(text[close...])
        return lines.joined(separator: "\n")
    }
}

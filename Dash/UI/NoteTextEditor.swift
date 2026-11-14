import AppKit
import SwiftUI

/// What the editor's context menu can do to the selected text.
enum NoteSelectionAction: String, CaseIterable {
    // AI (Dashii rewrites the selection)
    case rewrite, fix, shorter, longer, translateEnglish, translateFrench, checklist, summarize
    // Ask Dashii about it in the chat
    case explain
    // Formatting (local)
    case bold, italic, code, heading, quote, callout, link
    // Structure
    case extractSubNote

    var title: String {
        switch self {
        case .rewrite: "Rewrite"
        case .fix: "Fix Spelling & Grammar"
        case .shorter: "Make Shorter"
        case .longer: "Make Longer"
        case .translateEnglish: "Translate to English"
        case .translateFrench: "Translate to French"
        case .checklist: "Turn into Checklist"
        case .summarize: "Summarize"
        case .explain: "Explain in Chat"
        case .bold: "Bold"
        case .italic: "Italic"
        case .code: "Code"
        case .heading: "Heading"
        case .quote: "Quote"
        case .callout: "Callout"
        case .link: "Link to Note"
        case .extractSubNote: "Move to New Sub-note"
        }
    }

    var isAI: Bool { [.rewrite, .fix, .shorter, .longer, .translateEnglish, .translateFrench, .checklist, .summarize].contains(self) }

    /// The instruction Dashii follows for AI actions.
    var instruction: String {
        switch self {
        case .rewrite: "Rewrite this text to be clearer, keeping its meaning and Markdown formatting."
        case .fix: "Fix spelling, grammar and punctuation. Change nothing else."
        case .shorter: "Make this text about half as long, keeping the key points."
        case .longer: "Expand this text with useful detail, in the same voice."
        case .translateEnglish: "Translate this text to English, keeping its Markdown."
        case .translateFrench: "Translate this text to French, keeping its Markdown."
        case .checklist: "Turn this text into a Markdown checklist (- [ ] …) of concrete actions."
        case .summarize: "Summarize this text in a few bullet points."
        default: ""
        }
    }

    /// Local formatting: the replacement for `text`.
    func format(_ text: String) -> String? {
        let multiline = text.contains("\n")
        switch self {
        case .bold: return "**\(text)**"
        case .italic: return "*\(text)*"
        case .code: return multiline ? "```\n\(text)\n```" : "`\(text)`"
        case .heading: return "## " + text.replacingOccurrences(of: "\n", with: " ")
        case .quote: return text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        case .callout: return "@Callout(style: note) {\n\(text)\n}"
        case .link: return "[[\(text.trimmingCharacters(in: .whitespacesAndNewlines))]]"
        default: return nil
        }
    }
}

/// The note editor: a plain-text NSTextView (undo, find, spell check) whose right-click menu
/// adds Dashii and formatting actions for the selection, and component inserts.
struct NoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Components to offer under "Insert" (name and example).
    var inserts: [(name: String, example: String)] = []
    /// Runs an action on the selection; returns the replacement (nil: leave the text alone).
    var onAction: (NoteSelectionAction, String) async -> String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize + 1, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.backgroundColor = .clear
        scrollView.drawsBackground = false
        textView.string = text
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        let selection = textView.selectedRanges
        textView.string = text
        // Keep the selection where it still fits; AppKit throws on an empty list, so fall back
        // to the start of the text.
        let length = (text as NSString).length
        let kept = selection.filter { $0.rangeValue.upperBound <= length }
        textView.selectedRanges = kept.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : kept
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor
        weak var textView: NSTextView?

        init(_ parent: NoteTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let selected = view.selectedRange()
            var items: [NSMenuItem] = []
            if selected.length > 0 {
                let ai = NSMenuItem(title: "Dashii", action: nil, keyEquivalent: "")
                ai.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
                ai.submenu = submenu(NoteSelectionAction.allCases.filter { $0.isAI || $0 == .explain })
                items.append(ai)
                let format = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
                format.submenu = submenu([.bold, .italic, .code, .heading, .quote, .callout, .link])
                items.append(format)
                items.append(item(.extractSubNote))
            }
            if !parent.inserts.isEmpty {
                let insert = NSMenuItem(title: "Insert", action: nil, keyEquivalent: "")
                let menu = NSMenu()
                for component in parent.inserts {
                    let entry = NSMenuItem(title: component.name, action: #selector(insertComponent(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = component.example
                    menu.addItem(entry)
                }
                insert.submenu = menu
                items.append(insert)
            }
            for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
            if !items.isEmpty { menu.insertItem(.separator(), at: items.count) }
            return menu
        }

        private func submenu(_ actions: [NoteSelectionAction]) -> NSMenu {
            let menu = NSMenu()
            for action in actions { menu.addItem(item(action)) }
            return menu
        }

        private func item(_ action: NoteSelectionAction) -> NSMenuItem {
            let item = NSMenuItem(title: action.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            return item
        }

        @objc private func run(_ sender: NSMenuItem) {
            guard let textView, let raw = sender.representedObject as? String, let action = NoteSelectionAction(rawValue: raw) else { return }
            let range = textView.selectedRange()
            let selected = (textView.string as NSString).substring(with: range)
            Task {
                guard let replacement = await parent.onAction(action, selected) else { return }
                // Only if the text there hasn't changed meanwhile.
                guard range.upperBound <= (textView.string as NSString).length,
                      (textView.string as NSString).substring(with: range) == selected else { return }
                replace(range, with: replacement)
            }
        }

        @objc private func insertComponent(_ sender: NSMenuItem) {
            guard let textView, let example = sender.representedObject as? String else { return }
            let range = textView.selectedRange()
            let before = range.location > 0 ? (textView.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) : "\n"
            replace(range, with: (before == "\n" ? "" : "\n") + example + "\n")
        }

        /// Replaces through the text view, so it's undoable.
        private func replace(_ range: NSRange, with text: String) {
            guard let textView else { return }
            if textView.shouldChangeText(in: range, replacementString: text) {
                textView.replaceCharacters(in: range, with: text)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
            }
        }
    }
}

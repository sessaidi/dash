import DashKit
import Foundation
import SwiftUI
import Testing
@testable import Dash

/// Settings › Appearance: what's saved, and when a widget gets a card.
@MainActor
struct AppearanceTests {
    private func make() -> (Appearance, UserDefaults) {
        let defaults = UserDefaults(suiteName: "dash-appearance-\(UUID())")!
        return (Appearance(defaults: defaults), defaults)
    }

    @Test func choicesAreSavedAndRestored() {
        let (appearance, defaults) = make()
        appearance.mode = .light
        appearance.accentHex = "#ff5257"
        appearance.widgetStyle = .cards
        let widget = UUID()
        appearance.setColor("#62ba46", ofWidget: widget)
        let again = Appearance(defaults: defaults)
        #expect(again.mode == .light && again.accentHex == "#ff5257" && again.widgetStyle == .cards)
        #expect(again.color(ofWidget: widget) != nil)
        again.setColor(nil, ofWidget: widget)
        #expect(Appearance(defaults: defaults).color(ofWidget: widget) == nil)
    }

    @Test func widgetsGetACardOnlyWhenTheyShouldStandOut() {
        let (appearance, _) = make()
        let widget = UUID()
        #expect(appearance.cardFill(widget: widget, editing: false) == nil)
        #expect(appearance.cardFill(widget: widget, editing: true) != nil)
        appearance.setColor("#007aff", ofWidget: widget)
        #expect(appearance.cardFill(widget: widget, editing: false) != nil)
        appearance.setColor(nil, ofWidget: widget)
        appearance.widgetStyle = .cards
        #expect(appearance.cardFill(widget: widget, editing: false) != nil)
        appearance.reset()
        #expect(appearance.widgetStyle == .page && appearance.mode == .system)
    }

    @Test func coloursRoundTripThroughHex() {
        #expect(Color(hex: "#ff5257")?.hexString == "#ff5257")
    }
}

/// GitHub Markdown from plugins, cleaned for the note renderer.
struct HostMarkdownTests {
    @Test func templateCommentsAndDetailsAreCleaned() {
        let body = "<!-- Tips:\n1. add a label\n-->\n# What\n\n<details><summary>Logs</summary>\n\nline<br>next\n</details>"
        #expect(HostMarkdown.clean(body) == "# What\n\n**Logs**\n\nline  \nnext")
    }
}

/// swift-markdown traps on Windows line endings in its directive parser: notes and plugin
/// Markdown must never reach it with them.
struct MarkdownLineEndingTests {
    static let sample = """
        ### 1. Check the list

        - [ ] **Before:** the button opens the old page.
          ```bash
          curl -s "$BASE/home" "${A[@]}" | jq -r "$URL"
          ```
        - [ ] **After:** nothing else changes.
          ```bash
          diff <(curl -s "$BASE/home" | jq -S .) \\
               <(curl -s "$BASE/away" | jq -S .) && echo SAME
          ```
        """

    @Test func windowsLineEndingsParse() {
        let document = NoteDocument(Self.sample.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n@Callout(type: note) {\r\nHi\r\n}")
        #expect(document.blocks.count >= 3)
    }

    @Test func directivesAreParsedOnlyWhenPresent() {
        #expect(NoteDocument.hasDirective("text\n  @Callout(type: note) {"))
        #expect(!NoteDocument.hasDirective("mail me at a@b.test\n`@escaping`"))
    }
}

/// Confluence pages arrive as `doc` entities: searchable in full, linked to their repository.
struct KnowledgeDocTests {
    @Test func docsKeepTheirWholeTextAndAreSearchable() async throws {
        let store = try KnowledgeStore(url: nil)
        let body = String(repeating: "lorem ", count: 1500) + "restart the epg cache"
        try await KnowledgeLinker.ingest([KnowledgeEntity(id: "doc:confluence:1", kind: "doc", title: "EPG runbook", text: body)],
                                         source: "atlassian", into: store)
        let node = try #require(try await store.node("doc:confluence:1"))
        #expect(node.signature.count == body.count)
        #expect(try await store.search("epg runbook", kinds: ["doc"], limit: 5).first?.id == "doc:confluence:1")
    }
}

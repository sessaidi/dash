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

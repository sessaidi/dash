import AppKit
import DashKit
import Observation
import SwiftUI

/// How Dash looks: light or dark, the accent colour, the page behind the widgets and the widgets
/// themselves (on the page, or on cards of their own colour), plus a colour per widget.
@MainActor
@Observable
final class Appearance {
    static let shared = Appearance()

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum WidgetStyle: String, CaseIterable, Identifiable {
        /// Widgets sit on the page itself; a card shows only while editing the layout.
        case page
        /// Every widget on a card, in the card colour (or its own).
        case cards
        var id: String { rawValue }
        var title: String { self == .page ? "On the page" : "On cards" }
    }

    /// The colours offered next to the colour well: macOS's accent colours.
    static let palette: [(name: String, hex: String)] = [
        ("Blue", "#007aff"), ("Purple", "#a550a7"), ("Pink", "#f74f9e"), ("Red", "#ff5257"),
        ("Orange", "#f7821b"), ("Yellow", "#ffc600"), ("Green", "#62ba46"), ("Teal", "#30b0c7"), ("Graphite", "#8c8c8c"),
    ]

    var mode: Mode { didSet { save(mode.rawValue, "appearance.mode"); apply() } }
    /// "#rrggbb", or nil for the system accent colour.
    var accentHex: String? { didSet { save(accentHex, "appearance.accent") } }
    /// Behind the widgets; nil for the window's own background.
    var pageHex: String? { didSet { save(pageHex, "appearance.page") } }
    var widgetStyle: WidgetStyle { didSet { save(widgetStyle.rawValue, "appearance.widgetStyle") } }
    /// The cards' colour; nil for the standard secondary background.
    var cardHex: String? { didSet { save(cardHex, "appearance.card") } }
    /// How strongly a card or page colour shows (0.05 to 1).
    var tintStrength: Double { didSet { defaults.set(tintStrength, forKey: "appearance.tintStrength") } }
    /// A colour per widget id: its card and its accent.
    private(set) var widgetHex: [String: String] { didSet { defaults.set(widgetHex, forKey: "appearance.widgets") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = DashDefaults.shared) {
        self.defaults = defaults
        mode = defaults.string(forKey: "appearance.mode").flatMap(Mode.init) ?? .system
        accentHex = defaults.string(forKey: "appearance.accent")
        pageHex = defaults.string(forKey: "appearance.page")
        widgetStyle = defaults.string(forKey: "appearance.widgetStyle").flatMap(WidgetStyle.init) ?? .page
        cardHex = defaults.string(forKey: "appearance.card")
        tintStrength = defaults.object(forKey: "appearance.tintStrength") as? Double ?? 0.18
        widgetHex = defaults.dictionary(forKey: "appearance.widgets") as? [String: String] ?? [:]
    }

    var accent: Color? { accentHex.flatMap(Color.init(hex:)) }
    var page: Color? { pageHex.flatMap(Color.init(hex:)).map { $0.opacity(tintStrength) } }

    /// A widget's own colour, if it has one.
    func color(ofWidget id: UUID) -> Color? { widgetHex[id.uuidString].flatMap(Color.init(hex:)) }

    func setColor(_ hex: String?, ofWidget id: UUID) {
        widgetHex[id.uuidString] = hex
    }

    /// What a widget's card is filled with, or nil for no card (widgets on the page, not editing).
    func cardFill(widget id: UUID, editing: Bool) -> AnyShapeStyle? {
        if let own = color(ofWidget: id) { return AnyShapeStyle(own.opacity(tintStrength)) }
        guard widgetStyle == .cards || editing else { return nil }
        if let card = cardHex.flatMap(Color.init(hex:)) { return AnyShapeStyle(card.opacity(tintStrength)) }
        return AnyShapeStyle(.background.secondary)
    }

    /// Light or dark for every window, menus and sheets included (nil follows the system).
    func apply() {
        NSApp?.appearance = switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func reset() {
        mode = .system
        accentHex = nil
        pageHex = nil
        widgetStyle = .page
        cardHex = nil
        tintStrength = 0.18
        widgetHex = [:]
    }

    private func save(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

extension Color {
    /// "#rrggbb" in sRGB (alpha dropped): how Appearance stores colours.
    var hexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let value = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02x%02x%02x", value[0], value[1], value[2])
    }
}

extension View {
    /// The accent colour Appearance sets, or the system's.
    func dashAccent() -> some View { modifier(DashAccent()) }
}

private struct DashAccent: ViewModifier {
    @State private var appearance = Appearance.shared

    func body(content: Content) -> some View {
        if let accent = appearance.accent { content.tint(accent) } else { content }
    }
}

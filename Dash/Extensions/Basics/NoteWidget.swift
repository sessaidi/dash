import DashKit
import DashKitUI
import SwiftUI

struct NoteWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var text: String
    }

    static let kind = "note"
    static let sizeLimits = GridLimits(minW: 2, minH: 3, maxW: 8, maxH: 16)
    static let displayName = "Note"
    static let summary = "A free-text scratch pad."
    static let systemImage = "note.text"
    static let defaultSize = WidgetSize.small
    static let defaultConfig = Config(text: "")
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["text": ["type": "string", "description": "Note contents (plain text)."]],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        NoteView(text: config.text)
    }

    static func preview(config: Config) -> some View {
        NoteView(text: .constant(config.text.isEmpty ? sample : config.text))
    }

    static let sample = "Standup: ship the PR review fixes, pair on the flaky deploy test, follow up on the INC-42 postmortem."
}

/// The note, per size family: denser type on narrow cards, a word and line count once there's
/// room for it (wide), and roomier type on large cards.
struct NoteView: View {
    @Binding var text: String
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        let family = layout.family
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(Self.font(for: family))
                .lineSpacing(family == .large ? 3 : family == .narrow ? 0 : 1)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Jot something down…").font(Self.font(for: family)).foregroundStyle(.tertiary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
            if family == .wide || family == .large, !text.isEmpty {
                HStack {
                    Spacer()
                    Text(Self.counts(text)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        }
    }

    static func font(for family: WidgetLayout.Family) -> Font {
        switch family {
        case .narrow: .callout
        case .large: .title3
        default: .body
        }
    }

    /// "18 words · 2 lines".
    static func counts(_ text: String) -> String {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(words) \(words == 1 ? "word" : "words") · \(lines) \(lines == 1 ? "line" : "lines")"
    }
}

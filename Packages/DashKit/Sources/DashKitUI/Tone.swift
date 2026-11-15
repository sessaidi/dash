import SwiftUI

/// Semantic colour for badges, status and dots. Extensions pick a meaning, not a colour.
public enum Tone: String, Sendable, CaseIterable {
    case neutral, info, success, warning, danger, accent

    public var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .danger: .red
        case .accent: .purple
        }
    }
}

/// A small capsule label: statuses, verdicts, node pools, kinds.
public struct Badge: View {
    let text: String
    let tone: Tone
    let systemImage: String?

    public init(_ text: String, tone: Tone = .neutral, systemImage: String? = nil) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tone.color)
        .background(tone.color.opacity(0.15), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// A coloured dot for compact status (sidebar rows, list leading edge).
public struct StatusDot: View {
    let tone: Tone
    let help: String?

    public init(_ tone: Tone, help: String? = nil) {
        self.tone = tone
        self.help = help
    }

    public var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 8, height: 8)
            .help(help ?? "")
            .accessibilityLabel(help ?? tone.rawValue)
    }
}

#Preview("Badges") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(Tone.allCases, id: \.self) { tone in
            HStack {
                Badge(tone.rawValue, tone: tone)
                Badge("with icon", tone: tone, systemImage: "checkmark")
                StatusDot(tone)
            }
        }
    }
    .padding()
}

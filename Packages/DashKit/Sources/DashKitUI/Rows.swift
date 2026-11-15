import SwiftUI

/// The standard list row: leading accessory, title, subtitle, trailing accessory.
public struct ItemRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let monospacedTitle: Bool
    let leading: Leading
    let trailing: Trailing

    public init(
        _ title: String, subtitle: String? = nil, monospacedTitle: Bool = false,
        @ViewBuilder leading: () -> Leading = { EmptyView() }, @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.monospacedTitle = monospacedTitle
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(monospacedTitle ? .callout.monospaced() : .callout).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .contentShape(.rect)
    }
}

/// A big number with a caption, for metric widgets.
public struct MetricView: View {
    let value: String
    let label: String
    let tone: Tone

    public init(_ value: String, label: String, tone: Tone = .neutral) {
        self.value = value
        self.label = label
        self.tone = tone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 40, weight: .semibold).monospacedDigit())
                .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "3m ago", kept fresh.
public struct RelativeTime: View {
    let date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public var body: some View {
        TimelineView(.everyMinute) { _ in
            Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
        }
    }
}

#Preview("Rows") {
    List {
        ItemRow("Add retry to the order fetcher", subtitle: "acme/api#812 · jrivera", leading: { Badge("high", tone: .danger) }, trailing: { Badge("review requested", tone: .warning) })
        ItemRow("alpha", subtitle: "sadik · main", monospacedTitle: true, leading: { StatusDot(.success) })
        MetricView("99.9%", label: "API availability", tone: .success)
    }
    .frame(width: 420, height: 260)
}

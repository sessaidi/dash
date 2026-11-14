import SwiftUI

/// The space a widget's content has, so a widget can show a different layout per size (like
/// iOS widget families) instead of squeezing one layout. Read it with
/// `@Environment(\.widgetLayout)` inside the view a widget's `content` returns.
///
/// ```swift
/// switch layout.family {
/// case .narrow: CompactList(pods)
/// case .wide, .large: PodTable(pods)
/// default: PodRows(pods)
/// }
/// ```
public struct WidgetLayout: Equatable, Sendable {
    public enum Family: String, Sendable, CaseIterable {
        /// Under 320 points wide: one column of short lines.
        case narrow
        /// The usual card.
        case medium
        /// 640 points wide or more, but short: room for columns.
        case wide
        /// 640 × 360 points or more: room for columns and a detail area.
        case large
    }

    /// The content area in points (inside the card's padding and header).
    public var size: CGSize

    public init(size: CGSize) {
        self.size = size
    }

    public var family: Family { Self.family(for: size) }

    public static func family(for size: CGSize) -> Family {
        if size.width < 320 { return .narrow }
        if size.width >= 640 { return size.height >= 360 ? .large : .wide }
        return .medium
    }

    /// Unknown size (previews, the gallery): treated as a medium card.
    public static let unknown = WidgetLayout(size: CGSize(width: 480, height: 320))
}

extension EnvironmentValues {
    /// The widget's content area and size family, set by the dashboard around each widget.
    @Entry public var widgetLayout: WidgetLayout = .unknown
}

extension View {
    /// Measures this view and publishes its size as `widgetLayout` to its content.
    public func measuresWidgetLayout() -> some View {
        modifier(WidgetLayoutReader())
    }
}

private struct WidgetLayoutReader: ViewModifier {
    @State private var size: CGSize?

    func body(content: Content) -> some View {
        content
            .environment(\.widgetLayout, size.map(WidgetLayout.init) ?? .unknown)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }
}

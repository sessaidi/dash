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
        /// Up to 3 grid columns (or under 260 points): one column of short lines.
        case narrow
        /// The usual card: 4–5 columns.
        case medium
        /// 8 columns or more (or 6–7 but short): room for columns.
        case wide
        /// 6–7 columns and 8 rows or more, or 8+ columns and 12+ rows: columns and a detail area.
        case large
    }

    /// The content area in points (inside the card's padding and header).
    public var size: CGSize
    /// The widget's span on the dashboard grid (12 columns), when it's on one: the family follows
    /// the preset sizes (Small, Medium, Large, Wide), stepping down only when the window is too
    /// narrow for it (wide and large need `minimumWideWidth` points, medium `minimumMediumWidth`).
    public var columns: Int?
    public var rows: Int?

    public static let minimumMediumWidth: CGFloat = 260
    public static let minimumWideWidth: CGFloat = 480

    public init(size: CGSize) {
        self.init(size: size, columns: nil, rows: nil)
    }

    public init(size: CGSize, columns: Int?, rows: Int?) {
        self.size = size
        self.columns = columns
        self.rows = rows
    }

    public var family: Family {
        guard let columns else { return Self.family(for: size) }
        // The presets: Small 3×4 narrow, Medium 4×6 medium, Large 6×9 large, Wide 8×9 wide.
        let rows = self.rows ?? 0
        let span: Family = if columns <= 3 { .narrow }
            else if columns >= 8 { rows >= 12 ? .large : .wide }
            else if columns >= 6 { rows >= 8 ? .large : .wide }
            else { .medium }
        if span == .narrow || size.width < Self.minimumMediumWidth { return .narrow }
        if span != .medium, size.width < Self.minimumWideWidth { return .medium }
        return span
    }

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
    /// Measures this view and publishes its size as `widgetLayout`.
    public func measuresWidgetLayout() -> some View {
        modifier(WidgetLayoutReader(columns: nil, rows: nil))
    }

    /// Measures this view and publishes its size and grid span as `widgetLayout`.
    public func measuresWidgetLayout(columns: Int?, rows: Int?) -> some View {
        modifier(WidgetLayoutReader(columns: columns, rows: rows))
    }
}

private struct WidgetLayoutReader: ViewModifier {
    let columns: Int?
    let rows: Int?
    @State private var size: CGSize?

    func body(content: Content) -> some View {
        content
            .environment(\.widgetLayout, size.map { WidgetLayout(size: $0, columns: columns, rows: rows) } ?? WidgetLayout(size: WidgetLayout.unknown.size, columns: columns, rows: rows))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                // A layout switch (narrow → medium…) is instant, never a cross-fade while resizing.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { size = newSize }
            }
            .transaction(value: columns) { $0.animation = nil }
            .transaction(value: rows) { $0.animation = nil }
    }
}

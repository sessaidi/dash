import CoreGraphics

/// Grid units to points for one grid width: where a cell is drawn, and how far a pointer
/// translation moves in cells.
public struct GridGeometry: Hashable, Sendable {
    public let cellWidth: CGFloat
    public let rowHeight: CGFloat
    public let spacing: CGFloat

    /// `columns` columns sharing `width` (without the outer padding), `spacing` between them.
    public init(width: CGFloat, columns: Int, rowHeight: CGFloat, spacing: CGFloat) {
        let columns = max(columns, 1)
        cellWidth = max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 1)
        self.rowHeight = rowHeight
        self.spacing = spacing
    }

    /// As many columns as fit `width` at `minimumColumnWidth`, up to `columns`: a narrow window
    /// drops columns instead of squeezing them.
    public static func columns(fitting width: CGFloat, upTo columns: Int, minimumColumnWidth: CGFloat, spacing: CGFloat) -> Int {
        min(columns, max(1, Int((width + spacing) / (minimumColumnWidth + spacing))))
    }

    public func rect(_ frame: GridRect) -> CGRect {
        CGRect(x: CGFloat(frame.x) * (cellWidth + spacing), y: CGFloat(frame.y) * (rowHeight + spacing),
               width: CGFloat(frame.w) * cellWidth + CGFloat(frame.w - 1) * spacing,
               height: CGFloat(frame.h) * rowHeight + CGFloat(frame.h - 1) * spacing)
    }

    public func height(rows: Int) -> CGFloat { CGFloat(rows) * (rowHeight + spacing) }

    /// Cells moved by a pointer translation, rounded to the nearest cell (the magnet).
    public func cells(_ translation: CGSize) -> (dx: Int, dy: Int) {
        (Int((translation.width / (cellWidth + spacing)).rounded()), Int((translation.height / (rowHeight + spacing)).rounded()))
    }
}

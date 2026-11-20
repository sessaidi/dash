import Foundation

/// A cell's place on the grid, in grid units: column, row, width in columns, height in rows.
public struct GridRect: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public func intersects(_ other: GridRect) -> Bool {
        x < other.x + other.w && other.x < x + w && y < other.y + other.h && other.y < y + h
    }

    public var description: String { "(\(x),\(y) \(w)x\(h))" }
}

/// How small and large a cell may be resized, in grid units. Each cell can have its own; the
/// grid enforces them while resizing.
public struct GridSizeLimits: Hashable, Codable, Sendable, CustomStringConvertible {
    public var minW: Int
    public var minH: Int
    public var maxW: Int
    public var maxH: Int

    public init(minW: Int = 2, minH: Int = 3, maxW: Int = 12, maxH: Int = 40) {
        self.minW = max(1, minW)
        self.minH = max(1, minH)
        self.maxW = max(self.minW, maxW)
        self.maxH = max(self.minH, maxH)
    }

    /// No limits beyond the grid's own.
    public static let any = GridSizeLimits(minW: 1, minH: 1, maxW: 1000, maxH: 1000)

    public var description: String { "\(minW)x\(minH)…\(maxW)x\(maxH)" }
}

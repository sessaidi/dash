import Foundation
internal import MagnetGrid

/// A widget's place on the dashboard grid, in cells.
public struct GridFrame: Hashable, Codable, Sendable, CustomStringConvertible {
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

    public func intersects(_ other: GridFrame) -> Bool {
        rect.intersects(other.rect)
    }

    public var description: String { rect.description }
}

/// How small and large a widget may be resized, in grid cells. A widget declares its own; the
/// grid enforces it while resizing.
public struct GridLimits: Hashable, Codable, Sendable, CustomStringConvertible {
    public var minW: Int
    public var minH: Int
    public var maxW: Int
    public var maxH: Int

    public init(minW: Int = 2, minH: Int = 3, maxW: Int = 12, maxH: Int = 40) {
        let limits = GridSizeLimits(minW: minW, minH: minH, maxW: maxW, maxH: maxH)
        self.minW = limits.minW
        self.minH = limits.minH
        self.maxW = limits.maxW
        self.maxH = limits.maxH
    }

    /// No limits beyond the grid's own.
    public static let any = GridLimits(minW: 1, minH: 1, maxW: 1000, maxH: 1000)

    public var description: String { sizeLimits.description }
}

/// Snap-grid layout rules (the react-grid-layout model): when a frame moves or resizes,
/// frames it overlaps are pushed down. With `compacts` on, everything then falls upward to
/// close gaps; with it off (free placement), frames stay where they're put, gaps and all.
/// The rules live in MagnetGrid's `GridLayoutEngine`; this keeps DashKit's types and signatures.
public struct GridEngine: Sendable {
    public let columns: Int
    public let minSize: (w: Int, h: Int)
    public let compacts: Bool

    public init(columns: Int = 12, minSize: (w: Int, h: Int) = (2, 3), compacts: Bool = true) {
        self.columns = columns
        self.minSize = minSize
        self.compacts = compacts
    }

    var core: GridLayoutEngine { GridLayoutEngine(columns: columns, minSize: minSize, compacts: compacts) }

    /// Keeps a frame inside the columns, at least the grid's minimum size, and within `limits`.
    public func clamp(_ frame: GridFrame, limits: GridLimits? = nil) -> GridFrame {
        GridFrame(core.clamp(frame.rect, limits: limits?.sizeLimits))
    }

    /// The layout after `id` is dropped at `frame`: `id` keeps the spot it was dropped on,
    /// colliding frames move below it, then (when compacting) all frames compact upward.
    public func layout<ID: Hashable>(_ frames: [ID: GridFrame], moving id: ID, to frame: GridFrame,
                                     limits: [ID: GridLimits] = [:]) -> [ID: GridFrame] {
        core.layout(frames.mapValues(\.rect), moving: id, to: frame.rect, limits: limits.mapValues(\.sizeLimits)).mapValues(GridFrame.init)
    }

    /// Moves every frame up as far as it goes, top to bottom. The pinned frame (the one being
    /// dragged) compacts too, but is placed first among frames on its row so it wins ties.
    /// Without compaction (free placement) frames keep their rows and only overlaps are resolved.
    public func compact<ID: Hashable>(_ frames: [ID: GridFrame], pinned: ID? = nil) -> [ID: GridFrame] {
        core.compact(frames.mapValues(\.rect), pinned: pinned).mapValues(GridFrame.init)
    }

    /// The closest spot in the same columns that overlaps none of `others`: up or down by the
    /// fewest rows (up wins ties, so space freed above is used first).
    public func nearestFree(_ frame: GridFrame, avoiding others: [GridFrame]) -> GridFrame {
        GridFrame(core.nearestFree(frame.rect, avoiding: others.map(\.rect)))
    }

    /// Pushes overlapping frames down, top to bottom, without moving anything up.
    public func resolveOverlaps<ID: Hashable>(_ frames: [ID: GridFrame], pinned: ID? = nil) -> [ID: GridFrame] {
        core.resolveOverlaps(frames.mapValues(\.rect), pinned: pinned).mapValues(GridFrame.init)
    }

    /// The first free spot for a new w×h frame, scanning rows top to bottom, left to right.
    public func firstFit<ID: Hashable>(w: Int, h: Int, in frames: [ID: GridFrame]) -> GridFrame {
        GridFrame(core.firstFit(w: w, h: h, in: frames.mapValues(\.rect)))
    }

    /// The layout re-packed into fewer columns, for a window too narrow for the saved one.
    /// Cells keep their reading order and height; each keeps its width, clamped to its limits and
    /// to `columns`, and goes in the first spot that isn't above the previous cell, so nothing
    /// jumps ahead of what came before it. The saved layout is untouched.
    public func reflow<ID: Hashable>(_ frames: [ID: GridFrame], columns: Int, limits: [ID: GridLimits] = [:]) -> [ID: GridFrame] {
        core.reflow(frames.mapValues(\.rect), columns: columns, limits: limits.mapValues(\.sizeLimits)).mapValues(GridFrame.init)
    }

    public func reflow<ID: Hashable>(_ frames: [ID: GridFrame], columns: Int, width: (ID, GridFrame) -> Int) -> [ID: GridFrame] {
        core.reflow(frames.mapValues(\.rect), columns: columns) { width($0, GridFrame($1)) }.mapValues(GridFrame.init)
    }

    /// Reading order (top to bottom, left to right).
    public func order(_ a: GridFrame, _ b: GridFrame) -> Bool {
        core.order(a.rect, b.rect)
    }

    /// Rows used by a layout.
    public func height<ID: Hashable>(_ frames: [ID: GridFrame]) -> Int {
        core.height(frames.mapValues(\.rect))
    }
}

extension GridFrame {
    init(_ rect: GridRect) {
        self.init(x: rect.x, y: rect.y, w: rect.w, h: rect.h)
    }

    var rect: GridRect { GridRect(x: x, y: y, w: w, h: h) }
}

extension GridLimits {
    var sizeLimits: GridSizeLimits { GridSizeLimits(minW: minW, minH: minH, maxW: maxW, maxH: maxH) }
}

import Foundation

/// Snap-grid layout rules (the react-grid-layout model): when a cell moves or resizes, cells it
/// overlaps are pushed down. With `compacts` on, everything then falls upward to close gaps; with
/// it off (free placement), cells stay where they're put, gaps and all.
public struct GridLayoutEngine: Sendable {
    public let columns: Int
    public let minSize: (w: Int, h: Int)
    public let compacts: Bool

    public init(columns: Int = 12, minSize: (w: Int, h: Int) = (2, 3), compacts: Bool = true) {
        self.columns = columns
        self.minSize = minSize
        self.compacts = compacts
    }

    /// Keeps a cell inside the columns, at least the grid's minimum size, and within `limits`.
    public func clamp(_ frame: GridRect, limits: GridSizeLimits? = nil) -> GridRect {
        let limits = limits ?? .any
        let minW = min(max(minSize.w, limits.minW), columns), minH = max(minSize.h, limits.minH)
        let w = min(max(frame.w, minW), min(limits.maxW, columns))
        let h = min(max(frame.h, minH), max(limits.maxH, minH))
        return GridRect(x: min(max(frame.x, 0), columns - w), y: max(frame.y, 0), w: w, h: h)
    }

    /// The layout after `id` is dropped at `frame`: `id` keeps the spot it was dropped on,
    /// colliding cells move below it, then (when compacting) all cells compact upward.
    public func layout<ID: Hashable>(_ frames: [ID: GridRect], moving id: ID, to frame: GridRect,
                                     limits: [ID: GridSizeLimits] = [:]) -> [ID: GridRect] {
        var placed: [(ID, GridRect)] = [(id, clamp(frame, limits: limits[id]))]
        let others = frames.filter { $0.key != id }.sorted { order($0.value, $1.value) }
        for (otherID, other) in others {
            var candidate = clamp(other, limits: limits[otherID])
            if compacts {
                // Push below whatever it overlaps until it fits.
                while let blocker = placed.first(where: { $0.1.intersects(candidate) }) {
                    candidate.y = blocker.1.y + blocker.1.h
                }
            } else {
                // Free placement: the nearest free rows, above or below, whichever is closer.
                candidate = nearestFree(candidate, avoiding: placed.map(\.1))
            }
            placed.append((otherID, candidate))
        }
        let result = Dictionary(uniqueKeysWithValues: placed)
        return compacts ? compact(result, pinned: id) : result
    }

    /// Moves every cell up as far as it goes, top to bottom. The pinned cell (the one being
    /// dragged) compacts too, but is placed first among cells on its row so it wins ties.
    /// Without compaction (free placement) cells keep their rows and only overlaps are resolved.
    public func compact<ID: Hashable>(_ frames: [ID: GridRect], pinned: ID? = nil) -> [ID: GridRect] {
        guard compacts else { return resolveOverlaps(frames, pinned: pinned) }
        var result: [ID: GridRect] = [:]
        let sorted = frames.sorted { left, right in
            if left.value.y != right.value.y { return left.value.y < right.value.y }
            if left.key == pinned { return true }
            if right.key == pinned { return false }
            return left.value.x < right.value.x
        }
        for (id, frame) in sorted {
            var candidate = clamp(frame)
            while candidate.y > 0 {
                var up = candidate
                up.y -= 1
                if result.values.contains(where: { $0.intersects(up) }) { break }
                candidate = up
            }
            // An earlier cell may now overlap (it fell into this column); push down past it.
            while let blocker = result.values.first(where: { $0.intersects(candidate) }) {
                candidate.y = blocker.y + blocker.h
            }
            result[id] = candidate
        }
        return result
    }

    /// The closest spot in the same columns that overlaps none of `others`: up or down by the
    /// fewest rows (up wins ties, so space freed above is used first).
    public func nearestFree(_ frame: GridRect, avoiding others: [GridRect]) -> GridRect {
        func fits(_ candidate: GridRect) -> Bool { !others.contains { $0.intersects(candidate) } }
        if fits(frame) { return frame }
        let bottom = (others.map { $0.y + $0.h }.max() ?? 0) + frame.h
        for distance in 1...max(bottom, 1) {
            var up = frame
            up.y -= distance
            if up.y >= 0, fits(up) { return up }
            var down = frame
            down.y += distance
            if fits(down) { return down }
        }
        var below = frame
        below.y = others.map { $0.y + $0.h }.max() ?? frame.y
        return below
    }

    /// Pushes overlapping cells down, top to bottom, without moving anything up.
    public func resolveOverlaps<ID: Hashable>(_ frames: [ID: GridRect], pinned: ID? = nil) -> [ID: GridRect] {
        var result: [ID: GridRect] = [:]
        let sorted = frames.sorted { left, right in
            if left.key == pinned { return true }
            if right.key == pinned { return false }
            return order(left.value, right.value)
        }
        for (id, frame) in sorted {
            var candidate = clamp(frame)
            while let blocker = result.values.first(where: { $0.intersects(candidate) }) {
                candidate.y = blocker.y + blocker.h
            }
            result[id] = candidate
        }
        return result
    }

    /// The first free spot for a new w×h cell, scanning rows top to bottom, left to right.
    public func firstFit<ID: Hashable>(w: Int, h: Int, in frames: [ID: GridRect]) -> GridRect {
        let size = clamp(GridRect(x: 0, y: 0, w: w, h: h))
        let bottom = frames.values.map { $0.y + $0.h }.max() ?? 0
        for y in 0...bottom {
            for x in 0...(columns - size.w) {
                let candidate = GridRect(x: x, y: y, w: size.w, h: size.h)
                if !frames.values.contains(where: { $0.intersects(candidate) }) { return candidate }
            }
        }
        return GridRect(x: 0, y: bottom, w: size.w, h: size.h)
    }

    /// The layout re-packed into fewer columns, for a window too narrow for the saved one.
    /// Cells keep their reading order and height; each keeps its width, clamped to its limits and
    /// to `columns`, and goes in the first spot that isn't above the previous cell, so nothing
    /// jumps ahead of what came before it. The saved layout is untouched.
    public func reflow<ID: Hashable>(_ frames: [ID: GridRect], columns: Int, limits: [ID: GridSizeLimits] = [:]) -> [ID: GridRect] {
        reflow(frames, columns: columns) { id, frame in
            let limit = limits[id] ?? .any
            return min(max(frame.w, limit.minW), limit.maxW)
        }
    }

    public func reflow<ID: Hashable>(_ frames: [ID: GridRect], columns: Int, width: (ID, GridRect) -> Int) -> [ID: GridRect] {
        let columns = max(1, columns)
        var placed: [ID: GridRect] = [:]
        var floor = 0
        for (id, frame) in frames.sorted(by: { order($0.value, $1.value) }) {
            let w = min(max(width(id, frame), 1), columns)
            var y = floor
            search: while true {
                for x in 0...(columns - w) {
                    let candidate = GridRect(x: x, y: y, w: w, h: frame.h)
                    if !placed.values.contains(where: { $0.intersects(candidate) }) {
                        placed[id] = candidate
                        floor = y
                        break search
                    }
                }
                y += 1
            }
        }
        return placed
    }

    /// Reading order (top to bottom, left to right).
    public func order(_ a: GridRect, _ b: GridRect) -> Bool {
        a.y != b.y ? a.y < b.y : a.x < b.x
    }

    /// Rows used by a layout.
    public func height<ID: Hashable>(_ frames: [ID: GridRect]) -> Int {
        frames.values.map { $0.y + $0.h }.max() ?? 0
    }
}

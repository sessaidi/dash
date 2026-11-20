import CoreGraphics

/// A cell being moved or resized: where it started and how far the pointer went. The view keeps
/// one while a gesture runs; everything it draws from it (the snapped target, the limit warning,
/// the cell following the pointer) is computed here.
public struct GridDrag<ID: Hashable & Sendable>: Equatable, Sendable {
    public enum Kind: Sendable { case move, resize }

    public let id: ID
    public let kind: Kind
    public let start: GridRect
    public var translation: CGSize

    public init(id: ID, kind: Kind, start: GridRect, translation: CGSize = .zero) {
        self.id = id
        self.kind = kind
        self.start = start
        self.translation = translation
    }

    /// The frame the pointer asks for, snapped to whole cells but not yet clamped.
    public func wanted(_ geometry: GridGeometry) -> GridRect {
        let delta = geometry.cells(translation)
        var frame = start
        switch kind {
        case .move:
            frame.x += delta.dx
            frame.y += delta.dy
        case .resize:
            frame.w += delta.dx
            frame.h += delta.dy
        }
        return frame
    }

    /// The snapped frame the cell would land on.
    public func target(_ engine: GridLayoutEngine, _ geometry: GridGeometry, limits: GridSizeLimits? = nil) -> GridRect {
        engine.clamp(wanted(geometry), limits: limits)
    }

    /// A resize asking for more (or less) than the cell's limits allow.
    public func isAtLimit(_ engine: GridLayoutEngine, _ geometry: GridGeometry, limits: GridSizeLimits? = nil) -> Bool {
        guard kind == .resize else { return false }
        let wanted = wanted(geometry), got = target(engine, geometry, limits: limits)
        return got.w != wanted.w || got.h != wanted.h
    }

    /// Where the dragged cell is drawn: it follows the pointer; a resize stays within the cell's
    /// limits, with a little rubber band past them.
    public func liveRect(_ engine: GridLayoutEngine, _ geometry: GridGeometry, limits: GridSizeLimits? = nil) -> CGRect {
        let start = geometry.rect(self.start)
        switch kind {
        case .move:
            return start.offsetBy(dx: translation.width, dy: translation.height)
        case .resize:
            let smallest = engine.clamp(GridRect(x: 0, y: 0, w: 1, h: 1), limits: limits)
            let largest = engine.clamp(GridRect(x: 0, y: 0, w: 1000, h: 1000), limits: limits)
            let minimum = geometry.rect(GridRect(x: 0, y: 0, w: smallest.w, h: smallest.h))
            let maximum = geometry.rect(GridRect(x: 0, y: 0, w: largest.w, h: largest.h))
            return CGRect(x: start.minX, y: start.minY,
                          width: Self.band(start.width + translation.width, minimum.width, maximum.width),
                          height: Self.band(start.height + translation.height, minimum.height, maximum.height))
        }
    }

    /// `value` kept between `low` and `high`, giving 15% of whatever goes past them.
    static func band(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        value < low ? low - (low - value) * 0.15 : value > high ? high + (value - high) * 0.15 : value
    }
}

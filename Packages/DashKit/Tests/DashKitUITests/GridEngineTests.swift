import CoreGraphics
import Testing
@testable import DashKitUI

struct GridEngineTests {
    let engine = GridEngine(columns: 12, minSize: (2, 3))

    @Test func clampKeepsFramesInsideTheColumnsAndAboveMinimum() {
        #expect(engine.clamp(GridFrame(x: 11, y: -2, w: 4, h: 1)) == GridFrame(x: 8, y: 0, w: 4, h: 3))
        #expect(engine.clamp(GridFrame(x: 0, y: 0, w: 20, h: 5)) == GridFrame(x: 0, y: 0, w: 12, h: 5))
    }

    @Test func droppingOnAWidgetPushesItDown() {
        let frames = ["a": GridFrame(x: 0, y: 0, w: 6, h: 4), "b": GridFrame(x: 6, y: 0, w: 6, h: 4)]
        let result = engine.layout(frames, moving: "b", to: GridFrame(x: 0, y: 0, w: 6, h: 4))
        #expect(result["b"] == GridFrame(x: 0, y: 0, w: 6, h: 4))
        #expect(result["a"] == GridFrame(x: 0, y: 4, w: 6, h: 4))
    }

    @Test func gapsCloseUpwardLikeAMagnet() {
        let frames = ["a": GridFrame(x: 0, y: 0, w: 4, h: 4), "b": GridFrame(x: 0, y: 4, w: 4, h: 4)]
        // Moving a to the right leaves b's column empty above it: b rises to the top.
        let result = engine.layout(frames, moving: "a", to: GridFrame(x: 6, y: 0, w: 4, h: 4))
        #expect(result["a"] == GridFrame(x: 6, y: 0, w: 4, h: 4))
        #expect(result["b"] == GridFrame(x: 0, y: 0, w: 4, h: 4))
    }

    @Test func droppedFrameFloatsUpIntoFreeSpace() {
        let frames = ["a": GridFrame(x: 0, y: 0, w: 4, h: 4)]
        let result = engine.layout(frames, moving: "a", to: GridFrame(x: 4, y: 10, w: 4, h: 4))
        #expect(result["a"] == GridFrame(x: 4, y: 0, w: 4, h: 4))
    }

    @Test func pushesCascadeAndNothingOverlaps() {
        let frames = [
            "a": GridFrame(x: 0, y: 0, w: 12, h: 3), "b": GridFrame(x: 0, y: 3, w: 6, h: 3),
            "c": GridFrame(x: 6, y: 3, w: 6, h: 3), "d": GridFrame(x: 0, y: 6, w: 12, h: 3),
        ]
        let result = engine.layout(frames, moving: "d", to: GridFrame(x: 0, y: 0, w: 12, h: 3))
        #expect(result["d"]?.y == 0)
        #expect(result["a"]?.y == 3)
        let values = Array(result.values)
        for i in values.indices { for j in values.indices where i < j { #expect(!values[i].intersects(values[j])) } }
    }

    @Test func resizeWiderPushesNeighboursDown() {
        let frames = ["a": GridFrame(x: 0, y: 0, w: 6, h: 4), "b": GridFrame(x: 6, y: 0, w: 6, h: 4)]
        let result = engine.layout(frames, moving: "a", to: GridFrame(x: 0, y: 0, w: 8, h: 4))
        #expect(result["a"] == GridFrame(x: 0, y: 0, w: 8, h: 4))
        #expect(result["b"] == GridFrame(x: 6, y: 4, w: 6, h: 4))
    }

    @Test func firstFitFindsTheTopLeftHole() {
        let frames = ["a": GridFrame(x: 0, y: 0, w: 4, h: 4), "b": GridFrame(x: 8, y: 0, w: 4, h: 4)]
        #expect(engine.firstFit(w: 4, h: 4, in: frames) == GridFrame(x: 4, y: 0, w: 4, h: 4))
        #expect(engine.firstFit(w: 6, h: 3, in: frames) == GridFrame(x: 0, y: 4, w: 6, h: 3))
    }

    @Test func freePlacementKeepsGapsAndMovesCollisionsToTheNearestFreeRows() {
        let free = GridEngine(columns: 12, minSize: (2, 3), compacts: false)
        let frames = ["a": GridFrame(x: 0, y: 0, w: 4, h: 4), "b": GridFrame(x: 0, y: 4, w: 4, h: 4)]
        // Dropping "a" far down and to the right leaves the gap above it.
        let moved = free.layout(frames, moving: "a", to: GridFrame(x: 6, y: 10, w: 4, h: 4))
        #expect(moved["a"] == GridFrame(x: 6, y: 10, w: 4, h: 4))
        #expect(moved["b"] == GridFrame(x: 0, y: 4, w: 4, h: 4))
        // Dropping onto "b": it moves up into the space "a" left, the nearer free spot.
        let collided = free.layout(frames, moving: "a", to: GridFrame(x: 0, y: 5, w: 4, h: 4))
        #expect(collided["a"] == GridFrame(x: 0, y: 5, w: 4, h: 4))
        #expect(collided["b"] == GridFrame(x: 0, y: 1, w: 4, h: 4))
        // No room above: it goes down.
        let pushed = free.layout(frames, moving: "a", to: GridFrame(x: 0, y: 3, w: 4, h: 4))
        #expect(pushed["b"] == GridFrame(x: 0, y: 7, w: 4, h: 4))
    }

    @Test func limitsClampResizes() {
        let limits = GridLimits(minW: 3, minH: 4, maxW: 6, maxH: 8)
        #expect(engine.clamp(GridFrame(x: 0, y: 0, w: 1, h: 1), limits: limits) == GridFrame(x: 0, y: 0, w: 3, h: 4))
        #expect(engine.clamp(GridFrame(x: 10, y: 0, w: 12, h: 20), limits: limits) == GridFrame(x: 6, y: 0, w: 6, h: 8))
        let laid = engine.layout(["a": GridFrame(x: 0, y: 0, w: 4, h: 4)], moving: "a", to: GridFrame(x: 0, y: 0, w: 11, h: 2),
                                 limits: ["a": limits])
        #expect(laid["a"] == GridFrame(x: 0, y: 0, w: 6, h: 4))
    }

    @Test func reflowKeepsOrderAndHeights() {
        let engine = GridEngine()
        // Side by side on the full grid: pods (6 wide) left of analytics (6 wide), notes below.
        let frames = ["pods": GridFrame(x: 0, y: 0, w: 6, h: 8), "analytics": GridFrame(x: 6, y: 0, w: 6, h: 8),
                      "notes": GridFrame(x: 0, y: 8, w: 4, h: 5)]
        // Narrow: 6 columns, each widget wants all 6 → stacked in reading order.
        let stacked = engine.reflow(frames, columns: 6) { _, _ in 6 }
        #expect(stacked["pods"] == GridFrame(x: 0, y: 0, w: 6, h: 8))
        #expect(stacked["analytics"] == GridFrame(x: 0, y: 8, w: 6, h: 8))
        #expect(stacked["notes"] == GridFrame(x: 0, y: 16, w: 6, h: 5))
        // Wider than asked is clamped; smaller ones share a row but never move above an earlier one.
        let packed = engine.reflow(frames, columns: 8) { $1.w == 4 ? 4 : 99 }
        #expect(packed["pods"]?.w == 8 && packed["analytics"]?.y == 8 && packed["notes"]?.y == 16)
        let sideBySide = engine.reflow(["a": GridFrame(x: 0, y: 0, w: 3, h: 2), "b": GridFrame(x: 3, y: 0, w: 3, h: 4)], columns: 6) { $1.w }
        // Dropping one column at a time: widths are kept, clamped to the limits and columns left.
        let saved = ["pods": GridFrame(x: 0, y: 0, w: 5, h: 6), "chart": GridFrame(x: 5, y: 0, w: 7, h: 6)]
        let eleven = engine.reflow(saved, columns: 11, limits: ["pods": GridLimits(minW: 3, maxW: 12), "chart": GridLimits(minW: 6, maxW: 12)])
        #expect(eleven["pods"] == GridFrame(x: 0, y: 0, w: 5, h: 6) && eleven["chart"] == GridFrame(x: 0, y: 6, w: 7, h: 6))
        let four = engine.reflow(saved, columns: 4, limits: ["pods": GridLimits(minW: 3, maxW: 12), "chart": GridLimits(minW: 6, maxW: 12)])
        #expect(four["pods"]?.w == 4 && four["chart"]?.w == 4)
        #expect(sideBySide["a"] == GridFrame(x: 0, y: 0, w: 3, h: 2) && sideBySide["b"] == GridFrame(x: 3, y: 0, w: 3, h: 4))
    }
}

struct WidgetLayoutTests {
    @Test func familiesBySize() {
        #expect(WidgetLayout.family(for: CGSize(width: 260, height: 600)) == .narrow)
        #expect(WidgetLayout.family(for: CGSize(width: 480, height: 300)) == .medium)
        #expect(WidgetLayout.family(for: CGSize(width: 900, height: 240)) == .wide)
        #expect(WidgetLayout.family(for: CGSize(width: 900, height: 500)) == .large)
    }
}

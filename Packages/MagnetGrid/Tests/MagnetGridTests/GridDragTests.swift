import CoreGraphics
import MagnetGrid
import Testing

/// 12 columns of 60 points with 20 between them, rows of 40: one cell step is 80 by 60.
private let geometry = GridGeometry(width: 12 * 60 + 11 * 20, columns: 12, rowHeight: 40, spacing: 20)
private let engine = GridLayoutEngine()

struct GridGeometryTests {
    @Test func cellsToPoints() {
        #expect(geometry.cellWidth == 60)
        #expect(geometry.rect(GridRect(x: 2, y: 1, w: 3, h: 2)) == CGRect(x: 160, y: 60, width: 220, height: 100))
        #expect(geometry.height(rows: 3) == 180)
    }

    @Test func translationsSnapToTheNearestCell() {
        func cells(_ width: CGFloat, _ height: CGFloat) -> [Int] {
            let delta = geometry.cells(CGSize(width: width, height: height))
            return [delta.dx, delta.dy]
        }
        #expect(cells(39, 29) == [0, 0])
        #expect(cells(41, 31) == [1, 1])
        #expect(cells(-121, 150) == [-2, 3])
    }

    @Test func narrowWidthsDropColumns() {
        #expect(GridGeometry.columns(fitting: 2000, upTo: 12, minimumColumnWidth: 40, spacing: 16) == 12)
        #expect(GridGeometry.columns(fitting: 280, upTo: 12, minimumColumnWidth: 40, spacing: 16) == 5)
        #expect(GridGeometry.columns(fitting: 10, upTo: 12, minimumColumnWidth: 40, spacing: 16) == 1)
    }
}

struct GridDragTests {
    @Test func moveSnapsAndStaysInsideTheGrid() {
        let drag = GridDrag(id: "a", kind: .move, start: GridRect(x: 2, y: 2, w: 4, h: 3), translation: CGSize(width: 170, height: -50))
        #expect(drag.target(engine, geometry) == GridRect(x: 4, y: 1, w: 4, h: 3))
        let far = GridDrag(id: "a", kind: .move, start: GridRect(x: 2, y: 2, w: 4, h: 3), translation: CGSize(width: 2000, height: -900))
        #expect(far.target(engine, geometry) == GridRect(x: 8, y: 0, w: 4, h: 3))
        #expect(!far.isAtLimit(engine, geometry))
    }

    @Test func movedCellFollowsThePointerExactly() {
        let drag = GridDrag(id: "a", kind: .move, start: GridRect(x: 1, y: 0, w: 2, h: 3), translation: CGSize(width: 13, height: 7))
        #expect(drag.liveRect(engine, geometry) == geometry.rect(drag.start).offsetBy(dx: 13, dy: 7))
    }

    @Test func resizeStopsAtTheLimitsAndSaysSo() {
        let limits = GridSizeLimits(minW: 3, minH: 4, maxW: 6, maxH: 8)
        let start = GridRect(x: 0, y: 0, w: 4, h: 5)
        let within = GridDrag(id: "a", kind: .resize, start: start, translation: CGSize(width: 80, height: 60))
        #expect(within.target(engine, geometry, limits: limits) == GridRect(x: 0, y: 0, w: 5, h: 6))
        #expect(!within.isAtLimit(engine, geometry, limits: limits))
        let tooBig = GridDrag(id: "a", kind: .resize, start: start, translation: CGSize(width: 800, height: 0))
        #expect(tooBig.target(engine, geometry, limits: limits).w == 6)
        #expect(tooBig.isAtLimit(engine, geometry, limits: limits))
        let tooSmall = GridDrag(id: "a", kind: .resize, start: start, translation: CGSize(width: 0, height: -300))
        #expect(tooSmall.target(engine, geometry, limits: limits).h == 4)
        #expect(tooSmall.isAtLimit(engine, geometry, limits: limits))
    }

    @Test func resizedCellRubberBandsPastItsLimits() {
        let limits = GridSizeLimits(minW: 3, minH: 4, maxW: 6, maxH: 8)
        let start = GridRect(x: 0, y: 0, w: 4, h: 5)
        let largest = geometry.rect(GridRect(x: 0, y: 0, w: 6, h: 8))
        let smallest = geometry.rect(GridRect(x: 0, y: 0, w: 3, h: 4))
        let startRect = geometry.rect(start)
        // Inside the limits it follows the pointer.
        let inside = GridDrag(id: "a", kind: .resize, start: start, translation: CGSize(width: 30, height: -10))
        #expect(inside.liveRect(engine, geometry, limits: limits).size == CGSize(width: startRect.width + 30, height: startRect.height - 10))
        // Past them, it gives 15% of the overshoot.
        let past = GridDrag(id: "a", kind: .resize, start: start, translation: CGSize(width: largest.width - startRect.width + 100, height: -1000))
        let rect = past.liveRect(engine, geometry, limits: limits)
        #expect(abs(rect.width - (largest.width + 15)) < 0.001)
        #expect(abs(rect.height - (smallest.height - (smallest.height - (startRect.height - 1000)) * 0.15)) < 0.001)
        #expect(rect.origin == startRect.origin)
    }
}

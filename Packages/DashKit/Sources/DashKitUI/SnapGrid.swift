import SwiftUI

/// Callbacks a cell's drag handle and resize handle report to their grid.
struct SnapGridCellActions {
    var move: (_ translation: CGSize, _ ended: Bool) -> Void
    var resize: (_ translation: CGSize, _ ended: Bool) -> Void
}

private struct SnapGridCellKey: EnvironmentKey {
    static var defaultValue: SnapGridCellActions? { nil }
}

private struct SnapGridEditingKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    var snapGridCell: SnapGridCellActions? {
        get { self[SnapGridCellKey.self] }
        set { self[SnapGridCellKey.self] = newValue }
    }

    /// The enclosing snap grid is in edit mode: cells can be moved and resized. Cells use it to
    /// show edit affordances and to stop their content from taking clicks.
    public var isGridEditing: Bool {
        get { self[SnapGridEditingKey.self] }
        set { self[SnapGridEditingKey.self] = newValue }
    }
}

extension View {
    /// Makes this view (typically a card header) the handle that drags its cell around the grid.
    /// Content outside the handle keeps its own gestures (scrolling, text editing).
    public func gridDragHandle() -> some View {
        modifier(GridDragHandle())
    }
}

private struct GridDragHandle: ViewModifier {
    @Environment(\.snapGridCell) private var actions

    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .onHover { inside in
                // Only in edit mode (the grid hands out actions then); always balance push/pop.
                if inside, actions != nil, !cursorPushed { NSCursor.openHand.push(); cursorPushed = true }
                if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
            }
            .onChange(of: actions == nil) { _, locked in
                if locked, cursorPushed { NSCursor.pop(); cursorPushed = false }
            }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(SnapGridSpace.name))
                    .onChanged { actions?.move($0.translation, false) }
                    .onEnded { actions?.move($0.translation, true) },
                isEnabled: actions != nil)
    }
}

enum SnapGridSpace {
    static let name = "DashKitUI.SnapGrid"
}

/// A dashboard grid with snapping drag-to-move and drag-to-resize.
///
/// Moving and resizing only work while `editing` is on; otherwise the layout is locked and
/// cells behave like plain content.
///
/// While dragging, the cell follows the pointer, a dashed outline shows where it will
/// land, and the other cells animate out of the way. On drop, `onCommit` receives the
/// whole new layout to persist.
public struct SnapGrid<ID: Hashable & Sendable, Cell: View>: View {
    let frames: [ID: GridFrame]
    let engine: GridEngine
    let rowHeight: CGFloat
    let spacing: CGFloat
    let editing: Bool
    /// Scrolls with the grid, above it (e.g. a page's welcome).
    let header: AnyView?
    /// Per-cell resize limits (missing: the engine's minimum, up to the full width).
    let limits: [ID: GridLimits]
    let onCommit: ([ID: GridFrame]) -> Void
    let cell: (ID) -> Cell
    /// Narrowest a column may get. A full window shows all the engine's columns; as it narrows
    /// the grid drops one column at a time instead of squeezing them, and widgets keep their
    /// width in columns (within their limits and the columns left). Editing waits for the full grid.
    let minimumColumnWidth: CGFloat

    private enum Kind { case move, resize }
    private struct Drag {
        let id: ID
        let kind: Kind
        let start: GridFrame
        var translation: CGSize
    }

    @State private var drag: Drag?

    public init(
        frames: [ID: GridFrame], engine: GridEngine = GridEngine(), rowHeight: CGFloat = 40, spacing: CGFloat = 16,
        editing: Bool = true, limits: [ID: GridLimits] = [:], header: AnyView? = nil,
        minimumColumnWidth: CGFloat = 60,
        onCommit: @escaping ([ID: GridFrame]) -> Void, @ViewBuilder cell: @escaping (ID) -> Cell
    ) {
        self.minimumColumnWidth = minimumColumnWidth
        self.frames = frames
        self.editing = editing
        self.header = header
        self.limits = limits
        self.engine = engine
        self.rowHeight = rowHeight
        self.spacing = spacing
        self.onCommit = onCommit
        self.cell = cell
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - spacing * 2, 0)
            // As many columns as fit at the minimum width, up to the engine's (all of them full screen).
            let columns = min(engine.columns, max(1, Int((width + spacing) / (minimumColumnWidth + spacing))))
            let reflowed = columns < engine.columns
            let metrics = Metrics(width: width, columns: columns, rowHeight: rowHeight, spacing: spacing)
            let editing = self.editing && !reflowed
            let layout = reflowed ? engine.reflow(frames, columns: columns, limits: limits) : previewLayout(metrics)
            // While editing, spare rows below the last widget give room to drop things lower.
            let rows = engine.height(layout) + (editing ? 8 : 0) + (drag == nil ? 0 : 4)
            let height = max(metrics.height(rows: rows), editing ? proxy.size.height - spacing * 2 : 0)
            ScrollView {
                if let header { header.padding(.horizontal, spacing).padding(.top, spacing) }
                if reflowed && self.editing {
                    Label("The window is too narrow to arrange widgets, so they're stacked. Make it wider to edit the layout.",
                          systemImage: "arrow.left.and.right")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, spacing).padding(.top, spacing)
                }
                ZStack(alignment: .topLeading) {
                    Color.clear
                    if editing {
                        GridBackdrop(metrics: metrics, columns: engine.columns,
                                     rows: Int((height / (metrics.rowHeight + metrics.spacing)).rounded(.up)))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    if let drag, let target = layout[drag.id] {
                        let rect = metrics.rect(target)
                        let atLimit = drag.kind == .resize && self.atLimit(drag, metrics: metrics)
                        let tint = atLimit ? Color.orange : Color.accentColor
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .background(tint.opacity(0.08), in: .rect(cornerRadius: 14))
                            .frame(width: rect.width, height: rect.height)
                            .overlay(alignment: .bottomTrailing) {
                                if drag.kind == .resize {
                                    // The snapped size, and the widget's limit when it stops growing or shrinking.
                                    Text(atLimit ? "\(target.w)×\(target.h) · limit" : "\(target.w)×\(target.h)")
                                        .font(.caption.monospacedDigit().bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(tint, in: .capsule)
                                        .padding(30)
                                }
                            }
                            .offset(x: rect.minX, y: rect.minY)
                    }
                    ForEach(Array(frames.keys), id: \.self) { id in
                        let rect = reflowed ? metrics.rect(layout[id] ?? frames[id]!) : liveRect(id, layout: layout, metrics: metrics)
                        let dragging = drag?.id == id
                        cell(id)
                            .frame(width: rect.width, height: rect.height)
                            .overlay {
                                if editing {
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(Color.accentColor.opacity(dragging ? 0.9 : 0.45),
                                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                        .allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .bottomTrailing) { if editing { ResizeHandle() } }
                            .shadow(color: .black.opacity(dragging ? 0.25 : 0), radius: dragging ? 16 : 0, y: dragging ? 8 : 0)
                            .scaleEffect(dragging && drag?.kind == .move ? 1.02 : 1)
                            .offset(x: rect.minX, y: rect.minY)
                            .zIndex(dragging ? 1 : 0)
                            .environment(\.snapGridCell, editing ? actions(for: id, metrics: metrics) : nil)
                            .environment(\.isGridEditing, editing)
                    }
                }
                // A fixed frame: the cells never change the grid's size, so the window's layout can't loop.
                .frame(width: width, height: height, alignment: .topLeading)
                .animation(.spring(duration: 0.28), value: layout)
                .coordinateSpace(.named(SnapGridSpace.name))
                .padding(spacing)
            }
        }
        .frame(minWidth: 0, minHeight: 0)
    }

    // MARK: Geometry

    struct Metrics {
        let cellWidth: CGFloat
        let rowHeight: CGFloat
        let spacing: CGFloat

        init(width: CGFloat, columns: Int, rowHeight: CGFloat, spacing: CGFloat) {
            cellWidth = max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 1)
            self.rowHeight = rowHeight
            self.spacing = spacing
        }

        func rect(_ frame: GridFrame) -> CGRect {
            CGRect(x: CGFloat(frame.x) * (cellWidth + spacing), y: CGFloat(frame.y) * (rowHeight + spacing),
                   width: CGFloat(frame.w) * cellWidth + CGFloat(frame.w - 1) * spacing,
                   height: CGFloat(frame.h) * rowHeight + CGFloat(frame.h - 1) * spacing)
        }

        func height(rows: Int) -> CGFloat { CGFloat(rows) * (rowHeight + spacing) }

        /// Cells moved by a pointer translation, rounded to the nearest cell (the magnet).
        func cells(_ translation: CGSize) -> (dx: Int, dy: Int) {
            (Int((translation.width / (cellWidth + spacing)).rounded()), Int((translation.height / (rowHeight + spacing)).rounded()))
        }
    }

    /// The snapped frame the dragged cell would land on.
    private func target(_ drag: Drag, metrics: Metrics) -> GridFrame {
        let delta = metrics.cells(drag.translation)
        var frame = drag.start
        switch drag.kind {
        case .move:
            frame.x += delta.dx
            frame.y += delta.dy
        case .resize:
            frame.w += delta.dx
            frame.h += delta.dy
        }
        return engine.clamp(frame, limits: limits[drag.id])
    }

    /// The resize hit the widget's minimum or maximum (the pointer asks for more than allowed).
    private func atLimit(_ drag: Drag, metrics: Metrics) -> Bool {
        let delta = metrics.cells(drag.translation)
        let wanted = GridFrame(x: drag.start.x, y: drag.start.y, w: drag.start.w + delta.dx, h: drag.start.h + delta.dy)
        let got = target(drag, metrics: metrics)
        return got.w != wanted.w || got.h != wanted.h
    }

    private func previewLayout(_ metrics: Metrics) -> [ID: GridFrame] {
        guard let drag else { return frames }
        return engine.layout(frames, moving: drag.id, to: target(drag, metrics: metrics), limits: limits)
    }

    /// The dragged cell follows the pointer; the rest sit at their preview frames.
    private func liveRect(_ id: ID, layout: [ID: GridFrame], metrics: Metrics) -> CGRect {
        guard let drag, drag.id == id else { return metrics.rect(layout[id] ?? frames[id]!) }
        let start = metrics.rect(drag.start)
        switch drag.kind {
        case .move:
            return start.offsetBy(dx: drag.translation.width, dy: drag.translation.height)
        case .resize:
            // Follows the pointer, but only within the widget's limits (with a little rubber band).
            let bounds = engine.clamp(GridFrame(x: 0, y: 0, w: 1, h: 1), limits: limits[id])
            let largest = engine.clamp(GridFrame(x: 0, y: 0, w: 1000, h: 1000), limits: limits[id])
            let minimum = metrics.rect(GridFrame(x: 0, y: 0, w: bounds.w, h: bounds.h))
            let maximum = metrics.rect(GridFrame(x: 0, y: 0, w: largest.w, h: largest.h))
            func band(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
                value < low ? low - (low - value) * 0.15 : value > high ? high + (value - high) * 0.15 : value
            }
            return CGRect(x: start.minX, y: start.minY,
                          width: band(start.width + drag.translation.width, minimum.width, maximum.width),
                          height: band(start.height + drag.translation.height, minimum.height, maximum.height))
        }
    }

    private func actions(for id: ID, metrics: Metrics) -> SnapGridCellActions {
        func update(_ kind: Kind, _ translation: CGSize, _ ended: Bool) {
            guard let start = frames[id] else { return }
            if drag?.id != id || drag?.kind != kind { drag = Drag(id: id, kind: kind, start: start, translation: .zero) }
            drag?.translation = translation
            if ended, let current = drag {
                let result = engine.layout(frames, moving: id, to: target(current, metrics: metrics), limits: limits)
                drag = nil
                if result != frames { onCommit(result) }
            }
        }
        return SnapGridCellActions(move: { update(.move, $0, $1) }, resize: { update(.resize, $0, $1) })
    }
}

/// The magnetic grid shown in edit mode: one faint slot per cell.
private struct GridBackdrop<ID: Hashable & Sendable, Cell: View>: View {
    let metrics: SnapGrid<ID, Cell>.Metrics
    let columns: Int
    let rows: Int

    var body: some View {
        Canvas { context, _ in
            for row in 0..<max(rows, 0) {
                for column in 0..<columns {
                    let rect = metrics.rect(GridFrame(x: column, y: row, w: 1, h: 1))
                    context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(.primary.opacity(0.045)))
                }
            }
        }
    }
}

/// The corner grip that resizes a cell.
private struct ResizeHandle: View {
    @Environment(\.snapGridCell) private var actions
    @State private var hovering = false

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(hovering ? Color.white : Color.accentColor)
            .frame(width: 24, height: 24)
            .background(Color.accentColor.opacity(hovering ? 1 : 0.18), in: .circle)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(SnapGridSpace.name))
                    .onChanged { actions?.resize($0.translation, false) }
                    .onEnded { actions?.resize($0.translation, true) })
            .accessibilityLabel("Resize")
            .padding(2)
    }
}

#Preview("Snap grid") {
    @Previewable @State var frames: [String: GridFrame] = [
        "Jira": GridFrame(x: 0, y: 0, w: 8, h: 6), "PRs": GridFrame(x: 8, y: 0, w: 4, h: 6),
        "Agents": GridFrame(x: 0, y: 6, w: 4, h: 4), "Meeting": GridFrame(x: 4, y: 6, w: 4, h: 4),
    ]
    SnapGrid(frames: frames, onCommit: { frames = $0 }) { id in
        VStack(alignment: .leading) {
            Text(id).font(.headline).frame(maxWidth: .infinity, alignment: .leading).gridDragHandle()
            Spacer()
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
    .frame(width: 900, height: 600)
}

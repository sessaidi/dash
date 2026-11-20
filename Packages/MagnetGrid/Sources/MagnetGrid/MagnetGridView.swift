import SwiftUI

/// Callbacks a cell's drag handle and resize handle report to their grid.
struct MagnetGridCellActions {
    var move: (_ translation: CGSize, _ ended: Bool) -> Void
    var resize: (_ translation: CGSize, _ ended: Bool) -> Void
}

private struct MagnetGridCellKey: EnvironmentKey {
    static var defaultValue: MagnetGridCellActions? { nil }
}

private struct MagnetGridEditingKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    var magnetGridCell: MagnetGridCellActions? {
        get { self[MagnetGridCellKey.self] }
        set { self[MagnetGridCellKey.self] = newValue }
    }

    /// The enclosing grid is in edit mode: cells can be moved and resized. Cells use it to show
    /// edit affordances and to stop their content from taking clicks.
    public var isMagnetGridEditing: Bool {
        get { self[MagnetGridEditingKey.self] }
        set { self[MagnetGridEditingKey.self] = newValue }
    }
}

extension View {
    /// Makes this view (typically a card header) the handle that drags its cell around the grid.
    /// Content outside the handle keeps its own gestures (scrolling, text editing).
    public func magnetGridDragHandle() -> some View {
        modifier(MagnetGridDragHandle())
    }
}

private struct MagnetGridDragHandle: ViewModifier {
    @Environment(\.magnetGridCell) private var actions

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
                DragGesture(minimumDistance: 3, coordinateSpace: .named(MagnetGridSpace.name))
                    .onChanged { actions?.move($0.translation, false) }
                    .onEnded { actions?.move($0.translation, true) },
                isEnabled: actions != nil)
    }
}

enum MagnetGridSpace {
    static let name = "MagnetGrid"
}

/// A dashboard grid with magnetic drag-to-move and drag-to-resize.
///
/// Moving and resizing only work while `editing` is on; otherwise the layout is locked and
/// cells behave like plain content.
///
/// While dragging, the cell follows the pointer, a dashed outline shows the slot it snaps to,
/// and the other cells animate out of the way. On drop, `onCommit` receives the whole new
/// layout to persist.
public struct MagnetGridView<ID: Hashable & Sendable, Cell: View>: View {
    let frames: [ID: GridRect]
    let engine: GridLayoutEngine
    let rowHeight: CGFloat
    let spacing: CGFloat
    let editing: Bool
    /// Scrolls with the grid, above it (e.g. a page's welcome).
    let header: AnyView?
    /// Per-cell resize limits (missing: the engine's minimum, up to the full width).
    let limits: [ID: GridSizeLimits]
    let onCommit: ([ID: GridRect]) -> Void
    let cell: (ID) -> Cell
    /// Narrowest a column may get. A full window shows all the engine's columns; as it narrows
    /// the grid drops one column at a time instead of squeezing them, and cells keep their
    /// width in columns (within their limits and the columns left). Editing waits for the full grid.
    let minimumColumnWidth: CGFloat

    @State private var drag: GridDrag<ID>?

    public init(
        frames: [ID: GridRect], engine: GridLayoutEngine = GridLayoutEngine(), rowHeight: CGFloat = 40, spacing: CGFloat = 16,
        editing: Bool = true, limits: [ID: GridSizeLimits] = [:], header: AnyView? = nil,
        minimumColumnWidth: CGFloat = 40,
        onCommit: @escaping ([ID: GridRect]) -> Void, @ViewBuilder cell: @escaping (ID) -> Cell
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
            let columns = GridGeometry.columns(fitting: width, upTo: engine.columns, minimumColumnWidth: minimumColumnWidth, spacing: spacing)
            let reflowed = columns < engine.columns
            let geometry = GridGeometry(width: width, columns: columns, rowHeight: rowHeight, spacing: spacing)
            let editing = self.editing && !reflowed
            let layout = reflowed ? engine.reflow(frames, columns: columns, limits: limits) : previewLayout(geometry)
            // While editing, spare rows below the last cell give room to drop things lower.
            let rows = engine.height(layout) + (editing ? 8 : 0) + (drag == nil ? 0 : 4)
            let height = max(geometry.height(rows: rows), editing ? proxy.size.height - spacing * 2 : 0)
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
                        GridBackdrop(geometry: geometry, columns: engine.columns,
                                     rows: Int((height / (geometry.rowHeight + geometry.spacing)).rounded(.up)))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    if let drag, let target = layout[drag.id] {
                        let rect = geometry.rect(target)
                        let atLimit = drag.isAtLimit(engine, geometry, limits: limits[drag.id])
                        let tint = atLimit ? Color.orange : Color.accentColor
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .background(tint.opacity(0.08), in: .rect(cornerRadius: 14))
                            .frame(width: rect.width, height: rect.height)
                            .overlay(alignment: .bottomTrailing) {
                                if drag.kind == .resize {
                                    // The snapped size, and the cell's limit when it stops growing or shrinking.
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
                        let rect = reflowed ? geometry.rect(layout[id] ?? frames[id]!) : liveRect(id, layout: layout, geometry: geometry)
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
                            .environment(\.magnetGridCell, editing ? actions(for: id, geometry: geometry) : nil)
                            .environment(\.isMagnetGridEditing, editing)
                    }
                }
                // A fixed frame: the cells never change the grid's size, so the window's layout can't loop.
                .frame(width: width, height: height, alignment: .topLeading)
                .animation(.spring(duration: 0.28), value: layout)
                .coordinateSpace(.named(MagnetGridSpace.name))
                .padding(spacing)
            }
        }
        .frame(minWidth: 0, minHeight: 0)
    }

    private func previewLayout(_ geometry: GridGeometry) -> [ID: GridRect] {
        guard let drag else { return frames }
        return engine.layout(frames, moving: drag.id, to: drag.target(engine, geometry, limits: limits[drag.id]), limits: limits)
    }

    /// The dragged cell follows the pointer; the rest sit at their preview frames.
    private func liveRect(_ id: ID, layout: [ID: GridRect], geometry: GridGeometry) -> CGRect {
        guard let drag, drag.id == id else { return geometry.rect(layout[id] ?? frames[id]!) }
        return drag.liveRect(engine, geometry, limits: limits[id])
    }

    private func actions(for id: ID, geometry: GridGeometry) -> MagnetGridCellActions {
        func update(_ kind: GridDrag<ID>.Kind, _ translation: CGSize, _ ended: Bool) {
            guard let start = frames[id] else { return }
            if drag?.id != id || drag?.kind != kind { drag = GridDrag(id: id, kind: kind, start: start) }
            drag?.translation = translation
            if ended, let current = drag {
                let result = engine.layout(frames, moving: id, to: current.target(engine, geometry, limits: limits[id]), limits: limits)
                drag = nil
                if result != frames { onCommit(result) }
            }
        }
        return MagnetGridCellActions(move: { update(.move, $0, $1) }, resize: { update(.resize, $0, $1) })
    }
}

/// The magnetic grid shown in edit mode: one faint slot per cell.
private struct GridBackdrop: View {
    let geometry: GridGeometry
    let columns: Int
    let rows: Int

    var body: some View {
        Canvas { context, _ in
            for row in 0..<max(rows, 0) {
                for column in 0..<columns {
                    let rect = geometry.rect(GridRect(x: column, y: row, w: 1, h: 1))
                    context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(.primary.opacity(0.045)))
                }
            }
        }
    }
}

/// The corner grip that resizes a cell.
private struct ResizeHandle: View {
    @Environment(\.magnetGridCell) private var actions
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
                DragGesture(minimumDistance: 2, coordinateSpace: .named(MagnetGridSpace.name))
                    .onChanged { actions?.resize($0.translation, false) }
                    .onEnded { actions?.resize($0.translation, true) })
            .accessibilityLabel("Resize")
            .padding(2)
    }
}

#Preview("Magnet grid") {
    @Previewable @State var frames: [String: GridRect] = [
        "Board": GridRect(x: 0, y: 0, w: 8, h: 6), "Pull requests": GridRect(x: 8, y: 0, w: 4, h: 6),
        "Agents": GridRect(x: 0, y: 6, w: 4, h: 4), "Meeting": GridRect(x: 4, y: 6, w: 4, h: 4),
    ]
    MagnetGridView(frames: frames, onCommit: { frames = $0 }) { id in
        VStack(alignment: .leading) {
            Text(id).font(.headline).frame(maxWidth: .infinity, alignment: .leading).magnetGridDragHandle()
            Spacer()
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
    .frame(width: 900, height: 600)
}

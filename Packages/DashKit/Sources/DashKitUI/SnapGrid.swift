import SwiftUI
internal import MagnetGrid

extension EnvironmentValues {
    /// The enclosing snap grid is in edit mode: cells can be moved and resized. Cells use it to
    /// show edit affordances and to stop their content from taking clicks.
    public var isGridEditing: Bool {
        get { isMagnetGridEditing }
        set { isMagnetGridEditing = newValue }
    }
}

extension View {
    /// Makes this view (typically a card header) the handle that drags its cell around the grid.
    /// Content outside the handle keeps its own gestures (scrolling, text editing).
    public func gridDragHandle() -> some View {
        magnetGridDragHandle()
    }
}

/// A dashboard grid with snapping drag-to-move and drag-to-resize: MagnetGrid's
/// `MagnetGridView` with DashKit's frame and limit types.
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

    public init(
        frames: [ID: GridFrame], engine: GridEngine = GridEngine(), rowHeight: CGFloat = 40, spacing: CGFloat = 16,
        editing: Bool = true, limits: [ID: GridLimits] = [:], header: AnyView? = nil,
        minimumColumnWidth: CGFloat = 40,
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
        let onCommit = onCommit
        MagnetGridView(
            frames: frames.mapValues(\.rect), engine: engine.core, rowHeight: rowHeight, spacing: spacing,
            editing: editing, limits: limits.mapValues(\.sizeLimits), header: header, minimumColumnWidth: minimumColumnWidth,
            onCommit: { onCommit($0.mapValues(GridFrame.init)) }, cell: cell)
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

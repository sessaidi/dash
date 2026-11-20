# MagnetGrid

A magnetic dashboard grid for SwiftUI on macOS 15. Cells sit on a grid of columns and rows; while
you drag or resize one it follows the pointer, a dashed outline shows the slot it snaps to, and
the other cells move out of the way. On drop you get the whole new layout to save.

It has no dependencies. Dash's widget grid (DashKit's `SnapGrid`) is built on it.

## Use

```swift
import MagnetGrid
import SwiftUI

struct Board: View {
    @State private var frames: [String: GridRect] = [
        "billing-api": GridRect(x: 0, y: 0, w: 8, h: 6),
        "KAN-123": GridRect(x: 8, y: 0, w: 4, h: 6),
    ]
    @State private var editing = true

    var body: some View {
        MagnetGridView(frames: frames, editing: editing, limits: ["KAN-123": GridSizeLimits(minW: 3, maxW: 6)],
                       onCommit: { frames = $0 }) { id in
            VStack(alignment: .leading) {
                Text(id).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    .magnetGridDragHandle()   // drag the cell by its header
                Spacer()
            }
            .padding(12)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
        }
    }
}
```

Cells read `@Environment(\.isMagnetGridEditing)` to show edit affordances. Each cell gets a resize
grip in its bottom-right corner while editing.

## Types

| Type | What |
|---|---|
| `GridRect` | A cell's place in grid units: column, row, width, height |
| `GridSizeLimits` | How small and large a cell may be resized |
| `GridLayoutEngine` | The layout rules: clamp, drop with push-down, compact upward (or free placement with `compacts: false`), first free spot, reflow into fewer columns |
| `GridGeometry` | Grid units to points, and the magnet: a pointer translation rounded to whole cells |
| `GridDrag` | A move or resize in progress: its snapped target, whether it hit the cell's limits, and where the cell is drawn (with a rubber band past its limits) |
| `MagnetGridView` | The SwiftUI view tying them together |

A window narrower than `minimumColumnWidth` per column drops columns instead of squeezing them:
cells keep their reading order and width (within their limits), and editing waits until the
grid is full width again.

## Test

```sh
swift test
```

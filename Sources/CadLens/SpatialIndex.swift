import Foundation

/// Uniform grid over one drawing space. Entities are bucketed by bounding box
/// so a 100k entity drawing only touches what a tile can actually show.
///
/// Mirrors SpatialIndex.cpp: an entity that spans too many cells is kept in an
/// `oversized` list and tested on every query instead of being dropped. The old
/// Swift version `continue`d in that case, which silently erased every large
/// wall outline, sheet frame and full-room hatch — the "missing fills" defect.
final class SpatialIndex {
    let space: Int32
    let range: Range<Int>

    private let originX: Double
    private let originY: Double
    private let cellSize: Double
    private let columns: Int
    private let rows: Int
    private var cells: [[Int32]]
    /// Absolute entity indices whose box covers too many cells to bucket.
    private var oversized: [Int32] = []
    /// Bounding box per entity in `range`, used for the exact overlap test.
    private var boxes: [CGRect] = []
    private var stamp: [Int32]
    private var generation: Int32 = 0
    private let lock = NSLock()

    /// Reference SpatialIndex.cpp rejects a bucket span above this many cells.
    private static let maximumCellSpan = 1024

    init(document: CadDocument, space: Int32) {
        self.space = space
        self.range = document.entityIndices(in: space)

        // The grid has to cover every entity it indexes. spaceInfo().box comes
        // from the file and can omit entities a block insert placed outside the
        // declared extents; the reference derives its grid from the real
        // drawing bounds instead, so do the same here.
        var bounds = CGRect.null
        for index in range {
            let box = document.entities[index].box
            // `isEmpty` is true for a segment (zero height) or a vertical line
            // (zero width). Filtering on it threw those out of the grid *and*
            // out of the oversized list, so queries could never return them —
            // walls, dimension lines and extension lines disappeared wholesale.
            guard box.width.isFinite, box.height.isFinite,
                  box.minX.isFinite, box.minY.isFinite else { continue }
            bounds = bounds.isNull ? box : bounds.union(box)
        }
        if bounds.isNull || !bounds.width.isFinite || !bounds.height.isFinite {
            bounds = document.spaceInfo(space)?.box ?? .zero
        }
        if !bounds.minX.isFinite || !bounds.minY.isFinite
            || !bounds.width.isFinite || !bounds.height.isFinite {
            bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        }
        let padding = max(bounds.width, bounds.height) * 0.02 + 1
        bounds = bounds.insetBy(dx: -padding, dy: -padding)

        let count = max(1, range.count)
        let grid = max(8, min(256, Int(Double(count).squareRoot().rounded(.up))))
        let cell = max(max(bounds.width, bounds.height) / Double(grid), 1e-9)
        self.originX = bounds.minX
        self.originY = bounds.minY
        self.cellSize = cell
        self.columns = grid
        self.rows = grid
        self.cells = Array(repeating: [], count: columns * rows)
        self.stamp = Array(repeating: -1, count: document.entities.count)
        self.boxes.reserveCapacity(range.count)

        for index in range {
            let box = document.entities[index].box
            boxes.append(box)
            guard box.width.isFinite, box.height.isFinite,
                  box.minX.isFinite, box.minY.isFinite else { continue }
            let minCol = column(box.minX)
            let maxCol = column(box.maxX)
            let minRow = row(box.minY)
            let maxRow = row(box.maxY)
            let span = (maxCol - minCol + 1) * (maxRow - minRow + 1)
            if span > Self.maximumCellSpan {
                // Never drop it: a full-sheet hatch or a long centre line is
                // exactly the geometry a viewer is judged on.
                oversized.append(Int32(index))
                continue
            }
            for r in minRow...maxRow {
                for c in minCol...maxCol {
                    cells[r * columns + c].append(Int32(index))
                }
            }
        }
    }

    private func column(_ x: Double) -> Int {
        min(max(Int((x - originX) / cellSize), 0), columns - 1)
    }

    private func row(_ y: Double) -> Int {
        min(max(Int((y - originY) / cellSize), 0), rows - 1)
    }

    /// Returns candidate entity indices overlapping `rect` (no duplicates).
    func query(_ rect: CGRect) -> [Int32] {
        guard !rect.isNull, rect.width.isFinite, rect.height.isFinite else { return [] }
        let minCol = column(rect.minX)
        let maxCol = column(rect.maxX)
        let minRow = row(rect.minY)
        let maxRow = row(rect.maxY)
        var result: [Int32] = []
        result.reserveCapacity(256)

        lock.lock()
        generation &+= 1
        let current = generation
        let lower = range.lowerBound

        // A shared cell only proves two boxes are nearby, not that they
        // overlap. The reference tests `boxes[index].intersects(clipped)` for
        // exactly this reason; without it every entity hugging the viewport
        // edge was re-stroked on every frame.
        func consider(_ index: Int32) {
            let key = Int(index)
            guard key >= 0, key < stamp.count, stamp[key] != current else { return }
            stamp[key] = current
            let local = key - lower
            if local >= 0, local < boxes.count, !cadBoxesOverlap(boxes[local], rect) {
                return
            }
            result.append(index)
        }

        for r in minRow...maxRow {
            for c in minCol...maxCol {
                for index in cells[r * columns + c] { consider(index) }
            }
        }
        for index in oversized { consider(index) }
        lock.unlock()
        return result
    }

    /// Brute force nearest search used for snapping inside a small window.
    func nearby(_ rect: CGRect) -> [Int32] {
        query(rect)
    }
}

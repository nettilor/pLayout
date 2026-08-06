import Foundation

struct WellPos: Hashable {
    var row: Int
    var col: Int
}

/// A rectangular block of wells, Excel-style: an anchor plus a moving focus corner.
struct WellRange: Equatable {
    var anchor: WellPos
    var focus: WellPos

    init(anchor: WellPos, focus: WellPos) {
        self.anchor = anchor
        self.focus = focus
    }

    init(single: WellPos) {
        self.anchor = single
        self.focus = single
    }

    var minRow: Int { min(anchor.row, focus.row) }
    var maxRow: Int { max(anchor.row, focus.row) }
    var minCol: Int { min(anchor.col, focus.col) }
    var maxCol: Int { max(anchor.col, focus.col) }

    var rowCount: Int { maxRow - minRow + 1 }
    var colCount: Int { maxCol - minCol + 1 }
    var wellCount: Int { rowCount * colCount }
    var isSingleWell: Bool { wellCount == 1 }

    func contains(row: Int, col: Int) -> Bool {
        row >= minRow && row <= maxRow && col >= minCol && col <= maxCol
    }

    func containsRow(_ row: Int) -> Bool { row >= minRow && row <= maxRow }
    func containsCol(_ col: Int) -> Bool { col >= minCol && col <= maxCol }

    /// Row-major well indices for a given plate shape, clipped to the plate.
    func indices(in format: PlateFormat) -> [Int] {
        guard format.rows > 0, format.cols > 0 else { return [] }
        let firstRow = max(0, min(minRow, format.rows - 1))
        let lastRow = max(0, min(maxRow, format.rows - 1))
        let firstCol = max(0, min(minCol, format.cols - 1))
        let lastCol = max(0, min(maxCol, format.cols - 1))
        guard firstRow <= lastRow, firstCol <= lastCol else { return [] }

        var out: [Int] = []
        out.reserveCapacity((lastRow - firstRow + 1) * (lastCol - firstCol + 1))
        for row in firstRow...lastRow {
            for col in firstCol...lastCol {
                out.append(format.index(row: row, col: col))
            }
        }
        return out
    }

    func clamped(to format: PlateFormat) -> WellRange {
        WellRange(
            anchor: WellPos(
                row: min(max(anchor.row, 0), format.rows - 1),
                col: min(max(anchor.col, 0), format.cols - 1)
            ),
            focus: WellPos(
                row: min(max(focus.row, 0), format.rows - 1),
                col: min(max(focus.col, 0), format.cols - 1)
            )
        )
    }

    static func wholePlate(_ format: PlateFormat) -> WellRange {
        WellRange(
            anchor: WellPos(row: 0, col: 0),
            focus: WellPos(row: format.rows - 1, col: format.cols - 1)
        )
    }

    static func wholeRow(_ row: Int, format: PlateFormat) -> WellRange {
        WellRange(anchor: WellPos(row: row, col: 0), focus: WellPos(row: row, col: format.cols - 1))
    }

    static func wholeColumn(_ col: Int, format: PlateFormat) -> WellRange {
        WellRange(anchor: WellPos(row: 0, col: col), focus: WellPos(row: format.rows - 1, col: col))
    }
}

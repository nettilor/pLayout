import AppKit
import XCTest
@testable import PLayout

/// Flipping the plate is a drawing change and nothing else: the same wells, the same
/// ids, the same file. The danger is that only *half* of the app learns about it — so
/// most of this checks that hit-testing still lands where the drawing put things.
final class OrientationTests: XCTestCase {

    private let bounds = NSRect(x: 0, y: 0, width: 1000, height: 700)

    private func geo(_ format: PlateFormat, transposed: Bool) -> PlateGeometry {
        PlateGeometry(format: format, bounds: bounds, transposed: transposed)
    }

    // MARK: - Layout

    func testTheGridTurnsOnItsSide() {
        let upright = geo(.well96, transposed: false)
        let flipped = geo(.well96, transposed: true)
        XCTAssertEqual(upright.displayCols, 12)
        XCTAssertEqual(upright.displayRows, 8)
        XCTAssertEqual(flipped.displayCols, 8)
        XCTAssertEqual(flipped.displayRows, 12)
    }

    /// A1 is the top-left well in a real plate and stays the top-left well here — the
    /// flip pivots about it rather than moving it.
    func testA1StaysInTheTopLeftCorner() {
        for format in PlateFormat.standard {
            for transposed in [false, true] {
                let g = geo(format, transposed: transposed)
                let first = g.cellRect(row: 0, col: 0)
                XCTAssertEqual(first.minX, g.gridRect.minX, accuracy: 0.001)
                XCTAssertEqual(first.minY, g.gridRect.minY, accuracy: 0.001)
            }
        }
    }

    /// The point of the mode: a plate taller than it is wide comes out wider than it is
    /// tall, so it can be read the way it is held.
    func testATallPlateIsDrawnWide() {
        let tall = PlateFormat(rows: 8, cols: 6)
        let upright = geo(tall, transposed: false)
        let flipped = geo(tall, transposed: true)
        XCTAssertLessThan(upright.gridRect.width, upright.gridRect.height)
        XCTAssertGreaterThan(flipped.gridRect.width, flipped.gridRect.height)
    }

    func testEveryWellGetsItsOwnDistinctCell() {
        let format = PlateFormat(rows: 5, cols: 7)
        let g = geo(format, transposed: true)
        var seen = Set<String>()
        for row in 0..<format.rows {
            for col in 0..<format.cols {
                let rect = g.cellRect(row: row, col: col)
                XCTAssertTrue(g.gridRect.insetBy(dx: -0.5, dy: -0.5).contains(rect.center),
                              "\(row),\(col) fell outside the grid")
                XCTAssertTrue(seen.insert("\(Int(rect.minX)),\(Int(rect.minY))").inserted,
                              "\(row),\(col) landed on another well")
            }
        }
    }

    // MARK: - Hit-testing agrees with drawing

    /// The one that matters. If these two ever disagree, clicks paint the wrong wells
    /// and nothing on screen says so.
    func testClickingWhereAWellIsDrawnSelectsThatWell() {
        for format in [PlateFormat.well96, .well48, PlateFormat(rows: 5, cols: 7), PlateFormat(rows: 1, cols: 8)] {
            for transposed in [false, true] {
                let g = geo(format, transposed: transposed)
                for row in 0..<format.rows {
                    for col in 0..<format.cols {
                        let centre = g.cellRect(row: row, col: col).center
                        XCTAssertEqual(
                            g.hit(centre), .well(WellPos(row: row, col: col)),
                            "\(format.rows)×\(format.cols) transposed=\(transposed) at \(row),\(col)"
                        )
                        XCTAssertEqual(g.nearestWell(centre), WellPos(row: row, col: col))
                    }
                }
            }
        }
    }

    /// A header selects an axis, and which strip it lives on depends on the orientation.
    /// The hit has to name the *model* axis either way, or a click on the top of a
    /// flipped plate would select a column when it is pointing at a row.
    func testHeadersSelectTheAxisTheyLabel() {
        for transposed in [false, true] {
            let g = geo(.well96, transposed: transposed)
            for col in 0..<12 {
                XCTAssertEqual(g.hit(g.columnHeaderRect(col).center), .columnHeader(col),
                               "transposed=\(transposed) column \(col)")
            }
            for row in 0..<8 {
                XCTAssertEqual(g.hit(g.rowHeaderRect(row).center), .rowHeader(row),
                               "transposed=\(transposed) row \(row)")
            }
        }
    }

    /// The header strips swap sides with the grid — letters along the top when flipped.
    func testTheHeaderStripsSwapSides() {
        let flipped = geo(.well96, transposed: true)
        XCTAssertEqual(flipped.rowHeaderRect(0), flipped.topHeaderRect(0))
        XCTAssertEqual(flipped.columnHeaderRect(0), flipped.sideHeaderRect(0))

        let upright = geo(.well96, transposed: false)
        XCTAssertEqual(upright.columnHeaderRect(0), upright.topHeaderRect(0))
        XCTAssertEqual(upright.rowHeaderRect(0), upright.sideHeaderRect(0))
    }

    /// Dragging out of the plate keeps extending, and has to extend along the axis the
    /// pointer is actually moving over.
    func testDraggingPastTheEdgeClampsAlongTheRightAxis() {
        let g = geo(.well96, transposed: true)
        let far = CGPoint(x: g.gridRect.maxX + 500, y: g.gridRect.maxY + 500)
        XCTAssertEqual(g.nearestWell(far), WellPos(row: 7, col: 11))
        let before = CGPoint(x: g.gridRect.minX - 500, y: g.gridRect.minY - 500)
        XCTAssertEqual(g.nearestWell(before), WellPos(row: 0, col: 0))
    }

    /// A block of wells is still a block when the plate is turned, so the marquee has
    /// to cover exactly the same wells.
    func testASelectionRectangleCoversTheSameWellsEitherWay() {
        let range = WellRange(anchor: WellPos(row: 1, col: 2), focus: WellPos(row: 4, col: 9))
        for transposed in [false, true] {
            let g = geo(.well96, transposed: transposed)
            let rect = g.rect(of: range).insetBy(dx: -0.5, dy: -0.5)
            for row in 0..<8 {
                for col in 0..<12 {
                    let inside = rect.contains(g.cellRect(row: row, col: col).center)
                    let expected = range.contains(row: row, col: col)
                    XCTAssertEqual(inside, expected,
                                   "transposed=\(transposed) at \(row),\(col)")
                }
            }
        }
    }

    // MARK: - The document

    func testFlippingIsUndoableAndSaved() throws {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let undo = UndoManager()
        editor.undoManager = undo

        XCTAssertFalse(editor.isTransposed)
        editor.toggleOrientation()
        XCTAssertTrue(editor.isTransposed)

        let reopened = try JSONDecoder().decode(
            Layout.self, from: JSONEncoder().encode(document.layout)
        )
        XCTAssertTrue(reopened.transposedView, "the orientation did not survive a save")

        undo.undo()
        XCTAssertFalse(editor.isTransposed, "flipping was not undoable")
    }

    /// Older files have no such key, and must open upright rather than not at all.
    func testAFileWrittenBeforeThisFeatureStillOpens() throws {
        let json = #"{"formatVersion":1,"wellLabelMode":"allFactors"}"#
        let decoded = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.transposedView)
        XCTAssertEqual(decoded.wellLabelMode, .allFactors)
    }

    /// Turning the plate must not touch a single well.
    func testFlippingChangesNoData() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factor = document.layout.factors[0]
        editor.paint(wells: [0, 5, 40], level: factor.levels[1].id)
        let before = document.layout.plates

        editor.toggleOrientation()
        XCTAssertEqual(document.layout.plates, before, "flipping moved well values")
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

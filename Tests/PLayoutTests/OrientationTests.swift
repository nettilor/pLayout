import AppKit
import XCTest
@testable import PLayout

/// Turning the plate is a drawing change and nothing else: the same wells, the same
/// ids, the same file. Two things can go wrong. Only half the app learns about the
/// turn, so clicks and drawing disagree with nothing on screen saying so — or the
/// "rotation" is really a mirror, which looks tidy and cannot happen to a real plate.
final class OrientationTests: XCTestCase {

    private let bounds = NSRect(x: 0, y: 0, width: 1000, height: 700)
    private let turns = [0, 1, 2, 3]

    private func geo(_ format: PlateFormat, _ quarterTurns: Int) -> PlateGeometry {
        PlateGeometry(format: format, bounds: bounds, quarterTurns: quarterTurns)
    }

    // MARK: - It is a rotation, not a mirror

    /// The one that matters most, and the one whose absence let a transpose ship as a
    /// "flip". A rotation preserves handedness; a mirror reverses it.
    ///
    /// Step one column in model space and one row in model space, and look at where
    /// those two steps point on screen. The sign of their cross product is the
    /// handedness of the pair. A rotation cannot change it at any angle; a reflection
    /// flips it at every angle.
    func testEveryTurnIsARotationAndNotAReflection() {
        for format in [PlateFormat.well96, .well48, PlateFormat(rows: 5, cols: 7)] {
            for turn in turns {
                let g = geo(format, turn)
                let origin = g.cellRect(row: 0, col: 0).center
                let alongColumns = g.cellRect(row: 0, col: 1).center
                let alongRows = g.cellRect(row: 1, col: 0).center

                let a = CGPoint(x: alongColumns.x - origin.x, y: alongColumns.y - origin.y)
                let b = CGPoint(x: alongRows.x - origin.x, y: alongRows.y - origin.y)
                let cross = a.x * b.y - a.y * b.x

                XCTAssertGreaterThan(
                    cross, 0,
                    "\(format.rows)×\(format.cols) at \(turn * 90)° is mirrored, not turned"
                )
            }
        }
    }

    /// A1 travels round the corners, one per turn. Pinning it to the top left is exactly
    /// the mistake this test exists to prevent.
    func testA1TravelsRoundTheCornersClockwise() {
        let g = turns.map { geo(.well96, $0) }
        func corner(_ i: Int) -> (x: Bool, y: Bool) {
            let cell = g[i].cellRect(row: 0, col: 0)
            let grid = g[i].gridRect
            return (abs(cell.minX - grid.minX) < 0.001, abs(cell.minY - grid.minY) < 0.001)
        }
        XCTAssertEqual(corner(0).x, true); XCTAssertEqual(corner(0).y, true)     // top left
        XCTAssertEqual(corner(1).x, false); XCTAssertEqual(corner(1).y, true)    // top right
        XCTAssertEqual(corner(2).x, false); XCTAssertEqual(corner(2).y, false)   // bottom right
        XCTAssertEqual(corner(3).x, true); XCTAssertEqual(corner(3).y, false)    // bottom left
    }

    /// Four turns is a full circle, so everything has to land exactly where it started.
    func testFourTurnsComeBackToTheStart() {
        let format = PlateFormat(rows: 5, cols: 7)
        let start = geo(format, 0)
        let round = geo(format, 4)
        for row in 0..<format.rows {
            for col in 0..<format.cols {
                XCTAssertEqual(start.cellRect(row: row, col: col), round.cellRect(row: row, col: col))
            }
        }
    }

    // MARK: - Layout

    func testTheGridStandsOnEndForTheQuarterTurns() {
        XCTAssertEqual(geo(.well96, 0).displayCols, 12)
        XCTAssertEqual(geo(.well96, 1).displayCols, 8)
        XCTAssertEqual(geo(.well96, 2).displayCols, 12)
        XCTAssertEqual(geo(.well96, 3).displayCols, 8)
    }

    /// The point of the mode: a plate taller than it is wide comes out wider than it is
    /// tall, so it can be read the way it is held.
    func testATallPlateIsDrawnWideOnEnd() {
        let tall = PlateFormat(rows: 8, cols: 6)
        XCTAssertLessThan(geo(tall, 0).gridRect.width, geo(tall, 0).gridRect.height)
        XCTAssertGreaterThan(geo(tall, 1).gridRect.width, geo(tall, 1).gridRect.height)
    }

    func testEveryWellGetsItsOwnDistinctCell() {
        let format = PlateFormat(rows: 5, cols: 7)
        for turn in turns {
            let g = geo(format, turn)
            var seen = Set<String>()
            for row in 0..<format.rows {
                for col in 0..<format.cols {
                    let rect = g.cellRect(row: row, col: col)
                    XCTAssertTrue(g.gridRect.insetBy(dx: -0.5, dy: -0.5).contains(rect.center),
                                  "\(row),\(col) at \(turn * 90)° fell outside the grid")
                    XCTAssertTrue(seen.insert("\(Int(rect.minX)),\(Int(rect.minY))").inserted,
                                  "\(row),\(col) at \(turn * 90)° landed on another well")
                }
            }
        }
    }

    // MARK: - Hit-testing agrees with drawing

    func testClickingWhereAWellIsDrawnSelectsThatWell() {
        for format in [PlateFormat.well96, .well48, PlateFormat(rows: 5, cols: 7), PlateFormat(rows: 1, cols: 8)] {
            for turn in turns {
                let g = geo(format, turn)
                for row in 0..<format.rows {
                    for col in 0..<format.cols {
                        let centre = g.cellRect(row: row, col: col).center
                        XCTAssertEqual(
                            g.hit(centre), .well(WellPos(row: row, col: col)),
                            "\(format.rows)×\(format.cols) at \(turn * 90)° well \(row),\(col)"
                        )
                        XCTAssertEqual(g.nearestWell(centre), WellPos(row: row, col: col))
                    }
                }
            }
        }
    }

    /// A header selects an axis, and which strip it lives on depends on the turn. The
    /// hit has to name the *model* axis either way.
    func testHeadersSelectTheAxisTheyLabel() {
        for turn in turns {
            let g = geo(.well96, turn)
            for col in 0..<12 {
                XCTAssertEqual(g.hit(g.columnHeaderRect(col).center), .columnHeader(col),
                               "\(turn * 90)° column \(col)")
            }
            for row in 0..<8 {
                XCTAssertEqual(g.hit(g.rowHeaderRect(row).center), .rowHeader(row),
                               "\(turn * 90)° row \(row)")
            }
        }
    }

    /// Standing the plate on end swaps which strip each axis is labelled on; a half turn
    /// leaves them where they were but running backwards.
    func testTheHeaderStripsFollowTheirOwnAxis() {
        XCTAssertEqual(geo(.well96, 0).columnHeaderRect(0), geo(.well96, 0).horizontalHeaderRect(0))
        XCTAssertEqual(geo(.well96, 1).rowHeaderRect(0), geo(.well96, 1).horizontalHeaderRect(7))
        XCTAssertEqual(geo(.well96, 2).columnHeaderRect(0), geo(.well96, 2).horizontalHeaderRect(11))
        XCTAssertEqual(geo(.well96, 3).rowHeaderRect(0), geo(.well96, 3).horizontalHeaderRect(0))
    }

    /// The strips travel with their own edge of the plate, which is the whole point:
    /// turning clockwise carries the numbers from the top edge to the right-hand one,
    /// where they sit on a plate you have actually turned.
    func testTheStripsSitOnTheEdgeTheirAxisTravelledTo() {
        let upright = geo(.well96, 0)
        XCTAssertLessThan(upright.rowHeaderRect(0).minX, upright.gridRect.minX, "letters left")
        XCTAssertLessThan(upright.columnHeaderRect(0).minY, upright.gridRect.minY, "numbers on top")

        let turned = geo(.well96, 1)
        XCTAssertLessThan(turned.rowHeaderRect(0).minY, turned.gridRect.minY, "letters on top")
        XCTAssertGreaterThanOrEqual(
            turned.columnHeaderRect(0).minX, turned.gridRect.maxX - 0.001, "numbers on the right"
        )
    }

    /// The button lives where the two strips meet, so it travels with them.
    func testTheCornerFollowsTheStrips() {
        for turn in turns {
            let g = geo(.well96, turn)
            XCTAssertFalse(g.gridRect.intersects(g.cornerRect), "\(turn * 90)° corner overlaps the wells")
            XCTAssertEqual(g.hit(CGPoint(x: g.cornerRect.midX, y: g.cornerRect.midY)), .corner)
        }
        XCTAssertLessThan(geo(.well96, 0).cornerRect.midX, geo(.well96, 0).gridRect.minX)
        XCTAssertGreaterThan(geo(.well96, 1).cornerRect.midX, geo(.well96, 1).gridRect.maxX)
    }

    func testDraggingPastTheEdgeClampsAlongTheRightAxis() {
        for turn in turns {
            let g = geo(.well96, turn)
            let past = CGPoint(x: g.gridRect.maxX + 500, y: g.gridRect.maxY + 500)
            let clamped = g.nearestWell(past)
            XCTAssertTrue((0..<8).contains(clamped.row), "\(turn * 90)° row \(clamped.row)")
            XCTAssertTrue((0..<12).contains(clamped.col), "\(turn * 90)° col \(clamped.col)")
            // Whichever corner it is, it has to be a corner.
            XCTAssertTrue([0, 7].contains(clamped.row) && [0, 11].contains(clamped.col))
        }
    }

    func testASelectionRectangleCoversTheSameWellsAtEveryTurn() {
        let range = WellRange(anchor: WellPos(row: 1, col: 2), focus: WellPos(row: 4, col: 9))
        for turn in turns {
            let g = geo(.well96, turn)
            let rect = g.rect(of: range).insetBy(dx: -0.5, dy: -0.5)
            for row in 0..<8 {
                for col in 0..<12 {
                    XCTAssertEqual(
                        rect.contains(g.cellRect(row: row, col: col).center),
                        range.contains(row: row, col: col),
                        "\(turn * 90)° at \(row),\(col)"
                    )
                }
            }
        }
    }

    // MARK: - Lying the plate down by default

    /// A real plate is wider than it is tall, so that is how a layout should open. A
    /// plate that is already wide is left alone.
    func testATallPlateOpensTurnedAndAWideOneDoesNot() {
        XCTAssertEqual(PlateOrientation.automatic.quarterTurns(for: PlateFormat(rows: 8, cols: 6)), 1)
        XCTAssertEqual(PlateOrientation.automatic.quarterTurns(for: .well96), 0)
        XCTAssertEqual(PlateOrientation.automatic.quarterTurns(for: PlateFormat(rows: 4, cols: 4)), 0)
    }

    /// Three-valued and not a Bool precisely so this case works: choosing upright on a
    /// tall plate has to stick, rather than being read as "never decided" and lain down
    /// again on the next open.
    func testChoosingUprightOnATallPlateSticks() {
        let tall = PlateFormat(rows: 8, cols: 6)
        XCTAssertEqual(PlateOrientation.upright.quarterTurns(for: tall), 0)
        XCTAssertEqual(PlateOrientation.turned.quarterTurns(for: .well96), 1)
    }

    // MARK: - The document

    func testTurningIsUndoableAndSaved() throws {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let undo = UndoManager()
        editor.undoManager = undo

        XCTAssertEqual(editor.quarterTurns, 0, "a 96-well plate is already lying down")
        editor.rotatePlate()
        XCTAssertEqual(editor.quarterTurns, 1)
        XCTAssertTrue(editor.isTurned)

        let reopened = try JSONDecoder().decode(
            Layout.self, from: JSONEncoder().encode(document.layout)
        )
        // Turning is per plate now — the board shows several at once, and standing a tall
        // plate on its end must not lie the 96-well beside it down too. The document's own
        // `orientation` is the default a plate falls back to when it has no opinion.
        XCTAssertEqual(
            reopened.plates[0].orientation, .turned, "the orientation did not survive a save"
        )

        undo.undo()
        XCTAssertEqual(editor.quarterTurns, 0, "turning was not undoable")
    }

    /// One click turns it, the next turns it back — not a four-way cycle.
    func testTheControlTurnsAndTurnsBack() {
        let editor = PlateEditor(document: PlateDocument())
        editor.rotatePlate()
        XCTAssertEqual(editor.quarterTurns, 1)
        editor.rotatePlate()
        XCTAssertEqual(editor.quarterTurns, 0)
        editor.rotatePlate()
        XCTAssertEqual(editor.quarterTurns, 1)
    }

    /// Older files have no such key, and must open lying down rather than not at all.
    func testAFileWrittenBeforeThisFeatureStillOpens() throws {
        let json = #"{"formatVersion":1,"wellLabelMode":"allFactors"}"#
        let decoded = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.orientation, .automatic)
        XCTAssertEqual(decoded.wellLabelMode, .allFactors)
    }

    /// Two short-lived predecessors: `transposedView` (a mirror) and `quarterTurns` (a
    /// four-way cycle). A file carrying either keeps its turned-ness rather than
    /// silently springing back upright.
    func testFilesFromTheTwoEarlierSpellingsKeepTheirOrientation() throws {
        func orientation(_ json: String) throws -> PlateOrientation {
            try JSONDecoder().decode(Layout.self, from: Data(json.utf8)).orientation
        }
        XCTAssertEqual(try orientation(#"{"formatVersion":1,"transposedView":true}"#), .turned)
        XCTAssertEqual(try orientation(#"{"formatVersion":1,"transposedView":false}"#), .automatic)
        XCTAssertEqual(try orientation(#"{"formatVersion":1,"quarterTurns":1}"#), .turned)
        XCTAssertEqual(try orientation(#"{"formatVersion":1,"quarterTurns":3}"#), .turned)
        XCTAssertEqual(try orientation(#"{"formatVersion":1,"quarterTurns":0}"#), .automatic)
    }

    /// Turning the plate must not touch a single well.
    func testTurningChangesNoData() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factor = document.layout.factors[0]
        editor.paint(wells: [0, 5, 40], level: factor.levels[1].id)
        let before = document.layout.plates

        editor.rotatePlate()
        // The plate now records which way round it is, so compare what turning must never
        // touch rather than the whole value.
        XCTAssertEqual(
            document.layout.plates.map(\.assignments), before.map(\.assignments),
            "turning moved well values"
        )
        XCTAssertEqual(document.layout.plates.map(\.format), before.map(\.format))
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

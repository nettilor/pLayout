import XCTest
@testable import PLayout

/// Per-well and per-plate notes: subtle on screen, durable in the file, and
/// travelling into the Wells sheet and tidy CSV only when any exist.
final class NotesTests: XCTestCase {

    // MARK: - Model

    /// The reason Plate now decodes by hand — a file saved before notes existed
    /// must keep opening. Same trap as Layout and LayoutSnapshot before it.
    func testAPlateSavedBeforeNotesStillDecodes() throws {
        let legacy = """
        { "id": "33333333-3333-3333-3333-333333333333",
          "name": "Plate 1",
          "format": { "rows": 8, "cols": 12 },
          "assignments": {} }
        """
        let plate = try JSONDecoder().decode(Plate.self, from: Data(legacy.utf8))
        XCTAssertTrue(plate.wellNotes.isEmpty)
        XCTAssertEqual(plate.note, "")
    }

    func testNotesRoundTripThroughTheFile() throws {
        var plate = Plate(name: "P", format: .well96)
        plate.setNote("bubble in this well", well: 13)
        plate.note = "run 2, incubated 24 h"

        let decoded = try JSONDecoder().decode(Plate.self, from: JSONEncoder().encode(plate))
        XCTAssertEqual(decoded.note(well: 13), "bubble in this well")
        XCTAssertEqual(decoded.note, "run 2, incubated 24 h")
    }

    func testAnEmptyNoteIsARemovedOne() {
        var plate = Plate(name: "P", format: .well96)
        plate.setNote("something", well: 5)
        plate.setNote("   ", well: 5)
        XCTAssertNil(plate.note(well: 5))
        XCTAssertTrue(plate.wellNotes.isEmpty, "no empty entries left behind to mark wells")
    }

    /// Notes follow their row and column through a format change, like assignments.
    func testNotesSurviveAFormatChangeAtTheirPosition() {
        var plate = Plate(name: "P", format: .well96)
        let b2 = plate.format.index(row: 1, col: 1)
        let h12 = plate.format.index(row: 7, col: 11)
        plate.setNote("keep me", well: b2)
        plate.setNote("off the edge", well: h12)

        plate.changeFormat(to: .well24)
        XCTAssertEqual(plate.note(well: plate.format.index(row: 1, col: 1)), "keep me")
        XCTAssertEqual(plate.wellNotes.count, 1, "a note outside the smaller plate goes with its well")
    }

    // MARK: - Editor

    func testSavingAndUndoingAWellNote() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let undo = UndoManager()
        editor.undoManager = undo

        editor.saveNote("smeared", for: .well(7))
        XCTAssertEqual(document.layout.plates[0].note(well: 7), "smeared")

        undo.undo()
        XCTAssertNil(document.layout.plates[0].note(well: 7))
    }

    func testTheStatusBarSummaryCarriesTheNote() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.saveNote("check under scope", for: .well(0))

        XCTAssertTrue(editor.summary(row: 0, col: 0).contains("check under scope"))
        XCTAssertFalse(editor.summary(row: 0, col: 1).contains("check under scope"))
    }

    func testTheNoteSheetTargetsTheSelectionFocus() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.selection = WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 2, col: 3))
        editor.openWellNoteSheet()

        let expected = document.layout.plates[0].format.index(row: 2, col: 3)
        XCTAssertEqual(editor.noteTarget, .well(expected))
        XCTAssertEqual(editor.noteTitle(for: .well(expected)), "Note for C4")
    }

    // MARK: - Export

    func testTheNoteColumnExistsOnlyWhenAnyNoteDoes() {
        var layout = Layout.starter()
        XCTAssertFalse(Exporter.tidyGrid(layout: layout)[0].contains("Note"))

        layout.plates[0].setNote("bubble", well: layout.plates[0].format.index(row: 0, col: 1))
        let grid = Exporter.tidyGrid(layout: layout)
        XCTAssertEqual(grid[0].last, "Note")
        // Row-major: A2 is the second data row.
        XCTAssertEqual(grid[2].last, "bubble")
        XCTAssertEqual(grid[1].last, "")
    }
}

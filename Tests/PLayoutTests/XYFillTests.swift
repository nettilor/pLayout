import XCTest
import AppKit
@testable import PLayout

/// The Keyence workflow: number the wells as imaging positions XY01… in the
/// order the stage will visit them, as levels of one "XY" factor.
final class XYFillTests: XCTestCase {

    private func makeEditor() -> PlateEditor {
        PlateEditor(document: PlateDocument())
    }

    private func xyFactor(_ editor: PlateEditor) -> Factor? {
        editor.document.layout.factors.first { $0.name == PlateEditor.xyFactorName }
    }

    private func positionName(_ editor: PlateEditor, row: Int, col: Int) -> String? {
        guard let factor = xyFactor(editor), let plate = editor.document.layout.plates.first else { return nil }
        let id = plate.levelID(factor: factor.id, well: plate.format.index(row: row, col: col))
        return factor.level(id: id)?.name
    }

    // MARK: - Names

    func testNamesReadLikeTheInstrument() {
        let names96 = PlateEditor.xyNames(count: 96)
        XCTAssertEqual(names96.first, "XY01")
        XCTAssertEqual(names96[9], "XY10")
        XCTAssertEqual(names96.last, "XY96")

        // Two digits is the instrument's own style; it widens only when it must.
        let names384 = PlateEditor.xyNames(count: 384)
        XCTAssertEqual(names384.first, "XY001")
        XCTAssertEqual(names384.last, "XY384")
    }

    // MARK: - Coverage

    func testNothingSelectedNumbersTheWholePlate() {
        let editor = makeEditor()
        editor.selection = nil
        editor.applyXYFill(.init())

        let factor = xyFactor(editor)
        XCTAssertNotNil(factor)
        XCTAssertEqual(editor.document.layout.factors.count, 2, "the starter factor must survive")
        XCTAssertEqual(factor?.levels.count, 96)
        XCTAssertEqual(positionName(editor, row: 0, col: 0), "XY01")
        XCTAssertEqual(positionName(editor, row: 0, col: 11), "XY12")
        XCTAssertEqual(positionName(editor, row: 7, col: 11), "XY96")
    }

    /// The app rests with a one-well selection — the cursor — and one imaging
    /// position is never the ask, so that counts as "nothing selected" too.
    func testTheRestingCursorCountsAsNothingSelected() {
        let editor = makeEditor()
        XCTAssertEqual(editor.selection?.isSingleWell, true, "precondition: the default selection is the cursor")
        editor.applyXYFill(.init())
        XCTAssertEqual(xyFactor(editor)?.levels.count, 96)
    }

    func testOnlyTheSelectionIsNumbered() {
        let editor = makeEditor()
        editor.selection = WellRange(anchor: WellPos(row: 1, col: 1), focus: WellPos(row: 2, col: 2))
        editor.applyXYFill(.init())

        XCTAssertEqual(xyFactor(editor)?.levels.count, 4)
        XCTAssertEqual(positionName(editor, row: 1, col: 1), "XY01")
        XCTAssertEqual(positionName(editor, row: 1, col: 2), "XY02")
        XCTAssertEqual(positionName(editor, row: 2, col: 1), "XY03")
        XCTAssertEqual(positionName(editor, row: 2, col: 2), "XY04")
        XCTAssertNil(positionName(editor, row: 0, col: 0), "outside the selection stays untouched")
    }

    // MARK: - Patterns

    func testDownRowsWalksAColumnFirst() {
        let editor = makeEditor()
        editor.selection = WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 1, col: 2))
        editor.applyXYFill(.init(pattern: .downRows))

        XCTAssertEqual(positionName(editor, row: 0, col: 0), "XY01")
        XCTAssertEqual(positionName(editor, row: 1, col: 0), "XY02")
        XCTAssertEqual(positionName(editor, row: 0, col: 1), "XY03")
        XCTAssertEqual(positionName(editor, row: 1, col: 1), "XY04")
        XCTAssertEqual(positionName(editor, row: 0, col: 2), "XY05")
        XCTAssertEqual(positionName(editor, row: 1, col: 2), "XY06")
    }

    func testSerpentineComesBackAlongTheNextRow() {
        let editor = makeEditor()
        editor.selection = WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 1, col: 2))
        editor.applyXYFill(.init(pattern: .serpentine))

        XCTAssertEqual(positionName(editor, row: 0, col: 0), "XY01")
        XCTAssertEqual(positionName(editor, row: 0, col: 1), "XY02")
        XCTAssertEqual(positionName(editor, row: 0, col: 2), "XY03")
        XCTAssertEqual(positionName(editor, row: 1, col: 2), "XY04")
        XCTAssertEqual(positionName(editor, row: 1, col: 1), "XY05")
        XCTAssertEqual(positionName(editor, row: 1, col: 0), "XY06")
    }

    // MARK: - Re-running

    func testRerunRenumbersInsteadOfDuplicating() {
        let editor = makeEditor()
        editor.selection = nil
        editor.applyXYFill(.init(pattern: .serpentine))
        XCTAssertEqual(positionName(editor, row: 7, col: 0), "XY96", "row 8 runs right-to-left under serpentine")

        editor.applyXYFill(.init(pattern: .acrossColumns))
        XCTAssertEqual(editor.document.layout.factors.count, 2, "one XY factor, not one per run")
        XCTAssertEqual(xyFactor(editor)?.levels.count, 96)
        XCTAssertEqual(positionName(editor, row: 7, col: 0), "XY85")
    }

    // MARK: - What the fill leaves active

    func testTheXYFactorBecomesActiveAndItsColoursRunAsOneRamp() {
        let editor = makeEditor()
        let before = editor.document.layout
        let expectedBase = PlateEditor.newLevelColor(in: before, fallback: before.factors.count)
        editor.selection = nil
        editor.applyXYFill(.init())

        let factor = xyFactor(editor)
        XCTAssertEqual(editor.activeFactorID, factor?.id)
        XCTAssertEqual(factor.map { $0.levels.map(\.colorHex) }, Palette.ramp(count: 96, baseHex: expectedBase))
    }

    // MARK: - Undo

    func testTheFillIsOneUndoStep() {
        let editor = makeEditor()
        editor.selection = nil
        // Attached after setup, or the setup edits coalesce into this group.
        let undo = UndoManager()
        editor.undoManager = undo

        editor.applyXYFill(.init())
        XCTAssertNotNil(xyFactor(editor))

        undo.undo()
        XCTAssertNil(xyFactor(editor), "one undo must remove the factor and every assignment")
        XCTAssertEqual(editor.document.layout.factors.count, 1)
    }

    // MARK: - Overview

    func testOverviewRefusesTheFill() {
        let editor = makeEditor()
        editor.setWellLabelMode(.overview)

        editor.openXYFillSheet()
        XCTAssertFalse(editor.showingXYFillSheet)
        XCTAssertTrue(editor.transientMessage.contains("Overview"), editor.transientMessage)

        editor.transientMessage = ""
        editor.applyXYFill(.init())
        XCTAssertNil(xyFactor(editor))
        XCTAssertTrue(editor.transientMessage.contains("Overview"), editor.transientMessage)
    }
}

import XCTest
import AppKit
@testable import PLayout

/// ⌘-click in the sidebar lists: several rows selected at once for bulk deletion,
/// with painting off for exactly as long as the multi-selection stands.
final class SidebarMultiSelectTests: XCTestCase {

    private var document: PlateDocument!
    private var editor: PlateEditor!
    private var levels: [Level] { document.layout.factors[0].levels }

    override func setUp() {
        super.setUp()
        document = PlateDocument()
        editor = PlateEditor(document: document)
    }

    // MARK: - Conditions

    func testCommandClickSeedsFromTheArmedConditionAndDisarms() {
        let armed = editor.armedLevelID
        editor.toggleLevelInMultiSelection(levels[2].id)

        XCTAssertEqual(editor.multiSelectedLevelIDs, [armed!, levels[2].id])
        XCTAssertNil(editor.armedLevelID, "nothing is armed while several rows are selected")
        XCTAssertTrue(editor.isMultiSelecting)
    }

    func testPaintingIsRefusedOutLoudWhileMultiSelecting() {
        editor.toggleLevelInMultiSelection(levels[2].id)
        editor.paint(wells: [0], level: levels[2].id)

        let plate = document.layout.plates[0]
        XCTAssertNil(plate.levelID(factor: document.layout.factors[0].id, well: 0))
        XCTAssertFalse(editor.transientMessage.isEmpty, "a brush that does nothing must say why")
    }

    func testTogglingBackDownToOneRowRearmsIt() {
        editor.toggleLevelInMultiSelection(levels[2].id)
        editor.toggleLevelInMultiSelection(levels[0].id)

        XCTAssertTrue(editor.multiSelectedLevelIDs.isEmpty)
        XCTAssertEqual(editor.armedLevelID, levels[2].id)
    }

    func testArmingByNumberKeyLeavesTheMultiSelection() {
        editor.toggleLevelInMultiSelection(levels[2].id)
        editor.armLevel(atIndex: 1)

        XCTAssertFalse(editor.isMultiSelecting)
        XCTAssertEqual(editor.armedLevelID, levels[1].id)
    }

    func testDeleteConditionsIsOneUndoStep() {
        editor.toggleLevelInMultiSelection(levels[2].id)
        let doomed = editor.multiSelectedLevelIDs
        let undo = UndoManager()
        editor.undoManager = undo

        editor.deleteLevels(doomed)
        XCTAssertEqual(levels.count, 1)
        XCTAssertFalse(editor.isMultiSelecting)
        XCTAssertEqual(editor.armedLevelID, levels[0].id, "the survivor is armed so painting can resume")

        undo.undo()
        XCTAssertEqual(levels.count, 3, "one undo puts every deleted condition back")
    }

    // MARK: - Factors

    func testFactorMultiSelectionSeedsFromTheActiveFactorAndDisarms() {
        editor.addFactor()
        let first = document.layout.factors[0].id
        let second = document.layout.factors[1].id
        editor.setActiveFactor(first)
        editor.toggleFactorInMultiSelection(second)

        XCTAssertEqual(editor.multiSelectedFactorIDs, [first, second])
        XCTAssertNil(editor.armedLevelID)
    }

    func testDeletingEveryFactorKeepsOne() {
        editor.addFactor()
        let ids = Set(document.layout.factors.map(\.id))
        editor.deleteFactors(ids)

        XCTAssertEqual(document.layout.factors.count, 1)
        XCTAssertTrue(editor.transientMessage.contains("at least one factor"), editor.transientMessage)
    }

    func testUndoDeletingSelectedRowsPrunesTheSets() {
        editor.toggleLevelInMultiSelection(levels[2].id)
        let doomed = editor.multiSelectedLevelIDs
        editor.deleteLevels(doomed)

        XCTAssertTrue(editor.multiSelectedLevelIDs.isEmpty)
        XCTAssertFalse(editor.isMultiSelecting)
    }
}

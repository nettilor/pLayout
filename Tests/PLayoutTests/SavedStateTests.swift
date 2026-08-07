import XCTest
@testable import PLayout

/// Saved states are a safety net for trying a combination out, so the thing that
/// matters most is that every one of the three buttons is itself undoable.
final class SavedStateTests: XCTestCase {

    private var document: PlateDocument!
    private var editor: PlateEditor!

    override func setUp() {
        super.setUp()
        document = PlateDocument()
        editor = PlateEditor(document: document)
    }

    private var factor: Factor { document.layout.factors[0] }

    private func paint(_ wells: [Int], _ levelIndex: Int) {
        editor.paint(wells: wells, level: factor.levels[levelIndex].id)
    }

    private func levelName(at well: Int) -> String? {
        let plate = document.layout.plates[0]
        return factor.level(id: plate.levelID(factor: factor.id, well: well))?.name
    }

    /// Attaching the undo manager late keeps each action in its own undo group; a
    /// test has no run-loop turns to close groups between them.
    private func freshUndoManager() -> UndoManager {
        let undo = UndoManager()
        editor.undoManager = undo
        return undo
    }

    // MARK: - Saving

    func testSaveStateCapturesTheDesign() {
        paint([0, 1, 2], 0)
        editor.saveState()

        XCTAssertEqual(editor.savedStates.count, 1)
        XCTAssertEqual(editor.savedStates.first?.name, "State 1")
        XCTAssertEqual(editor.savedStates.first?.plates.count, 1)
        XCTAssertEqual(editor.savedStates.first?.factors.count, document.layout.factors.count)
    }

    func testSavedStatesAreNumberedInOrder() {
        editor.saveState()
        paint([0], 0)
        editor.saveState()
        XCTAssertEqual(editor.savedStates.map(\.name), ["State 1", "State 2"])
    }

    func testSavingIsUndoable() {
        let undo = freshUndoManager()
        editor.saveState()
        XCTAssertEqual(editor.savedStates.count, 1)

        undo.undo()
        XCTAssertTrue(editor.savedStates.isEmpty, "an accidental save must be undoable")
        undo.redo()
        XCTAssertEqual(editor.savedStates.count, 1)
    }

    func testOldestStatesAreDroppedAtTheCap() {
        // Each iteration must change the design, or saving is correctly refused
        // as a duplicate.
        for i in 0..<(Layout.maxSnapshots + 3) {
            paint([i], 0)
            editor.saveState()
        }
        XCTAssertEqual(editor.savedStates.count, Layout.maxSnapshots)
        XCTAssertFalse(editor.savedStates.contains { $0.name == "State 1" },
                       "the oldest state should have been dropped")
    }

    // MARK: - Reverting

    func testRevertRestoresTheSavedDesign() {
        paint([0, 1], 0)
        editor.saveState()
        XCTAssertEqual(levelName(at: 0), "Untreated")

        // Try something else out.
        paint([0, 1, 2, 3], 2)
        XCTAssertEqual(levelName(at: 3), "Treated")

        editor.revertToLatestState()
        XCTAssertEqual(levelName(at: 0), "Untreated")
        XCTAssertNil(levelName(at: 3), "wells painted after the save should be gone")
    }

    /// The whole point: a revert is an ordinary edit, not a destructive jump.
    func testRevertIsUndoableAndRedoable() {
        paint([0], 0)
        editor.saveState()
        paint([5], 2)

        let undo = freshUndoManager()
        editor.revertToLatestState()
        XCTAssertNil(levelName(at: 5))

        undo.undo()
        XCTAssertEqual(levelName(at: 5), "Treated", "undo should restore the experiment")

        undo.redo()
        XCTAssertNil(levelName(at: 5), "redo should re-apply the revert")
    }

    func testRevertKeepsTheSavedStateListAndDisplaySettings() {
        editor.setWellLabelMode(.allFactors)
        editor.setPadWellLabels(true)
        paint([0], 0)
        editor.saveState()
        paint([1], 2)
        editor.saveState()

        editor.setWellLabelMode(.none)
        editor.revertToLatestState()

        XCTAssertEqual(editor.savedStates.count, 2, "reverting must not discard bookmarks")
        XCTAssertEqual(document.layout.wellLabelMode, .none,
                       "reverting should not change how you are looking at the plate")
        XCTAssertTrue(document.layout.padWellLabels)
    }

    func testCanRevertToAnOlderStateNotJustTheLatest() {
        paint([0], 0)
        editor.saveState()
        let first = editor.savedStates[0].id

        paint([1], 2)
        editor.saveState()

        paint([2], 2)
        editor.revertToState(first)

        XCTAssertEqual(levelName(at: 0), "Untreated")
        XCTAssertNil(levelName(at: 1), "the second state's changes should be gone too")
        XCTAssertNil(levelName(at: 2))
    }

    func testRevertingWithNoSavedStatesDoesNothing() {
        paint([0], 0)
        editor.revertToLatestState()
        XCTAssertEqual(levelName(at: 0), "Untreated")
        XCTAssertTrue(editor.savedStates.isEmpty)
    }

    func testMenuOrderIsNewestFirst() {
        editor.saveState()
        paint([0], 0)
        editor.saveState()
        XCTAssertEqual(editor.savedStatesNewestFirst.map(\.name), ["State 2", "State 1"])
    }

    // MARK: - Renaming and deleting

    func testRenamingAState() {
        editor.saveState()
        let id = editor.savedStates[0].id
        editor.renameState(id, to: "  Before dose curve  ")
        XCTAssertEqual(editor.savedStates[0].name, "Before dose curve", "name should be trimmed")
    }

    func testRenamingIsUndoableAndIgnoresBlanks() {
        editor.saveState()
        let id = editor.savedStates[0].id
        let undo = freshUndoManager()

        editor.renameState(id, to: "Baseline")
        XCTAssertEqual(editor.savedStates[0].name, "Baseline")
        undo.undo()
        XCTAssertEqual(editor.savedStates[0].name, "State 1")

        editor.renameState(id, to: "   ")
        XCTAssertEqual(editor.savedStates[0].name, "State 1", "a blank name should be ignored")
    }

    func testDeletingASingleState() {
        editor.saveState()
        paint([0], 0)
        editor.saveState()
        let first = editor.savedStates[0].id

        editor.deleteState(first)
        XCTAssertEqual(editor.savedStates.map(\.name), ["State 2"])
    }

    func testDeletingIsUndoable() {
        editor.saveState()
        let id = editor.savedStates[0].id
        let undo = freshUndoManager()

        editor.deleteState(id)
        XCTAssertTrue(editor.savedStates.isEmpty)
        undo.undo()
        XCTAssertEqual(editor.savedStates.count, 1, "an accidental delete must be undoable")
    }

    func testDeletingLeavesThePlateAlone() {
        paint([0], 0)
        editor.saveState()
        editor.deleteState(editor.savedStates[0].id)
        XCTAssertEqual(levelName(at: 0), "Untreated", "deleting a bookmark is not an edit to the plate")
    }

    // MARK: - Matching the current design

    func testBookmarkFillsWhenTheDesignMatchesASavedState() {
        XCTAssertFalse(editor.currentDesignIsSaved)

        paint([0, 1], 0)
        editor.saveState()
        XCTAssertTrue(editor.currentDesignIsSaved, "just-saved design should read as saved")
        XCTAssertEqual(editor.matchingSavedStateID, editor.savedStates[0].id)

        paint([5], 2)
        XCTAssertFalse(editor.currentDesignIsSaved, "editing should clear the match")

        editor.revertToLatestState()
        XCTAssertTrue(editor.currentDesignIsSaved, "reverting should restore the match")
    }

    /// Undo and redo go through the document, not the editor, so the match has to
    /// track the published layout rather than being recomputed inside each action.
    func testMatchTracksUndoAndRedo() {
        paint([0], 0)
        editor.saveState()
        let undo = freshUndoManager()

        paint([7], 2)
        XCTAssertFalse(editor.currentDesignIsSaved)

        undo.undo()
        XCTAssertTrue(editor.currentDesignIsSaved, "undo back onto a saved design should refill")

        undo.redo()
        XCTAssertFalse(editor.currentDesignIsSaved)
    }

    func testMatchClearsWhenTheMatchingStateIsDeleted() {
        paint([0], 0)
        editor.saveState()
        XCTAssertTrue(editor.currentDesignIsSaved)

        editor.deleteState(editor.savedStates[0].id)
        XCTAssertFalse(editor.currentDesignIsSaved)
    }

    func testSavingTheSameDesignTwiceDoesNotDuplicate() {
        paint([0], 0)
        editor.saveState()
        editor.saveState()
        XCTAssertEqual(editor.savedStates.count, 1, "an unchanged design should not be saved again")
    }

    func testDisplayOnlyChangesDoNotBreakTheMatch() {
        paint([0], 0)
        editor.saveState()
        editor.setWellLabelMode(.allFactors)
        XCTAssertTrue(
            editor.currentDesignIsSaved,
            "a state captures the design, so changing how it is displayed should not unmatch it"
        )
    }

    // MARK: - Restoring across structural changes

    /// A state saved on a bigger plate must not leave the editor pointing at wells,
    /// factors or levels that no longer exist.
    func testRevertingAfterStructuralChangesLeavesTheEditorConsistent() {
        editor.setFormat(.well384)
        editor.selection = WellRange(anchor: WellPos(row: 10, col: 20), focus: WellPos(row: 12, col: 22))
        editor.addFactor()
        let addedFactor = editor.activeFactorID
        editor.saveState()

        // Now throw away the factor and shrink the plate, then go back.
        editor.deleteFactor(addedFactor!)
        editor.setFormat(.well6)
        editor.revertToLatestState()

        XCTAssertEqual(document.layout.plates[0].format, .well384)
        XCTAssertEqual(document.layout.factors.count, 2)
        XCTAssertNotNil(editor.activeFactor, "active factor should still resolve")
        XCTAssertNotNil(editor.plate, "active plate should still resolve")
        if let selection = editor.selection {
            XCTAssertLessThan(selection.maxRow, editor.format.rows)
            XCTAssertLessThan(selection.maxCol, editor.format.cols)
        }
    }

    /// A state bookmarks one plate, so reverting it must leave the rest of the document
    /// alone. Removing a factor added since would strand *other* plates on levels that
    /// no longer exist — blank wells, with nothing to say why.
    func testRevertingOnePlateKeepsWhatTheRestOfTheDocumentGained() {
        editor.saveState()
        editor.addFactor()
        let addedFactor = editor.activeFactorID!
        editor.addPlate()
        let addedPlate = editor.activePlateID!

        editor.activePlateID = document.layout.plates[0].id
        editor.revertToLatestState()

        XCTAssertEqual(document.layout.factors.count, 2, "reverting one plate dropped a factor")
        XCTAssertTrue(document.layout.factors.contains { $0.id == addedFactor })
        XCTAssertTrue(
            document.layout.plates.contains { $0.id == addedPlate },
            "reverting one plate deleted another"
        )
        XCTAssertNotNil(editor.activeFactor)
        XCTAssertNotNil(editor.armedLevel, "an armed level should still resolve")
    }

    /// The other half: a level the state needs and the document has since lost has to
    /// come back, or the restored wells point at nothing.
    func testRevertingPutsBackALevelThatWasDeletedSince() {
        paint([0, 1], 2)
        editor.saveState()
        let doomed = factor.levels[2]
        editor.deleteLevel(doomed.id)
        XCTAssertNil(levelName(at: 0), "the level should be gone before reverting")

        editor.revertToLatestState()
        XCTAssertTrue(
            document.layout.factors[0].levels.contains { $0.id == doomed.id },
            "the level the state needs was not reinstated"
        )
        XCTAssertEqual(levelName(at: 0), doomed.name)
    }

    // MARK: - Editor stays consistent across undo and redo

    /// Regression: reconciling only inside `revertToState` left undo and redo able to
    /// strand the editor on a deleted factor, after which painting wrote into a factor
    /// that no longer existed — invisible on screen, but saved to the file.
    /// Driven through a real deletion now that reverting is scoped to one plate and no
    /// longer removes anything. The hazard is unchanged: redo can take away whatever the
    /// editor is pointing at, and it has to notice.
    func testRedoingADeletionCannotStrandTheEditorOnAMissingFactor() {
        editor.addFactor()
        let added = editor.activeFactorID!

        let undo = freshUndoManager()
        editor.deleteFactor(added)
        undo.undo()                                   // it comes back
        editor.setActiveFactor(added)                 // view state, so redo survives
        undo.redo()                                   // and now it is gone again

        XCTAssertNotNil(editor.activeFactor, "active factor must still exist after redo")
        XCTAssertNotEqual(editor.activeFactorID, added)
        XCTAssertNotNil(editor.armedLevel, "an armed level must be reselected too")
    }

    func testRedoingADeletionCannotStrandTheEditorOnAMissingPlate() {
        editor.addPlate()
        let added = editor.activePlateID!

        let undo = freshUndoManager()
        editor.deletePlate(added)
        undo.undo()
        editor.activePlateID = added
        undo.redo()

        XCTAssertNotNil(editor.plate, "active plate must still exist after redo")
        XCTAssertNotEqual(editor.activePlateID, added)
    }

    func testPaintingAfterRedoWritesIntoALiveFactor() {
        editor.saveState()
        editor.addFactor()
        let addedFactor = editor.activeFactorID!

        let undo = freshUndoManager()
        editor.revertToLatestState()
        undo.undo()
        editor.setActiveFactor(addedFactor)
        undo.redo()

        editor.armedLevelID = editor.activeFactor?.levels.first?.id
        editor.selection = WellRange(single: WellPos(row: 0, col: 0))
        editor.paintSelection()

        let plate = document.layout.plates[0]
        let liveFactorIDs = Set(document.layout.factors.map(\.id.uuidString))
        XCTAssertFalse(plate.assignments.isEmpty, "the paint should have landed somewhere")
        for key in plate.assignments.keys {
            XCTAssertTrue(
                liveFactorIDs.contains(key),
                "painted into factor \(key), which is not in the layout any more"
            )
        }
    }

    func testUndoingAddFactorLeavesAValidActiveFactor() {
        let undo = freshUndoManager()
        editor.addFactor()
        let added = editor.activeFactorID
        undo.undo()

        XCTAssertNotEqual(editor.activeFactorID, added)
        XCTAssertNotNil(editor.activeFactor)
        XCTAssertNotNil(editor.armedLevel)
    }

    func testUndoingAPlateShrinkReclampsTheSelection() {
        editor.setFormat(.well384)
        editor.selection = WellRange(anchor: WellPos(row: 12, col: 20), focus: WellPos(row: 14, col: 22))
        let undo = freshUndoManager()
        editor.setFormat(.well96)                     // clamps on the way down
        undo.undo()                                   // back to 384
        undo.redo()                                   // and down again

        XCTAssertEqual(editor.format, .well96)
        if let selection = editor.selection {
            XCTAssertLessThan(selection.maxRow, editor.format.rows,
                              "selection should not outlive the bigger plate")
            XCTAssertLessThan(selection.maxCol, editor.format.cols)
        }
    }

    /// Escape means "select without painting"; a revert should not quietly re-arm.
    func testRevertingKeepsTheUserDisarmed() {
        paint([0], 0)
        editor.saveState()
        paint([1], 2)
        editor.disarmLevel()

        editor.revertToLatestState()
        XCTAssertNil(editor.armedLevelID, "reverting should not re-arm a deliberately disarmed level")
    }

    func testRevertingStillReArmsAStaleLevel() {
        editor.addFactor()
        editor.saveState()
        let armed = editor.armedLevelID
        XCTAssertNotNil(armed)
        editor.deleteFactor(editor.activeFactorID!)   // takes the armed level with it
        editor.revertToLatestState()
        XCTAssertNotNil(editor.armedLevel, "a level that no longer exists should be replaced")
    }

    // MARK: - Persistence

    func testSavedStatesSurviveADocumentRoundTrip() throws {
        paint([0, 1], 0)
        editor.saveState()

        let data = try JSONEncoder().encode(document.layout)
        let decoded = try JSONDecoder().decode(Layout.self, from: data)
        XCTAssertEqual(decoded, document.layout)
        XCTAssertEqual(decoded.snapshots.count, 1)
        XCTAssertEqual(decoded.snapshots[0].name, "State 1")
        XCTAssertEqual(decoded.snapshots[0].plates[0].assignments.count, 1)
    }

    /// Documents written before this feature existed must still open.
    func testDocumentWithoutSnapshotsStillOpens() throws {
        let json = """
        { "formatVersion": 1, "factors": [], "plates": [],
          "padWellLabels": false, "notes": "" }
        """
        let layout = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        XCTAssertTrue(layout.snapshots.isEmpty)
    }

    func testSnapshotsDoNotNest() throws {
        editor.saveState()
        editor.saveState()
        let data = try JSONEncoder().encode(document.layout)
        let text = String(decoding: data, as: UTF8.self)
        // A snapshot storing a whole Layout would recurse and the key would appear
        // inside the snapshot objects as well.
        XCTAssertEqual(text.components(separatedBy: "\"snapshots\"").count - 1, 1)
    }
}

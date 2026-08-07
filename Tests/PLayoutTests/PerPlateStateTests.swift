import AppKit
import XCTest
@testable import PLayout

/// A saved state bookmarks one plate. Before this, a document with three plates showed
/// one shared list and reverting rewrote all three — which is not what "go back to how
/// Plate 2 looked" means.
final class PerPlateStateTests: XCTestCase {

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

    private func levelName(plate: Int, well: Int) -> String? {
        let plate = document.layout.plates[plate]
        return factor.level(id: plate.levelID(factor: factor.id, well: well))?.name
    }

    /// Two plates, each with something painted and a state of its own.
    private func twoPlatesEachSaved() -> (first: UUID, second: UUID) {
        let first = editor.activePlateID!
        paint([0, 1, 2], 0)
        editor.saveState()

        editor.addPlate()
        let second = editor.activePlateID!
        paint([10, 11], 1)
        editor.saveState()
        return (first, second)
    }

    // MARK: - The list follows the plate

    func testEachPlateSeesOnlyItsOwnStates() {
        let plates = twoPlatesEachSaved()
        XCTAssertEqual(document.layout.snapshots.count, 2, "both states should exist in the file")

        editor.activePlateID = plates.first
        XCTAssertEqual(editor.savedStates.count, 1)
        XCTAssertEqual(editor.savedStates.first?.plateID, plates.first)

        editor.activePlateID = plates.second
        XCTAssertEqual(editor.savedStates.count, 1)
        XCTAssertEqual(editor.savedStates.first?.plateID, plates.second)
    }

    /// Numbered per plate, since that is the list they appear in — two plates should not
    /// read "State 1" and "State 2" for their first save each.
    func testStatesAreNumberedWithinTheirOwnPlate() {
        let plates = twoPlatesEachSaved()
        editor.activePlateID = plates.first
        XCTAssertEqual(editor.savedStates.map(\.name), ["State 1"])
        editor.activePlateID = plates.second
        XCTAssertEqual(editor.savedStates.map(\.name), ["State 1"])
    }

    func testAStateOnlyEverHoldsItsOwnPlate() {
        _ = twoPlatesEachSaved()
        for state in document.layout.snapshots {
            XCTAssertEqual(state.plates.count, 1, "\(state.name) captured more than its plate")
            XCTAssertEqual(state.plates.first?.id, state.plateID)
        }
    }

    // MARK: - Reverting stays on its own plate

    func testRevertingOnePlateLeavesTheOtherAlone() {
        let plates = twoPlatesEachSaved()

        // Move both on from where they were saved.
        editor.activePlateID = plates.first
        paint([5], 1)
        editor.activePlateID = plates.second
        paint([20], 0)
        let secondBefore = document.layout.plates[1]

        editor.activePlateID = plates.first
        editor.revertToLatestState()

        XCTAssertNil(levelName(plate: 0, well: 5), "the reverted plate kept a later edit")
        XCTAssertEqual(document.layout.plates[1], secondBefore, "reverting one plate rewrote another")
    }

    /// The bookmark is per plate, so it has to change when the plate does — even though
    /// the document itself has not moved at all.
    func testTheBookmarkFollowsTheSelectedPlate() {
        let plates = twoPlatesEachSaved()

        editor.activePlateID = plates.first
        XCTAssertTrue(editor.currentDesignIsSaved)

        editor.activePlateID = plates.second
        XCTAssertTrue(editor.currentDesignIsSaved, "the second plate is saved too")

        paint([30], 0)
        XCTAssertFalse(editor.currentDesignIsSaved, "editing should empty the bookmark")

        editor.activePlateID = plates.first
        XCTAssertTrue(editor.currentDesignIsSaved, "the first plate is still saved")
    }

    func testSavingTheSamePlateTwiceIsRefused() {
        _ = editor.activePlateID
        paint([0], 0)
        editor.saveState()
        editor.saveState()
        XCTAssertEqual(document.layout.snapshots.count, 1)
        XCTAssertTrue(editor.transientMessage.contains("already saved"), editor.transientMessage)
    }

    /// The same layout on a *different* plate is a different state, and must still save.
    func testAnIdenticalLayoutOnAnotherPlateStillSaves() {
        paint([0], 0)
        editor.saveState()
        editor.addPlate()
        paint([0], 0)
        editor.saveState()
        XCTAssertEqual(document.layout.snapshots.count, 2)
    }

    func testRevertingToTheLatestUsesThisPlatesLatest() {
        let plates = twoPlatesEachSaved()
        editor.activePlateID = plates.first
        paint([7], 1)
        editor.revertToLatestState()
        XCTAssertNil(levelName(plate: 0, well: 7))
        XCTAssertTrue(editor.transientMessage.contains("Reverted"), editor.transientMessage)
    }

    func testAPlateWithNoStatesSaysSoRatherThanRevertingSomethingElse() {
        _ = twoPlatesEachSaved()
        editor.addPlate()
        XCTAssertTrue(editor.savedStates.isEmpty)
        editor.revertToLatestState()
        XCTAssertTrue(editor.transientMessage.contains("No saved states"), editor.transientMessage)
    }

    // MARK: - Older files

    /// `LayoutSnapshot` gained a field, and its decoder is hand-written for exactly the
    /// reason `Layout`'s is — a synthesized one would reject every document that already
    /// had saved states.
    func testAStateWrittenBeforeThisFeatureStillOpens() throws {
        let plateID = UUID()
        let json = """
        {"id":"\(UUID().uuidString)","name":"State 1","savedAt":0,
         "factors":[],"plates":[{"id":"\(plateID.uuidString)","name":"Plate 1",
         "format":{"rows":8,"cols":12},"assignments":{}}]}
        """
        let decoded = try JSONDecoder().decode(LayoutSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "State 1")
        // One plate, so it is adopted by it rather than left as a whole-document state.
        XCTAssertEqual(decoded.plateID, plateID)
    }

    func testAnOldMultiPlateStateStaysAWholeDocumentOne() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Everything","savedAt":0,"factors":[],
         "plates":[{"id":"\(UUID().uuidString)","name":"A","format":{"rows":8,"cols":12},"assignments":{}},
                   {"id":"\(UUID().uuidString)","name":"B","format":{"rows":8,"cols":12},"assignments":{}}]}
        """
        let decoded = try JSONDecoder().decode(LayoutSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(decoded.plateID)
        // With no plate of its own it belongs to whichever one is showing, so it stays
        // reachable rather than disappearing from every list.
        XCTAssertTrue(decoded.belongs(to: UUID()))
    }
}

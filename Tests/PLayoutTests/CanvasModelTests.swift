import XCTest
@testable import PLayout

/// The board's document state. The rules worth pinning are all about what it must *not*
/// do: not dirty a file that was only looked at, not disturb saved states, and not change
/// a document that never used it.
final class CanvasModelTests: XCTestCase {

    private func multiPlate() -> (PlateDocument, PlateEditor) {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addPlate()
        editor.addPlate()
        return (document, editor)
    }

    // MARK: - The file format

    func testADocumentWithNoBoardEncodesExactlyAsBefore() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(String(data: try encoder.encode(Layout.starter()), encoding: .utf8))
        XCTAssertFalse(json.contains("\"canvas\""), json)
    }

    func testADocumentSavedBeforeTheBoardStillOpens() throws {
        let legacy = """
        { "formatVersion": 1, "notes": "", "padWellLabels": false,
          "factors": [], "plates": [] }
        """
        let layout = try JSONDecoder().decode(Layout.self, from: Data(legacy.utf8))
        XCTAssertNil(layout.canvas)
    }

    func testTheBoardRoundTripsInItsSavedOrder() throws {
        var layout = Layout.starter()
        let plateID = layout.plates[0].id
        layout.canvas = CanvasLayout(items: [
            CanvasItem(kind: .note, frame: CanvasFrame(x: 10, y: 20, width: 200, height: 150), text: "check"),
            CanvasItem(kind: .plate, plateID: plateID, frame: CanvasFrame(x: 300, y: 40, width: 560, height: 420)),
            CanvasItem(kind: .prep, frame: CanvasFrame(x: 900, y: 40, width: 620, height: 520)),
        ])

        let decoded = try JSONDecoder().decode(Layout.self, from: try JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(
            decoded.canvas?.items.map(\.kind), [.note, .plate, .prep],
            "array order is z-order and has to survive a round trip"
        )
    }

    /// A dictionary keyed by plate would iterate differently on every launch, so
    /// overlapping cards would restack themselves between openings.
    func testTheOrderIsStableAcrossManyDecodes() throws {
        var layout = Layout.starter()
        layout.canvas = CanvasLayout(items: (0..<8).map { index in
            CanvasItem(kind: .note, frame: CanvasFrame(x: Double(index), y: 0, width: 200, height: 150),
                       text: "note \(index)")
        })
        let data = try JSONEncoder().encode(layout)
        let first = try JSONDecoder().decode(Layout.self, from: data).canvas?.items.map(\.text)
        for _ in 0..<20 {
            XCTAssertEqual(try JSONDecoder().decode(Layout.self, from: data).canvas?.items.map(\.text), first)
        }
    }

    func testAPartialItemTakesTheDefaultsAndAnUnknownKindIsDropped() throws {
        let json = """
        { "formatVersion": 1, "factors": [], "plates": [], "padWellLabels": false, "notes": "",
          "canvas": { "items": [
            { "kind": "note", "frame": { "x": 5 } },
            { "kind": "someFutureThing", "frame": { "x": 0, "y": 0, "width": 10, "height": 10 } },
            { "kind": "prep" }
          ] } }
        """
        let layout = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        let items = try XCTUnwrap(layout.canvas?.items)
        XCTAssertEqual(items.map(\.kind), [.note, .prep], "an unknown kind is dropped, not thrown on")
        XCTAssertEqual(items[0].frame.x, 5)
        XCTAssertEqual(items[0].frame.y, 0, "a missing number takes its default")
        XCTAssertEqual(items[0].frame.width, 560)
    }

    // MARK: - What it must not disturb

    func testLookingAtTheBoardIsNotAnEdit() {
        let (document, editor) = multiPlate()
        let undo = UndoManager()
        editor.undoManager = undo

        editor.toggleCanvas()
        XCTAssertTrue(editor.showsCanvas)
        XCTAssertEqual(editor.canvasItems.count, 3, "three plates, all auto-placed")
        XCTAssertNil(document.layout.canvas, "auto-placement is computed, never written")
        XCTAssertFalse(undo.canUndo, "opening the board is not an edit")
    }

    /// `Layout.snapshotMatching` compares whole `Plate` values, so a card frame stored on
    /// `Plate` would empty the saved-state bookmark every time a card was nudged.
    func testMovingACardDoesNotDisturbTheSavedStateMatch() {
        let (document, editor) = multiPlate()
        editor.saveState()
        XCTAssertNotNil(editor.matchingSavedStateID, "the design should match the state just saved")

        let card = editor.canvasItems[0]
        editor.setCanvasFrame(card.id, to: CGRect(x: 900, y: 700, width: 560, height: 420))

        XCTAssertNotNil(
            editor.matchingSavedStateID,
            "moving a card is not a change to the design"
        )
        XCTAssertNotNil(document.layout.canvas)
    }

    func testMovingACardIsOneUndoStepAndFreezesTheRest() {
        let (document, editor) = multiPlate()
        let before = editor.canvasItems
        let undo = UndoManager()
        editor.undoManager = undo

        editor.setCanvasFrame(before[0].id, to: CGRect(x: 900, y: 700, width: 560, height: 420))
        let saved = try? XCTUnwrap(document.layout.canvas?.items)
        XCTAssertEqual(saved?.count, 3, "the first deliberate move freezes every card where it appears")
        XCTAssertEqual(saved?.first { $0.id == before[0].id }?.frame.x, 900)
        // Moving a card also raises it, so it is last — array order is z-order.
        XCTAssertEqual(saved?.last?.id, before[0].id)
        // The others must be exactly where they already were, not re-placed around the move.
        XCTAssertEqual(saved?.first { $0.id == before[1].id }?.frame, before[1].frame)

        undo.undo()
        XCTAssertNil(document.layout.canvas)
    }

    func testDeletingAPlateHidesItsCardAndUndoBringsItBack() {
        let (document, editor) = multiPlate()
        let plateID = document.layout.plates[1].id
        editor.setCanvasFrame(plateID, to: CGRect(x: 40, y: 900, width: 560, height: 420))

        let undo = UndoManager()
        editor.undoManager = undo
        editor.deletePlate(plateID)

        XCTAssertFalse(
            editor.canvasItems.contains { $0.plateID == plateID },
            "a card for a plate that is gone is not shown"
        )
        undo.undo()
        let restored = editor.canvasItems.first { $0.plateID == plateID }
        XCTAssertEqual(restored?.frame.y, 900, "undo puts the plate and its place back together")
    }

    // MARK: - Each plate keeps its own selection

    /// The board shows several plates at once, so a selection that followed you from
    /// plate to plate read as every plate sharing one.
    func testEachPlateKeepsItsOwnSelection() {
        let (document, editor) = multiPlate()
        let first = document.layout.plates[0].id
        let second = document.layout.plates[1].id

        editor.activePlateID = first
        editor.select(WellRange(anchor: WellPos(row: 2, col: 2), focus: WellPos(row: 4, col: 5)))

        editor.activePlateID = second
        XCTAssertEqual(
            editor.selection, WellRange(single: WellPos(row: 0, col: 0)),
            "a plate you have not touched starts at A1, not wherever you were on another"
        )

        editor.select(WellRange(single: WellPos(row: 7, col: 9)))
        editor.activePlateID = first
        XCTAssertEqual(editor.selection?.minRow, 2, "the first plate's selection came back")
        XCTAssertEqual(editor.selection?.maxCol, 5)

        editor.activePlateID = second
        XCTAssertEqual(editor.selection, WellRange(single: WellPos(row: 7, col: 9)))
    }

    /// A ⌘-click selection belongs to its plate too.
    func testADiscontiguousSelectionIsAlsoPerPlate() {
        let (document, editor) = multiPlate()
        let first = document.layout.plates[0].id
        editor.activePlateID = first
        // ⌘-click adds to what is already selected, and a plate opens with A1 selected,
        // so this is A1 plus the two toggled wells.
        editor.toggleWell(WellPos(row: 1, col: 1))
        editor.toggleWell(WellPos(row: 3, col: 3))
        XCTAssertEqual(editor.customWells?.count, 3)

        editor.activePlateID = document.layout.plates[1].id
        XCTAssertNil(editor.customWells, "the other plate has no ⌘-click selection of its own")

        editor.activePlateID = first
        XCTAssertEqual(editor.customWells?.count, 3)
    }

    // MARK: - Notes

    func testANoteIsAddedEditedAndEmptiedAway() {
        let (document, editor) = multiPlate()
        let point = CGPoint(x: 100, y: 100)
        editor.addCanvasNote(at: point)
        XCTAssertEqual(editor.noteTarget, .newCanvasNote(point), "asking for one opens it for typing")

        editor.saveNote("thaw cells first", for: .newCanvasNote(point))
        let note = try? XCTUnwrap(document.layout.canvas?.items.last)
        XCTAssertEqual(note?.kind, .note)
        XCTAssertEqual(document.layout.canvas?.items.last?.text, "thaw cells first")

        // An emptied sticky note is a removed one, exactly as an emptied well note is.
        editor.saveNote("  ", for: .canvasNote(note!.id))
        XCTAssertFalse(document.layout.canvas?.items.contains { $0.id == note!.id } ?? false)
    }

    func testOnlyNotesCanBeDeleted() {
        let (document, editor) = multiPlate()
        let plateCard = try? XCTUnwrap(editor.canvasItems.first { $0.kind == .plate })
        editor.deleteCanvasItem(plateCard!.id)
        XCTAssertEqual(editor.canvasItems.filter { $0.kind == .plate }.count, 3,
                       "a plate's card is the plate; hiding it would be a way to lose one")
        XCTAssertEqual(document.layout.plates.count, 3)
    }

    // MARK: - Closing and re-adding

    /// Closing a card takes it off the board. It must not touch the plate itself — that
    /// would be a way to lose a plate by tidying up.
    func testClosingAPlateCardHidesItWithoutDeletingThePlate() {
        let (document, editor) = multiPlate()
        let card = try? XCTUnwrap(editor.canvasItems.first { $0.kind == .plate })
        let plateID = try? XCTUnwrap(card?.plateID)

        editor.closeCanvasItem(card!.id)
        XCTAssertEqual(document.layout.plates.count, 3, "the plate itself is untouched")
        XCTAssertFalse(editor.canvasItems.contains { $0.plateID == plateID })
        XCTAssertEqual(document.layout.canvas?.dismissedPlates, [plateID!])
    }

    func testDroppingItsTabBackPutsTheCardWhereItWasDropped() {
        let (document, editor) = multiPlate()
        let card = try? XCTUnwrap(editor.canvasItems.first { $0.kind == .plate })
        let plateID = try? XCTUnwrap(card?.plateID)
        editor.closeCanvasItem(card!.id)

        editor.placeOnCanvas(plateID: plateID!, at: CGPoint(x: 700, y: 500))
        let back = try? XCTUnwrap(editor.canvasItems.first { $0.plateID == plateID })
        XCTAssertEqual(back?.frame.x, 700)
        XCTAssertEqual(back?.frame.y, 500)
        XCTAssertEqual(document.layout.canvas?.dismissedPlates, [], "it is no longer dismissed")
        XCTAssertEqual(editor.activePlateID, plateID, "and it becomes the plate you are editing")
    }

    func testClosingThePrepCardHidesOnlyThePrepCard() {
        let (document, editor) = multiPlate()
        editor.setFactorIsDilution(document.layout.factors[0].id, true)
        let prep = try? XCTUnwrap(editor.canvasItems.first { $0.kind == .prep })

        editor.closeCanvasItem(prep!.id)
        XCTAssertFalse(editor.canvasItems.contains { $0.kind == .prep })
        XCTAssertEqual(editor.canvasItems.filter { $0.kind == .plate }.count, 3)
        XCTAssertNotNil(
            document.layout.factors[0].dilution,
            "the factor is still one you make by dilution — only its card went"
        )
    }

    /// A closed card has to stay closed through whatever you do to the board next.
    ///
    /// Every board edit rewrites `layout.canvas`, and rebuilding one from its items alone
    /// silently resets what else it remembers — so adding a note, or any other edit that
    /// only touches the items, used to bring every closed card back.
    func testAClosedCardStaysClosedThroughTheNextBoardEdit() {
        let (document, editor) = multiPlate()
        let card = editor.canvasItems.first { $0.kind == .plate }!
        let plateID = card.plateID!
        editor.closeCanvasItem(card.id)
        XCTAssertFalse(editor.canvasItems.contains { $0.plateID == plateID })

        editor.addCanvasNote(at: CGPoint(x: 40, y: 40))
        editor.saveNote("note", for: .newCanvasNote(CGPoint(x: 40, y: 40)))
        XCTAssertFalse(editor.canvasItems.contains { $0.plateID == plateID },
                       "adding a note brought a closed card back")
        XCTAssertEqual(document.layout.canvas?.dismissedPlates, [plateID])

        let note = editor.canvasItems.first { $0.kind == .note }!
        editor.saveNote("hello", for: PlateEditor.NoteTarget.canvasNote(note.id))
        XCTAssertFalse(editor.canvasItems.contains { $0.plateID == plateID },
                       "editing a note brought a closed card back")

        editor.deleteCanvasItem(note.id)
        XCTAssertFalse(editor.canvasItems.contains { $0.plateID == plateID },
                       "deleting a note brought a closed card back")

        let other = editor.canvasItems.first { $0.kind == .plate }!
        editor.bringCanvasItemToFront(other.id)
        XCTAssertFalse(editor.canvasItems.contains { $0.plateID == plateID },
                       "raising a card brought a closed card back")
    }

    /// Asking for a note and then cancelling must leave no trace. Creating the note up
    /// front left a blank sticky behind on Escape — and, because writing the board freezes
    /// every auto-placed card where it happens to be, that cancelled gesture also froze
    /// the whole arrangement into a document that autosaves in place.
    func testAskingForANoteAndCancellingChangesNothing() {
        let (document, editor) = multiPlate()
        let undo = UndoManager()
        editor.undoManager = undo

        editor.addCanvasNote(at: CGPoint(x: 40, y: 40))
        XCTAssertEqual(editor.noteTarget, .newCanvasNote(CGPoint(x: 40, y: 40)))
        XCTAssertNil(document.layout.canvas, "nothing is written until something is typed")
        XCTAssertFalse(undo.canUndo)

        // Cancelling is the sheet simply going away; saving it empty is the same thing.
        editor.saveNote("   ", for: .newCanvasNote(CGPoint(x: 40, y: 40)))
        XCTAssertNil(document.layout.canvas)
        XCTAssertFalse(editor.canvasItems.contains { $0.kind == .note })
    }

    /// And writing one is a single undo step, not an empty note followed by its text.
    func testWritingANoteIsOneStep() {
        let (document, editor) = multiPlate()
        let undo = UndoManager()
        editor.undoManager = undo

        editor.addCanvasNote(at: CGPoint(x: 60, y: 80))
        editor.saveNote("seed 5k", for: .newCanvasNote(CGPoint(x: 60, y: 80)))

        let note = editor.canvasItems.first { $0.kind == .note }
        XCTAssertEqual(note?.text, "seed 5k")
        XCTAssertEqual(note?.frame.x, 60)

        undo.undo()
        XCTAssertFalse(editor.canvasItems.contains { $0.kind == .note },
                       "one undo should take the note away, not leave an empty one")
        XCTAssertNil(document.layout.canvas)
    }

    /// Closing the card of the plate you are editing has to hand editing to a card that
    /// is still there. Otherwise the sidebar, the keyboard and the status bar all point
    /// at a plate with nothing on screen to show it.
    func testClosingTheActivePlatesCardHandsEditingToOneStillOnTheBoard() {
        let (document, editor) = multiPlate()
        let active = document.layout.plates[1].id
        editor.activePlateID = active
        let card = editor.canvasItems.first { $0.plateID == active }!

        editor.closeCanvasItem(card.id)

        XCTAssertNotEqual(editor.activePlateID, active)
        XCTAssertTrue(
            editor.canvasItems.contains { $0.kind == .plate && $0.plateID == editor.activePlateID },
            "the plate being edited must be one you can see"
        )
    }

    /// And closing someone else's card must not steal editing away from where you were.
    func testClosingAnotherCardLeavesYouOnThePlateYouWereEditing() {
        let (document, editor) = multiPlate()
        let mine = document.layout.plates[0].id
        editor.activePlateID = mine
        let other = editor.canvasItems.first { $0.plateID == document.layout.plates[2].id }!

        editor.closeCanvasItem(other.id)
        XCTAssertEqual(editor.activePlateID, mine)
    }

    /// And the same for the prep card, which is remembered by a different field.
    func testAClosedPrepCardStaysClosedThroughTheNextBoardEdit() {
        let (document, editor) = multiPlate()
        editor.setFactorIsDilution(document.layout.factors[0].id, true)
        let prep = editor.canvasItems.first { $0.kind == .prep }!
        editor.closeCanvasItem(prep.id)

        editor.addCanvasNote(at: CGPoint(x: 40, y: 40))
        editor.saveNote("note", for: .newCanvasNote(CGPoint(x: 40, y: 40)))
        XCTAssertFalse(editor.canvasItems.contains { $0.kind == .prep },
                       "adding a note brought the prep card back")
        XCTAssertEqual(document.layout.canvas?.hidesPrep, true)
    }

    /// A plate can shrink while its selection is parked, so the selection has to be
    /// clamped on the way back in. Out of range it draws as nothing at all while still
    /// painting when a key is pressed — an invisible selection acting on a well you
    /// never chose.
    func testAParkedSelectionIsClampedToThePlateItComesBackTo() throws {
        let (document, editor) = multiPlate()
        let first = document.layout.plates[0].id
        let second = document.layout.plates[1].id

        document.layout.plates[0].changeFormat(to: PlateFormat(rows: 32, cols: 48))
        editor.activePlateID = first
        editor.select(WellRange(single: WellPos(row: 31, col: 47)))
        editor.activePlateID = second

        // Shrunk while parked — an undone format change does exactly this.
        document.layout.plates[0].changeFormat(to: .well96)
        editor.activePlateID = first

        let format = document.layout.plates[0].format
        let selection = try XCTUnwrap(editor.selection)
        XCTAssertLessThan(selection.maxRow, format.rows)
        XCTAssertLessThan(selection.maxCol, format.cols)
    }

    // MARK: - Turning one plate

    /// Orientation is how you are looking at a plate, not part of its design — the same
    /// reason the board's layout was kept off `Plate`. Riding inside the snapshot, it
    /// emptied the saved-state bookmark for a picture that had not changed.
    func testTurningAPlateAndTurningItBackKeepsTheSavedStateMatch() {
        let (document, editor) = multiPlate()
        editor.activePlateID = document.layout.plates[0].id
        editor.saveState()
        XCTAssertNotNil(editor.matchingSavedStateID, "the design should match the state just saved")

        editor.rotatePlate()
        editor.rotatePlate()

        XCTAssertNil(document.layout.plates[0].orientation,
                     "back where it started, so it follows the document again")
        XCTAssertNotNil(editor.matchingSavedStateID,
                        "the picture is identical, so the bookmark must still be filled")
    }

    /// And a state that *is* saved while turned must not turn the plate back when
    /// reverted: reverting restores the design, never how you are looking at it.
    func testRevertingAStateDoesNotTurnThePlate() throws {
        let (document, editor) = multiPlate()
        editor.activePlateID = document.layout.plates[0].id
        editor.saveState()
        let state = try XCTUnwrap(document.layout.snapshots.last).id

        editor.rotatePlate()
        XCTAssertEqual(document.layout.plates[0].orientation, .turned)

        XCTAssertTrue(document.layout.restoreSnapshot(state))
        XCTAssertEqual(document.layout.plates[0].orientation, .turned,
                       "reverting changed how the plate is drawn")
    }


    /// The board shows several plates at once, so standing a tall one on its end must not
    /// lie the 96-well beside it down as well.
    func testTurningOnePlateLeavesTheOthersAlone() {
        let (document, editor) = multiPlate()
        let first = document.layout.plates[0].id
        editor.activePlateID = first
        editor.rotatePlate()

        XCTAssertEqual(document.layout.plates[0].orientation, .turned)
        XCTAssertNil(document.layout.plates[1].orientation, "the others keep the document default")
        XCTAssertEqual(editor.quarterTurns, 1)

        editor.activePlateID = document.layout.plates[1].id
        XCTAssertEqual(editor.quarterTurns, 0, "and read their own turn, not the active one's")
    }

    func testBringingACardToTheFrontMovesItToTheEnd() {
        let (document, editor) = multiPlate()
        let first = editor.canvasItems[0].id
        editor.bringCanvasItemToFront(first)
        XCTAssertEqual(document.layout.canvas?.items.last?.id, first)
    }
}

/// Placement. Pure, so it is all assertions about rectangles.
final class CanvasArrangementTests: XCTestCase {

    private func plates(_ count: Int, format: PlateFormat = .well96) -> [Plate] {
        (0..<count).map { Plate(name: "Plate \($0 + 1)", format: format) }
    }

    func testAutoPlacementNeverOverlaps() {
        let items = CanvasArrangement.resolved(
            saved: nil, plates: plates(6), orientation: .automatic, includesPrep: true
        )
        XCTAssertEqual(items.count, 7)
        for (i, a) in items.enumerated() {
            for b in items[(i + 1)...] {
                XCTAssertFalse(
                    a.frame.rect.intersects(b.frame.rect),
                    "\(a.kind) at \(a.frame.rect) overlaps \(b.kind) at \(b.frame.rect)"
                )
            }
        }
    }

    func testAutoPlacementIsDeterministic() {
        let plates = plates(5)
        let a = CanvasArrangement.resolved(saved: nil, plates: plates, orientation: .automatic, includesPrep: false)
        let b = CanvasArrangement.resolved(saved: nil, plates: plates, orientation: .automatic, includesPrep: false)
        XCTAssertEqual(a.map(\.frame), b.map(\.frame), "same inputs must give the same board")
    }

    func testASavedFrameIsNeverMoved() {
        let plates = plates(3)
        let saved = CanvasLayout(items: [
            CanvasItem(id: plates[2].id, kind: .plate, plateID: plates[2].id,
                       frame: CanvasFrame(x: 1200, y: 900, width: 560, height: 420)),
        ])
        let items = CanvasArrangement.resolved(
            saved: saved, plates: plates, orientation: .automatic, includesPrep: false
        )
        let pinned = items.first { $0.plateID == plates[2].id }
        XCTAssertEqual(pinned?.frame.x, 1200)
        XCTAssertEqual(pinned?.frame.y, 900)
        XCTAssertEqual(items.count, 3, "the other two are placed around it")
    }

    /// A duplicated plate has no saved card, so it takes its own slot rather than landing
    /// exactly on top of the plate it was copied from.
    func testADuplicatedPlateGetsItsOwnSlot() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.duplicatePlate()
        let items = editor.canvasItems
        XCTAssertEqual(items.count, 2)
        XCTAssertNotEqual(items[0].frame.rect.origin, items[1].frame.rect.origin)
        XCTAssertFalse(items[0].frame.rect.intersects(items[1].frame.rect))
    }

    func testACardIsBigEnoughToDrawItsPlate() {
        for format in [PlateFormat.well96, .well384, .well1536] {
            let size = CanvasArrangement.size(forPlate: format, quarterTurns: 0)
            let geo = PlateGeometry(
                format: format,
                bounds: CGRect(origin: .zero, size: CGSize(
                    width: size.width, height: size.height - CanvasArrangement.titleBarHeight
                ))
            )
            XCTAssertGreaterThanOrEqual(
                geo.cell, 4,
                "\(format.name) cards must clear the hairline threshold, got \(geo.cell)"
            )
        }
    }

    func testATurnedPlateGetsATurnedCard() {
        let tall = PlateFormat(rows: 24, cols: 8)
        let upright = CanvasArrangement.size(forPlate: tall, quarterTurns: 0)
        let turned = CanvasArrangement.size(forPlate: tall, quarterTurns: 1)
        XCTAssertGreaterThan(upright.height, upright.width)
        XCTAssertGreaterThan(turned.width, turned.height)
    }

    func testTheExtentCoversEveryCardAndNeverGoesNegative() {
        let items = CanvasArrangement.resolved(
            saved: CanvasLayout(items: [
                CanvasItem(kind: .note, frame: CanvasFrame(x: 2000, y: 1500, width: 240, height: 180)),
            ]),
            plates: plates(2), orientation: .automatic, includesPrep: false
        )
        let extent = CanvasArrangement.extent(of: items)
        XCTAssertEqual(extent.minX, 0)
        XCTAssertEqual(extent.minY, 0)
        for item in items {
            XCTAssertTrue(extent.contains(item.frame.rect), "\(item.frame.rect) is off the board")
        }
    }
}

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
        editor.addCanvasNote(at: CGPoint(x: 100, y: 100))
        let note = try? XCTUnwrap(document.layout.canvas?.items.last)
        XCTAssertEqual(note?.kind, .note)
        XCTAssertEqual(editor.noteTarget, .canvasNote(note!.id), "adding one opens it for typing")

        editor.saveNote("thaw cells first", for: .canvasNote(note!.id))
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
        document.layout.factors[0].kind = .numeric
        editor.updatePrep { $0.doseFactorID = document.layout.factors[0].id }
        let prep = try? XCTUnwrap(editor.canvasItems.first { $0.kind == .prep })

        editor.closeCanvasItem(prep!.id)
        XCTAssertFalse(editor.canvasItems.contains { $0.kind == .prep })
        XCTAssertEqual(editor.canvasItems.filter { $0.kind == .plate }.count, 3)
        XCTAssertNotNil(document.layout.prep, "the prep setup itself survives")
    }

    // MARK: - Turning one plate

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

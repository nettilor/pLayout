import XCTest
import AppKit
@testable import PLayout

/// Copying a well with everything in it. `⌘C` takes the active factor as cells for
/// Excel; `⌥⌘C` takes the whole well — every factor — so a piece of a design can be
/// put down again somewhere else, including in another document.
final class WellClipboardTests: XCTestCase {

    private var document: PlateDocument!
    private var editor: PlateEditor!

    /// "Condition" (the starter factor) plus a numeric "Dose", painted over a 2×2
    /// block in the top-left corner: two factors, two values each, one blank.
    override func setUp() {
        super.setUp()
        document = PlateDocument()
        editor = PlateEditor(document: document)

        var dose = Factor(name: "Dose", kind: .numeric, unit: "µM")
        dose.levels = [
            Level(name: "10", colorHex: "#1B3A5C"),
            Level(name: "1", colorHex: "#AFC8DD"),
        ]
        document.layout.factors.append(dose)

        let condition = document.layout.factors[0]
        let format = document.layout.plates[0].format
        func paint(_ factor: UUID, _ level: UUID, row: Int, col: Int) {
            document.layout.plates[0].setLevelID(level, factor: factor, well: format.index(row: row, col: col))
        }
        paint(condition.id, condition.levels[0].id, row: 0, col: 0)   // Untreated
        paint(condition.id, condition.levels[1].id, row: 0, col: 1)   // Vehicle
        paint(condition.id, condition.levels[2].id, row: 1, col: 0)   // Treated
        // (1,1) is left unpainted for Condition on purpose — a blank is part of a design.
        paint(dose.id, dose.levels[0].id, row: 0, col: 0)
        paint(dose.id, dose.levels[1].id, row: 0, col: 1)
        paint(dose.id, dose.levels[0].id, row: 1, col: 0)
        paint(dose.id, dose.levels[1].id, row: 1, col: 1)
    }

    private var block: WellRange {
        WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 1, col: 1))
    }

    private func name(_ layout: Layout, factor: String, row: Int, col: Int, plate: Int = 0) -> String? {
        guard let factor = layout.factors.first(where: { $0.name == factor }) else { return nil }
        let format = layout.plates[plate].format
        let id = layout.plates[plate].levelID(factor: factor.id, well: format.index(row: row, col: col))
        return factor.level(id: id)?.name
    }

    private func select(_ range: WellRange) {
        editor.selection = range
        editor.customWells = nil
    }

    // MARK: - Capture

    func testCaptureTakesEveryFactorAndKeepsTheBlanks() {
        let clip = WellClipboard.capture(
            plate: document.layout.plates[0], factors: document.layout.factors, range: block
        )
        XCTAssertEqual(clip.rows, 2)
        XCTAssertEqual(clip.cols, 2)
        XCTAssertEqual(clip.factors.map(\.name), ["Condition", "Dose"])
        XCTAssertEqual(clip.value(factor: 0, row: 0, col: 1), "Vehicle")
        XCTAssertEqual(clip.value(factor: 1, row: 1, col: 1), "1")
        XCTAssertNil(clip.value(factor: 0, row: 1, col: 1), "an unpainted well travels as unpainted")
        XCTAssertEqual(clip.factors[1].unit, "µM", "the unit comes along for a factor being created")
        XCTAssertEqual(clip.factors[0].colors["Vehicle"], document.layout.factors[0].levels[1].colorHex)
    }

    /// Everything that is not pLayout gets one readable cell per well, which is the
    /// same shape as the workbook's one-cell plate map.
    func testTheTextFlavourJoinsTheFactorsPerWell() {
        let clip = WellClipboard.capture(
            plate: document.layout.plates[0], factors: document.layout.factors, range: block
        )
        let grid = clip.joinedGrid(separator: "+")
        XCTAssertEqual(grid[0][0], "Untreated+10")
        XCTAssertEqual(grid[1][1], "1", "a well with one value has nothing to join it to")
    }

    // MARK: - Paste, same document

    func testPastingRebuildsEveryFactorAtTheNewCorner() {
        select(block)
        editor.copyWells()
        select(WellRange(single: WellPos(row: 4, col: 5)))
        editor.pasteWells()

        let layout = document.layout
        XCTAssertEqual(name(layout, factor: "Condition", row: 4, col: 5), "Untreated")
        XCTAssertEqual(name(layout, factor: "Dose", row: 4, col: 5), "10")
        XCTAssertEqual(name(layout, factor: "Condition", row: 4, col: 6), "Vehicle")
        XCTAssertEqual(name(layout, factor: "Dose", row: 5, col: 6), "1")
        XCTAssertNil(name(layout, factor: "Condition", row: 5, col: 6), "the copied blank stays blank")
        XCTAssertEqual(layout.factors.count, 2, "nothing new to create inside one document")
        XCTAssertEqual(
            layout.factors[0].levels.count, 3, "an existing condition is matched, not duplicated"
        )
    }

    /// A blank in the block is a value like any other: it clears what was there.
    func testACopiedBlankClearsTheWellItLandsOn() {
        let condition = document.layout.factors[0]
        let format = document.layout.plates[0].format
        document.layout.plates[0].setLevelID(
            condition.levels[0].id, factor: condition.id, well: format.index(row: 5, col: 6)
        )
        select(block)
        editor.copyWells()
        select(WellRange(single: WellPos(row: 4, col: 5)))
        editor.pasteWells()

        XCTAssertNil(name(document.layout, factor: "Condition", row: 5, col: 6))
    }

    func testPasteIsClippedToThePlateAndSaysHowMuchLanded() {
        select(block)
        editor.copyWells()
        let format = document.layout.plates[0].format
        select(WellRange(single: WellPos(row: format.rows - 1, col: format.cols - 1)))
        editor.pasteWells()

        XCTAssertEqual(
            name(document.layout, factor: "Condition", row: format.rows - 1, col: format.cols - 1),
            "Untreated"
        )
        XCTAssertTrue(editor.transientMessage.contains("Pasted 1 well"), editor.transientMessage)
    }

    /// However many factors and conditions it had to create, a paste is one ⌘Z.
    func testPasteIsASingleUndoStep() {
        select(block)
        editor.copyWells()

        // Attached after setup, or every edit above would coalesce into this group.
        let undo = UndoManager()
        editor.undoManager = undo

        select(WellRange(single: WellPos(row: 4, col: 5)))
        editor.pasteWells()
        XCTAssertEqual(name(document.layout, factor: "Condition", row: 4, col: 5), "Untreated")

        undo.undo()
        XCTAssertNil(name(document.layout, factor: "Condition", row: 4, col: 5))
        XCTAssertEqual(name(document.layout, factor: "Condition", row: 0, col: 0), "Untreated",
                       "the original block is untouched")
    }

    /// Escape disarms the brush so a click selects without painting, and moving a
    /// design around in chunks is exactly that: select, copy, select, paste, again.
    /// A paste that armed the first condition made the next click paint the plate.
    func testPasteLeavesADisarmedBrushDisarmed() {
        select(block)
        editor.copyWells()
        editor.disarmLevel()
        XCTAssertNil(editor.armedLevelID)

        select(WellRange(single: WellPos(row: 4, col: 5)))
        editor.pasteWells()
        XCTAssertEqual(name(document.layout, factor: "Condition", row: 4, col: 5), "Untreated")
        XCTAssertNil(editor.armedLevelID, "the paste armed a condition nobody asked for")

        // The plain paste of text values keeps the same promise.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Vehicle\tTreated", forType: .string)
        editor.pasteFromPasteboard()
        XCTAssertEqual(name(document.layout, factor: "Condition", row: 4, col: 6), "Treated")
        XCTAssertNil(editor.armedLevelID)
    }

    /// The other half of the rule: a brush pointing at a condition the active factor
    /// no longer has is put back on something real, as it always was.
    func testPasteStillReplacesAStaleBrush() {
        select(block)
        editor.copyWells()
        editor.armedLevelID = UUID()

        select(WellRange(single: WellPos(row: 4, col: 5)))
        editor.pasteWells()
        XCTAssertEqual(editor.armedLevelID, editor.activeFactor?.levels.first?.id)
    }

    // MARK: - Paste, another document

    func testPastingIntoAnotherDocumentCreatesWhatItIsMissing() {
        select(block)
        editor.copyWells()

        let other = PlateDocument()
        let otherEditor = PlateEditor(document: other)
        // A fresh document has "Condition" with the same three names, and no "Dose".
        otherEditor.selection = WellRange(single: WellPos(row: 2, col: 2))
        otherEditor.pasteWells()

        let layout = other.layout
        XCTAssertEqual(layout.factors.count, 2, "Dose should have been created here")
        XCTAssertEqual(layout.factors[1].name, "Dose")
        XCTAssertEqual(layout.factors[1].unit, "µM")
        XCTAssertEqual(layout.factors[1].kind, .numeric)
        XCTAssertEqual(name(layout, factor: "Dose", row: 2, col: 2), "10")
        XCTAssertEqual(name(layout, factor: "Condition", row: 2, col: 2), "Untreated")
        XCTAssertEqual(
            layout.factors[0].levels.count, 3,
            "the names already existed here, so they are matched rather than added"
        )
    }

    func testACreatedConditionKeepsTheColourItWasCopiedWith() {
        // A value the receiving document has never seen, so it has to be created.
        let condition = document.layout.factors[0]
        document.layout.factors[0].levels.append(Level(name: "Positive control", colorHex: "#7B2D8E"))
        let created = document.layout.factors[0].levels.last!
        let format = document.layout.plates[0].format
        document.layout.plates[0].setLevelID(
            created.id, factor: condition.id, well: format.index(row: 0, col: 0)
        )

        select(block)
        editor.copyWells()

        let other = PlateDocument()
        let otherEditor = PlateEditor(document: other)
        otherEditor.selection = WellRange(single: WellPos(row: 0, col: 0))
        otherEditor.pasteWells()

        let arrived = other.layout.factors[0].levels.first { $0.name == "Positive control" }
        XCTAssertEqual(arrived?.colorHex, "#7B2D8E")
    }

    // MARK: - What it refuses

    func testCopyRefusesADiscontiguousSelection() {
        editor.customWells = [WellPos(row: 0, col: 0), WellPos(row: 3, col: 5)]
        NSPasteboard.general.clearContents()
        editor.copyWells()

        XCTAssertNil(WellClipboard.read())
        XCTAssertTrue(editor.transientMessage.contains("rectangular"), editor.transientMessage)
    }

    func testPasteIsRefusedInOverviewLikeEveryOtherEdit() {
        select(block)
        editor.copyWells()
        editor.setWellLabelMode(.overview)
        select(WellRange(single: WellPos(row: 4, col: 5)))
        editor.pasteWells()

        XCTAssertNil(name(document.layout, factor: "Condition", row: 4, col: 5))
        XCTAssertFalse(editor.transientMessage.isEmpty, "a key that does nothing has to say so")
    }

    func testPasteWithoutACopiedBlockSaysSoRatherThanDoingNothing() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Untreated\tVehicle", forType: .string)
        editor.pasteWells()

        XCTAssertTrue(editor.transientMessage.contains("Copy Wells"), editor.transientMessage)
    }

    // MARK: - ⌘V

    /// The plain paste has to notice a block of wells on the pasteboard, or it would
    /// paint the active factor with the joined text sitting beside it for Excel.
    func testPlainPasteTakesTheWholeBlockWhenThereIsOne() {
        select(block)
        editor.copyWells()
        select(WellRange(single: WellPos(row: 4, col: 5)))
        editor.pasteFromPasteboard()

        XCTAssertEqual(name(document.layout, factor: "Condition", row: 4, col: 5), "Untreated")
        XCTAssertEqual(name(document.layout, factor: "Dose", row: 4, col: 5), "10",
                       "⌘V should have brought the other factor too")
        XCTAssertNil(
            document.layout.factors[0].levels.first { $0.name.contains("+") },
            "no joined text should have been taken for a condition name"
        )
    }

    /// And the Excel path still works: plain text on the pasteboard pastes as values
    /// of the active factor, exactly as before.
    func testPlainTextStillPastesAsTheActiveFactor() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Alpha\tBeta", forType: .string)
        editor.setActiveFactor(document.layout.factors[0].id)
        select(WellRange(single: WellPos(row: 7, col: 0)))
        editor.pasteFromPasteboard()

        XCTAssertEqual(name(document.layout, factor: "Condition", row: 7, col: 0), "Alpha")
        XCTAssertEqual(name(document.layout, factor: "Condition", row: 7, col: 1), "Beta")
    }
}

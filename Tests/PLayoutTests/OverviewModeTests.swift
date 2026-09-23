import AppKit
import XCTest
@testable import PLayout

/// Overview is the "stand back and read the plate" mode: every factor at one size on
/// a neutral well, and — the part with teeth — no factor active, so nothing paints.
/// That last bit is an invariant across undo, redo and reopening, which is what most
/// of these guard.
final class OverviewModeTests: XCTestCase {

    private var document: PlateDocument!
    private var editor: PlateEditor!

    override func setUp() {
        super.setUp()
        document = PlateDocument()
        editor = PlateEditor(document: document)
        editor.addFactor()
        editor.addFactor()
        editor.setActiveFactor(document.layout.factors[0].id)
    }

    private var factors: [Factor] { document.layout.factors }

    // MARK: - The no-active-factor invariant

    func testOverviewDropsTheActiveFactorAndTheArmedCondition() {
        XCTAssertNotNil(editor.activeFactorID)
        editor.setWellLabelMode(.overview)
        XCTAssertNil(editor.activeFactorID)
        XCTAssertNil(editor.armedLevelID)
        XCTAssertTrue(editor.isOverview)
    }

    func testPaintingDoesNothingInOverview() {
        let level = factors[0].levels[0].id
        editor.setWellLabelMode(.overview)
        editor.paint(wells: [0, 1, 2], level: level)
        XCTAssertTrue(document.layout.plates[0].assignments.isEmpty)
    }

    func testClickingAWellSelectsWithoutPaintingInOverview() {
        editor.setWellLabelMode(.overview)
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        let canvas = PlateCanvasView(frame: frame)
        canvas.attach(editor: editor)
        window.contentView = canvas

        let target = canvas.cellCentreForTesting(row: 2, col: 3)
        let point = CGPoint(x: target.x, y: canvas.bounds.height - target.y)
        let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        canvas.mouseDown(with: click)
        canvas.mouseUp(with: click)

        XCTAssertEqual(editor.selection?.anchor, WellPos(row: 2, col: 3))
        XCTAssertTrue(document.layout.plates[0].assignments.isEmpty, "a click in Overview painted")
    }

    /// The mode lives in the document, so undo can walk back into it. The editor has to
    /// follow, or painting writes into a factor the UI says is not selected.
    func testUndoAndRedoKeepTheFactorInStepWithTheMode() {
        // Attached after setup so the mode change is its own undo group; a test has no
        // run-loop turns to close one for it.
        let undo = UndoManager()
        editor.undoManager = undo

        editor.setWellLabelMode(.overview)
        XCTAssertNil(editor.activeFactorID)

        undo.undo()
        XCTAssertFalse(editor.isOverview)
        XCTAssertNotNil(editor.activeFactorID, "leaving Overview by undo left nothing to paint with")

        undo.redo()
        XCTAssertTrue(editor.isOverview)
        XCTAssertNil(editor.activeFactorID, "redoing into Overview left a factor active")
    }

    func testDeletingAFactorWhileInOverviewDoesNotSelectOne() {
        editor.setWellLabelMode(.overview)
        editor.deleteFactor(factors[1].id)
        XCTAssertTrue(editor.isOverview)
        XCTAssertNil(editor.activeFactorID)
    }

    func testADocumentSavedInOverviewReopensWithNothingSelected() throws {
        editor.setWellLabelMode(.overview)
        let data = try JSONEncoder().encode(document.layout)

        let reopened = PlateDocument()
        reopened.layout = try JSONDecoder().decode(Layout.self, from: data)
        let fresh = PlateEditor(document: reopened)

        XCTAssertTrue(fresh.isOverview)
        XCTAssertNil(fresh.activeFactorID)
        XCTAssertNil(fresh.armedLevelID)
    }

    // MARK: - Getting back out

    func testPickingAnotherTextModeRestoresTheFactorYouWerePainting() {
        editor.setActiveFactor(factors[2].id)
        editor.setWellLabelMode(.overview)
        editor.setWellLabelMode(.allFactors)
        XCTAssertEqual(editor.activeFactorID, factors[2].id)
        XCTAssertEqual(editor.armedLevelID, factors[2].levels.first?.id)
    }

    /// Overview is a look, not a place: clicking a factor puts you back in the mode you
    /// stepped away from rather than stranding you in All factors.
    func testClickingAFactorLeavesOverviewInTheModeYouCameFrom() {
        editor.setWellLabelMode(.activeFactor)
        editor.setWellLabelMode(.overview)
        editor.setActiveFactor(factors[1].id)

        XCTAssertEqual(document.layout.wellLabelMode, .activeFactor)
        XCTAssertEqual(editor.activeFactorID, factors[1].id)
    }

    func testTogglingOverviewGoesThereAndBack() {
        editor.setWellLabelMode(.activeFactor)
        editor.setActiveFactor(factors[1].id)

        editor.toggleOverview()
        XCTAssertTrue(editor.isOverview)

        editor.toggleOverview()
        XCTAssertEqual(document.layout.wellLabelMode, .activeFactor)
        XCTAssertEqual(editor.activeFactorID, factors[1].id)
    }

    /// Tab has no factor to advance from in Overview, so it has to pick the first one
    /// up rather than skipping past it.
    func testTabInOverviewLandsOnTheFirstFactor() {
        editor.setWellLabelMode(.overview)
        editor.cycleFactor(by: 1)
        XCTAssertEqual(editor.activeFactorID, factors[0].id)
        XCTAssertFalse(editor.isOverview)
    }

    func testShiftTabInOverviewLandsOnTheLastFactor() {
        editor.setWellLabelMode(.overview)
        editor.cycleFactor(by: -1)
        XCTAssertEqual(editor.activeFactorID, factors.last?.id)
    }

    /// A key that quietly does nothing reads as a bug, so the read-only edits say so.
    func testEditsInOverviewExplainThemselves() {
        editor.setWellLabelMode(.overview)
        editor.paintSelection()
        XCTAssertTrue(editor.transientMessage.contains("Overview"), editor.transientMessage)

        editor.transientMessage = ""
        editor.clearSelection()
        XCTAssertTrue(editor.transientMessage.contains("Overview"), editor.transientMessage)

        editor.transientMessage = ""
        editor.randomizeSelection()
        XCTAssertTrue(editor.transientMessage.contains("Overview"), editor.transientMessage)
    }

    /// The sheet has no factor to write into, so it says so instead of opening on a
    /// dead end. Disabling the toolbar button instead would re-tile the whole bar.
    func testTheSeriesSheetDoesNotOpenInOverview() {
        editor.setWellLabelMode(.overview)
        editor.openSeriesSheet()
        XCTAssertFalse(editor.showingSeriesSheet)
        XCTAssertTrue(editor.transientMessage.contains("Overview"), editor.transientMessage)

        editor.setActiveFactor(factors[0].id)
        editor.openSeriesSheet()
        XCTAssertTrue(editor.showingSeriesSheet)
    }

    // MARK: - Persistence

    func testOverviewRoundTripsThroughTheDocumentFormat() throws {
        var layout = Layout()
        layout.wellLabelMode = .overview
        let decoded = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded.wellLabelMode, .overview)
    }

    /// The lenient decode is what lets a file written by a newer build still open, so
    /// it has to stay lenient now that there is a fourth case to not recognise.
    func testAnUnknownModeStillOpens() throws {
        let json = #"{"formatVersion":1,"wellLabelMode":"holographic"}"#
        let decoded = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.wellLabelMode, .activeFactor)
    }
}

// MARK: - Layout of the uniform stack

final class OverviewLabelPlanTests: XCTestCase {

    private func plan(cell: CGFloat, factors: Int = 4, mode: WellLabelMode = .overview)
        -> PlateCanvasView.LabelPlan
    {
        PlateCanvasView.labelPlan(cell: cell, mode: mode, factorCount: factors)
    }

    func testEveryLineIsTheSameSize() {
        for cell in stride(from: CGFloat(20), through: 96, by: 2) {
            let p = plan(cell: cell)
            XCTAssertTrue(p.uniform)
            XCTAssertEqual(p.primarySize, p.secondarySize, accuracy: 0.0001)
        }
    }

    func testTheGradedStackKeepsItsHeadline() {
        let p = plan(cell: 62, mode: .allFactors)
        XCTAssertFalse(p.uniform)
        XCTAssertLessThan(p.secondarySize, p.primarySize)
    }

    /// Equal weight must not cost a factor: if Overview showed fewer lines than All
    /// factors it would be the worse overview of the two.
    func testOverviewNeverShowsFewerLinesThanTheGradedStack() {
        for factors in 2...6 {
            for tenths in 170...960 {
                let cell = CGFloat(tenths) / 10
                XCTAssertGreaterThanOrEqual(
                    plan(cell: cell, factors: factors).lineCount,
                    plan(cell: cell, factors: factors, mode: .allFactors).lineCount,
                    "cell \(cell), \(factors) factors"
                )
            }
        }
    }

    func testLineCountIsMonotonicInCellSize() {
        for factors in 2...5 {
            var previous = 0
            for tenths in 90...960 {
                let lines = plan(cell: CGFloat(tenths) / 10, factors: factors).lineCount
                XCTAssertGreaterThanOrEqual(lines, previous, "\(factors) factors at \(tenths)")
                previous = lines
            }
        }
    }

    func testStackHeightFitsInsideTheWell() {
        for factors in 2...6 {
            for cell in stride(from: CGFloat(20), through: 96, by: 1) {
                let p = plan(cell: cell, factors: factors)
                guard p.lineCount >= 2 else { continue }
                let inset = PlateCanvasView.bodyInset(cell: cell)
                XCTAssertLessThanOrEqual(
                    p.stackHeight(lines: p.lineCount), cell - inset * 2 + 0.001,
                    "\(p.lineCount) lines overflow a \(cell)pt cell"
                )
            }
        }
    }
}

// MARK: - What Overview actually draws

final class OverviewRenderTests: XCTestCase {

    /// Two factors, every well painted, so the active factor would flood the plate
    /// with colour in any other mode.
    private func editor(mode: WellLabelMode, format: PlateFormat = PlateFormat(rows: 1, cols: 1))
        -> PlateEditor
    {
        let document = PlateDocument()
        var layout = Layout()
        let treatment = Factor(
            name: "Treatment", levels: [Level(name: "Drug", colorHex: "#E4572E")]
        )
        let line = Factor(name: "Cell line", levels: [Level(name: "HeLa", colorHex: "#17BEBB")])

        var plate = Plate(name: "Plate 1", format: format)
        for well in 0..<format.wellCount {
            plate.setLevelID(treatment.levels[0].id, factor: treatment.id, well: well)
            plate.setLevelID(line.levels[0].id, factor: line.id, well: well)
        }
        layout.factors = [treatment, line]
        layout.plates = [plate]
        document.layout = layout

        let editor = PlateEditor(document: document)
        editor.activePlateID = plate.id
        editor.setActiveFactor(treatment.id)
        // Set last: choosing a factor is itself a way out of Overview.
        editor.setWellLabelMode(mode)
        return editor
    }

    private func render(_ editor: PlateEditor, size: NSSize = NSSize(width: 400, height: 400))
        throws -> (Data, PlateCanvasView)
    {
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        let canvas = PlateCanvasView(frame: frame)
        canvas.attach(editor: editor)
        window.contentView = canvas
        return (try XCTUnwrap(canvas.pngData()), canvas)
    }

    /// Samples the well's own fill: high enough above the vertically centred label
    /// stack that no glyph can reach it.
    private func wellFill(_ editor: PlateEditor, mode: WellLabelMode) throws -> NSColor {
        let (png, canvas) = try render(editor)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let geo = PlateGeometry(format: editor.format, bounds: canvas.bounds)
        let cell = geo.cellRect(row: 0, col: 0)
        let point = CGPoint(x: cell.midX, y: cell.minY + cell.height * 0.1)
        let x = Int(point.x * CGFloat(rep.pixelsWide) / canvas.bounds.width)
        let y = Int(point.y * CGFloat(rep.pixelsHigh) / canvas.bounds.height)
        return try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    // MARK: - Factors hidden from Overview

    /// Treatment and cell line on every well, plus an XY position that makes each well
    /// unique — the factor there is every reason to hide. `present` leaves XY out of the
    /// document altogether, for comparison against hiding it.
    private func xyEditor(mode: WellLabelMode, hidden: Bool, present: Bool = true) -> PlateEditor {
        let format = PlateFormat(rows: 2, cols: 3)
        let document = PlateDocument()
        var layout = Layout()
        let treatment = Factor(name: "Treatment", levels: [Level(name: "Drug", colorHex: "#E4572E")])
        let line = Factor(name: "Cell line", levels: [Level(name: "HeLa", colorHex: "#17BEBB")])
        var xy = Factor(name: "XY", hiddenInOverview: hidden ? true : nil)
        xy.levels = (0..<format.wellCount).map {
            Level(name: "XY0\($0 + 1)", colorHex: Palette.color(at: $0))
        }

        var plate = Plate(name: "Plate 1", format: format)
        for well in 0..<format.wellCount {
            plate.setLevelID(treatment.levels[0].id, factor: treatment.id, well: well)
            plate.setLevelID(line.levels[0].id, factor: line.id, well: well)
            if present { plate.setLevelID(xy.levels[well].id, factor: xy.id, well: well) }
        }
        layout.factors = present ? [treatment, line, xy] : [treatment, line]
        layout.plates = [plate]
        document.layout = layout

        let editor = PlateEditor(document: document)
        editor.activePlateID = plate.id
        editor.setActiveFactor(treatment.id)
        editor.setWellLabelMode(mode)
        editor.showOverviewGroups = true
        editor.selection = nil
        return editor
    }

    /// A hidden factor is absent from the picture, not merely dimmed: the plate draws
    /// exactly as it would if the factor did not exist — same lines, same type size,
    /// same key, same blocks. And it is Overview's alone — the graded stack still has it.
    func testAHiddenFactorDrawsAsIfItWereNotThere() throws {
        let hidden = try render(xyEditor(mode: .overview, hidden: true)).0
        let absent = try render(xyEditor(mode: .overview, hidden: false, present: false)).0
        let shown = try render(xyEditor(mode: .overview, hidden: false)).0
        XCTAssertEqual(hidden, absent, "hidden should draw exactly as not-there")
        XCTAssertNotEqual(hidden, shown, "and differently from shown, or nothing was hidden")

        let gradedHidden = try render(xyEditor(mode: .allFactors, hidden: true)).0
        let gradedShown = try render(xyEditor(mode: .allFactors, hidden: false)).0
        XCTAssertEqual(gradedHidden, gradedShown, "the flag means nothing outside Overview")
    }

    func testOverviewGivesEveryWellTheSameNeutralTile() throws {
        let colour = try wellFill(editor(mode: .overview), mode: .overview)
        XCTAssertEqual(colour.redComponent, colour.greenComponent, accuracy: 0.02)
        XCTAssertEqual(colour.greenComponent, colour.blueComponent, accuracy: 0.02)
        XCTAssertLessThan(colour.redComponent, 0.99, "the tile has to be visible against the plate")
    }

    /// The counterweight: without Overview the same plate is flooded with the active
    /// factor's colour, which is exactly what the dummy-grey-factor workaround existed
    /// to defeat.
    func testTheOtherModesStillColourTheWellByActiveFactor() throws {
        let colour = try wellFill(editor(mode: .allFactors), mode: .allFactors)
        XCTAssertGreaterThan(
            colour.redComponent, colour.blueComponent + 0.2,
            "expected the active factor's red, got \(colour)"
        )
    }

    func testOverviewRendersAtEveryStandardFormat() throws {
        for format in PlateFormat.standard {
            let (png, _) = try render(
                editor(mode: .overview, format: format), size: NSSize(width: 900, height: 620)
            )
            XCTAssertGreaterThan(png.count, 500, "\(format.rows)×\(format.cols) produced no image")
            if let base = ProcessInfo.processInfo.environment["PLATE_OVERVIEW_DIR"] {
                try png.write(to: URL(fileURLWithPath: "\(base)/overview-\(format.rows)x\(format.cols).png"))
            }
        }
    }
}

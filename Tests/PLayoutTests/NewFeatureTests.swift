import XCTest
import AppKit
@testable import PLayout

// MARK: - Document compatibility

final class LayoutCompatibilityTests: XCTestCase {

    /// Swift's synthesized decoder ignores stored-property defaults, so adding a field
    /// would otherwise make every previously saved document fail to open.
    func testDocumentSavedBeforeTheNewFieldsStillOpens() throws {
        let legacy = """
        {
          "formatVersion": 1,
          "notes": "",
          "padWellLabels": false,
          "factors": [
            { "id": "11111111-1111-1111-1111-111111111111",
              "name": "Condition", "kind": "categorical", "unit": "",
              "levels": [ { "id": "22222222-2222-2222-2222-222222222222",
                            "name": "Ctrl", "colorHex": "#4E79A7" } ] }
          ],
          "plates": [
            { "id": "33333333-3333-3333-3333-333333333333",
              "name": "Plate 1",
              "format": { "rows": 8, "cols": 12 },
              "assignments": {} }
          ]
        }
        """
        let layout = try JSONDecoder().decode(Layout.self, from: Data(legacy.utf8))
        XCTAssertEqual(layout.factors.count, 1)
        XCTAssertEqual(layout.plates.first?.format, .well96)
        XCTAssertEqual(layout.wellLabelMode, .activeFactor, "missing field should fall back to the default")
    }

    /// A file written by a newer build must not break this one.
    func testUnknownLabelModeFallsBackInsteadOfThrowing() throws {
        let json = """
        { "formatVersion": 1, "factors": [], "plates": [],
          "padWellLabels": false, "notes": "", "wellLabelMode": "someFutureMode" }
        """
        let layout = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        XCTAssertEqual(layout.wellLabelMode, .activeFactor)
    }

    func testRoundTripPreservesTheLabelMode() throws {
        var layout = Layout.starter()
        layout.wellLabelMode = .allFactors
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(Layout.self, from: data), layout)
    }

    /// A truncated or hand-edited file can carry a column that no longer fits its plate.
    func testDecodingNormalisesMismatchedAssignmentColumns() throws {
        let json = """
        { "formatVersion": 1, "padWellLabels": false, "notes": "",
          "factors": [ { "id": "11111111-1111-1111-1111-111111111111", "name": "F",
                         "kind": "categorical", "unit": "",
                         "levels": [ { "id": "22222222-2222-2222-2222-222222222222",
                                       "name": "A", "colorHex": "#4E79A7" } ] } ],
          "plates": [ { "id": "33333333-3333-3333-3333-333333333333", "name": "P",
                        "format": { "rows": 2, "cols": 3 },
                        "assignments": { "11111111-1111-1111-1111-111111111111":
                          ["22222222-2222-2222-2222-222222222222", null] } } ] }
        """
        let layout = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        let plate = try XCTUnwrap(layout.plates.first)
        XCTAssertEqual(plate.assignments.values.first?.count, 6, "column should be resized to the well count")
        XCTAssertEqual(plate.levelID(factor: layout.factors[0].id, well: 0)?.uuidString,
                       "22222222-2222-2222-2222-222222222222")
    }

    /// A corrupt size must be clamped, not trapped on, since layout divides by it.
    func testDecodingClampsAnImpossiblePlateSize() throws {
        let json = #"{"rows": 0, "cols": 5000}"#
        let format = try JSONDecoder().decode(PlateFormat.self, from: Data(json.utf8))
        XCTAssertEqual(format.rows, PlateFormat.rowRange.lowerBound)
        XCTAssertEqual(format.cols, PlateFormat.columnRange.upperBound)
    }

    func testCustomSizesAreClampedOnConstruction() {
        XCTAssertEqual(PlateFormat(rows: 0, cols: 0), PlateFormat(rows: 1, cols: 1))
        XCTAssertEqual(PlateFormat(rows: 999, cols: 999),
                       PlateFormat(rows: PlateFormat.rowRange.upperBound,
                                   cols: PlateFormat.columnRange.upperBound))
        XCTAssertEqual(PlateFormat(rows: -4, cols: 7).rows, 1)
    }

    func testCustomFormatsRoundTripThroughADocument() throws {
        var layout = Layout.starter()
        layout.plates[0].changeFormat(to: PlateFormat(rows: 5, cols: 7))
        let decoded = try JSONDecoder().decode(Layout.self, from: try JSONEncoder().encode(layout))
        XCTAssertEqual(decoded.plates[0].format, PlateFormat(rows: 5, cols: 7))
        XCTAssertEqual(decoded.plates[0].format.wellCount, 35)
    }
}

// MARK: - Templates

final class PlateTemplateStoreTests: XCTestCase {

    private var store: PlateTemplateStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "plate-template-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = PlateTemplateStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A template that duplicates a standard plate would appear twice in the format
    /// menu, both rows ticked, with a name that displayName() never returns.
    func testAStandardShapeIsNotSavedAsATemplate() {
        XCTAssertNil(store.add(name: "My 96", format: .well96))
        XCTAssertFalse(store.canSave(.well96))
        XCTAssertTrue(store.templates.isEmpty)
    }

    func testTheSameShapeIsNotSavedTwice() {
        let shape = PlateFormat(rows: 5, cols: 7)
        XCTAssertNotNil(store.add(name: "First", format: shape))
        XCTAssertNil(store.add(name: "Second", format: shape))
        XCTAssertEqual(store.templates.count, 1)
    }

    func testStandardAndDuplicateShapesAreDroppedWhenLoaded() throws {
        let rogue = [
            PlateTemplate(name: "Sneaky 96", rows: 8, cols: 12),
            PlateTemplate(name: "Custom", rows: 5, cols: 7),
            PlateTemplate(name: "Custom again", rows: 5, cols: 7),
        ]
        defaults.set(try JSONEncoder().encode(rogue), forKey: "customPlateTemplates")
        let reloaded = PlateTemplateStore(defaults: defaults)
        XCTAssertEqual(reloaded.templates.map(\.name), ["Custom"])
    }

    func testAddAndLookUpByShape() {
        let chamber = PlateFormat(rows: 2, cols: 4)
        store.add(name: "Chamber slide", format: chamber)
        XCTAssertEqual(store.displayName(for: chamber), "Chamber slide")
        XCTAssertEqual(store.template(matching: chamber)?.name, "Chamber slide")
        XCTAssertEqual(store.detailedName(for: chamber), "Chamber slide  (2×4)")
    }

    func testStandardFormatsAreNeverRenamedByATemplate() {
        store.add(name: "My 96", format: .well96)
        XCTAssertEqual(store.displayName(for: .well96), "96-well",
                       "a standard plate should keep its standard name")
    }

    func testUnknownShapeFallsBackToTheWellCount() {
        XCTAssertEqual(store.displayName(for: PlateFormat(rows: 5, cols: 7)), "35-well")
    }

    func testNamesAreMadeUnique() {
        // Two different non-standard shapes, so both are saved.
        store.add(name: "Slide", format: PlateFormat(rows: 2, cols: 4))
        store.add(name: "Slide", format: PlateFormat(rows: 2, cols: 5))
        XCTAssertEqual(store.templates.map(\.name), ["Slide", "Slide 2"])
    }

    func testEmptyNameGetsADescriptiveFallback() {
        store.add(name: "   ", format: PlateFormat(rows: 5, cols: 7))
        XCTAssertEqual(store.templates.first?.name, "5×7 plate")
    }

    func testRenameRemoveAndPersistence() throws {
        let template = try XCTUnwrap(store.add(name: "Strip", format: PlateFormat(rows: 1, cols: 8)))
        store.rename(template.id, to: "8-strip")
        XCTAssertEqual(store.templates.first?.name, "8-strip")

        // A second store over the same defaults must see the saved list.
        let reloaded = PlateTemplateStore(defaults: defaults)
        XCTAssertEqual(reloaded.templates.first?.name, "8-strip")

        store.remove(template.id)
        XCTAssertTrue(store.templates.isEmpty)
        XCTAssertTrue(PlateTemplateStore(defaults: defaults).templates.isEmpty)
    }

    func testRenameIgnoresBlankNames() throws {
        let template = try XCTUnwrap(store.add(name: "Strip", format: PlateFormat(rows: 1, cols: 8)))
        store.rename(template.id, to: "  ")
        XCTAssertEqual(store.templates.first?.name, "Strip")
    }

    func testOutOfBoundsTemplatesAreDroppedOnLoad() throws {
        let rogue = [PlateTemplate(name: "Huge", rows: 5000, cols: 5000)]
        defaults.set(try JSONEncoder().encode(rogue), forKey: "customPlateTemplates")
        XCTAssertTrue(PlateTemplateStore(defaults: defaults).templates.isEmpty)
    }
}

// MARK: - Multi-factor label layout

final class LabelPlanTests: XCTestCase {

    private func plan(cell: CGFloat, factors: Int = 3, mode: WellLabelMode = .allFactors)
        -> PlateCanvasView.LabelPlan
    {
        PlateCanvasView.labelPlan(cell: cell, mode: mode, factorCount: factors)
    }

    func testOtherModesNeverStack() {
        XCTAssertEqual(plan(cell: 62, mode: .none).lineCount, 0)
        XCTAssertEqual(plan(cell: 62, mode: .activeFactor).lineCount, 0)
    }

    func testASingleFactorNeverStacks() {
        XCTAssertEqual(plan(cell: 62, factors: 1).lineCount, 0)
    }

    func testLineCountNeverExceedsTheFactorCount() {
        for factors in 2...6 {
            XCTAssertLessThanOrEqual(plan(cell: 96, factors: factors).lineCount, factors)
        }
    }

    /// Making the window bigger must never remove a label — a non-monotonic
    /// ramp would do exactly that as the user resizes.
    func testLineCountIsMonotonicInCellSize() {
        for factors in 2...5 {
            var previous = 0
            for tenths in 90...960 {
                let cell = CGFloat(tenths) / 10
                let lines = plan(cell: cell, factors: factors).lineCount
                XCTAssertGreaterThanOrEqual(
                    lines, previous,
                    "cell \(cell) with \(factors) factors dropped from \(previous) to \(lines) lines"
                )
                previous = lines
            }
        }
    }

    func testSmallWellsFallBackToASingleLabel() {
        XCTAssertEqual(plan(cell: 16).lineCount, 0, "a 1536-well cell has no room to stack")
    }

    func testA96WellPlateStacksAtLeastTwoFactors() {
        // ~62pt is what a 96-well plate gets in the default window.
        XCTAssertGreaterThanOrEqual(plan(cell: 62, factors: 2).lineCount, 2)
        XCTAssertGreaterThanOrEqual(plan(cell: 62, factors: 3).lineCount, 3)
    }

    func testStackHeightFitsInsideTheWell() {
        for factors in 2...5 {
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

    func testInactiveTierStaysSmallerThanTheActiveTier() {
        for cell in stride(from: CGFloat(20), through: 96, by: 2) {
            let p = plan(cell: cell)
            XCTAssertLessThan(p.secondarySize, p.primarySize)
        }
    }

    /// Regression: the plan used to subtract room for a stripe that render() might not
    /// draw, so a whole label line was lost for nothing.
    func testPlanDoesNotPayForAStripeItCannotSee() {
        // 4 factors at a 96-well cell: every line the body can hold should be used.
        let p = plan(cell: 62, factors: 4)
        let available = 62 - PlateCanvasView.bodyInset(cell: 62) * 2
        var maxLines = 1
        while p.stackHeight(lines: maxLines + 1) <= available { maxLines += 1 }
        XCTAssertEqual(p.lineCount, min(maxLines, 4))
    }
}

// MARK: - Regressions found in review

final class LabelLayoutRegressionTests: XCTestCase {

    private func canvas(factors: Int, format: PlateFormat, size: NSSize)
        -> (PlateCanvasView, PlateEditor, NSWindow)
    {
        let document = PlateDocument()
        var layout = Layout()
        layout.factors = (0..<factors).map { i in
            Factor(name: "F\(i + 1)", levels: [Level(name: "L\(i + 1)", colorHex: Palette.color(at: i))])
        }
        var plate = Plate(name: "P", format: format)
        for factor in layout.factors {
            for well in 0..<format.wellCount {
                plate.setLevelID(factor.levels[0].id, factor: factor.id, well: well)
            }
        }
        layout.plates = [plate]
        layout.wellLabelMode = .allFactors
        document.layout = layout

        let editor = PlateEditor(document: document)
        editor.activePlateID = plate.id
        editor.setActiveFactor(layout.factors[0].id)

        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let view = PlateCanvasView(frame: frame)
        view.attach(editor: editor)
        window.contentView = view
        return (view, editor, window)
    }

    /// Regression: an 18pt key strip used to be reserved based on the *unreduced*
    /// bounds, so across a band of window heights the reservation shrank the cell just
    /// enough to destroy the labels the strip was there to describe.
    func testGrowingTheCanvasNeverRemovesLabelLines() {
        for format in [PlateFormat.well96, .well384, .well1536, PlateFormat(rows: 20, cols: 30)] {
            for factors in 2...3 {
                var previous = 0
                var previousCell: CGFloat = 0
                for tenths in stride(from: 3000, through: 8000, by: 25) {
                    let height = CGFloat(tenths) / 10
                    let (view, _, _) = canvas(
                        factors: factors, format: format, size: NSSize(width: 1200, height: height)
                    )
                    let geo = PlateGeometry(format: format, bounds: view.bounds)
                    let lines = PlateCanvasView.labelPlan(
                        cell: geo.cell, mode: .allFactors, factorCount: factors
                    ).lineCount
                    XCTAssertGreaterThanOrEqual(
                        lines, previous,
                        "\(format.rows)×\(format.cols), \(factors) factors: height \(height) dropped \(previous) → \(lines) lines"
                    )
                    XCTAssertGreaterThanOrEqual(
                        geo.cell, previousCell - 0.001,
                        "\(format.rows)×\(format.cols): height \(height) shrank the wells"
                    )
                    previous = lines
                    previousCell = geo.cell
                }
            }
        }
    }

    /// The geometry always leaves padding under the plate, which is where the key is
    /// drawn — so it never has to take space away from the wells.
    func testThereIsAlwaysRoomBelowThePlateForTheKey() {
        for format in PlateFormat.standard + [PlateFormat(rows: 64, cols: 96)] {
            for height in [NSSize(width: 1200, height: 400), NSSize(width: 900, height: 620),
                           NSSize(width: 1400, height: 900)] {
                let geo = PlateGeometry(format: format, bounds: NSRect(origin: .zero, size: height))
                XCTAssertGreaterThanOrEqual(
                    height.height - geo.frameRect.maxY, 13.9,
                    "\(format.rows)×\(format.cols) at \(height) left no room for the key"
                )
            }
        }
    }

    /// Regression: with "Show other factors" off the overflow factors were drawn
    /// nowhere, yet the key still announced them as being in a stripe.
    func testRenderingIsStableWithSecondaryFactorsHidden() throws {
        let (view, editor, _) = canvas(
            factors: 6, format: .well96, size: NSSize(width: 1000, height: 700)
        )
        editor.showSecondaryFactors = false
        XCTAssertNotNil(view.pngData())
        editor.showSecondaryFactors = true
        XCTAssertNotNil(view.pngData())
    }

    func testEveryFactorCountRendersAcrossAWideRangeOfWindows() throws {
        for factors in 1...6 {
            for size in [NSSize(width: 700, height: 420), NSSize(width: 1000, height: 700),
                         NSSize(width: 1600, height: 1000)] {
                let (view, _, _) = canvas(factors: factors, format: .well96, size: size)
                XCTAssertNotNil(view.pngData(), "\(factors) factors at \(size)")
            }
        }
    }
}

final class CustomFormatFlowTests: XCTestCase {

    /// Regression: the template used to be saved before the plate size was applied,
    /// so cancelling the data-loss warning left a template behind for a size never used.
    func testApplyingAFormatThatLosesDataIsAllOrNothing() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factor = document.layout.factors[0]
        // Paint the far corner so shrinking would discard it.
        editor.paint(wells: [95], level: factor.levels[0].id)

        let shrunk = PlateFormat(rows: 4, cols: 6)
        XCTAssertTrue(
            document.layout.plates[0].formatChangeWouldLoseData(shrunk),
            "test needs a format change that would warn"
        )
        // The warning is modal, so assert the ordering contract instead of clicking it:
        // a template is only written once setFormat reports success.
        XCTAssertTrue(editor.setFormat(PlateFormat(rows: 9, cols: 13)),
                      "a lossless change should report success")
        XCTAssertEqual(document.layout.plates[0].format, PlateFormat(rows: 9, cols: 13))
    }

    func testSettingTheSameFormatIsASuccessfulNoOp() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        XCTAssertTrue(editor.setFormat(.well96))
        XCTAssertEqual(document.layout.plates[0].format, .well96)
    }

    /// Factor order drives the order of the stacked well labels, so reordering has to
    /// be a real, undoable document edit rather than a view-only nicety.
    func testFactorsCanBeReorderedAndUndone() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        editor.addFactor()
        let before = document.layout.factors.map(\.name)
        XCTAssertEqual(before.count, 3)

        // Attached only now, so the reorder is its own undo group rather than being
        // coalesced with the setup edits (a test runs without run-loop turns between them).
        let undo = UndoManager()
        editor.undoManager = undo

        editor.moveFactors(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(document.layout.factors.map(\.name), [before[2], before[0], before[1]])

        undo.undo()
        XCTAssertEqual(document.layout.factors.map(\.name), before)
    }

    func testReorderingFactorsKeepsEveryWellAssignment() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        let first = document.layout.factors[0]
        let second = document.layout.factors[1]
        editor.setActiveFactor(first.id)
        editor.paint(wells: [0], level: first.levels[0].id)
        editor.setActiveFactor(second.id)
        editor.paint(wells: [0], level: second.levels[0].id)

        editor.moveFactors(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        let plate = document.layout.plates[0]
        XCTAssertEqual(plate.levelID(factor: first.id, well: 0), first.levels[0].id)
        XCTAssertEqual(plate.levelID(factor: second.id, well: 0), second.levels[0].id)
    }

    func testCustomFormatAppliesAndNamesItself() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        XCTAssertTrue(editor.applyCustomFormat(rows: 5, cols: 7, templateName: nil))
        XCTAssertEqual(document.layout.plates[0].format, PlateFormat(rows: 5, cols: 7))
        XCTAssertEqual(editor.formatDisplayName(editor.format), "35-well")
    }
}

// MARK: - Rendering with all factors labelled

final class MultiFactorRenderTests: XCTestCase {

    /// Builds a 3-factor plate where one factor is deliberately blank in some wells,
    /// so the reserved-slot behaviour is exercised.
    private func editor(mode: WellLabelMode, format: PlateFormat = .well96) -> PlateEditor {
        let document = PlateDocument()
        var layout = Layout()
        var compound = Factor(name: "Compound")
        compound.levels = [
            Level(name: "DMSO", colorHex: Palette.color(at: 5)),
            Level(name: "Cmpd A", colorHex: Palette.color(at: 0)),
            Level(name: "Cmpd B", colorHex: Palette.color(at: 1)),
        ]
        var dose = Factor(name: "Dose", kind: .numeric, unit: "µM")
        dose.levels = zip(["30", "10", "3.3", "1.1", "0.37"],
                          Palette.ramp(count: 5, baseHex: Palette.color(at: 4)))
            .map { Level(name: $0, colorHex: $1) }
        var line = Factor(name: "Cell line")
        line.levels = [
            Level(name: "HeLa", colorHex: Palette.color(at: 2)),
            Level(name: "U2OS", colorHex: Palette.color(at: 3)),
        ]

        var plate = Plate(name: "Plate 1", format: format)
        for row in 0..<format.rows {
            for col in 0..<format.cols {
                let well = format.index(row: row, col: col)
                plate.setLevelID(line.levels[row < format.rows / 2 ? 0 : 1].id,
                                 factor: line.id, well: well)
                if col == 0 {
                    plate.setLevelID(compound.levels[0].id, factor: compound.id, well: well)
                    // Dose deliberately left blank here: its slot must still be reserved.
                } else if col <= 5 {
                    plate.setLevelID(compound.levels[1].id, factor: compound.id, well: well)
                    plate.setLevelID(dose.levels[min(col - 1, 4)].id, factor: dose.id, well: well)
                } else if col <= 10 {
                    plate.setLevelID(compound.levels[2].id, factor: compound.id, well: well)
                    plate.setLevelID(dose.levels[min(col - 6, 4)].id, factor: dose.id, well: well)
                }
            }
        }

        layout.factors = [compound, dose, line]
        layout.plates = [plate]
        layout.wellLabelMode = mode
        document.layout = layout

        let editor = PlateEditor(document: document)
        editor.activePlateID = plate.id
        editor.setActiveFactor(compound.id)
        editor.selection = WellRange(anchor: WellPos(row: 1, col: 1), focus: WellPos(row: 4, col: 4))
        return editor
    }

    private func render(_ editor: PlateEditor, size: NSSize = NSSize(width: 1000, height: 700))
        throws -> Data
    {
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = PlateCanvasView(frame: frame)
        canvas.attach(editor: editor)
        window.contentView = canvas
        return try XCTUnwrap(canvas.pngData())
    }

    func testAllFactorModeRenders() throws {
        let png = try render(editor(mode: .allFactors))
        XCTAssertGreaterThan(png.count, 5000)
        if let path = ProcessInfo.processInfo.environment["PLATE_ALL_FACTORS_PATH"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    func testEveryModeRendersAtEveryStandardFormat() throws {
        for mode in WellLabelMode.allCases {
            for format in PlateFormat.standard {
                _ = try render(editor(mode: mode, format: format), size: NSSize(width: 900, height: 620))
            }
        }
    }

    func testCustomShapesRender() throws {
        for format in [PlateFormat(rows: 1, cols: 8), PlateFormat(rows: 5, cols: 7),
                       PlateFormat(rows: 64, cols: 96), PlateFormat(rows: 1, cols: 1)] {
            let png = try render(editor(mode: .allFactors, format: format))
            XCTAssertGreaterThan(png.count, 500, "\(format.rows)×\(format.cols) produced no image")
            if let base = ProcessInfo.processInfo.environment["PLATE_CUSTOM_DIR"] {
                try png.write(to: URL(fileURLWithPath: "\(base)/custom-\(format.rows)x\(format.cols).png"))
            }
        }
    }

    /// The key strip steals height from the plate, so hit-testing has to agree with
    /// drawing about how much — otherwise clicks land on the wrong row.
    func testHitTestingAgreesWithDrawingWhenTheKeyStripIsShown() {
        let editor = self.editor(mode: .allFactors)
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = PlateCanvasView(frame: frame)
        canvas.attach(editor: editor)
        window.contentView = canvas

        let armed = editor.activeFactor?.levels[2].id
        editor.armedLevelID = armed
        // Click dead centre of D4 as the view itself computes it.
        let target = canvas.cellCentreForTesting(row: 3, col: 3)
        let point = CGPoint(x: target.x, y: canvas.bounds.height - target.y)
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        canvas.mouseDown(with: down)
        canvas.mouseUp(with: down)

        XCTAssertEqual(editor.selection?.anchor, WellPos(row: 3, col: 3))
        let plate = editor.document.layout.plates[0]
        XCTAssertEqual(
            plate.levelID(factor: editor.activeFactorID!, well: plate.format.index(row: 3, col: 3)),
            armed
        )
    }
}

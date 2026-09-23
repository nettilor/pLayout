import XCTest
import AppKit
@testable import PLayout

/// Chunking the plate in Overview: a line round each run of wells that share the same
/// conditions, so a 384 reads as the blocks it was designed as.
final class WellGroupingTests: XCTestCase {

    private var layout = Layout.starter()
    private var format: PlateFormat { layout.plates[0].format }

    private var condition: Factor { layout.factors[0] }

    private func paint(_ factor: Factor, _ level: Int, rows: ClosedRange<Int>, cols: ClosedRange<Int>) {
        for row in rows {
            for col in cols {
                layout.plates[0].setLevelID(
                    factor.levels[level].id, factor: factor.id, well: format.index(row: row, col: col)
                )
            }
        }
    }

    private func blocks(_ basis: WellGrouping.Basis = .allFactors) -> [Int?] {
        WellGrouping.blocks(plate: layout.plates[0], factors: layout.factors, basis: basis)
    }

    private func block(_ blocks: [Int?], _ row: Int, _ col: Int) -> Int? {
        blocks[format.index(row: row, col: col)]
    }

    // MARK: - What makes a block

    func testWellsWithTheSameValuesInOneRunAreOneBlock() {
        paint(condition, 0, rows: 0...1, cols: 0...2)
        let blocks = blocks()

        let first = block(blocks, 0, 0)
        XCTAssertNotNil(first)
        for row in 0...1 {
            for col in 0...2 {
                XCTAssertEqual(block(blocks, row, col), first, "(\(row),\(col)) should be in the same block")
            }
        }
    }

    /// A rectangle round every well sharing a value would swallow everything between
    /// two distant copies of it, which is the opposite of chunking.
    func testTheSameConditionInTwoPlacesIsTwoBlocks() {
        paint(condition, 0, rows: 0...1, cols: 0...1)
        paint(condition, 0, rows: 5...6, cols: 8...9)
        let blocks = blocks()

        XCTAssertNotNil(block(blocks, 0, 0))
        XCTAssertNotNil(block(blocks, 5, 8))
        XCTAssertNotEqual(block(blocks, 0, 0), block(blocks, 5, 8))
        XCTAssertNil(block(blocks, 3, 5), "the wells between them belong to neither")
    }

    func testAnLShapedRunStaysOneBlock() {
        paint(condition, 0, rows: 0...2, cols: 0...0)
        paint(condition, 0, rows: 2...2, cols: 0...3)
        let blocks = blocks()

        XCTAssertEqual(block(blocks, 0, 0), block(blocks, 2, 3))
        XCTAssertNil(block(blocks, 0, 3), "the inside of the L is not part of it")
    }

    func testDifferentValuesSideBySideAreDifferentBlocks() {
        paint(condition, 0, rows: 0...3, cols: 0...0)
        paint(condition, 1, rows: 0...3, cols: 1...1)
        let blocks = blocks()

        XCTAssertNotEqual(block(blocks, 0, 0), block(blocks, 0, 1))
    }

    /// Empty wells are an absence, not a condition — boxing them together would draw
    /// a line round the unused half of the plate.
    func testEmptyWellsAreInNoBlockAtAll() {
        paint(condition, 0, rows: 0...0, cols: 0...0)
        let blocks = blocks()

        XCTAssertNotNil(block(blocks, 0, 0))
        XCTAssertNil(block(blocks, 4, 4))
        XCTAssertNil(block(blocks, 7, 11))
    }

    // MARK: - The two bases

    func testASecondFactorSplitsABlockThatWasOtherwiseIdentical() {
        paint(condition, 0, rows: 0...1, cols: 0...3)
        var dose = Factor(name: "Dose", kind: .numeric, unit: "µM")
        dose.levels = [Level(name: "10", colorHex: "#1B3A5C"), Level(name: "1", colorHex: "#AFC8DD")]
        layout.factors.append(dose)
        paint(dose, 0, rows: 0...1, cols: 0...1)
        paint(dose, 1, rows: 0...1, cols: 2...3)

        let all = blocks()
        XCTAssertNotEqual(block(all, 0, 1), block(all, 0, 2), "the doses differ, so the block does")

        // Grouping on the condition alone is the coarse view: the dose stops mattering.
        let byCondition = blocks(.factor(condition.id))
        XCTAssertEqual(block(byCondition, 0, 1), block(byCondition, 0, 2))
    }

    func testGroupingOnAFactorIgnoresWellsThatFactorHasNoValueFor() {
        paint(condition, 0, rows: 0...1, cols: 0...1)
        var dose = Factor(name: "Dose", kind: .numeric)
        dose.levels = [Level(name: "10", colorHex: "#1B3A5C")]
        layout.factors.append(dose)
        paint(dose, 0, rows: 0...0, cols: 0...0)

        let byDose = blocks(.factor(dose.id))
        XCTAssertNotNil(block(byDose, 0, 0))
        XCTAssertNil(block(byDose, 1, 1), "no dose there, so nothing to group")
    }

    func testGroupingOnAFactorThatIsGoneGroupsNothing() {
        paint(condition, 0, rows: 0...1, cols: 0...1)
        XCTAssertTrue(blocks(.factor(UUID())).allSatisfy { $0 == nil })
    }

    // MARK: - The editor's side of it

    func testTheOutlinesAreOverviewOnly() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.showOverviewGroups = true

        XCTAssertFalse(editor.drawsOverviewGroups, "not while a factor is being painted")
        editor.setWellLabelMode(.overview)
        XCTAssertTrue(editor.drawsOverviewGroups)
        editor.setWellLabelMode(.allFactors)
        XCTAssertFalse(editor.drawsOverviewGroups)
    }

    func testDeletingTheGroupedFactorFallsBackToGroupingOnEverything() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        let second = document.layout.factors[1].id
        editor.overviewGroupFactorID = second
        XCTAssertEqual(editor.overviewGroupBasis, .factor(second))

        editor.deleteFactor(second)
        XCTAssertNil(editor.overviewGroupFactorID)
        XCTAssertEqual(editor.overviewGroupBasis, .allFactors)
    }

    // MARK: - Factors hidden from Overview

    /// The list the canvas hands the grouping: what Overview shows, not everything.
    private func overviewBlocks(_ basis: WellGrouping.Basis = .allFactors) -> [Int?] {
        WellGrouping.blocks(plate: layout.plates[0], factors: layout.overviewFactors, basis: basis)
    }

    /// An XY imaging position numbers every well uniquely, so grouping on everything
    /// boxes each well on its own. Hiding it from Overview takes it out of the grouping
    /// as well as the picture: what you see is what has to match.
    func testHidingAFactorTakesItOutOfTheGrouping() {
        paint(condition, 0, rows: 0...1, cols: 0...1)
        var xy = Factor(name: "XY")
        xy.levels = (0..<4).map { Level(name: "XY0\($0 + 1)", colorHex: Palette.color(at: $0)) }
        layout.factors.append(xy)
        for (i, (row, col)) in [(0, 0), (0, 1), (1, 0), (1, 1)].enumerated() {
            layout.plates[0].setLevelID(
                xy.levels[i].id, factor: xy.id, well: format.index(row: row, col: col)
            )
        }

        let fine = overviewBlocks()
        XCTAssertNotNil(block(fine, 0, 0))
        XCTAssertNotEqual(block(fine, 0, 0), block(fine, 0, 1), "every position is its own block")

        layout.factors[1].hiddenInOverview = true
        let coarse = overviewBlocks()
        XCTAssertEqual(
            block(coarse, 0, 0), block(coarse, 1, 1),
            "with XY hidden the four wells are one condition"
        )
    }

    func testTheShownFactorsKeepTheirOrderAndNeverComeUpEmpty() {
        let dose = Factor(name: "Dose")
        layout.factors.append(dose)
        XCTAssertEqual(layout.overviewFactors.map(\.name), [condition.name, "Dose"])

        layout.factors[0].hiddenInOverview = true
        XCTAssertEqual(layout.overviewFactors.map(\.name), ["Dose"])
        XCTAssertFalse(layout.isShownInOverview(condition.id))

        // A delete can leave the only factor hidden; Overview shows it rather than nothing.
        layout.removeFactor(dose.id)
        XCTAssertEqual(layout.overviewFactors.map(\.name), [condition.name])
        XCTAssertTrue(layout.isShownInOverview(condition.id), "the effective state, not the flag")
        XCTAssertEqual(layout.factors[0].hiddenInOverview, true, "and the flag itself is left alone")
    }

    func testHidingTheGroupedFactorFallsBackToGroupingOnWhatIsShown() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        let second = document.layout.factors[1].id
        editor.overviewGroupFactorID = second

        editor.setFactorHiddenInOverview(second, true)
        XCTAssertEqual(document.layout.factors[1].hiddenInOverview, true)
        XCTAssertNil(
            editor.overviewGroupFactorID,
            "the blocks cannot be drawn on a factor the wells no longer show"
        )
        XCTAssertEqual(editor.overviewGroupBasis, .allFactors)
    }

    func testHidingIsOneUndoStepAndShowingLeavesNoTrace() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        let second = document.layout.factors[1].id
        // Attached after setup, so the hide is its own undo group.
        let undo = UndoManager()
        editor.undoManager = undo

        editor.setFactorHiddenInOverview(second, true)
        XCTAssertEqual(document.layout.overviewFactors.count, 1)
        XCTAssertEqual(undo.undoActionName, "Hide in Overview")

        undo.undo()
        XCTAssertEqual(document.layout.overviewFactors.count, 2, "undo shows it again")

        undo.redo()
        XCTAssertEqual(document.layout.overviewFactors.count, 1)
        editor.setFactorHiddenInOverview(second, false)
        XCTAssertNil(
            document.layout.factors[1].hiddenInOverview,
            "shown again is nil, not false, so the file is byte-for-byte what it was"
        )
    }

    func testTheLastShownFactorStaysShown() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        let ids = document.layout.factors.map(\.id)

        editor.setFactorHiddenInOverview(ids[0], true)
        editor.setFactorHiddenInOverview(ids[1], true)
        XCTAssertNil(document.layout.factors[1].hiddenInOverview, "Overview cannot be left with nothing to show")
        XCTAssertFalse(editor.transientMessage.isEmpty, "and the refusal is said out loud")
    }

    // MARK: - The outline itself

    /// One segment per cell edge, so a block's outline is its perimeter: a 2×3 block
    /// has ten edges round it, however the plate is turned.
    func testABlocksOutlineIsItsPerimeter() {
        paint(condition, 0, rows: 0...1, cols: 0...2)
        let bounds = NSRect(x: 0, y: 0, width: 900, height: 560)

        for turns in 0..<4 {
            let geo = PlateGeometry(format: format, bounds: bounds, quarterTurns: turns)
            let segments = PlateCanvasView.groupOutlineSegments(
                geo: geo, blocks: blocks(), format: format
            )
            XCTAssertEqual(
                segments.count, 10,
                "a 2×3 block has a ten-edge perimeter — \(turns) quarter turns"
            )
            // And every one of them is a cell edge: horizontal or vertical, one cell long.
            for (from, to) in segments {
                let length = max(abs(from.x - to.x), abs(from.y - to.y))
                XCTAssertEqual(length, geo.cell, accuracy: 0.01)
                XCTAssertTrue(from.x == to.x || from.y == to.y, "segments run along the grid")
            }
        }
    }

    /// Turning the plate must not move the lines relative to the wells. Walked in
    /// display space for exactly that reason: the block is the same block, so the
    /// outline stays wrapped round the same wells.
    func testTheOutlineFollowsTheWellsWhenThePlateIsTurned() {
        paint(condition, 0, rows: 0...1, cols: 0...2)
        let bounds = NSRect(x: 0, y: 0, width: 900, height: 560)
        let upright = PlateGeometry(format: format, bounds: bounds, quarterTurns: 0)
        let turned = PlateGeometry(format: format, bounds: bounds, quarterTurns: 1)

        // The block's own rectangle, as each geometry draws it.
        let painted = WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 1, col: 2))
        for geo in [upright, turned] {
            let frame = geo.rect(of: painted)
            let segments = PlateCanvasView.groupOutlineSegments(
                geo: geo, blocks: blocks(), format: format
            )
            for (from, to) in segments {
                for point in [from, to] {
                    XCTAssertTrue(
                        frame.insetBy(dx: -0.01, dy: -0.01).contains(point),
                        "every outline point should sit on the block being outlined"
                    )
                }
            }
        }
    }

    /// Renders a realistic Overview plate with the outlines on, both ways round, for
    /// eyeballing. `PLATE_GROUPS_DIR=/tmp/groups swift test --filter WellGroupingTests`.
    func testTheGroupedPlateRenders() throws {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        var dose = Factor(name: "Dose", kind: .numeric, unit: "µM")
        dose.levels = [
            Level(name: "10", colorHex: Palette.color(at: 3)),
            Level(name: "1", colorHex: Palette.color(at: 4)),
        ]
        document.layout.factors.append(dose)

        let condition = document.layout.factors[0]
        let format = document.layout.plates[0].format
        for row in 0..<format.rows {
            for col in 0..<format.cols {
                let well = format.index(row: row, col: col)
                guard col < 9 else { continue }   // leave a strip empty
                document.layout.plates[0].setLevelID(
                    condition.levels[col / 3].id, factor: condition.id, well: well
                )
                document.layout.plates[0].setLevelID(
                    dose.levels[row < 4 ? 0 : 1].id, factor: dose.id, well: well
                )
            }
        }
        editor.setWellLabelMode(.overview)
        editor.showOverviewGroups = true

        let frame = NSRect(x: 0, y: 0, width: 940, height: 620)
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        let canvas = PlateCanvasView(frame: frame)
        canvas.attach(editor: editor)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()

        let directory = ProcessInfo.processInfo.environment["PLATE_GROUPS_DIR"]
        for (name, turned) in [("upright", false), ("turned", true)] {
            if turned { editor.rotatePlate() }
            let png = try XCTUnwrap(canvas.pngData(), "\(name) produced no image")
            XCTAssertGreaterThan(png.count, 5000)
            // With the outlines off the same plate has to come out different, or
            // nothing was drawn.
            editor.showOverviewGroups = false
            let plain = try XCTUnwrap(canvas.pngData())
            XCTAssertNotEqual(png, plain, "\(name): the outlines left no mark")
            editor.showOverviewGroups = true

            if let directory {
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: directory), withIntermediateDirectories: true
                )
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
    }

    /// The save panel's checkbox has to actually govern the exported image.
    func testAnExportCanLeaveTheOutlinesOut() throws {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factor = document.layout.factors[0]
        let format = document.layout.plates[0].format
        for col in 0..<3 {
            document.layout.plates[0].setLevelID(
                factor.levels[0].id, factor: factor.id, well: format.index(row: 0, col: col)
            )
        }
        editor.setWellLabelMode(.overview)
        editor.showOverviewGroups = true

        let frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        let canvas = PlateCanvasView(frame: frame)
        canvas.attach(editor: editor)
        NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            .contentView = canvas

        let with = try XCTUnwrap(canvas.pngData(includingGroupOutlines: true))
        let without = try XCTUnwrap(canvas.pngData(includingGroupOutlines: false))
        XCTAssertNotEqual(with, without)
    }

    /// The outline colour and thickness are Settings choices, and the canvas has to
    /// honour both. Compared between renders rather than against a hex: the offscreen
    /// backing store converts colourspaces, so an absolute value is not the same
    /// number that went in — the same reason the empty-well test samples a reference.
    func testTheOutlineTakesItsColourAndWeightFromSettings() throws {
        let previousColor = Preferences.shared.groupOutlineColorHex
        let previousThickness = Preferences.shared.groupOutlineThickness
        defer {
            Preferences.shared.groupOutlineColorHex = previousColor
            Preferences.shared.groupOutlineThickness = previousThickness
        }

        let frame = NSRect(x: 0, y: 0, width: 940, height: 560)
        let plateFormat = PlateFormat.well96
        let geo = PlateGeometry(format: plateFormat, bounds: frame)

        /// Two blocks side by side, so there is an internal seam to sample across.
        func rendered(outlines: Bool) throws -> NSBitmapImageRep {
            let document = PlateDocument()
            let editor = PlateEditor(document: document)
            let factor = document.layout.factors[0]
            for row in 2...5 {
                for col in 0..<8 {
                    document.layout.plates[0].setLevelID(
                        factor.levels[col < 4 ? 0 : 1].id, factor: factor.id,
                        well: plateFormat.index(row: row, col: col)
                    )
                }
            }
            editor.setWellLabelMode(.overview)
            editor.showOverviewGroups = outlines
            editor.selection = nil

            let window = NSWindow(
                contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
            )
            let canvas = PlateCanvasView(frame: frame)
            canvas.attach(editor: editor)
            window.contentView = canvas
            canvas.layoutSubtreeIfNeeded()
            return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.pngData())))
        }

        let seam = geo.cellRect(row: 3, col: 3).maxX
        let y = geo.cellRect(row: 3, col: 3).midY

        /// The pixels across the seam that the outline changed, and their colour.
        func markedPixels(_ rep: NSBitmapImageRep, against plain: NSBitmapImageRep) -> [NSColor] {
            let scale = CGFloat(rep.pixelsWide) / frame.width
            return (-8...8).compactMap { offset -> NSColor? in
                let x = Int((seam + CGFloat(offset)) * scale)
                let row = Int(y * scale)
                guard let drawn = rep.colorAt(x: x, y: row),
                      let before = plain.colorAt(x: x, y: row),
                      drawn.hexString != before.hexString
                else { return nil }
                return drawn.usingColorSpace(.sRGB)
            }
        }

        Preferences.shared.groupOutlineColorHex = "#C1440E"
        Preferences.shared.groupOutlineThickness = 4
        let plain = try rendered(outlines: false)
        let thick = markedPixels(try rendered(outlines: true), against: plain)

        XCTAssertFalse(thick.isEmpty, "the outline left no mark on the seam at all")
        // Every marked pixel is the chosen red rather than the default grey ink.
        for colour in thick {
            XCTAssertGreaterThan(colour.redComponent, colour.greenComponent + 0.2)
            XCTAssertGreaterThan(colour.redComponent, colour.blueComponent + 0.3)
        }

        Preferences.shared.groupOutlineThickness = 1
        let thin = markedPixels(try rendered(outlines: true), against: plain)
        XCTAssertFalse(thin.isEmpty)
        XCTAssertGreaterThan(
            thick.count, thin.count, "4pt should cover more of the seam than 1pt"
        )
    }

    func testEmptyWellsGetNoOutlineAtAll() {
        let bounds = NSRect(x: 0, y: 0, width: 900, height: 560)
        let geo = PlateGeometry(format: format, bounds: bounds, quarterTurns: 0)
        XCTAssertTrue(
            PlateCanvasView.groupOutlineSegments(geo: geo, blocks: blocks(), format: format).isEmpty,
            "an unpainted plate has no blocks to draw"
        )
    }
}

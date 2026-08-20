import XCTest
import Foundation
@testable import PLayout

final class WellNamingTests: XCTestCase {
    func testRowLabelsCoverLargePlates() {
        XCTAssertEqual(WellNaming.rowLabel(0), "A")
        XCTAssertEqual(WellNaming.rowLabel(7), "H")     // last row of a 96
        XCTAssertEqual(WellNaming.rowLabel(15), "P")    // last row of a 384
        XCTAssertEqual(WellNaming.rowLabel(25), "Z")
        XCTAssertEqual(WellNaming.rowLabel(26), "AA")
        XCTAssertEqual(WellNaming.rowLabel(31), "AF")   // last row of a 1536
    }

    func testRowIndexInvertsRowLabel() {
        for row in 0..<40 {
            XCTAssertEqual(WellNaming.rowIndex(WellNaming.rowLabel(row)), row)
        }
        XCTAssertNil(WellNaming.rowIndex("A1"))
        XCTAssertNil(WellNaming.rowIndex(""))
    }

    func testWellLabelPadding() {
        XCTAssertEqual(WellNaming.wellLabel(row: 1, col: 6, padded: false), "B7")
        XCTAssertEqual(WellNaming.wellLabel(row: 1, col: 6, padded: true), "B07")
    }

    func testParseWell() {
        XCTAssertTrue(WellNaming.parseWell("A1")! == (0, 0))
        XCTAssertTrue(WellNaming.parseWell("h12")! == (7, 11))
        XCTAssertTrue(WellNaming.parseWell(" B07 ")! == (1, 6))
        XCTAssertNil(WellNaming.parseWell("12"))
        XCTAssertNil(WellNaming.parseWell("AB"))
    }
}

final class PlateModelTests: XCTestCase {
    private func factor() -> Factor {
        Factor(name: "Condition", levels: [
            Level(name: "Control", colorHex: "#4E79A7"),
            Level(name: "Treated", colorHex: "#F28E2B"),
        ])
    }

    func testAssignmentRoundTrip() {
        let f = factor()
        var plate = Plate(name: "P", format: .well96)
        let well = plate.format.index(row: 3, col: 5)   // D6
        plate.setLevelID(f.levels[1].id, factor: f.id, well: well)
        XCTAssertEqual(plate.levelID(factor: f.id, well: well), f.levels[1].id)
        XCTAssertEqual(plate.assignedWellCount(factor: f.id, level: f.levels[1].id), 1)

        plate.setLevelID(nil, factor: f.id, well: well)
        XCTAssertNil(plate.levelID(factor: f.id, well: well))
        // The whole column is dropped once empty, keeping saved documents small.
        XCTAssertTrue(plate.assignments.isEmpty)
    }

    func testFormatChangeKeepsRowAndColumn() {
        let f = factor()
        var plate = Plate(name: "P", format: .well96)
        plate.setLevelID(f.levels[0].id, factor: f.id, well: plate.format.index(row: 2, col: 4))
        plate.changeFormat(to: .well384)

        XCTAssertEqual(plate.format, PlateFormat.well384)
        // Same C5 well, different linear index.
        XCTAssertEqual(plate.levelID(factor: f.id, well: plate.format.index(row: 2, col: 4)), f.levels[0].id)
    }

    func testShrinkingDetectsDataLoss() {
        let f = factor()
        var plate = Plate(name: "P", format: .well384)
        plate.setLevelID(f.levels[0].id, factor: f.id, well: plate.format.index(row: 12, col: 20))
        XCTAssertTrue(plate.formatChangeWouldLoseData(.well96))
        XCTAssertFalse(plate.formatChangeWouldLoseData(.well1536))

        plate.changeFormat(to: .well96)
        XCTAssertTrue(plate.assignments.isEmpty)
    }

    func testEnsureLevelIsCaseInsensitiveAndStable() {
        var f = factor()
        let existing = f.ensureLevel(named: "  treated ")
        XCTAssertEqual(existing, f.levels[1].id)
        XCTAssertEqual(f.levels.count, 2)

        let fresh = f.ensureLevel(named: "Washout")
        XCTAssertEqual(f.levels.count, 3)
        XCTAssertEqual(f.levels.last?.id, fresh)
    }

    func testRemoveLevelClearsWells() {
        var layout = Layout.starter()
        let f = layout.factors[0]
        let doomed = f.levels[1].id
        layout.plates[0].setLevelID(doomed, factor: f.id, well: 0)
        layout.plates[0].setLevelID(f.levels[0].id, factor: f.id, well: 1)

        layout.removeLevel(doomed, from: f.id)
        XCTAssertNil(layout.plates[0].levelID(factor: f.id, well: 0))
        XCTAssertEqual(layout.plates[0].levelID(factor: f.id, well: 1), f.levels[0].id)
        XCTAssertEqual(layout.factors[0].levels.count, 2)
    }

    func testDocumentJSONRoundTrip() throws {
        var layout = Layout.starter()
        let f = layout.factors[0]
        layout.plates[0].setLevelID(f.levels[0].id, factor: f.id, well: 11)
        layout.padWellLabels = true

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(Layout.self, from: data)
        XCTAssertEqual(decoded, layout)
    }
}

final class SelectionTests: XCTestCase {
    func testIndicesAreRowMajorAndClipped() {
        let format = PlateFormat.well96
        let range = WellRange(anchor: WellPos(row: 1, col: 2), focus: WellPos(row: 2, col: 3))
        XCTAssertEqual(range.indices(in: format), [14, 15, 26, 27])
    }

    func testOutOfBoundsSelectionDoesNotTrap() {
        // A selection left over from a 384 plate must not crash on a 96 plate.
        let stale = WellRange(anchor: WellPos(row: 12, col: 20), focus: WellPos(row: 14, col: 22))
        XCTAssertEqual(stale.indices(in: .well96), [95])

        let farOff = WellRange(anchor: WellPos(row: 40, col: 40), focus: WellPos(row: 41, col: 41))
        XCTAssertEqual(farOff.indices(in: .well96), [95])
    }

    func testWholeRowAndColumn() {
        XCTAssertEqual(WellRange.wholeRow(0, format: .well96).indices(in: .well96), Array(0..<12))
        XCTAssertEqual(WellRange.wholeColumn(0, format: .well96).indices(in: .well96),
                       stride(from: 0, to: 96, by: 12).map { $0 })
        XCTAssertEqual(WellRange.wholePlate(.well96).wellCount, 96)
    }
}

final class TableIOTests: XCTestCase {
    func testTSVRoundTripPadsRaggedRows() {
        let grid = TSV.parse("a\tb\tc\nd\te\n")
        XCTAssertEqual(grid, [["a", "b", "c"], ["d", "e", ""]])
        XCTAssertEqual(TSV.serialize([["a", "b"], ["c", "d"]]), "a\tb\nc\td")
    }

    func testTSVHandlesWindowsLineEndings() {
        XCTAssertEqual(TSV.parse("a\tb\r\nc\td\r\n"), [["a", "b"], ["c", "d"]])
    }

    func testPlateHeadersAreStripped() {
        let pasted = "\t1\t2\t3\nA\tCtrl\tCtrl\tDrug\nB\tCtrl\tDrug\tDrug\n"
        let stripped = TSV.strippingPlateHeaders(TSV.parse(pasted))
        XCTAssertEqual(stripped, [["Ctrl", "Ctrl", "Drug"], ["Ctrl", "Drug", "Drug"]])
    }

    func testHeaderlessDataIsLeftAlone() {
        let pasted = "Ctrl\tDrug\nCtrl\tDrug\n"
        let grid = TSV.parse(pasted)
        XCTAssertEqual(TSV.strippingPlateHeaders(grid), grid)
    }

    /// An absent header is not a header. Every one of the three tests used to accept a
    /// blank cell, so a copied block that merely had nothing painted down its left edge
    /// and across its top passed all three and was stripped: ⌘V landed a row up and a
    /// column left of where it was aimed, and the row and column that were eaten never
    /// cleared the wells they covered. Copying a blank block to clear a region is the
    /// same bug — it cleared one row and one column less than it covered.
    func testAnUnpaintedEdgeIsNotAPlateHeader() {
        let copied = TSV.parse("\t\t\t\n\tX\tY\tZ\n\tX\tY\tZ\n\tX\tY\tZ\n")
        XCTAssertEqual(copied.count, 4)
        XCTAssertEqual(TSV.strippingPlateHeaders(copied), copied, "no header is present to strip")

        let blank = TSV.parse("\t\t\n\t\t\n\t\t\n")
        XCTAssertEqual(TSV.strippingPlateHeaders(blank), blank, "all 3 × 3 of it must reach the plate")
    }

    /// And a header that is only half there is not evidence either: a top row of column
    /// numbers with gaps in it is data as far as this can tell, and guessing wrong moves
    /// every value by one well.
    func testAPartialHeaderRowIsNotStripped() {
        let gappy = TSV.parse("\t1\t\t3\nA\tCtrl\tCtrl\tDrug\nB\tCtrl\tDrug\tDrug\n")
        XCTAssertEqual(TSV.strippingPlateHeaders(gappy), gappy)

        let gappyLeft = TSV.parse("\t1\t2\t3\nA\tCtrl\tCtrl\tDrug\n\tCtrl\tDrug\tDrug\n")
        XCTAssertEqual(TSV.strippingPlateHeaders(gappyLeft), gappyLeft)
    }

    func testCSVQuotingRoundTrip() {
        let grid = [["plain", "has,comma"], ["has\"quote", "has\nnewline"]]
        XCTAssertEqual(CSV.parse(CSV.serialize(grid)), grid)
    }

    /// A blank row at the bottom of a plate map is a statement — those wells are empty —
    /// and import clears them for it. CSV used to delete every trailing all-empty row, so
    /// the file extension decided which wells changed: the same 8-row map cleared row H
    /// as .tsv and left it painted as .csv. Both parsers now keep it.
    func testABlankBottomRowOfAPlateMapSurvivesInBothFormats() {
        let csv = "Ctrl,Ctrl,Drug\nCtrl,Drug,Drug\n,,\n"
        let tsv = "Ctrl\tCtrl\tDrug\nCtrl\tDrug\tDrug\n\t\t\n"
        let expected = [["Ctrl", "Ctrl", "Drug"], ["Ctrl", "Drug", "Drug"], ["", "", ""]]
        XCTAssertEqual(TSV.parse(tsv), expected)
        XCTAssertEqual(CSV.parse(csv), expected, "the same map must import the same way")
    }

    /// The one trailing row that is not a row of wells: the empty field a file's last
    /// newline leaves behind. Keeping it would paste a phantom blank line onto the plate,
    /// so it goes — in both formats, and however many of them there are.
    func testATrailingNewlineIsNotARowOfWells() {
        XCTAssertEqual(CSV.parse("a,b\nc,d\n"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(CSV.parse("a,b\nc,d\n\n\n"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(TSV.parse("a\tb\nc\td\n\n\n"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(CSV.parse(""), [])
        XCTAssertEqual(TSV.parse(""), [])
    }

    func testTidyGridHasOneRowPerWell() {
        var layout = Layout.starter()
        let f = layout.factors[0]
        layout.plates[0].setLevelID(f.levels[2].id, factor: f.id, well: 0)

        let grid = Exporter.tidyGrid(layout: layout)
        XCTAssertEqual(grid.count, 97)                       // header + 96 wells
        XCTAssertEqual(grid[0], ["Well", "Row", "Column", "Condition"])
        XCTAssertEqual(grid[1], ["A1", "A", "1", "Treated"])
        XCTAssertEqual(grid[2], ["A2", "A", "2", ""])
    }

    func testTidyGridNamesPlatesWhenThereAreSeveral() {
        var layout = Layout.starter()
        layout.plates.append(Plate(name: "Plate 2", format: .well6))
        let grid = Exporter.tidyGrid(layout: layout)
        XCTAssertEqual(grid[0].first, "Plate")
        XCTAssertEqual(grid.count, 1 + 96 + 6)
    }
}

final class SeriesTests: XCTestCase {
    private func editorWithSelection(_ range: WellRange) -> PlateEditor {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.selection = range
        return editor
    }

    func testThreeFoldDilutionAcrossColumns() {
        let editor = editorWithSelection(
            WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 7, col: 5))
        )
        var spec = PlateEditor.SeriesSpec()
        spec.start = 10
        spec.foldFactor = 3
        XCTAssertEqual(editor.seriesValues(spec), ["10", "3.33", "1.11", "0.37", "0.123", "0.0412"])
    }

    func testLastPositionCanBeVehicle() {
        let editor = editorWithSelection(
            WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 0, col: 3))
        )
        var spec = PlateEditor.SeriesSpec()
        spec.start = 100
        spec.foldFactor = 10
        spec.lastIsZero = true
        XCTAssertEqual(editor.seriesValues(spec), ["100", "10", "1", "0"])
    }

    func testLinearStepDownRows() {
        let editor = editorWithSelection(
            WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 3, col: 0))
        )
        var spec = PlateEditor.SeriesSpec()
        spec.direction = .downRows
        spec.mode = .linear
        spec.start = 24
        spec.step = -6
        XCTAssertEqual(editor.seriesValues(spec), ["24", "18", "12", "6"])
    }

    func testApplySeriesWritesEveryRowOfTheSelection() {
        let editor = editorWithSelection(
            WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 1, col: 2))
        )
        var spec = PlateEditor.SeriesSpec()
        spec.start = 9
        spec.foldFactor = 3
        editor.applySeries(spec)

        let layout = editor.document.layout
        let factor = layout.factors[0]
        XCTAssertEqual(factor.kind, .numeric)
        let plate = layout.plates[0]
        for row in 0..<2 {
            let names = (0..<3).map { col -> String in
                let id = plate.levelID(factor: factor.id, well: plate.format.index(row: row, col: col))
                return factor.level(id: id)?.name ?? ""
            }
            XCTAssertEqual(names, ["9", "3", "1"], "row \(row)")
        }
    }
}

final class EditorTests: XCTestCase {
    func testPaintAndUndo() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let undo = UndoManager()
        editor.undoManager = undo

        let factor = document.layout.factors[0]
        editor.selection = WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 1, col: 1))
        editor.armedLevelID = factor.levels[1].id
        editor.paintSelection()

        XCTAssertEqual(document.layout.plates[0].assignedWellCount(factor: factor.id, level: factor.levels[1].id), 4)
        undo.undo()
        XCTAssertEqual(document.layout.plates[0].assignedWellCount(factor: factor.id, level: factor.levels[1].id), 0)
        undo.redo()
        XCTAssertEqual(document.layout.plates[0].assignedWellCount(factor: factor.id, level: factor.levels[1].id), 4)
    }

    func testPasteCreatesMissingConditions() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.selection = WellRange(single: WellPos(row: 0, col: 0))

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Untreated\tsiCTRL\nsiCTRL\tsiTARGET", forType: .string)
        editor.pasteFromPasteboard()

        let factor = document.layout.factors[0]
        // "Untreated" already existed; the two siRNA values are new.
        XCTAssertEqual(factor.levels.count, 5)
        XCTAssertNotNil(factor.level(named: "siTARGET"))

        let plate = document.layout.plates[0]
        let value = { (r: Int, c: Int) -> String? in
            factor.level(id: plate.levelID(factor: factor.id, well: plate.format.index(row: r, col: c)))?.name
        }
        XCTAssertEqual(value(0, 0), "Untreated")
        XCTAssertEqual(value(0, 1), "siCTRL")
        XCTAssertEqual(value(1, 1), "siTARGET")
        XCTAssertNil(value(2, 0))
        // Selection follows the pasted block, like Excel.
        XCTAssertEqual(editor.selection?.wellCount, 4)
    }

    func testCopyProducesTabSeparatedText() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factor = document.layout.factors[0]
        editor.selection = WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 0, col: 1))
        editor.armedLevelID = factor.levels[0].id
        editor.paint(wells: [0], level: factor.levels[0].id)

        editor.copySelection()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Untreated\t")

        editor.copySelection(includeHeaders: true)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "\t1\t2\nA\tUntreated\t")
    }

    func testRandomiseKeepsCounts() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let factor = document.layout.factors[0]
        editor.selection = WellRange.wholeRow(0, format: .well96)
        editor.paint(wells: Array(0..<6), level: factor.levels[0].id)
        editor.randomizeSelection()

        XCTAssertEqual(document.layout.plates[0].assignedWellCount(factor: factor.id, level: factor.levels[0].id), 6)
    }

    func testClearAllFactorsWipesEveryLayer() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        let second = editor.activeFactorID!
        editor.paint(wells: [0], level: document.layout.factors[1].levels[0].id)
        editor.setActiveFactor(document.layout.factors[0].id)
        editor.paint(wells: [0], level: document.layout.factors[0].levels[0].id)

        editor.selection = WellRange(single: WellPos(row: 0, col: 0))
        editor.clearSelectionAllFactors()

        XCTAssertNil(document.layout.plates[0].levelID(factor: second, well: 0))
        XCTAssertNil(document.layout.plates[0].levelID(factor: document.layout.factors[0].id, well: 0))
    }
}

final class WorkbookTests: XCTestCase {
    private func sampleLayout() -> Layout {
        var layout = Layout.starter()
        let factor = layout.factors[0]
        layout.plates[0].setLevelID(factor.levels[0].id, factor: factor.id, well: 0)
        layout.plates[0].setLevelID(factor.levels[2].id, factor: factor.id, well: 13)
        var dose = Factor(name: "Dose", kind: .numeric, unit: "µM")
        dose.levels = [Level(name: "10", colorHex: "#1B3A5C"), Level(name: "1", colorHex: "#AFC8DD")]
        layout.factors.append(dose)
        layout.plates[0].setLevelID(dose.levels[0].id, factor: dose.id, well: 0)
        return layout
    }

    /// Unzips a workbook into a scratch directory the caller can inspect.
    private func extract(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("layout.xlsx")
        try data.write(to: file)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", file.path, "-d", directory.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0, "unzip rejected the workbook")
        return directory
    }

    private func allWorksheetXML(in directory: URL) throws -> String {
        let sheets = directory.appendingPathComponent("xl/worksheets")
        return try FileManager.default.contentsOfDirectory(atPath: sheets.path)
            .filter { $0.hasSuffix(".xml") }
            .map { try String(contentsOf: sheets.appendingPathComponent($0), encoding: .utf8) }
            .joined()
    }

    func testJointMapJoinsEveryFactorInOneCell() throws {
        let directory = try extract(Exporter.workbook(from: sampleLayout(), jointSeparator: "+"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let book = try String(contentsOf: directory.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)
        XCTAssertTrue(book.contains("Combined"), "the one-cell map gets its own tab")

        let xml = try allWorksheetXML(in: directory)
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">Untreated+10</t>"), "A1 joins both factors")
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">Treated</t>"), "a single value takes no separator")
    }

    func testJointMapIsOffByDefault() throws {
        let directory = try extract(Exporter.workbook(from: sampleLayout()))
        defer { try? FileManager.default.removeItem(at: directory) }

        let book = try String(contentsOf: directory.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)
        XCTAssertFalse(book.contains("Combined"), "no joint tab unless asked for")
    }

    func testABlankSeparatorFallsBackToPlus() {
        XCTAssertEqual(WorkbookJointMap(enabled: true, separator: "").resolvedSeparator, "+")
        XCTAssertEqual(WorkbookJointMap(enabled: true, separator: " / ").resolvedSeparator, " / ")
    }

    func testWorkbookIsAWellFormedZip() throws {
        let data = Exporter.workbook(from: sampleLayout())
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])  // "PK\003\004"

        // End-of-central-directory signature must terminate the archive.
        let tail = Array(data.suffix(22))
        XCTAssertEqual(Array(tail.prefix(4)), [0x50, 0x4B, 0x05, 0x06])
    }

    func testWorkbookOpensWithSystemUnarchiver() throws {
        let data = Exporter.workbook(from: sampleLayout())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("layout.xlsx")
        try data.write(to: file)

        // /usr/bin/unzip validates CRCs and the deflate streams for us.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", file.path, "-d", directory.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0, "unzip rejected the workbook")

        let parts = [
            "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
            "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml",
        ]
        for part in parts {
            let url = directory.appendingPathComponent(part)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(part)")
            // Parsing with XMLDocument proves each part is well-formed XML.
            let xml = try Data(contentsOf: url)
            XCTAssertNoThrow(try XMLDocument(data: xml, options: []), "malformed \(part)")
        }

        let sheet = try String(contentsOf: directory.appendingPathComponent("xl/worksheets/sheet1.xml"), encoding: .utf8)
        XCTAssertTrue(sheet.contains("<t xml:space=\"preserve\">Untreated</t>"))
        XCTAssertTrue(sheet.contains("state=\"frozen\""))

        let styles = try String(contentsOf: directory.appendingPathComponent("xl/styles.xml"), encoding: .utf8)
        // Painted colours survive into the workbook as solid fills. Taken from the
        // palette rather than written out as a literal: hard-coding the hex made this
        // fail the moment the palette was retuned, which says nothing about the export.
        let painted = "FF" + Palette.color(at: 0).dropFirst().uppercased()
        XCTAssertTrue(styles.contains(painted), "level colour \(painted) missing from styles.xml")
    }

    func testWorkbookHasASheetPerFactorPlusTidyAndLegend() throws {
        let layout = sampleLayout()
        let data = Exporter.workbook(from: layout)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plate-sheets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("layout.xlsx")
        try data.write(to: file)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", file.path, "-d", directory.path]
        try unzip.run()
        unzip.waitUntilExit()

        let workbook = try String(contentsOf: directory.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)
        XCTAssertTrue(workbook.contains("Plate 1 · Condition"))
        XCTAssertTrue(workbook.contains("Plate 1 · Dose"))
        XCTAssertTrue(workbook.contains("name=\"Wells\""))
        XCTAssertTrue(workbook.contains("name=\"Legend\""))
    }

    /// Writes a real workbook out when PLATE_XLSX_PATH is set, for checking against
    /// an actual spreadsheet reader.
    func testWorkbookCanBeWrittenForExternalChecking() throws {
        if let path = ProcessInfo.processInfo.environment["PLATE_XLSX_PATH"] {
            try Exporter.workbook(from: sampleLayout()).write(to: URL(fileURLWithPath: path))
        }
        if let path = ProcessInfo.processInfo.environment["PLATE_XLSX_COMBINED_PATH"] {
            try Exporter.workbook(from: sampleLayout(), sheetLayout: .allFactorsOneSheet)
                .write(to: URL(fileURLWithPath: path))
        }
    }

    /// Writes a document file when PLATE_DOC_PATH is set, for opening in the real app.
    func testDocumentCanBeWrittenForExternalChecking() throws {
        guard let path = ProcessInfo.processInfo.environment["PLATE_DOC_PATH"] else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sampleLayout()).write(to: URL(fileURLWithPath: path))
    }

    /// The combined layout puts every factor on one sheet per plate, each map under
    /// its own heading, instead of a tab per factor.
    func testCombinedLayoutUsesOneSheetPerPlate() throws {
        var layout = sampleLayout()
        layout.plates.append(Plate(name: "Plate 2", format: .well6))

        let perFactor = try sheetNames(of: Exporter.workbook(from: layout, sheetLayout: .sheetPerFactor))
        XCTAssertEqual(
            perFactor,
            ["Plate 1 · Condition", "Plate 1 · Dose", "Plate 2 · Condition", "Plate 2 · Dose",
             "Wells", "Legend"]
        )

        let combined = try sheetNames(of: Exporter.workbook(from: layout, sheetLayout: .allFactorsOneSheet))
        XCTAssertEqual(combined, ["Plate 1", "Plate 2", "Wells", "Legend"])
    }

    /// The save panel's plate scope: one plate id keeps exactly that plate's maps
    /// and rows, and an id that matches nothing keeps the whole document rather
    /// than exporting an empty workbook.
    func testWorkbookCanCoverJustOnePlate() throws {
        var layout = sampleLayout()
        layout.plates.append(Plate(name: "Plate 2", format: .well6))

        let only = try sheetNames(of: Exporter.workbook(
            from: layout, sheetLayout: .sheetPerFactor, onlyPlate: layout.plates[1].id
        ))
        XCTAssertEqual(only, ["Plate 2 · Condition", "Plate 2 · Dose", "Wells", "Legend"])

        let combined = try sheetNames(of: Exporter.workbook(
            from: layout, sheetLayout: .allFactorsOneSheet, onlyPlate: layout.plates[0].id
        ))
        XCTAssertEqual(combined, ["Plate 1", "Wells", "Legend"])

        let unknown = try sheetNames(of: Exporter.workbook(
            from: layout, sheetLayout: .sheetPerFactor, onlyPlate: UUID()
        ))
        XCTAssertEqual(unknown.count, 6, "an unmatched id should keep every plate")
    }

    func testWorkbookScopeIsRememberedLikeTheArrangement() {
        let key = "workbookScope"
        // `AppDefaults.store`, not `UserDefaults.standard`: under XCTest that is a scratch
        // domain, so this cannot reach the preferences of the app you actually use.
        let previous = AppDefaults.store.string(forKey: key)
        defer {
            if let previous {
                AppDefaults.store.set(previous, forKey: key)
            } else {
                AppDefaults.store.removeObject(forKey: key)
            }
        }

        AppDefaults.store.removeObject(forKey: key)
        XCTAssertEqual(WorkbookScope.remembered, .allPlates)
        WorkbookScope.activePlate.remember()
        XCTAssertEqual(WorkbookScope.remembered, .activePlate)
        AppDefaults.store.set("everything-twice", forKey: key)
        XCTAssertEqual(WorkbookScope.remembered, .allPlates, "garbage should fall back")
    }

    // MARK: - The pipetting prep tab

    /// A layout with a dose series and one compound, ready to prep.
    private func prepLayout() -> Layout {
        var layout = Layout(plates: [Plate(name: "Plate 1", format: .well96)])
        var dose = Factor(name: "Dose", kind: .numeric, unit: "µM")
        for (index, name) in ["10", "3.33", "1.11", "0"].enumerated() {
            dose.levels.append(Level(name: name, colorHex: Palette.color(at: index)))
        }
        var drug = Factor(name: "Drug")
        drug.levels = [
            Level(name: "Cpd1", colorHex: Palette.color(at: 5),
                  stock: StockConcentration(value: 10, unit: "mM")),
        ]
        layout.factors = [drug, dose]
        for (index, level) in dose.levels.enumerated() {
            for well in (index * 12)..<(index * 12 + 12) {
                layout.plates[0].setLevelID(level.id, factor: dose.id, well: well)
                layout.plates[0].setLevelID(drug.levels[0].id, factor: drug.id, well: well)
            }
        }
        var prep = PrepSetup()
        prep.doseFactorID = dose.id
        prep.compoundFactorID = drug.id
        prep.wellVolume = 100
        prep.addedVolume = 10
        layout.prep = prep
        return layout
    }

    func testThePrepTabAppearsOnlyWhenThereIsASetup() throws {
        var layout = prepLayout()
        XCTAssertTrue(try sheetNames(of: Exporter.workbook(from: layout)).contains("Prep"))

        layout.prep = nil
        XCTAssertFalse(
            try sheetNames(of: Exporter.workbook(from: layout)).contains("Prep"),
            "a document that never used the prep sheet exports exactly as before"
        )
    }

    func testTurningOffIncludeInWorkbookRemovesTheTab() throws {
        var layout = prepLayout()
        layout.prep?.includeInWorkbook = false
        XCTAssertFalse(try sheetNames(of: Exporter.workbook(from: layout)).contains("Prep"))
    }

    /// The Prep tab's XML, or "" when the workbook has no such tab.
    private func prepSheetXML(of data: Data) throws -> String {
        guard let index = try sheetNames(of: data).firstIndex(of: "Prep") else { return "" }
        let directory = try unzip(data)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try String(
            contentsOf: directory.appendingPathComponent("xl/worksheets/sheet\(index + 1).xml"),
            encoding: .utf8
        )
    }

    /// A refusal is the one thing the bench must not miss, and a tab gated on "has tubes"
    /// hid exactly that. `DilutionPlan` answers an added volume larger than the well with
    /// no compounds at all and the reason in `warnings`, so the workbook came out with no
    /// Prep tab and no message, while the window and the printout — which ask
    /// `!isEmpty || !allWarnings.isEmpty` — both showed the error.
    func testThePrepTabCarriesARefusalThatLeavesNothingToMake() throws {
        var layout = prepLayout()
        layout.prep?.addedVolume = 150          // into a well that ends up holding 100 µL
        let plan = try XCTUnwrap(DilutionPlan.make(from: layout))
        XCTAssertTrue(plan.isEmpty, "the premise: nothing to make, something to say")

        let xml = try prepSheetXML(of: Exporter.workbook(from: layout))
        XCTAssertFalse(xml.isEmpty, "the tab that carries the refusal is the one that vanished")
        XCTAssertTrue(xml.contains("Before you start"), "an emitted sheet has to say why")
        for warning in plan.allWarnings {
            XCTAssertTrue(xml.contains(warning.text), "the sheet omits: \(warning.text)")
        }
    }

    /// The other half of that rule, so widening the gate cannot leave a sheet of nothing
    /// but headings in the workbook: a setup over an unpainted plate has no tubes *and*
    /// nothing to warn about, and still adds no tab.
    func testAPrepSetupWithNothingToSayStillAddsNoTab() throws {
        var layout = prepLayout()
        let dose = try XCTUnwrap(layout.factors.first { $0.name == "Dose" })
        for well in 0..<layout.plates[0].format.wellCount {
            layout.plates[0].setLevelID(nil, factor: dose.id, well: well)
        }
        let plan = try XCTUnwrap(DilutionPlan.make(from: layout))
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.allWarnings.isEmpty, "the premise: nothing to say either")

        XCTAssertFalse(try sheetNames(of: Exporter.workbook(from: layout)).contains("Prep"))
    }

    /// Zero is not a concentration anything can be diluted from: the plan refuses to use
    /// such a stock and warns that there is none. Printing "stock 0 mM" beside the tubes
    /// therefore states a value the rest of the sheet denies — and a zero-with-a-unit is
    /// what a document carries whenever the unit was typed before the number. The window
    /// and the printout ask `isUsable`; the workbook only checked for nil.
    func testAStockOfZeroReadsAsNoStockSetInTheWorkbook() throws {
        var layout = prepLayout()
        let unset = StockConcentration(value: 0, unit: "mM")
        XCTAssertFalse(unset.isUsable)
        let drug = try XCTUnwrap(layout.factors.firstIndex { $0.name == "Drug" })
        layout.factors[drug].levels[0].stock = unset

        let xml = try prepSheetXML(of: Exporter.workbook(from: layout))
        XCTAssertFalse(xml.contains("stock \(unset.label)"), "0 mM is not a stock to take from")
        XCTAssertTrue(xml.contains("no stock set"), "the words the window and the printout use")
    }

    /// The volumes have to arrive as numbers, or nobody can sum a column of them.
    func testThePrepTabCarriesVolumesAsNumbers() throws {
        let data = Exporter.workbook(from: prepLayout())
        let directory = try unzip(data)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = try sheetNames(of: data)
        let index = try XCTUnwrap(names.firstIndex(of: "Prep"))
        let xml = try String(
            contentsOf: directory.appendingPathComponent("xl/worksheets/sheet\(index + 1).xml"),
            encoding: .utf8
        )
        XCTAssertTrue(xml.contains("Cpd1"), "the compound heading is missing")
        XCTAssertTrue(xml.contains("stock 10 mM"))
        // 12 wells × 10 µL + 20 % = 144 µL for the bottom tube, and it transfers nothing.
        XCTAssertTrue(xml.contains("<v>144</v>"), "the bottom tube's total should be a number")
        XCTAssertNoThrow(try XMLDocument(data: Data(xml.utf8), options: []))
    }

    /// The save panel's plate scope is one filter at the top; the prep counts follow it.
    func testThePrepTabFollowsTheSavePanelPlateScope() throws {
        var layout = prepLayout()
        var second = layout.plates[0]
        second.id = UUID()
        second.name = "Plate 2"
        layout.plates.append(second)

        func total(_ data: Data) throws -> String {
            let directory = try unzip(data)
            defer { try? FileManager.default.removeItem(at: directory) }
            let index = try XCTUnwrap(try sheetNames(of: data).firstIndex(of: "Prep"))
            return try String(
                contentsOf: directory.appendingPathComponent("xl/worksheets/sheet\(index + 1).xml"),
                encoding: .utf8
            )
        }
        // Both plates: 24 wells at the bottom dose, so 288 µL rather than 144.
        XCTAssertTrue(try total(Exporter.workbook(from: layout)).contains("<v>288</v>"))
        XCTAssertTrue(
            try total(Exporter.workbook(from: layout, onlyPlate: layout.plates[0].id))
                .contains("<v>144</v>"),
            "one plate's workbook should prep for one plate"
        )
    }

    func testAPlateNamedPrepDoesNotCollideWithThePrepTab() throws {
        var layout = prepLayout()
        layout.plates[0].name = "Prep"
        let names = try sheetNames(of: Exporter.workbook(from: layout))
        XCTAssertEqual(Set(names).count, names.count, "sheet names must stay unique: \(names)")
        XCTAssertTrue(names.contains("Prep"))
    }

    func testCombinedSheetHeadsEachMapWithItsFactorName() throws {
        let data = Exporter.workbook(from: sampleLayout(), sheetLayout: .allFactorsOneSheet)
        let directory = try unzip(data)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sheet = try String(
            contentsOf: directory.appendingPathComponent("xl/worksheets/sheet1.xml"), encoding: .utf8
        )
        XCTAssertTrue(sheet.contains(">Condition<"), "missing the first factor heading")
        XCTAssertTrue(sheet.contains(">Dose (µM)<"), "heading should use the factor's unit too")
        XCTAssertTrue(sheet.contains("<t xml:space=\"preserve\">Untreated</t>"))

        // Second block starts below the first: 1 title + 1 header + 8 rows + 1 gap.
        XCTAssertTrue(sheet.contains("r=\"A1\""), "first heading should be in A1")
        XCTAssertTrue(sheet.contains("r=\"A12\""), "second heading should follow the first block")
    }

    func testBothLayoutsProduceWorkbooksTheSystemUnarchiverAccepts() throws {
        for sheetLayout in WorkbookLayout.allCases {
            let data = Exporter.workbook(from: sampleLayout(), sheetLayout: sheetLayout)
            let directory = try unzip(data)
            defer { try? FileManager.default.removeItem(at: directory) }
            for part in ["[Content_Types].xml", "xl/workbook.xml", "xl/styles.xml",
                         "xl/worksheets/sheet1.xml"] {
                let url = directory.appendingPathComponent(part)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(sheetLayout): \(part)")
                XCTAssertNoThrow(
                    try XMLDocument(data: try Data(contentsOf: url), options: []),
                    "\(sheetLayout): malformed \(part)"
                )
            }
        }
    }

    func testRememberedLayoutRoundTrips() {
        let original = WorkbookLayout.remembered
        defer { original.remember() }

        WorkbookLayout.allFactorsOneSheet.remember()
        XCTAssertEqual(WorkbookLayout.remembered, .allFactorsOneSheet)
        WorkbookLayout.sheetPerFactor.remember()
        XCTAssertEqual(WorkbookLayout.remembered, .sheetPerFactor)
    }

    /// Unzips with /usr/bin/unzip, which validates CRCs and the deflate streams.
    private func unzip(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plate-xlsx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("book.xlsx")
        try data.write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", file.path, "-d", directory.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip rejected the workbook")
        return directory
    }

    private func sheetNames(of data: Data) throws -> [String] {
        let directory = try unzip(data)
        defer { try? FileManager.default.removeItem(at: directory) }
        let xml = try String(
            contentsOf: directory.appendingPathComponent("xl/workbook.xml"), encoding: .utf8
        )
        return xml.components(separatedBy: "<sheet name=\"").dropFirst().compactMap {
            $0.components(separatedBy: "\"").first
        }
    }

    func testCellReferences() {
        XCTAssertEqual(XLSX.reference(row: 0, col: 0), "A1")
        XCTAssertEqual(XLSX.reference(row: 7, col: 25), "Z8")
        XCTAssertEqual(XLSX.reference(row: 0, col: 26), "AA1")
        XCTAssertEqual(XLSX.reference(row: 0, col: 47), "AV1")   // 1536-well last column
    }
}

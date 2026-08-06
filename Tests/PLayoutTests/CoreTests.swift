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

    func testCSVQuotingRoundTrip() {
        let grid = [["plain", "has,comma"], ["has\"quote", "has\nnewline"]]
        XCTAssertEqual(CSV.parse(CSV.serialize(grid)), grid)
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
        // Painted colours survive into the workbook as solid fills.
        XCTAssertTrue(styles.contains("FF4E79A7"), "level colour missing from styles.xml")
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

import XCTest
import AppKit
@testable import PLayout

/// Renders the grid offscreen so the drawing code can be eyeballed without a GUI session.
/// Set PLATE_PREVIEW_PATH to write the PNG somewhere; otherwise this only checks it renders.
final class RenderPreviewTests: XCTestCase {

    private func demoEditor() -> PlateEditor {
        let document = PlateDocument()
        var layout = Layout()

        var compound = Factor(name: "Compound")
        compound.levels = [
            Level(name: "DMSO", colorHex: Palette.color(at: 5)),
            Level(name: "Cmpd A", colorHex: Palette.color(at: 0)),
            Level(name: "Cmpd B", colorHex: Palette.color(at: 1)),
            Level(name: "Blank", colorHex: Palette.color(at: 8)),
        ]

        var dose = Factor(name: "Dose", kind: .numeric, unit: "µM")
        let doseRamp = Palette.ramp(count: 5, baseHex: Palette.color(at: 4))
        dose.levels = zip(["30", "10", "3.3", "1.1", "0.37"], doseRamp).map {
            Level(name: $0, colorHex: $1)
        }

        var cellLine = Factor(name: "Cell line")
        cellLine.levels = [
            Level(name: "HeLa", colorHex: Palette.color(at: 2)),
            Level(name: "U2OS", colorHex: Palette.color(at: 3)),
        ]

        var plate = Plate(name: "Plate 1", format: .well96)
        let format = plate.format

        for row in 0..<format.rows {
            for col in 0..<format.cols {
                let well = format.index(row: row, col: col)

                plate.setLevelID(
                    cellLine.levels[row < 4 ? 0 : 1].id, factor: cellLine.id, well: well
                )

                switch col {
                case 0:
                    plate.setLevelID(compound.levels[0].id, factor: compound.id, well: well)
                case 1...5:
                    plate.setLevelID(compound.levels[1].id, factor: compound.id, well: well)
                    plate.setLevelID(dose.levels[col - 1].id, factor: dose.id, well: well)
                case 6...10:
                    plate.setLevelID(compound.levels[2].id, factor: compound.id, well: well)
                    plate.setLevelID(dose.levels[col - 6].id, factor: dose.id, well: well)
                default:
                    plate.setLevelID(compound.levels[3].id, factor: compound.id, well: well)
                }
            }
        }

        layout.factors = [compound, dose, cellLine]
        layout.plates = [plate]
        document.layout = layout

        let editor = PlateEditor(document: document)
        editor.activePlateID = plate.id
        editor.setActiveFactor(compound.id)
        editor.selection = WellRange(anchor: WellPos(row: 2, col: 1), focus: WellPos(row: 5, col: 5))
        return editor
    }

    func testCanvasRendersPlate() throws {
        let editor = demoEditor()
        let frame = NSRect(x: 0, y: 0, width: 940, height: 560)

        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        let canvas = PlateCanvasView(frame: frame)
        canvas.attach(editor: editor)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()

        let png = try XCTUnwrap(canvas.pngData(), "canvas produced no image")
        XCTAssertGreaterThan(png.count, 5000)
        let image = try XCTUnwrap(NSImage(data: png))
        XCTAssertGreaterThan(image.size.width, 100)

        if let path = ProcessInfo.processInfo.environment["PLATE_PREVIEW_PATH"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    func testDenseFormatsStillRender() throws {
        let frame = NSRect(x: 0, y: 0, width: 940, height: 560)
        for (format, key) in [(PlateFormat.well384, "PLATE_PREVIEW_384_PATH"),
                              (PlateFormat.well1536, "PLATE_PREVIEW_1536_PATH")] {
            let editor = demoEditor()
            editor.document.mutate("resize", undoManager: nil) { layout in
                layout.plates[0].changeFormat(to: format)
            }
            editor.selection = WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 3, col: 3))

            let window = NSWindow(
                contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
            )
            let canvas = PlateCanvasView(frame: frame)
            canvas.attach(editor: editor)
            window.contentView = canvas

            let png = try XCTUnwrap(canvas.pngData(), "\(format.name) produced no image")
            if let path = ProcessInfo.processInfo.environment[key] {
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Every shape, at every canvas size, must be drawn entirely inside the rect it
    /// was handed — anything outside is invisible and unclickable.
    func testGeometryNeverOverflowsItsBounds() {
        let shapes: [PlateFormat] = PlateFormat.standard + [
            PlateFormat(rows: 1, cols: 96),
            PlateFormat(rows: 64, cols: 1),
            PlateFormat(rows: 64, cols: 96),
            PlateFormat(rows: 2, cols: 3),
            PlateFormat(rows: 5, cols: 7),
            PlateFormat(rows: 1, cols: 1),
        ]
        let canvases: [NSRect] = [
            NSRect(x: 0, y: 0, width: 940, height: 560),
            NSRect(x: 0, y: 0, width: 1000, height: 730),
            NSRect(x: 0, y: 0, width: 420, height: 320),
            NSRect(x: 0, y: 0, width: 200, height: 150),
        ]

        for format in shapes {
            for bounds in canvases {
                let geo = PlateGeometry(format: format, bounds: bounds)
                let label = "\(format.rows)×\(format.cols) in \(Int(bounds.width))×\(Int(bounds.height))"
                XCTAssertGreaterThan(geo.cell, 0, "\(label): non-positive cell size")
                XCTAssertTrue(geo.cell.isFinite, "\(label): non-finite cell size")
                XCTAssertLessThanOrEqual(
                    geo.frameRect.maxX, bounds.width + 0.5, "\(label): overflows horizontally"
                )
                XCTAssertLessThanOrEqual(
                    geo.frameRect.maxY, bounds.height + 0.5, "\(label): overflows vertically"
                )
                XCTAssertGreaterThanOrEqual(geo.frameRect.minX, -0.5, "\(label): starts left of bounds")
                XCTAssertGreaterThanOrEqual(geo.frameRect.minY, -0.5, "\(label): starts above bounds")
            }
        }
    }

    /// The fix for overflow must not change how the standard plates already look.
    func testStandardFormatsKeepTheirCellSizes() {
        let bounds = NSRect(x: 0, y: 0, width: 940, height: 560)
        let expected: [(PlateFormat, CGFloat)] = [
            (.well6, 96), (.well12, 96), (.well24, 96), (.well48, 83),
            (.well96, 62.25), (.well384, 31.644), (.well1536, 16.0625),
        ]
        for (format, cell) in expected {
            let geo = PlateGeometry(format: format, bounds: bounds)
            XCTAssertEqual(geo.cell, cell, accuracy: 0.02, "\(format.name) cell size moved")
        }
    }

    func testHitTestingIsCorrectForEveryStandardFormat() {
        let bounds = NSRect(x: 0, y: 0, width: 940, height: 560)
        for format in PlateFormat.standard {
            let geo = PlateGeometry(format: format, bounds: bounds)
            XCTAssertGreaterThanOrEqual(geo.cell, 9, "\(format.name) wells too small to use")
            XCTAssertEqual(geo.hit(CGPoint(x: geo.originX + 1, y: geo.originY + 1)),
                           .well(WellPos(row: 0, col: 0)))
            XCTAssertEqual(geo.hit(CGPoint(x: geo.originX + 1, y: geo.originY - 2)), .columnHeader(0))
            XCTAssertEqual(geo.hit(CGPoint(x: geo.originX - 2, y: geo.originY + 1)), .rowHeader(0))
            XCTAssertEqual(geo.hit(CGPoint(x: geo.originX - 2, y: geo.originY - 2)), .corner)

            // The far corner of the plate must hit the last well, not fall outside.
            let last = geo.cellRect(row: format.rows - 1, col: format.cols - 1)
            XCTAssertEqual(geo.hit(CGPoint(x: last.midX, y: last.midY)),
                           .well(WellPos(row: format.rows - 1, col: format.cols - 1)))
        }
    }

    /// A degenerate canvas must not trap when hit-testing divides by the cell size.
    func testHitTestingSurvivesADegenerateCanvas() {
        let geo = PlateGeometry(format: PlateFormat(rows: 64, cols: 96), bounds: NSRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(geo.cell, 0)
        _ = geo.hit(CGPoint(x: 0.5, y: 0.5))
        _ = geo.nearestWell(CGPoint(x: -1000, y: 100_000))
        XCTAssertEqual(geo.nearestWell(CGPoint(x: -1000, y: -1000)), WellPos(row: 0, col: 0))
    }
}

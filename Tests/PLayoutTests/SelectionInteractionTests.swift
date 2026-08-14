import XCTest
import AppKit
@testable import PLayout

/// The macOS selection standard on the grid: ⌘-click toggles a well in and out of
/// the selection, ⌘-drag with nothing armed adds a rectangle, and every plain
/// interaction puts the rectangular model back. Driven with synthesized events,
/// like PaintingInteractionTests, so the real mouse paths are covered.
final class SelectionInteractionTests: XCTestCase {

    private var window: NSWindow!
    private var canvas: PlateCanvasView!
    private var editor: PlateEditor!
    private var document: PlateDocument!

    override func setUp() {
        super.setUp()
        document = PlateDocument()
        editor = PlateEditor(document: document)
        let frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        canvas = PlateCanvasView(frame: frame)
        canvas.attach(editor: editor)
        window.contentView = canvas
        editor.armedLevelID = document.layout.factors[0].levels[1].id   // "Vehicle"
    }

    private var geometry: PlateGeometry {
        PlateGeometry(format: editor.format, bounds: canvas.bounds, quarterTurns: editor.quarterTurns)
    }

    private func event(
        _ type: NSEvent.EventType, at viewPoint: CGPoint, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: CGPoint(x: viewPoint.x, y: canvas.bounds.height - viewPoint.y),
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func centre(row: Int, col: Int) -> CGPoint {
        let rect = geometry.cellRect(row: row, col: col)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func click(row: Int, col: Int, modifiers: NSEvent.ModifierFlags = []) {
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: row, col: col), modifiers: modifiers))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: row, col: col), modifiers: modifiers))
    }

    private func levelName(row: Int, col: Int) -> String? {
        let factor = document.layout.factors[0]
        let plate = document.layout.plates[0]
        let id = plate.levelID(factor: factor.id, well: plate.format.index(row: row, col: col))
        return factor.level(id: id)?.name
    }

    private func well(_ row: Int, _ col: Int) -> Int {
        editor.format.index(row: row, col: col)
    }

    // MARK: - ⌘-click toggling

    func testCommandClickAddsAWellWithoutPainting() {
        click(row: 2, col: 2)
        click(row: 4, col: 4, modifiers: .command)

        XCTAssertEqual(Set(editor.selectedWells), [well(2, 2), well(4, 4)])
        XCTAssertNil(levelName(row: 4, col: 4), "a ⌘-click must never paint, even armed")
    }

    func testCommandClickOnASelectedWellRemovesIt() {
        click(row: 2, col: 2)
        click(row: 4, col: 4, modifiers: .command)
        click(row: 2, col: 2, modifiers: .command)

        XCTAssertEqual(editor.selectedWells, [well(4, 4)])
    }

    func testTogglingTheLastWellClearsTheSelection() {
        click(row: 2, col: 2)
        click(row: 2, col: 2, modifiers: .command)

        XCTAssertFalse(editor.hasSelection)
    }

    // MARK: - ⌘-drag

    func testCommandDragStillPaintsFreehand() {
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 0, col: 0), modifiers: .command))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: centre(row: 0, col: 1), modifiers: .command))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: centre(row: 1, col: 2), modifiers: .command))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 1, col: 2), modifiers: .command))

        XCTAssertEqual(levelName(row: 0, col: 1), "Vehicle")
        XCTAssertEqual(levelName(row: 1, col: 2), "Vehicle")
        XCTAssertNil(editor.customWells, "an armed ⌘-drag is the brush, not a selection edit")
    }

    func testCommandDragDisarmedAddsARectangle() {
        editor.disarmLevel()
        click(row: 0, col: 0)
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 2, col: 2), modifiers: .command))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: centre(row: 3, col: 3), modifiers: .command))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 3, col: 3), modifiers: .command))

        XCTAssertEqual(
            Set(editor.selectedWells),
            [well(0, 0), well(2, 2), well(2, 3), well(3, 2), well(3, 3)]
        )
        XCTAssertNil(levelName(row: 2, col: 2), "a disarmed ⌘-drag selects, it does not paint")
    }

    // MARK: - Returning to the rectangle

    func testPlainClickReturnsToTheRectangle() {
        click(row: 2, col: 2, modifiers: .command)
        click(row: 5, col: 5)

        XCTAssertNil(editor.customWells)
        XCTAssertEqual(editor.selection, WellRange(single: WellPos(row: 5, col: 5)))
    }

    func testShiftClickExtendsFromTheToggledWell() {
        editor.clearSelectionMarquee()
        click(row: 2, col: 2, modifiers: .command)
        click(row: 4, col: 4, modifiers: .shift)

        XCTAssertNil(editor.customWells)
        XCTAssertEqual(editor.selection?.minRow, 2)
        XCTAssertEqual(editor.selection?.maxRow, 4)
        XCTAssertEqual(editor.selection?.wellCount, 9)
    }

    func testArrowCollapsesToTheLastToggledWell() {
        click(row: 2, col: 2, modifiers: .command)
        editor.moveCursor(dRow: 0, dCol: 1, extend: false)

        XCTAssertNil(editor.customWells)
        XCTAssertEqual(editor.selection, WellRange(single: WellPos(row: 2, col: 3)))
    }

    // MARK: - What a discontiguous selection can and cannot do

    func testFillPaintsTheDiscontiguousSelection() {
        editor.clearSelectionMarquee()
        click(row: 2, col: 2, modifiers: .command)
        click(row: 4, col: 4, modifiers: .command)
        editor.paintSelection()

        XCTAssertEqual(levelName(row: 2, col: 2), "Vehicle")
        XCTAssertEqual(levelName(row: 4, col: 4), "Vehicle")
        XCTAssertNil(levelName(row: 3, col: 3), "the gap between toggled wells is not selected")
    }

    func testCopyRefusesADiscontiguousSelection() {
        click(row: 2, col: 2, modifiers: .command)
        click(row: 4, col: 4, modifiers: .command)
        editor.copySelection()

        XCTAssertTrue(editor.transientMessage.contains("rectangular"), editor.transientMessage)
    }
}

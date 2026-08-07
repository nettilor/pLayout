import XCTest
import AppKit
@testable import PLayout

/// Drives the grid with synthesized mouse and key events, so the hit-testing,
/// drag-to-paint and header-click paths are covered rather than assumed.
final class PaintingInteractionTests: XCTestCase {

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

    /// Mirrors what the canvas itself builds, orientation included — otherwise a test
    /// aims at where a header *used* to be once the plate has been flipped.
    private var geometry: PlateGeometry {
        PlateGeometry(format: editor.format, bounds: canvas.bounds, transposed: editor.isTransposed)
    }

    /// Converts a point in the (flipped) view to the bottom-left window space AppKit events use.
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

    private func levelName(row: Int, col: Int) -> String? {
        let factor = document.layout.factors[0]
        let plate = document.layout.plates[0]
        let id = plate.levelID(factor: factor.id, well: plate.format.index(row: row, col: col))
        return factor.level(id: id)?.name
    }

    func testDragPaintsARectangleOfWells() {
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 2, col: 2)))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: centre(row: 4, col: 4)))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 4, col: 4)))

        XCTAssertEqual(editor.selection?.minRow, 2)
        XCTAssertEqual(editor.selection?.maxCol, 4)
        XCTAssertEqual(editor.selection?.wellCount, 9)

        for row in 2...4 {
            for col in 2...4 {
                XCTAssertEqual(levelName(row: row, col: col), "Vehicle", "well \(row),\(col)")
            }
        }
        XCTAssertNil(levelName(row: 1, col: 2), "painted outside the drag rectangle")
        XCTAssertNil(levelName(row: 5, col: 5))
    }

    func testDragUpAndLeftStillPaints() {
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 5, col: 6)))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: centre(row: 4, col: 5)))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 4, col: 5)))

        XCTAssertEqual(editor.selection?.wellCount, 4)
        XCTAssertEqual(levelName(row: 4, col: 5), "Vehicle")
        XCTAssertEqual(levelName(row: 5, col: 6), "Vehicle")
    }

    func testNothingIsPaintedWhileDisarmed() {
        editor.disarmLevel()
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 0, col: 0)))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: centre(row: 2, col: 2)))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 2, col: 2)))

        XCTAssertEqual(editor.selection?.wellCount, 9, "selection should still track the drag")
        XCTAssertNil(levelName(row: 1, col: 1), "disarmed drag must not paint")
    }

    func testColumnHeaderClickPaintsWholeColumn() {
        let header = geometry.columnHeaderRect(3)
        let point = CGPoint(x: header.midX, y: header.midY)
        canvas.mouseDown(with: event(.leftMouseDown, at: point))
        canvas.mouseUp(with: event(.leftMouseUp, at: point))

        XCTAssertEqual(editor.selection?.wellCount, editor.format.rows)
        for row in 0..<editor.format.rows {
            XCTAssertEqual(levelName(row: row, col: 3), "Vehicle", "row \(row)")
        }
        XCTAssertNil(levelName(row: 0, col: 2))
    }

    func testRowHeaderClickPaintsWholeRow() {
        let header = geometry.rowHeaderRect(5)
        let point = CGPoint(x: header.midX, y: header.midY)
        canvas.mouseDown(with: event(.leftMouseDown, at: point))
        canvas.mouseUp(with: event(.leftMouseUp, at: point))

        XCTAssertEqual(editor.selection?.wellCount, editor.format.cols)
        for col in 0..<editor.format.cols {
            XCTAssertEqual(levelName(row: 5, col: col), "Vehicle", "col \(col)")
        }
    }

    /// The corner flips the plate now. It used to select every well — that moved to ⌘A
    /// and the Plate menu, and this asserts the corner no longer paints, because an
    /// armed brush plus a select-all is how a whole plate gets overwritten by accident.
    func testCornerClickFlipsTheViewAndPaintsNothing() {
        let corner = geometry.cornerRect
        let point = CGPoint(x: corner.midX, y: corner.midY)
        XCTAssertFalse(document.layout.transposedView)

        canvas.mouseDown(with: event(.leftMouseDown, at: point))
        canvas.mouseUp(with: event(.leftMouseUp, at: point))
        XCTAssertTrue(document.layout.transposedView, "the corner did not flip the plate")

        let factor = document.layout.factors[0]
        XCTAssertEqual(
            document.layout.plates[0].assignedWellCount(factor: factor.id, level: factor.levels[1].id),
            0, "the corner painted"
        )

        // Flipping moves the corner, so it is fetched again rather than reused.
        let back = geometry.cornerRect
        let backPoint = CGPoint(x: back.midX, y: back.midY)
        canvas.mouseDown(with: event(.leftMouseDown, at: backPoint))
        canvas.mouseUp(with: event(.leftMouseUp, at: backPoint))
        XCTAssertFalse(document.layout.transposedView, "the corner did not flip back")
    }

    func testOptionDragErases() {
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 0, col: 0)))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: centre(row: 1, col: 1)))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 1, col: 1)))
        XCTAssertEqual(levelName(row: 1, col: 1), "Vehicle")

        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 1, col: 1), modifiers: .option))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 1, col: 1), modifiers: .option))
        XCTAssertNil(levelName(row: 1, col: 1), "option-click should erase")
        XCTAssertEqual(levelName(row: 0, col: 0), "Vehicle", "erase leaked outside the click")
    }

    func testShiftClickExtendsFromTheAnchor() {
        editor.disarmLevel()
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 1, col: 1)))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 1, col: 1)))
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 4, col: 5), modifiers: .shift))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 4, col: 5), modifiers: .shift))

        XCTAssertEqual(editor.selection?.minRow, 1)
        XCTAssertEqual(editor.selection?.maxRow, 4)
        XCTAssertEqual(editor.selection?.minCol, 1)
        XCTAssertEqual(editor.selection?.maxCol, 5)
    }

    func testDragBeyondThePlateClampsInsteadOfCrashing() {
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 6, col: 10)))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 5000, y: 5000)))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 5000, y: 5000)))

        XCTAssertEqual(editor.selection?.maxRow, editor.format.rows - 1)
        XCTAssertEqual(editor.selection?.maxCol, editor.format.cols - 1)
        XCTAssertEqual(levelName(row: 7, col: 11), "Vehicle")
    }

    /// Clicking off the plate deselects, the way clicking empty canvas does elsewhere.
    func testClickingOutsideThePlateClearsTheSelection() {
        canvas.mouseDown(with: event(.leftMouseDown, at: centre(row: 2, col: 2)))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 2, col: 2)))
        XCTAssertNotNil(editor.selection)

        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 2, y: 2)))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 2, y: 2)))
        XCTAssertNil(editor.selection, "a click off the plate should deselect")
        XCTAssertFalse(editor.hasSelection)
    }

    func testAnOutsideClickPaintsNothingEvenWithALevelArmed() {
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 2, y: 2)))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: centre(row: 3, col: 3)))
        canvas.mouseUp(with: event(.leftMouseUp, at: centre(row: 3, col: 3)))
        XCTAssertNil(levelName(row: 3, col: 3))
        XCTAssertNil(editor.selection)
    }

    func testActionsAreNoOpsWithNothingSelected() {
        editor.clearSelectionMarquee()
        editor.paintSelection()
        editor.clearSelection()
        editor.clearSelectionAllFactors()
        editor.randomizeSelection()
        editor.copySelection()
        XCTAssertNil(levelName(row: 0, col: 0))
        XCTAssertTrue(document.layout.plates[0].assignments.isEmpty)
    }

    /// With nothing selected, an arrow key should start again rather than do nothing.
    func testArrowKeyRestartsSelectionAtA1() throws {
        editor.clearSelectionMarquee()
        canvas.keyDown(with: try key("\u{F703}"))   // right arrow
        XCTAssertEqual(editor.selection, WellRange(single: WellPos(row: 0, col: 0)))
    }

    func testPasteWithNoSelectionLandsAtA1() {
        editor.clearSelectionMarquee()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Alpha\tBeta", forType: .string)
        editor.pasteFromPasteboard()
        XCTAssertEqual(levelName(row: 0, col: 0), "Alpha")
        XCTAssertEqual(levelName(row: 0, col: 1), "Beta")
    }

    func testHoverTracksTheWellUnderTheCursor() {
        canvas.mouseMoved(with: event(.mouseMoved, at: centre(row: 3, col: 7)))
        XCTAssertEqual(editor.hovered, WellPos(row: 3, col: 7))
        XCTAssertTrue(editor.summary(row: 3, col: 7).hasPrefix("D8"))

        canvas.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 2, y: 2)))
        XCTAssertNil(editor.hovered, "hover should clear outside the grid")
    }

    func testNumberKeysArmConditionsAndSpaceFills() throws {
        editor.selection = WellRange(anchor: WellPos(row: 0, col: 0), focus: WellPos(row: 0, col: 2))
        canvas.keyDown(with: try key("3"))
        XCTAssertEqual(editor.armedLevel?.name, "Treated")

        canvas.keyDown(with: try key(" "))
        XCTAssertEqual(levelName(row: 0, col: 0), "Treated")
        XCTAssertEqual(levelName(row: 0, col: 2), "Treated")

        canvas.keyDown(with: try key("\u{7F}"))   // delete
        XCTAssertNil(levelName(row: 0, col: 1))
    }

    private func key(_ characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }
}

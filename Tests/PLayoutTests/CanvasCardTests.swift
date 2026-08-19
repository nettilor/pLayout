import XCTest
import AppKit
@testable import PLayout

/// A card is a real `PlateCanvasView` pinned to one plate. These pin the things that
/// separate it from the editing surface — because every one of them is a way for a
/// read-only card to quietly change the plate you *are* editing.
final class CanvasCardTests: XCTestCase {

    private var document: PlateDocument!
    private var editor: PlateEditor!
    private var window: NSWindow!

    /// Two plates, painted with different conditions so a render says which is which.
    override func setUp() {
        super.setUp()
        document = PlateDocument()
        editor = PlateEditor(document: document)
        editor.addPlate()

        let factor = document.layout.factors[0]
        let format = document.layout.plates[0].format
        for well in 0..<format.wellCount {
            document.layout.plates[0].setLevelID(factor.levels[0].id, factor: factor.id, well: well)
            document.layout.plates[1].setLevelID(factor.levels[2].id, factor: factor.id, well: well)
        }
        editor.activePlateID = document.layout.plates[0].id
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
    }

    private func card(for index: Int, size: NSSize = NSSize(width: 600, height: 400)) -> PlateCanvasView {
        let view = PlateCanvasView(frame: NSRect(origin: .zero, size: size))
        view.attach(editor: editor, role: .card(plateID: document.layout.plates[index].id))
        return view
    }

    private func event(
        _ type: NSEvent.EventType, at point: CGPoint, in view: NSView,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: CGPoint(x: point.x, y: view.bounds.height - point.y),
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        )!
    }

    private func click(_ view: PlateCanvasView, at point: CGPoint) {
        window.contentView = view
        view.mouseDown(with: event(.leftMouseDown, at: point, in: view))
        view.mouseUp(with: event(.leftMouseUp, at: point, in: view))
    }

    // MARK: - It draws its own plate

    func testACardDrawsItsOwnPlateNotTheActiveOne() throws {
        let second = card(for: 1)
        window.contentView = second
        let png = try XCTUnwrap(second.pngData())
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let scale = CGFloat(rep.pixelsWide) / second.bounds.width
        let geo = PlateGeometry(format: .well96, bounds: second.bounds)
        let centre = geo.cellRect(row: 4, col: 6)
        let sampled = try XCTUnwrap(
            rep.colorAt(x: Int(centre.midX * scale), y: Int(centre.midY * scale))
        ).usingColorSpace(.sRGB)

        // Plate 2 is painted with condition 3; plate 1 — the active one — with condition 1.
        let expected = try XCTUnwrap(NSColor(hex: document.layout.factors[0].levels[2].colorHex))
            .usingColorSpace(.sRGB)
        let other = try XCTUnwrap(NSColor(hex: document.layout.factors[0].levels[0].colorHex))
            .usingColorSpace(.sRGB)
        XCTAssertLessThan(
            abs(sampled!.redComponent - expected!.redComponent)
                + abs(sampled!.greenComponent - expected!.greenComponent)
                + abs(sampled!.blueComponent - expected!.blueComponent),
            abs(sampled!.redComponent - other!.redComponent)
                + abs(sampled!.greenComponent - other!.greenComponent)
                + abs(sampled!.blueComponent - other!.blueComponent),
            "the card drew the active plate rather than its own"
        )
    }

    /// Orientation is document-wide but resolved *against a format*, so two cards of
    /// differently shaped plates must turn differently under `.automatic`.
    func testACardWorksOutItsOwnTurnFromItsOwnFormat() {
        document.layout.orientation = .automatic
        // Straight onto the model, **not** through `editor.applyCustomFormat`: narrowing
        // a plate that has values in the columns being lost puts up a modal alert, and a
        // modal in a test hangs the whole suite with no output at all — eleven minutes at
        // 0.65 s of CPU, and a dialog left sitting on the user's screen.
        document.layout.plates[0].changeFormat(to: PlateFormat(rows: 24, cols: 8))
        XCTAssertEqual(document.layout.plates[0].format, PlateFormat(rows: 24, cols: 8))

        let tall = card(for: 0)
        let wide = card(for: 1)
        window.contentView = tall
        // A 24×8 lies down when drawn; a 96-well is already wider than it is tall.
        XCTAssertNotEqual(
            tall.cellCentreForTesting(row: 0, col: 0),
            wide.cellCentreForTesting(row: 0, col: 0),
            "two cards of different shapes cannot share one geometry"
        )
    }

    // MARK: - A read-only card changes nothing

    func testClickingAReadOnlyCardMakesItsPlateActive() {
        let second = card(for: 1)
        XCTAssertFalse(second.isEditable)
        click(second, at: second.cellCentreForTesting(row: 2, col: 3))
        XCTAssertEqual(editor.activePlateID, document.layout.plates[1].id)
        XCTAssertTrue(second.isEditable, "and it becomes the editable one")
    }

    func testClickingAReadOnlyCardDoesNotPaint() {
        let factor = document.layout.factors[0]
        editor.armedLevelID = factor.levels[1].id
        let before = document.layout.plates[1].assignments

        let second = card(for: 1)
        click(second, at: second.cellCentreForTesting(row: 2, col: 3))
        XCTAssertEqual(document.layout.plates[1].assignments, before,
                       "an armed brush plus a card click must not overwrite a well")
    }

    /// `PlateGeometry` centres the plate, so a card whose aspect does not match has inner
    /// margins — and a click there used to clear the *active* plate's selection.
    func testClickingAReadOnlyCardsMarginDoesNotClearTheSelection() {
        editor.select(WellRange(anchor: WellPos(row: 1, col: 1), focus: WellPos(row: 3, col: 4)))
        let before = editor.selection

        let second = card(for: 1, size: NSSize(width: 900, height: 200))
        click(second, at: CGPoint(x: 4, y: 100))
        XCTAssertEqual(editor.selection, before)
    }

    func testClickingAReadOnlyCardsCornerDoesNotTurnEveryPlate() {
        let before = document.layout.orientation
        let second = card(for: 1)
        window.contentView = second
        let geo = PlateGeometry(format: .well96, bounds: second.bounds)
        // The corner control sits above and left of well A1.
        let corner = CGPoint(x: geo.cellRect(row: 0, col: 0).minX - 14,
                             y: geo.cellRect(row: 0, col: 0).minY - 12)
        click(second, at: corner)
        XCTAssertEqual(document.layout.orientation, before,
                       "the corner of one card must not turn the whole document")
    }

    func testAReadOnlyCardNeitherHoversNorTakesTheKeyboard() {
        let second = card(for: 1)
        window.contentView = second
        XCTAssertFalse(second.acceptsFirstResponder)

        editor.hovered = nil
        second.mouseMoved(with: event(.mouseMoved, at: second.cellCentreForTesting(row: 5, col: 5), in: second))
        XCTAssertNil(editor.hovered, "a read-only card must not put a hover ring on the active plate")
    }

    /// That single weak slot is what export, print and `focusCanvas()` resolve through.
    func testACardNeverClaimsTheEditorsCanvas() {
        let primary = PlateCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        primary.attach(editor: editor)
        XCTAssertTrue(editor.canvas === primary)

        _ = card(for: 0)
        _ = card(for: 1)
        XCTAssertTrue(editor.canvas === primary, "a card stole the editing surface")
    }

    // MARK: - The active card is the editing surface

    func testTheActiveCardPaintsExactlyAsThePrimaryCanvasDoes() {
        let factor = document.layout.factors[0]
        editor.armedLevelID = factor.levels[1].id

        let first = card(for: 0)
        XCTAssertTrue(first.isEditable)
        window.contentView = first
        let point = first.cellCentreForTesting(row: 2, col: 3)
        first.mouseDown(with: event(.leftMouseDown, at: point, in: first))
        first.mouseUp(with: event(.leftMouseUp, at: point, in: first))

        let format = document.layout.plates[0].format
        let painted = document.layout.plates[0].levelID(
            factor: factor.id, well: format.index(row: 2, col: 3)
        )
        XCTAssertEqual(painted, factor.levels[1].id, "the active card is the editing surface")
    }

    func testACardStopsBeingEditableWhenAnotherPlateBecomesActive() {
        let first = card(for: 0)
        XCTAssertTrue(first.isEditable)
        editor.activePlateID = document.layout.plates[1].id
        XCTAssertFalse(first.isEditable, "editability is derived, so it cannot go stale")
    }
}

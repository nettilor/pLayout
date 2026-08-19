import XCTest
import AppKit
@testable import PLayout

/// The board itself. The first test is the one the whole design rests on.
final class CanvasBoardTests: XCTestCase {

    private var document: PlateDocument!
    private var editor: PlateEditor!
    private var window: NSWindow!
    private var scroll: CanvasScrollView!
    private var board: CanvasBoardView!

    override func setUp() {
        super.setUp()
        document = PlateDocument()
        editor = PlateEditor(document: document)
        editor.addPlate()
        editor.activePlateID = document.layout.plates[0].id
        editor.showsCanvas = true

        board = CanvasBoardView(frame: NSRect(x: 0, y: 0, width: 2000, height: 1400))
        board.attach(editor: editor)

        scroll = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        scroll.contentView = CenteringClipView()
        scroll.documentView = board
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.15
        scroll.maxMagnification = 3
        scroll.bind(to: editor)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = scroll
        window.layoutIfNeeded()
    }

    private func activeCard() throws -> PlateCanvasView {
        try XCTUnwrap(board.activeCardView, "the active plate should have a card")
    }

    private func mouseEvent(_ type: NSEvent.EventType, atWindowPoint point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    /// **The crown jewel.** A board adds a pan and a magnification between the mouse and
    /// the plate. If AppKit's own coordinate conversion did not carry a click through
    /// both, `PlateGeometry` would have to learn about the board — which is exactly what
    /// CLAUDE.md says makes clicks and drawing disagree silently.
    func testAClickPassesThroughTheBoardsZoomAndPanToTheRightWell() throws {
        for (magnification, scrollTo) in [(1.0, CGPoint(x: 0, y: 0)),
                                          (0.5, CGPoint(x: 120, y: 90)),
                                          (2.0, CGPoint(x: 40, y: 30))] {
            // A fresh document each pass, so an earlier paint cannot mask a later miss —
            // and everything read out of it has to be read *after* that.
            setUp()
            let factor = document.layout.factors[0]
            let format = document.layout.plates[0].format
            scroll.magnification = magnification
            scroll.contentView.scroll(to: scrollTo)
            window.layoutIfNeeded()

            editor.armedLevelID = factor.levels[1].id
            let card = try activeCard()
            let target = card.cellCentreForTesting(row: 3, col: 5)
            let inWindow = card.convert(target, to: nil)

            // Through the window, so the scroll view's transform is genuinely in the path.
            let hit = try XCTUnwrap(
                window.contentView?.hitTest(inWindow),
                "nothing was hit at \(inWindow) — magnification \(magnification)"
            )
            XCTAssertTrue(hit === card, "the click landed on \(type(of: hit)), not the active card")
            hit.mouseDown(with: mouseEvent(.leftMouseDown, atWindowPoint: inWindow))
            hit.mouseUp(with: mouseEvent(.leftMouseUp, atWindowPoint: inWindow))

            XCTAssertEqual(
                document.layout.plates[0].levelID(factor: factor.id, well: format.index(row: 3, col: 5)),
                factor.levels[1].id,
                "at magnification \(magnification), the click missed the well it was aimed at"
            )
        }
    }

    func testClickingAnotherCardThroughTheBoardSwitchesTheActivePlate() throws {
        let second = document.layout.plates[1].id
        let item = try XCTUnwrap(editor.canvasItems.first { $0.plateID == second })
        let centre = CGPoint(x: item.frame.rect.midX, y: item.frame.rect.midY)
        let inWindow = board.convert(centre, to: nil)

        let hit = try XCTUnwrap(window.contentView?.hitTest(inWindow))
        hit.mouseDown(with: mouseEvent(.leftMouseDown, atWindowPoint: inWindow))
        hit.mouseUp(with: mouseEvent(.leftMouseUp, atWindowPoint: inWindow))

        XCTAssertEqual(editor.activePlateID, second)
    }

    // MARK: - Shape and zoom

    func testTheBoardCoversEveryCardAndNeverGoesNegative() {
        let extent = CanvasArrangement.extent(of: editor.canvasItems)
        XCTAssertEqual(extent.minX, 0)
        XCTAssertEqual(extent.minY, 0)
        XCTAssertGreaterThanOrEqual(board.frame.width, board.cardsExtent.maxX)
    }

    func testTheBoardGrowsWhenACardIsDraggedOut() {
        let before = board.frame.width
        let card = editor.canvasItems[0]
        editor.setCanvasFrame(card.id, to: CGRect(x: 3000, y: 200, width: 560, height: 420))
        board.reload()
        XCTAssertGreaterThan(board.frame.width, before)
    }

    func testFitContentShowsEveryCard() {
        scroll.magnification = 3
        editor.zoomToFit()
        let cards = board.cardsExtent
        XCTAssertGreaterThan(scroll.magnification, 0)
        XCTAssertLessThanOrEqual(
            cards.width * scroll.magnification, scroll.contentView.frame.width + 1,
            "everything on the board has to fit across"
        )
        XCTAssertLessThanOrEqual(cards.height * scroll.magnification, scroll.contentView.frame.height + 1)
    }

    /// The board can zoom out past 100%; the plate cannot. One invariant, stated once,
    /// with both controllers alive in the same test.
    func testTheBoardZoomsBelowOneWhereThePlateDoesNot() {
        let plateScroll = PlateScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let canvas = PlateCanvasView(frame: plateScroll.contentView.bounds)
        canvas.attach(editor: editor)
        plateScroll.documentView = canvas
        plateScroll.allowsMagnification = true
        plateScroll.minMagnification = 1
        plateScroll.maxMagnification = 10

        XCTAssertEqual(plateScroll.minimumZoom, 1)
        XCTAssertLessThan(scroll.minimumZoom, 1)

        // And the editor's floor follows whichever surface is bound.
        scroll.bind(to: editor)
        editor.zoomToFit()
        XCTAssertLessThan(editor.minimumZoomLevel, 1)
        XCTAssertTrue(editor.showsZoomReadout, "fitting a board is usually below 100%")
    }

    func testActivatingAPlateHandsTheKeyboardToItsCard() throws {
        let first = try activeCard()
        window.makeFirstResponder(first)
        XCTAssertTrue(window.firstResponder === first)

        editor.activePlateID = document.layout.plates[1].id
        board.reload()
        XCTAssertTrue(
            window.firstResponder === board.activeCardView,
            "the keyboard has to follow the plate being edited"
        )
    }

    func testTheBoardRendersWithItsCards() throws {
        let png = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
        board.cacheDisplay(in: board.bounds, to: png)
        XCTAssertNotNil(png.representation(using: .png, properties: [:]))
    }
}

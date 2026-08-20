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

    // MARK: - The drawing hint reaches every card

    /// Every plate card currently on the board, in the board's own subview order.
    private func plateCards() -> [PlateCanvasView] {
        board.subviews.compactMap { ($0 as? CanvasCardView)?.content as? PlateCanvasView }
    }

    /// `displayScale` is what makes a zoomed-out board affordable: below about 7 points of
    /// on-screen cell the labels and hairlines are mush and are skipped. It is pushed down
    /// by `noteDisplayScale`, which — rightly — only does anything when the magnification
    /// *changed*, so a card made afterwards was never told. Zoom out to 25%, drag a plate
    /// tab onto the board, and the new card drew labels and hairlines every one of its
    /// neighbours had dropped, and paid in full the render cost the hint exists to avoid.
    func testACardMadeWhileTheBoardIsZoomedOutIsBornWithTheDisplayScale() throws {
        scroll.setZoom(0.25)
        XCTAssertEqual(scroll.magnification, 0.25, accuracy: 0.001)
        for canvas in plateCards() {
            XCTAssertEqual(canvas.displayScale, 0.25, accuracy: 0.001, "the cards already there")
        }

        // Take a card off and drop its plate back on — the path that makes a *new* view.
        let second = document.layout.plates[1].id
        let item = try XCTUnwrap(editor.canvasItems.first { $0.plateID == second })
        editor.closeCanvasItem(item.id)
        board.reload()
        XCTAssertEqual(plateCards().count, 1, "the card came off the board")

        editor.placeOnCanvas(plateID: second, at: CGPoint(x: 900, y: 60))
        board.reload()
        let cards = plateCards()
        XCTAssertEqual(cards.count, 2)
        for canvas in cards {
            XCTAssertEqual(canvas.displayScale, 0.25, accuracy: 0.001,
                           "a card created after the zoom never heard about it")
        }
    }

    // MARK: - The board follows its viewport

    /// A scroll view's document must cover the viewport, or zooming out tears — and the
    /// viewport changes size without the zoom or the document moving at all. Widen the
    /// window, or go full screen, and `applyExtent()` used to have no way of hearing about
    /// it: the document view kept its old size, the dot grid ended mid-air, and
    /// `CenteringClipView.constrainBoundsRect` — which can otherwise never fire — recentred
    /// and jumped every card sideways.
    func testWideningTheViewportGrowsTheBoardWithNobodyTouchingTheZoom() {
        // Zoomed out, so the clip view's *bounds* are much larger than its frame — which
        // is the half of the extent the cards do not account for.
        scroll.setZoom(0.2)
        let before = board.frame.size
        XCTAssertGreaterThanOrEqual(before.width, scroll.contentView.bounds.width)

        window.setContentSize(NSSize(width: 1800, height: 700))
        window.layoutIfNeeded()

        XCTAssertGreaterThan(board.frame.width, before.width, "the board did not follow the window")
        XCTAssertGreaterThanOrEqual(
            board.frame.width, scroll.contentView.bounds.width,
            "the background runs out before the viewport does"
        )
    }

    /// The same thing said as the symptom: while the board is short of the viewport,
    /// `constrainBoundsRect` recentres it, so every card appears to jump sideways for no
    /// reason anybody can see.
    func testTheClipViewNeverHasToRecentreAfterAResize() {
        scroll.setZoom(0.2)
        window.setContentSize(NSSize(width: 1800, height: 900))
        window.layoutIfNeeded()

        let clip = scroll.contentView
        // The condition it recentres under, said as the board's own shape.
        XCTAssertGreaterThanOrEqual(board.frame.width, clip.bounds.width)
        XCTAssertGreaterThanOrEqual(board.frame.height, clip.bounds.height)

        let proposed = NSRect(origin: clip.bounds.origin, size: clip.bounds.size)
        let constrained = clip.constrainBoundsRect(proposed).origin
        // Sub-point slack: a magnified clip view's bounds carry conversion noise, and a
        // recentre here would move the cards by hundreds of points, not by 1e-9.
        XCTAssertEqual(constrained.x, proposed.origin.x, accuracy: 0.5,
                       "the clip view had to recentre, which reads as the cards jumping")
        XCTAssertEqual(constrained.y, proposed.origin.y, accuracy: 0.5,
                       "the clip view had to recentre, which reads as the cards jumping")
    }

    // MARK: - The dot grid during a pinch

    /// The grid reads the **live** magnification; the cards deliberately do not.
    ///
    /// Dropping card detail only when the gesture ends is what keeps a pinch smooth and is
    /// not up for revision. The grid is not a card, though — it fills the viewport, and
    /// during a pinch out the viewport is growing under your fingers. With the old value
    /// still in hand the step stayed tiny for an area several times larger, the dot count
    /// ran into the cap partway down, and the bottom of the board drew nothing at all
    /// until you lifted off.
    func testTheDotGridFollowsALivePinchWhileTheCardsWaitForItToEnd() {
        scroll.setZoom(1)
        for canvas in plateCards() { XCTAssertEqual(canvas.displayScale, 1, accuracy: 0.001) }

        // Mid-gesture: `magnification` has moved, `didEndLiveMagnify` has not fired.
        scroll.magnification = 0.2
        window.layoutIfNeeded()

        XCTAssertEqual(board.liveGridScale, 0.2, accuracy: 0.001,
                       "the grid is still drawing against the value the cards were given")
        for canvas in plateCards() {
            XCTAssertEqual(canvas.displayScale, 1, accuracy: 0.001,
                           "a card re-rendered mid-pinch — that is what makes a pinch stutter")
        }
    }

    /// And the number that made it visible: how many dots the step asks for over the
    /// visible area, against the cap `draw` stops at.
    func testTheGridStepKeepsTheDotCountUnderItsCapWhenZoomedOut() {
        scroll.setZoom(1)
        scroll.magnification = 0.2
        window.layoutIfNeeded()
        let area = scroll.contentView.bounds

        func dots(atScale scale: CGFloat) -> Int {
            let step = CanvasBoardView.gridStep(forScale: scale)
            return Int((area.width / step).rounded(.up)) * Int((area.height / step).rounded(.up))
        }

        XCTAssertGreaterThan(dots(atScale: 1), CanvasBoardView.gridDotCap,
                             "the stale value is what ran into the cap — otherwise there is no bug")
        XCTAssertLessThan(dots(atScale: board.liveGridScale), CanvasBoardView.gridDotCap,
                          "the live value has to fit the whole visible area under the cap")
    }

    // MARK: - Binding does not publish mid-render

    /// `bind(to:)` is called from `updateNSViewController`, i.e. from inside SwiftUI's own
    /// update pass, and the board's floor (0.15) is not the value the editor starts on
    /// (1) — so the first update after the board appeared mutated an `@Published` property
    /// of the object SwiftUI was in the middle of rendering: "Publishing changes from
    /// within view updates is not allowed". It converged, and invalidated the view
    /// mid-build every single time the board was switched on.
    func testBindingTheBoardDoesNotPublishFromInsideTheUpdatePass() {
        let fresh = PlateEditor(document: document)
        XCTAssertEqual(fresh.minimumZoomLevel, 1, "the editor starts on the plate's floor")

        scroll.bind(to: fresh)
        XCTAssertEqual(fresh.minimumZoomLevel, 1,
                       "bind() published from inside the caller's update pass")

        // It still arrives — one turn of the main queue later, where nothing is rendering.
        let settled = expectation(description: "the board's floor reaches the editor")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(fresh.minimumZoomLevel, scroll.minMagnification, accuracy: 0.0001)
    }

    /// The deferral is only for that first push. Everything the user drives has to publish
    /// straight away, or the status bar would trail the magnification the scroll view
    /// already has.
    func testZoomingStillPublishesSynchronously() {
        scroll.setZoom(0.4)
        XCTAssertEqual(editor.zoomLevel, 0.4, accuracy: 0.001)
        editor.zoomToFit()
        XCTAssertEqual(editor.zoomLevel, scroll.magnification, accuracy: 0.001)
        XCTAssertLessThan(editor.minimumZoomLevel, 1)
    }
}

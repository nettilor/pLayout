import XCTest
import AppKit
import SwiftUI
@testable import PLayout

/// The plate lives in a magnifying scroll view. The invariant that makes zoom work is
/// that the document view keeps its unmagnified size — if it tracked the clip view's
/// bounds it would re-fit the plate smaller and cancel the zoom out entirely.
final class ZoomTests: XCTestCase {

    private func makeScrollView(size: NSSize = NSSize(width: 1000, height: 700))
        -> (PlateScrollView, PlateCanvasView, PlateEditor)
    {
        let editor = PlateEditor(document: PlateDocument())
        let canvas = PlateCanvasView()
        canvas.attach(editor: editor)
        canvas.autoresizingMask = []

        let scroll = PlateScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.documentView = canvas
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 10
        canvas.frame = scroll.contentView.bounds
        scroll.bind(to: editor)
        scroll.layoutSubtreeIfNeeded()
        return (scroll, canvas, editor)
    }

    func testZoomingInEnlargesTheWellsRatherThanRefittingThem() {
        let (scroll, canvas, editor) = makeScrollView()
        let before = PlateGeometry(format: editor.format, bounds: canvas.bounds).cell
        XCTAssertGreaterThan(before, 0)

        editor.zoomIn()
        scroll.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(scroll.magnification, 1.001, "magnification did not change")
        let after = PlateGeometry(format: editor.format, bounds: canvas.bounds).cell
        XCTAssertEqual(
            after, before, accuracy: 0.01,
            "the document view resized with the clip view, which cancels the zoom"
        )
    }

    func testZoomStartsFittedAndNeverGoesBelowIt() {
        let (scroll, _, editor) = makeScrollView()
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
        XCTAssertFalse(editor.canZoomOut)

        editor.zoomOut()
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001, "zoomed out past the fitted plate")
        XCTAssertEqual(scroll.minMagnification, 1, accuracy: 0.001)
    }

    func testZoomInThenFitReturnsToTheWholePlate() {
        let (scroll, _, editor) = makeScrollView()
        editor.zoomIn()
        editor.zoomIn()
        XCTAssertGreaterThan(scroll.magnification, 1.5)
        XCTAssertTrue(editor.canZoomOut)

        editor.zoomToFit()
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
        XCTAssertFalse(editor.canZoomOut)
    }

    func testZoomIsClampedToTheScrollViewsRange() {
        let (scroll, _, editor) = makeScrollView()
        for _ in 0..<40 { editor.zoomIn() }
        XCTAssertLessThanOrEqual(scroll.magnification, scroll.maxMagnification + 0.001)
        for _ in 0..<40 { editor.zoomOut() }
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
    }

    /// The status bar reads a published value, so a trackpad pinch has to push back.
    func testZoomLevelIsPublishedBackToTheEditor() {
        let (scroll, _, editor) = makeScrollView()
        editor.zoomIn()
        XCTAssertEqual(editor.zoomLevel, scroll.magnification, accuracy: 0.001)
        editor.zoomToFit()
        XCTAssertEqual(editor.zoomLevel, 1, accuracy: 0.001)
    }

    /// Resizing the window while zoomed must keep the plate laid out for the full
    /// document, not for the smaller magnified viewport.
    func testResizingWhileZoomedKeepsTheDocumentAtWindowSize() {
        let (scroll, canvas, editor) = makeScrollView()
        editor.zoomIn()
        scroll.setFrameSize(NSSize(width: 1300, height: 900))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(canvas.bounds.width, 1300, accuracy: 1.5)
        XCTAssertEqual(canvas.bounds.height, 900, accuracy: 1.5)
    }
}

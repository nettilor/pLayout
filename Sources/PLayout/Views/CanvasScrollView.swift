import AppKit
import SwiftUI

/// The board's scroll view.
///
/// Unlike `PlateScrollView` it does **not** override `tile()`. That override is what pins
/// the plate to the viewport so magnification 1 means "whole plate" and zooming out can
/// never go further; a board is larger than its viewport by definition, so inheriting the
/// rule would be exactly wrong. Different class, different contract — which is also why
/// `ZoomTests`, which builds `PlateScrollView` by hand, is untouched by any of this.
final class CanvasScrollView: NSScrollView, PlateZoomController {

    private weak var editor: PlateEditor?
    private var magnifyObserver: NSObjectProtocol?

    var boundEditor: PlateEditor? { editor }

    private var board: CanvasBoardView? { documentView as? CanvasBoardView }

    func bind(to editor: PlateEditor) {
        self.editor = editor
        editor.zoomController = self
        if magnifyObserver == nil {
            magnifyObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.editor?.noteZoomChanged(self.magnification)
                self.board?.noteDisplayScale(self.magnification)
            }
        }
        editor.noteZoomChanged(magnification)
        board?.noteDisplayScale(magnification)
    }

    func setZoom(_ value: CGFloat) {
        let clamped = min(max(value, minMagnification), maxMagnification)
        let centre = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(clamped, centeredAt: centre)
        editor?.noteZoomChanged(magnification)
        board?.noteDisplayScale(magnification)
    }

    /// Every card in view at once — which, unlike the plate's, is a measurement rather
    /// than the constant 1.
    func fitContent() {
        guard let board else { return setZoom(1) }
        let cards = board.cardsExtent
        let available = contentView.frame.size
        guard cards.width > 1, cards.height > 1, available.width > 1, available.height > 1 else {
            return setZoom(1)
        }
        let inset: CGFloat = 32
        let scale = min(
            (available.width - inset) / cards.width,
            (available.height - inset) / cards.height
        )
        let clamped = min(max(scale, minMagnification), maxMagnification)
        setMagnification(clamped, centeredAt: CGPoint(x: cards.midX, y: cards.midY))
        editor?.noteZoomChanged(magnification)
        board.noteDisplayScale(magnification)
    }

    var minimumZoom: CGFloat { minMagnification }

    deinit {
        if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
    }
}

/// Keeps a board smaller than its viewport centred rather than jammed into a corner.
/// `NSScrollView` has no switch for this; `constrainBoundsRect` is the only hook.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}

// MARK: - SwiftUI bridge

/// Hosted as a **view controller**, not a bare view.
///
/// With `NSViewRepresentable` the scroll view arrived on screen with the right frame,
/// the right document view and a correct visible rect, drew on demand — and showed
/// nothing at all. This is the mirror image of the prep window, which was blank until
/// its SwiftUI content moved from an `NSHostingView` to an `NSHostingController`; in
/// both directions the fix is to let AppKit own a controller rather than a loose view.
final class CanvasBoardController: NSViewController {
    private let editor: PlateEditor
    private let board: CanvasBoardView
    let scroll = CanvasScrollView()

    init(editor: PlateEditor) {
        self.editor = editor
        self.board = CanvasBoardView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        scroll.contentView = CenteringClipView()
        scroll.documentView = board
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.15
        scroll.maxMagnification = 3
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        board.attach(editor: editor)
        scroll.bind(to: editor)
    }

    func rebind(to editor: PlateEditor) {
        if board.editor !== editor { board.attach(editor: editor) }
        scroll.bind(to: editor)
    }
}

struct CanvasBoard: NSViewControllerRepresentable {
    @ObservedObject var editor: PlateEditor

    func makeNSViewController(context: Context) -> CanvasBoardController {
        CanvasBoardController(editor: editor)
    }

    func updateNSViewController(_ controller: CanvasBoardController, context: Context) {
        controller.rebind(to: editor)
    }

    /// Hands the zoom slot back when the board goes away, so a stale board cannot keep
    /// answering ⌘0 for the plate view that has taken its place.
    static func dismantleNSViewController(_ controller: CanvasBoardController, coordinator: ()) {
        if let editor = controller.scroll.boundEditor, editor.zoomController === controller.scroll {
            editor.zoomController = nil
        }
    }
}

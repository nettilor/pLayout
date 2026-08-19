import AppKit
import Combine
import SwiftUI

// MARK: - The board

/// The board's document view: one card per thing on it.
///
/// Every card is a real AppKit view, which is the whole containment argument — AppKit's
/// own coordinate conversion carries a click through the board's pan and magnification
/// before the card sees it, so `PlateGeometry` works in the card's own bounds and never
/// learns the board exists.
final class CanvasBoardView: NSView {

    weak var editor: PlateEditor?
    private var cancellable: AnyCancellable?
    private var cards: [UUID: CanvasCardView] = [:]
    private var items: [CanvasItem] = []
    private var displayScale: CGFloat = 1

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func attach(editor: PlateEditor) {
        self.editor = editor
        editor.board = self
        // The board's own shape depends on the document and on which plate is active;
        // everything finer than that is the cards' own business.
        cancellable = Publishers.MergeMany([
            editor.document.$layout.map { _ in () }.eraseToAnyPublisher(),
            editor.$activePlateID.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.reload() }
        reload()
    }

    /// Rebuilds from the resolved arrangement, reusing card views by item id so a redraw
    /// cannot destroy a drag in flight.
    func reload() {
        guard let editor else { return }
        items = editor.canvasItems
        var live: Set<UUID> = []

        for item in items {
            live.insert(item.id)
            let card = cards[item.id] ?? make(item, editor: editor)
            cards[item.id] = card
            if card.superview !== self { addSubview(card) }
            card.title = title(for: item, editor: editor)
            card.isActive = item.kind == .plate && item.plateID == editor.activePlateID
            if !card.isDragging { card.frame = item.frame.rect }
            card.refresh(item: item, editor: editor)
        }

        for (id, card) in cards where !live.contains(id) {
            card.removeFromSuperview()
            cards.removeValue(forKey: id)
        }

        // Array order is z-order.
        for item in items {
            if let card = cards[item.id] { addSubview(card, positioned: .above, relativeTo: nil) }
        }

        let extent = CanvasArrangement.extent(of: items)
        if frame.size != extent.size { setFrameSize(extent.size) }
        handOverFocusIfNeeded()
        needsDisplay = true
    }

    /// When the active plate changes, the keyboard has to follow it. Otherwise the old
    /// card keeps first responder and `performKeyEquivalent`'s `firstResponder === self`
    /// guard runs on a card that is no longer editable.
    private func handOverFocusIfNeeded() {
        guard let window, let active = activeCardView else { return }
        guard let current = window.firstResponder as? PlateCanvasView else { return }
        guard current !== active, current.isDescendant(of: self) else { return }
        window.makeFirstResponder(active)
    }

    private func make(_ item: CanvasItem, editor: PlateEditor) -> CanvasCardView {
        let card = CanvasCardView(itemID: item.id, kind: item.kind)
        card.onCommitFrame = { [weak editor] frame in
            editor?.setCanvasFrame(item.id, to: frame)
        }
        card.onActivate = { [weak editor] in
            if item.kind == .plate, let id = item.plateID { editor?.activatePlate(id) }
            editor?.bringCanvasItemToFront(item.id)
        }
        card.onOpen = { [weak editor] in
            if item.kind == .note { editor?.noteTarget = .canvasNote(item.id) }
        }
        card.content = content(for: item, editor: editor)
        return card
    }

    private func content(for item: CanvasItem, editor: PlateEditor) -> NSView {
        switch item.kind {
        case .plate:
            let plate = PlateCanvasView()
            if let id = item.plateID { plate.attach(editor: editor, role: .card(plateID: id)) }
            return plate
        case .prep:
            let table = PrepTableView()
            table.plan = editor.prepPlan
            return table
        case .note:
            return CanvasNoteView()
        }
    }

    private func title(for item: CanvasItem, editor: PlateEditor) -> String {
        switch item.kind {
        case .plate:
            guard let id = item.plateID,
                  let plate = editor.layout.plates.first(where: { $0.id == id })
            else { return "Plate" }
            return "\(plate.name)  ·  \(editor.formatDisplayName(plate.format))"
        case .prep:
            return "Pipetting prep"
        case .note:
            return "Note"
        }
    }

    // MARK: - Geometry the scroll view asks for

    /// What is actually on the board, with no padding — what "fit everything" measures.
    var cardsExtent: CGRect {
        let frames = items.map(\.frame.rect)
        guard let first = frames.first else { return CGRect(x: 0, y: 0, width: 800, height: 600) }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    var activeCardView: PlateCanvasView? {
        guard let active = editor?.activePlateID else { return nil }
        for item in items where item.kind == .plate && item.plateID == active {
            return cards[item.id]?.content as? PlateCanvasView
        }
        return nil
    }

    /// The magnification, passed to the cards as a drawing hint.
    func noteDisplayScale(_ scale: CGFloat) {
        guard abs(scale - displayScale) > 0.001 else { return }
        displayScale = scale
        for card in cards.values {
            (card.content as? PlateCanvasView)?.displayScale = scale
        }
    }

    func reveal(plateID: UUID) {
        guard let item = items.first(where: { $0.kind == .plate && $0.plateID == plateID })
        else { return }
        scrollToVisible(item.frame.rect.insetBy(dx: -CanvasArrangement.gap, dy: -CanvasArrangement.gap))
    }

    // MARK: - Board background and empty space

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()

        // A dot grid, so panning an empty board still reads as movement. Dropped when
        // zoomed far out, where it would be noise rather than texture.
        guard displayScale > 0.4 else { return }
        let step: CGFloat = 40
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        var y = (dirtyRect.minY / step).rounded(.down) * step
        while y < dirtyRect.maxY {
            var x = (dirtyRect.minX / step).rounded(.down) * step
            while x < dirtyRect.maxX {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
                x += step
            }
            y += step
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Reaching the board itself means the click missed every card.
        guard event.clickCount == 2, let editor else { return }
        editor.addCanvasNote(at: convert(event.locationInWindow, from: nil))
    }
}

// MARK: - A card

/// Card chrome: a title bar you drag by, a border, and a resize grip. The content view
/// fills the rest, so a click in the body reaches the plate exactly as it does today.
final class CanvasCardView: NSView {

    let itemID: UUID
    let kind: CanvasItem.Kind

    var title: String = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    private(set) var isDragging = false

    var onCommitFrame: ((CGRect) -> Void)?
    var onActivate: (() -> Void)?
    var onOpen: (() -> Void)?

    var content: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let content { addSubview(content) }
            layoutContent()
        }
    }

    static let titleHeight = CanvasArrangement.titleBarHeight
    private static let gripSize: CGFloat = 16

    private enum Drag { case none, move, resize }
    private var drag: Drag = .none
    private var dragOrigin: CGPoint = .zero
    private var startFrame: CGRect = .zero

    init(itemID: UUID, kind: CanvasItem.Kind) {
        self.itemID = itemID
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func refresh(item: CanvasItem, editor: PlateEditor) {
        if let note = content as? CanvasNoteView {
            note.text = item.text
            note.colorHex = item.colorHex
        }
        if let table = content as? PrepTableView {
            table.plan = editor.prepPlan
        }
        content?.needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    /// Called on every size change rather than left to the layout pass.
    ///
    /// A card is created at zero size and given its frame afterwards, and setting an
    /// `NSView`'s frame does **not** re-run `layout()` — so relying on that pass left
    /// every plate card holding a zero-sized canvas that drew nothing at all, on a board
    /// that otherwise looked entirely correct.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    private func layoutContent() {
        guard let content else { return }
        let body = NSRect(
            x: 1, y: Self.titleHeight,
            width: max(0, bounds.width - 2), height: max(0, bounds.height - Self.titleHeight - 1)
        )
        if content.frame != body { content.frame = body }
        (content as? PrepTableView)?.fitWidth(to: body.width)
        content.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 8
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor.textBackgroundColor.setFill()
        shape.fill()

        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        (isActive ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.windowBackgroundColor)
            .setFill()
        bar.fill()
        NSGraphicsContext.restoreGraphicsState()

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(
            in: bar.insetBy(dx: 9, dy: 5),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: isActive ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
        )

        // The active card is the one the keyboard and the brush are pointed at, so it
        // says so in the accent colour rather than only in the plate tab bar.
        (isActive ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = isActive ? 2 : 1
        shape.stroke()

        NSColor.tertiaryLabelColor.setStroke()
        let grip = NSBezierPath()
        for offset in stride(from: 4.0, through: 10.0, by: 3.0) {
            grip.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.maxY - 3))
            grip.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.maxY - offset))
        }
        grip.lineWidth = 1
        grip.stroke()
    }

    private var gripRect: NSRect {
        NSRect(x: bounds.maxX - Self.gripSize, y: bounds.maxY - Self.gripSize,
               width: Self.gripSize, height: Self.gripSize)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onActivate?()
        if gripRect.contains(point) {
            drag = .resize
        } else if point.y <= Self.titleHeight {
            drag = .move
            if event.clickCount == 2 { onOpen?() }
        } else {
            drag = .none
            return
        }
        isDragging = true
        dragOrigin = convert(event.locationInWindow, from: nil)
        startFrame = frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != .none, let superview else { return }
        let now = superview.convert(event.locationInWindow, from: nil)
        let start = convert(dragOrigin, to: superview)
        let dx = now.x - start.x
        let dy = now.y - start.y
        switch drag {
        case .move:
            frame = CGRect(
                x: max(0, startFrame.minX + dx), y: max(0, startFrame.minY + dy),
                width: startFrame.width, height: startFrame.height
            )
        case .resize:
            frame = CGRect(
                x: startFrame.minX, y: startFrame.minY,
                width: max(CanvasFrame.minimum.width, startFrame.width + dx),
                height: max(CanvasFrame.minimum.height, startFrame.height + dy)
            )
        case .none:
            break
        }
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != .none else { return }
        drag = .none
        isDragging = false
        // Committed once, on mouse up: a drag is one ⌘Z, the same rule painting follows.
        onCommitFrame?(frame)
    }
}

// MARK: - A note

/// A sticky note, **drawn** rather than hosted. Anything layer-backed inside a magnified
/// scroll view renders at its layer's own scale and goes soft the moment you zoom in, so
/// an `NSTextView` here would blur; the text is drawn, and editing goes through the same
/// `NoteSheet` the well and plate notes already use.
final class CanvasNoteView: NSView {

    var text: String = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var colorHex: String? { didSet { if colorHex != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let paper = colorHex.flatMap { NSColor(hex: $0) }
            ?? NSColor.systemYellow.withAlphaComponent(0.22)
        paper.setFill()
        bounds.fill()

        let shown = text.isEmpty ? "Double-click to write" : text
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        (shown as NSString).draw(
            in: bounds.insetBy(dx: 10, dy: 9),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: text.isEmpty ? NSColor.tertiaryLabelColor : NSColor.labelColor,
                .paragraphStyle: style,
            ]
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        (superview as? CanvasCardView)?.onOpen?()
    }
}

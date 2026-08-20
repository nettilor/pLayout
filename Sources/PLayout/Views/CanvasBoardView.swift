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

    /// The board always paints every pixel it is asked for. Saying so is what stops
    /// AppKit's copy-on-scroll leaving unpainted strips behind — the white lines that
    /// surfaced across the background while zooming and scrolling.
    override var isOpaque: Bool { true }

    func attach(editor: PlateEditor) {
        self.editor = editor
        editor.board = self
        // A plate tab dragged onto the board puts that plate's card back.
        registerForDraggedTypes([.string])
        // The board's own shape depends on the document and on which plate is active;
        // everything finer than that is the cards' own business.
        cancellable = Publishers.MergeMany([
            editor.document.$layout.map { _ in () }.eraseToAnyPublisher(),
            editor.$activePlateID.map { _ in () }.eraseToAnyPublisher(),
            // The background colour lives outside any document, so a change in the
            // Settings window has to reach every open board by hand.
            Preferences.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            self?.applyBackground()
            self?.reload()
        }
        reload()
    }

    /// Rebuilds from the resolved arrangement, reusing card views by item id so a redraw
    /// cannot destroy a drag in flight.
    func reload() {
        guard let editor else { return }
        // Never rebuild mid-drag. Re-adding a card to reorder it cancels the mouse
        // tracking of the very view being dragged — which is what made cards jump
        // around and, on a card already at the front, refuse to move at all.
        guard !cards.values.contains(where: { $0.isDragging }) else { return }
        items = editor.canvasItems
        var live: Set<UUID> = []
        // Built once per reload rather than once per card: it walks every well of every
        // plate, so asking each card for its own copy was pure waste.
        let plan = items.contains { $0.kind == .prep } ? editor.prepPlan : nil

        for item in items {
            live.insert(item.id)
            let card = cards[item.id] ?? make(item, editor: editor)
            cards[item.id] = card
            if card.superview !== self { addSubview(card) }
            card.title = title(for: item, editor: editor)
            card.isActive = item.kind == .plate && item.plateID == editor.activePlateID
            if !card.isDragging { card.frame = item.frame.rect }
            card.refresh(item: item, prepPlan: plan)
        }

        for (id, card) in cards where !live.contains(id) {
            card.removeFromSuperview()
            cards.removeValue(forKey: id)
        }

        // Array order is z-order, and the plate being edited is always on top of it.
        // Raised here rather than on the press itself: a click has to bring a card
        // forward, but writing the document mid-press is what cancelled drags.
        for item in items {
            if let card = cards[item.id] { addSubview(card, positioned: .above, relativeTo: nil) }
        }
        if let active = items.first(where: { $0.kind == .plate && $0.plateID == editor.activePlateID }),
           let card = cards[active.id] {
            addSubview(card, positioned: .above, relativeTo: nil)
        }

        applyExtent()
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
        // Activation only — deliberately *not* a document write. Bringing the card to the
        // front is folded into the frame commit on mouse up, so a press cannot edit the
        // document underneath a drag that is about to start.
        card.onActivate = { [weak editor] in
            if item.kind == .plate, let id = item.plateID { editor?.activatePlate(id) }
        }
        card.onClose = { [weak editor] in editor?.closeCanvasItem(item.id) }
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
            return PrepTableView()
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

    /// The scroll view paints the same colour, so the strip beyond the board while a
    /// rubber-band scroll overshoots does not flash a different one.
    private func applyBackground() {
        enclosingScrollView?.backgroundColor = Preferences.shared.canvasBackground
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackground()
    }

    /// The board's own size: what is on it plus room to pan, and never smaller than the
    /// viewport asks for. Zooming out makes the clip view's *bounds* grow, so without the
    /// second half the background simply ran out and the board looked like a torn sheet.
    func applyExtent() {
        var size = CanvasArrangement.extent(of: items).size
        if let clip = enclosingScrollView?.contentView {
            size.width = max(size.width, clip.bounds.width)
            size.height = max(size.height, clip.bounds.height)
        }
        if frame.size != size { setFrameSize(size) }
    }

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
        applyExtent()
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
        // The whole damaged rect, not clipped to bounds: this is the document view, so
        // there is nothing behind it to protect, and any sliver left unpainted shows as
        // a seam.
        Preferences.shared.canvasBackground.setFill()
        dirtyRect.fill()

        // A dot grid, so panning an empty board still reads as movement.
        //
        // The step is scaled by the magnification so the dots stay the same distance
        // apart *on screen*. With a fixed board-space step, zooming out to 19% asked for
        // roughly 12,000 dots across a viewport-sized dirty rect — which is its own
        // answer to why the board felt heavy when zoomed out.
        guard displayScale > 0.25 else { return }
        let step: CGFloat = max(40, 40 / max(displayScale, 0.05))
        Preferences.shared.canvasGrid.setFill()
        let dot = max(1.5, 1.5 / max(displayScale, 0.2))
        let area = dirtyRect.intersection(bounds)
        var y = (area.minY / step).rounded(.down) * step
        var drawn = 0
        while y < area.maxY, drawn < 6_000 {
            var x = (area.minX / step).rounded(.down) * step
            while x < area.maxX, drawn < 6_000 {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
                x += step
                drawn += 1
            }
            y += step
        }
    }

    // MARK: - Dropping a plate tab onto the board

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPlate(from: sender) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPlate(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let plateID = droppedPlate(from: sender) else { return false }
        var point = convert(sender.draggingLocation, from: nil)
        // Drop under the cursor rather than starting at it, so the card lands where it
        // looked like it was going.
        point.x = max(0, point.x - 60)
        point.y = max(0, point.y - CanvasArrangement.titleBarHeight / 2)
        editor?.placeOnCanvas(plateID: plateID, at: point)
        return true
    }

    private func droppedPlate(from sender: NSDraggingInfo) -> UUID? {
        guard let text = sender.draggingPasteboard.string(forType: .string),
              let id = UUID(uuidString: text),
              editor?.layout.plates.contains(where: { $0.id == id }) == true
        else { return nil }
        return id
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
    var onClose: (() -> Void)?

    var content: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let content { addSubview(content) }
            layoutContent()
        }
    }

    static let titleHeight = CanvasArrangement.titleBarHeight
    /// One radius, used by the layer mask and by the border stroke, so the outline and
    /// the card it outlines cannot disagree.
    static let cornerRadius: CGFloat = 10
    /// Generous on purpose: a 16 pt corner was genuinely hard to hit, so the whole
    /// right-hand and bottom edge resizes, not just the little triangle that shows it.
    private static let gripSize: CGFloat = 26
    private static let edgeGrab: CGFloat = 10

    private enum Drag { case none, move, resize }
    private var drag: Drag = .none
    private var dragOrigin: CGPoint = .zero
    private var startFrame: CGRect = .zero

    init(itemID: UUID, kind: CanvasItem.Kind) {
        self.itemID = itemID
        self.kind = kind
        super.init(frame: .zero)
        // A card contains its content: without this a plate frozen mid-resize spills
        // outside its own card, and a prep table taller than its card draws over the
        // board below it.
        //
        // Masked on the *layer* rather than with `clipsToBounds` alone, because that
        // clips to the rectangular bounds — so the content painted square over the
        // rounded fill and only the title-bar corners looked rounded.
        clipsToBounds = true
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The content view fills the body, so without this a press on the resize edge lands
    /// on the plate canvas — which implements `mouseDown` and swallows it. The chrome
    /// (title bar, close button, resize band) belongs to the card and is claimed here,
    /// before any subview is offered the point.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview.map({ convert(point, from: $0) }) else {
            return super.hitTest(point)
        }
        guard bounds.contains(local) else { return super.hitTest(point) }
        if closeRect.contains(local) || local.y <= Self.titleHeight
            || resizeRegion(contains: local) {
            return self
        }
        return super.hitTest(point)
    }

    func refresh(item: CanvasItem, prepPlan: DilutionPlan?) {
        if let note = content as? CanvasNoteView {
            note.text = item.text
            note.colorHex = item.colorHex
        }
        if let table = content as? PrepTableView, table.plan != prepPlan {
            table.plan = prepPlan
        }
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
        // While a drag is live the content is left exactly as it is: re-laying a plate out
        // is a full re-render of every well, and doing that on each frame is what made
        // dragging a plate choppy where dragging the prep table was smooth. It catches up
        // once, on mouse up.
        guard !isDragging else { return }
        layoutContent()
    }

    private func layoutContent() {
        guard let content else { return }
        let body = NSRect(
            x: 1, y: Self.titleHeight,
            width: max(0, bounds.width - 2), height: max(0, bounds.height - Self.titleHeight - 1)
        )
        // Only when it genuinely moved. Setting a view's `frame` calls `setFrameSize` even
        // when just the origin changed, so an unconditional invalidation here redrew every
        // plate on the board on every step of a drag.
        guard content.frame != body else { return }
        content.frame = body
        (content as? PrepTableView)?.fitWidth(to: body.width)
        content.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Self.cornerRadius
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius
        )
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
            in: NSRect(x: 9, y: 5, width: max(0, bounds.width - 36), height: bar.height - 10),
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

        // Close: takes the card off the board. A plate is only hidden by it — the plate
        // itself is untouched, and dragging its tab back brings the card back.
        let cross = NSBezierPath()
        let box = closeRect.insetBy(dx: 5, dy: 5)
        cross.move(to: NSPoint(x: box.minX, y: box.minY))
        cross.line(to: NSPoint(x: box.maxX, y: box.maxY))
        cross.move(to: NSPoint(x: box.maxX, y: box.minY))
        cross.line(to: NSPoint(x: box.minX, y: box.maxY))
        NSColor.secondaryLabelColor.setStroke()
        cross.lineWidth = 1.5
        cross.lineCapStyle = .round
        cross.stroke()

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

    /// Anywhere along the right or bottom edge, not only the corner.
    private func resizeRegion(contains point: CGPoint) -> Bool {
        if gripRect.contains(point) { return true }
        let nearRight = point.x >= bounds.maxX - Self.edgeGrab
        let nearBottom = point.y >= bounds.maxY - Self.edgeGrab
        return (nearRight || nearBottom) && point.y > Self.titleHeight
    }

    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - 22, y: 4, width: 18, height: 18)
    }

    /// The cursor says which edges do what, so the grab areas do not have to be guessed.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight),
                      cursor: .openHand)
        addCursorRect(gripRect, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point) {
            drag = .none
            onActivate?()
            onClose?()
            return
        }
        if resizeRegion(contains: point) {
            drag = .resize
        } else if point.y <= Self.titleHeight {
            drag = .move
            if event.clickCount == 2 { onOpen?() }
        } else {
            drag = .none
            onActivate?()
            return
        }
        // Marked as dragging *before* anything that could touch the document: a reload
        // mid-press re-adds this very view and cancels the drag AppKit is about to send.
        isDragging = true
        onActivate?()
        // Anchored in the **board's** coordinates. Anchoring in the card's own meant the
        // reference point moved with the card as it was dragged, which is what made the
        // cards jump around instead of following the mouse.
        dragOrigin = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        startFrame = frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != .none, let superview else { return }
        let now = superview.convert(event.locationInWindow, from: nil)
        let dx = now.x - dragOrigin.x
        let dy = now.y - dragOrigin.y
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
        let wasResizing = drag == .resize
        drag = .none
        isDragging = false
        if wasResizing { layoutContent() }
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

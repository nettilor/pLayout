import AppKit
import Combine
import SwiftUI

// MARK: - Geometry

struct PlateGeometry {
    let format: PlateFormat
    /// Quarter turns clockwise, 0–3 — the plate picked up and turned on the bench.
    ///
    /// A *rotation*, deliberately, not a transpose. Swapping the two axes leaves A1 in
    /// the top-left corner, which looks tidy and is impossible: you cannot reach it by
    /// turning a plate, only by turning it over and looking through the back. Under a
    /// real rotation A1 travels round the corners, which is what makes the picture on
    /// screen match the plate in your hand.
    ///
    /// Every coordinate this type takes or returns stays in *model* space — a well keeps
    /// its id, its values and its place in the file; only where it lands on screen moves.
    let quarterTurns: Int
    let cell: CGFloat
    let headerW: CGFloat
    let headerH: CGFloat
    /// Top-left corner of well A1.
    let originX: CGFloat
    let originY: CGFloat

    /// Largest cell a plate may use, so a 6-well plate does not become absurd.
    static let maxCell: CGFloat = 96
    /// Not zero: hit-testing divides by this, and 0 would trap on the Int conversion.
    static let minCell: CGFloat = 0.01
    /// Clear space kept on every side of the plate. The line key is drawn into the
    /// bottom one rather than asking for room of its own.
    static let pad: CGFloat = 14

    /// A quarter or three-quarter turn stands the plate on end; a half turn leaves the
    /// grid the same shape upside down.
    var isTurnedOnEnd: Bool { quarterTurns % 2 == 1 }

    /// The header strips travel with their own edge of the plate. The letters live
    /// beside column 1 and the numbers above row A, so turning clockwise carries the
    /// letters from the left edge to the top and the numbers from the top to the right —
    /// which is where they end up on a plate you have actually turned.
    var verticalStripOnRight: Bool { quarterTurns == 1 || quarterTurns == 2 }
    var horizontalStripAtBottom: Bool { quarterTurns == 2 || quarterTurns == 3 }

    /// The grid as drawn. Everything that measures or hit-tests the plate works in
    /// these; only the two mapping helpers below cross back into model space.
    var displayRows: Int { isTurnedOnEnd ? format.cols : format.rows }
    var displayCols: Int { isTurnedOnEnd ? format.rows : format.cols }

    init(format: PlateFormat, bounds: CGRect, quarterTurns: Int = 0) {
        self.format = format
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        let onEnd = self.quarterTurns % 2 == 1
        let gridRows = onEnd ? format.cols : format.rows
        let gridCols = onEnd ? format.rows : format.cols
        let pad = Self.pad
        let availableW = max(bounds.width - pad * 2, 1)
        let availableH = max(bounds.height - pad * 2, 1)
        let minHeaderW: CGFloat = 26
        let minHeaderH: CGFloat = 18

        func headerWidth(for cell: CGFloat) -> CGFloat { max(minHeaderW, min(cell * 1.05, 54)) }
        func headerHeight(for cell: CGFloat) -> CGFloat { max(minHeaderH, min(cell * 0.8, 34)) }
        func fit(headerW: CGFloat, headerH: CGFloat) -> CGFloat {
            min(
                (availableW - headerW) / CGFloat(gridCols),
                (availableH - headerH) / CGFloat(gridRows)
            )
        }

        // The headers grow with the cell size, so this is solved rather than computed.
        // Starting from the most optimistic headers and only ever taking `min` keeps the
        // sequence monotonically decreasing, which guarantees the result still satisfies
        // the fit it was measured against — a plate drawn outside these bounds would be
        // both invisible and unclickable.
        var size = min(Self.maxCell, fit(headerW: minHeaderW, headerH: minHeaderH))
        for _ in 0..<3 {
            size = min(size, fit(headerW: headerWidth(for: size), headerH: headerHeight(for: size)))
        }
        size = max(Self.minCell, min(size, Self.maxCell))

        cell = size
        headerW = headerWidth(for: size)
        headerH = headerHeight(for: size)
        let totalW = headerW + size * CGFloat(gridCols)
        let totalH = headerH + size * CGFloat(gridRows)
        // A strip sits on exactly one of each pair of opposite edges, so the plate takes
        // the same room either way — only whether the grid is pushed clear of it changes.
        let turns = self.quarterTurns
        let stripOnRight = turns == 1 || turns == 2
        let stripAtBottom = turns == 2 || turns == 3
        originX = pad + max(0, (availableW - totalW) / 2) + (stripOnRight ? 0 : headerW)
        originY = pad + max(0, (availableH - totalH) / 2) + (stripAtBottom ? 0 : headerH)
    }

    /// Shared by every point-to-cell conversion. Guards the division and the Int
    /// conversion, either of which would trap on a degenerate cell size or a wild point.
    private func line(_ offset: CGFloat, from origin: CGFloat) -> Int {
        guard cell > 0, offset.isFinite, origin.isFinite else { return 0 }
        let raw = ((offset - origin) / cell).rounded(.down)
        guard raw.isFinite else { return 0 }
        return Int(min(max(raw, -1_000_000), 1_000_000))
    }

    var gridRect: CGRect {
        CGRect(x: originX, y: originY,
               width: cell * CGFloat(displayCols), height: cell * CGFloat(displayRows))
    }

    var frameRect: CGRect {
        CGRect(x: verticalStripOnRight ? originX : originX - headerW,
               y: horizontalStripAtBottom ? originY : originY - headerH,
               width: headerW + cell * CGFloat(displayCols),
               height: headerH + cell * CGFloat(displayRows))
    }

    /// Where a *model* well is drawn. Together with `modelPosition` this pair is the
    /// whole of the rotation; nothing above the geometry ever sees display coordinates.
    ///
    /// Clockwise: the top edge goes to the right edge. So a model row becomes a display
    /// *column*, counted from the right, and a model column becomes a display row.
    func displayPosition(row: Int, col: Int) -> (row: Int, col: Int) {
        switch quarterTurns {
        case 1: return (row: col, col: format.rows - 1 - row)
        case 2: return (row: format.rows - 1 - row, col: format.cols - 1 - col)
        case 3: return (row: format.cols - 1 - col, col: row)
        default: return (row: row, col: col)
        }
    }

    /// The inverse. Hit-testing turns a point into a display cell and then comes back
    /// through here, so a click always names the well that was drawn under it.
    func modelPosition(displayRow: Int, displayCol: Int) -> WellPos {
        switch quarterTurns {
        case 1: return WellPos(row: format.rows - 1 - displayCol, col: displayRow)
        case 2: return WellPos(row: format.rows - 1 - displayRow, col: format.cols - 1 - displayCol)
        case 3: return WellPos(row: displayCol, col: format.cols - 1 - displayRow)
        default: return WellPos(row: displayRow, col: displayCol)
        }
    }

    func cellRect(row: Int, col: Int) -> CGRect {
        let p = displayPosition(row: row, col: col)
        return CGRect(x: originX + CGFloat(p.col) * cell, y: originY + CGFloat(p.row) * cell,
                      width: cell, height: cell)
    }

    /// A rotation carries opposite corners to opposite corners, so a block of wells is
    /// still a block and these two still bound it.
    func rect(of range: WellRange) -> CGRect {
        cellRect(row: range.minRow, col: range.minCol)
            .union(cellRect(row: range.maxRow, col: range.maxCol))
    }

    /// The strip that runs across the plate, indexed as drawn. Above the grid normally,
    /// below it once the plate has been turned far enough to carry it there.
    func horizontalHeaderRect(_ index: Int) -> CGRect {
        CGRect(x: originX + CGFloat(index) * cell, y: horizontalStripY,
               width: cell, height: headerH)
    }

    /// The strip that runs down the plate, indexed as drawn.
    func verticalHeaderRect(_ index: Int) -> CGRect {
        CGRect(x: verticalStripX, y: originY + CGFloat(index) * cell,
               width: headerW, height: cell)
    }

    private var horizontalStripY: CGFloat {
        horizontalStripAtBottom ? originY + cell * CGFloat(displayRows) : originY - headerH
    }

    private var verticalStripX: CGFloat {
        verticalStripOnRight ? originX + cell * CGFloat(displayCols) : originX - headerW
    }

    /// Where a *model* column's header is drawn: it follows its own cells round, so it
    /// is on whichever strip those cells now line up with. Callers that want "the header
    /// for column 3" ask this way and stay correct at every turn.
    func columnHeaderRect(_ col: Int) -> CGRect {
        let p = displayPosition(row: 0, col: col)
        return isTurnedOnEnd ? verticalHeaderRect(p.row) : horizontalHeaderRect(p.col)
    }

    func rowHeaderRect(_ row: Int) -> CGRect {
        let p = displayPosition(row: row, col: 0)
        return isTurnedOnEnd ? horizontalHeaderRect(p.col) : verticalHeaderRect(p.row)
    }

    /// Where the two strips meet, which is the corner they both run from — so it
    /// travels with them as the plate turns.
    var cornerRect: CGRect {
        CGRect(x: verticalStripX, y: horizontalStripY, width: headerW, height: headerH)
    }

    enum Hit: Equatable {
        case well(WellPos)
        case columnHeader(Int)
        case rowHeader(Int)
        case corner
        case outside
    }

    /// Everything here comes back in model space, so the mouse handling above never
    /// has to know which way the plate is facing.
    func hit(_ point: CGPoint) -> Hit {
        let across = line(point.x, from: originX)
        let down = line(point.y, from: originY)
        let onGridX = across >= 0 && across < displayCols
        let onGridY = down >= 0 && down < displayRows
        if onGridX && onGridY {
            return .well(modelPosition(displayRow: down, displayCol: across))
        }
        // A strip labels whichever axis its cells belong to, which the turn decides.
        if onGridX, point.y >= horizontalStripY, point.y < horizontalStripY + headerH {
            let well = modelPosition(displayRow: 0, displayCol: across)
            return isTurnedOnEnd ? .rowHeader(well.row) : .columnHeader(well.col)
        }
        if onGridY, point.x >= verticalStripX, point.x < verticalStripX + headerW {
            let well = modelPosition(displayRow: down, displayCol: 0)
            return isTurnedOnEnd ? .columnHeader(well.col) : .rowHeader(well.row)
        }
        if cornerRect.contains(point) { return .corner }
        return .outside
    }

    /// Clamped lookup so a drag that leaves the plate keeps extending sensibly. Clamping
    /// happens in display space and is then mapped back, which is what keeps a drag
    /// running off the right-hand edge extending along the axis that edge belongs to.
    func nearestWell(_ point: CGPoint) -> WellPos {
        let across = min(max(line(point.x, from: originX), 0), displayCols - 1)
        let down = min(max(line(point.y, from: originY), 0), displayRows - 1)
        return modelPosition(displayRow: down, displayCol: across)
    }

    func nearestColumn(_ point: CGPoint) -> Int { nearestWell(point).col }

    func nearestRow(_ point: CGPoint) -> Int { nearestWell(point).row }
}

// MARK: - Canvas

/// What a canvas view is for.
///
/// `.primary` is the document's editing surface — the one canvas in plate mode, and the
/// only one that may claim `editor.canvas`. `.card` is a view of one plate on the board.
enum CanvasRole: Equatable {
    case primary
    case card(plateID: UUID)
}

final class PlateCanvasView: NSView, NSUserInterfaceValidations {

    weak var editor: PlateEditor?

    private(set) var role: CanvasRole = .primary

    /// The board's magnification, pushed in as a **drawing hint** — never as geometry.
    /// Below about 0.6 the hairlines and the well text are mush and are better left out.
    /// `PlateGeometry` still knows nothing about any of this.
    var displayScale: CGFloat = 1 {
        didSet { if displayScale != oldValue { needsDisplay = true } }
    }

    /// The plate this view draws. `.primary` follows the active plate exactly as before.
    private var shownPlate: Plate? {
        guard let editor else { return nil }
        guard case .card(let id) = role else { return editor.plate }
        return editor.layout.plates.first { $0.id == id }
    }

    /// True when what this view shows is also what the document is editing. Derived, not
    /// stored: a stored flag could disagree with `activePlateID`, and this cannot.
    var isEditable: Bool {
        guard case .card(let id) = role else { return true }
        return editor?.activePlateID == id
    }

    private enum DragKind { case none, wells, columns, rows }
    private var dragKind: DragKind = .none
    private var dragAnchorWell: WellPos?
    private var dragAnchorLine = 0
    private var freeformBrush = false
    /// The selection as it stood at ⌘-mouse-down, so a drag that follows the toggle
    /// can replay "base plus dragged rectangle" instead of accumulating every
    /// intermediate rectangle the cursor passed through.
    private var customDragBase: Set<WellPos>?

    /// Wells the in-progress drag will write when the mouse comes up.
    private var pendingWells: Set<Int> = []
    private var pendingLevelID: UUID?
    private var pendingIsErase = false
    private var isPaintingDrag = false

    private var exportMode = false
    /// Whether an exported image carries the Overview block outlines. Asked in the save
    /// panel and set for the one render — printing takes the plate exactly as shown,
    /// which is the promise the print command already makes.
    private var exportIncludesGroups = true
    /// Drives the corner control's hover state; a click target with no feedback reads
    /// as decoration.
    private var hoveringCorner = false
    private var trackingArea: NSTrackingArea?
    private var cancellable: AnyCancellable?

    override var isFlipped: Bool { true }
    /// A read-only card must not take the keyboard, or the arrows, `1`–`9` and `⌫` would
    /// go to a plate nobody is editing.
    override var acceptsFirstResponder: Bool { isEditable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(editor: PlateEditor, role: CanvasRole = .primary) {
        self.editor = editor
        self.role = role
        // Only the editing surface claims that slot. It is what export, print and
        // `focusCanvas()` resolve through, and a card is whatever size it was dragged
        // to — claiming it from a card would silently make an exported PNG card-sized.
        if case .primary = role { editor.canvas = self }
        subscribe(to: editor, role: role)
    }

    /// What makes this view redraw.
    ///
    /// A card takes a narrower set than the primary canvas. `editor.objectWillChange`
    /// fires for `hovered` too, so subscribing a board of four dense plates to it would
    /// redraw every one of them on every mouse move.
    ///
    /// Hopped through the main queue rather than the main *run loop*: run-loop delivery
    /// is scheduled in the default mode only, so while the mouse is down — exactly when
    /// a sidebar click happens — the redraw would wait for tracking to finish. The hop
    /// itself is still needed because objectWillChange fires before the value changes.
    private func subscribe(to editor: PlateEditor, role: CanvasRole) {
        let trigger: AnyPublisher<Void, Never>
        if case .card = role {
            trigger = Publishers.MergeMany([
                editor.document.$layout.map { _ in () }.eraseToAnyPublisher(),
                Preferences.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                editor.$activePlateID.map { _ in () }.eraseToAnyPublisher(),
                editor.$activeFactorID.map { _ in () }.eraseToAnyPublisher(),
                editor.$armedLevelID.map { _ in () }.eraseToAnyPublisher(),
                editor.$selection.map { _ in () }.eraseToAnyPublisher(),
                editor.$customWells.map { _ in () }.eraseToAnyPublisher(),
                editor.$spotlightLevelID.map { _ in () }.eraseToAnyPublisher(),
                editor.$roundWells.map { _ in () }.eraseToAnyPublisher(),
                editor.$showSecondaryFactors.map { _ in () }.eraseToAnyPublisher(),
                editor.$showOverviewGroups.map { _ in () }.eraseToAnyPublisher(),
                editor.$overviewGroupFactorID.map { _ in () }.eraseToAnyPublisher(),
            ]).eraseToAnyPublisher()
        } else {
            trigger = editor.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        }
        cancellable = trigger
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.needsDisplay = true }
    }

    /// The smallest bounds that still draw this plate exactly as it is drawn now.
    ///
    /// `PlateGeometry` centres the plate in whatever room it is given, so a card whose
    /// shape does not match the plate's carries empty margin on two sides. This is the
    /// same picture with that slack taken out: the cell size does not change, so nothing
    /// moves or resizes — the card simply stops being bigger than its plate.
    ///
    /// Solving against these bounds gives back all but a whisker of the cell size they
    /// were measured from — both axes bind at once, which is as close to a fixed point
    /// as the geometry's solve has. It is not exact: the solve starts from the smallest
    /// possible headers and only ever takes `min`, so a header that grows with that
    /// first estimate lands the result a fraction low — about a tenth of a percent, or
    /// three hundredths of a point per well.
    ///
    /// Deliberately not padded to make up the difference. Padding overshoots instead,
    /// and because the next trim measures the *new* frame it would creep the card larger
    /// every time the gesture was used. Undershooting settles: a second trim moves the
    /// card by less than the half-point `sizeToFitContent` bothers with, so trimming
    /// twice is trimming once. The line key lives in the padding and needs no room here.
    var snugSize: CGSize {
        let frame = geometry.frameRect
        return CGSize(width: frame.width + PlateGeometry.pad * 2,
                      height: frame.height + PlateGeometry.pad * 2)
    }

    /// A detached canvas at a stated size, for exporting and printing without depending
    /// on how big the window — or a card — happens to be. Same shape as
    /// `PrepTableView.print(plan:jobName:)`, and for the same reason.
    static func offscreen(editor: PlateEditor, size: NSSize) -> PlateCanvasView {
        let view = PlateCanvasView(frame: NSRect(origin: .zero, size: size))
        view.editor = editor
        return view
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // The window's undo manager is the one ⌘Z and Edit ▸ Undo reach, through the
        // responder chain — and it wins over whatever the editor was handed earlier.
        // On macOS 27 the SwiftUI environment gives `ContentView` a *different*
        // NSUndoManager for a restored or second document window, and its `onAppear`
        // runs before this view is in the window; taking the environment's when the
        // slot was empty meant every edit was registered where nothing could undo it.
        // Traced in the running app, not guessed (HANDOFF §2z).
        if let undoManager = window.undoManager, undoManager !== editor?.undoManager {
            editor?.undoManager = undoManager
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditable else { return }
            guard self.window?.firstResponder is NSWindow || self.window?.firstResponder == nil else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private var geometry: PlateGeometry {
        // Resolved from the plate this view actually shows. Orientation is document-wide
        // but is resolved *against a format*, so a card of a differently shaped plate has
        // to work its own turn out — `editor.quarterTurns` is the active plate's.
        let plate = shownPlate
        let format = plate?.format ?? .well96
        let orientation = plate?.orientation ?? editor?.layout.orientation ?? .automatic
        return PlateGeometry(
            format: format, bounds: bounds, quarterTurns: orientation.quarterTurns(for: format)
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Exported images should read as light-mode artwork even in a dark window.
        if exportMode, let aqua = NSAppearance(named: .aqua) {
            aqua.performAsCurrentDrawingAppearance { render() }
        } else {
            render()
        }
    }

    private func render() {
        guard let editor, let plate = shownPlate else { return }
        let geo = geometry
        let format = plate.format
        let mode = editor.layout.wellLabelMode
        let textStyle = Preferences.shared.wellTextStyle
        let bandOpacity = CGFloat(Preferences.shared.activeBandOpacity)
        let blockScale = (
            width: CGFloat(Preferences.shared.stackBlockWidthScale),
            height: CGFloat(Preferences.shared.stackBlockHeightScale)
        )
        // Overview has no factor being painted, so no factor colours the well. Read
        // from the mode rather than from `activeFactor` alone: that keeps the drawing
        // correct on its own terms, including when a test sets the mode directly.
        let factor = mode.isOverview ? nil : editor.activeFactor
        // The selection belongs to the plate being edited, and these sets feed the
        // header tint drawn well before the `isEditable` guard below — so a read-only
        // card would highlight the active plate's rows and columns at the same
        // coordinates, which reads as a selection it does not have.
        let selection = isEditable ? editor.selection?.clamped(to: format) : nil
        let customSelection = isEditable ? editor.customWells : nil
        let selectedRows: Set<Int>
        let selectedCols: Set<Int>
        if let customSelection {
            selectedRows = Set(customSelection.map(\.row))
            selectedCols = Set(customSelection.map(\.col))
        } else if let selection {
            selectedRows = Set(selection.minRow...selection.maxRow)
            selectedCols = Set(selection.minCol...selection.maxCol)
        } else {
            selectedRows = []
            selectedCols = []
        }

        (exportMode ? NSColor.white : NSColor.windowBackgroundColor).setFill()
        bounds.fill()

        NSColor.textBackgroundColor.setFill()
        NSBezierPath(roundedRect: geo.gridRect, xRadius: 3, yRadius: 3).fill()

        drawHeaders(geo: geo, selectedRows: selectedRows, selectedCols: selectedCols)

        // Overview draws only the factors not hidden from it — the same list the block
        // outlines are grouped on, so a hidden factor is absent from the picture entirely
        // rather than lingering in the stripe, the key or a seam. Every other mode shows
        // the lot: they have an active factor, and hiding that would make no sense.
        let factors = mode.isOverview ? editor.layout.overviewFactors : editor.layout.factors
        let plan = labelPlan(cell: geo.cell, mode: mode, factorCount: factors.count)
        // Factors shown as text lines; anything left over may fall back to the colour stripe.
        let stacked = plan.lineCount >= 2 && !(geo.cell * displayScale < 7)
            ? Array(factors.prefix(plan.lineCount)) : []
        let overflow = stacked.isEmpty ? [] : Array(factors.dropFirst(plan.lineCount))

        // Zoomed far out on the board, the labels and hairlines are mush on screen and
        // drawing them is most of the cost of a board full of dense plates. `displayScale`
        // is a *drawing* hint from the board — `PlateGeometry` still knows nothing of it.
        let onScreenCell = geo.cell * displayScale
        let coarse = onScreenCell < 7
        let showSingleText = mode.showsText && stacked.isEmpty && geo.cell >= 17 && !coarse
        // A well too small to stack still has to say something in Overview, so factor 1
        // takes the well's text and the rest drop to the stripe — the same shape the
        // other modes take, only without a factor having been chosen.
        let soloFactor = mode.isOverview && showSingleText ? factors.first : nil

        // Overview always shows the other factors — that is the whole mode — and the
        // toggle that would otherwise govern it is hidden while Overview is on.
        var secondary = mode.isOverview
            ? factors
            : editor.showSecondaryFactors ? editor.secondaryFactors : []
        if let soloFactor { secondary.removeAll { $0.id == soloFactor.id } }

        // The stack is sized against the whole body, so the stripe only gets what the
        // stack did not need. That keeps the two from fighting over the same space.
        // Once labels are stacked they are the whole story, so the overflow stripe is
        // always drawn there — "Show other factors" only governs the unstacked modes.
        var stripeFactors = stacked.isEmpty ? secondary : overflow
        var stripeHeight: CGFloat = 0
        if !stripeFactors.isEmpty {
            if stacked.isEmpty {
                // Overview has no active-factor colour competing for the well, and a
                // plate too dense to stack would otherwise be a blank grid, so the
                // stripe is let into far smaller cells there.
                stripeHeight = geo.cell >= (mode.isOverview ? 10 : 22) ? max(3, geo.cell * 0.15) : 0
            } else {
                let leftover = geo.cell - Self.bodyInset(cell: geo.cell) * 2
                    - plan.stackHeight(lines: stacked.count)
                stripeHeight = leftover >= 5 ? min(max(3, geo.cell * 0.15), leftover - 2) : 0
            }
            if stripeHeight == 0 { stripeFactors = [] }
        }
        let hiddenFactorCount = stacked.isEmpty ? 0 : overflow.count - stripeFactors.count

        let baseWellFontSize = max(7, min(geo.cell * 0.30, 13))
            * CGFloat(Preferences.shared.canvasFontScale)
        // One size for every well on the plate, measured against every name it is going
        // to draw. Skipped when there is no text to fit, and when the board has zoomed
        // out far enough that the labels are not being drawn at all.
        let fit = Preferences.shared.fitTextToWells && !coarse
            ? Self.fitScale(plateLabels(
                plate: plate, factor: factor, soloFactor: soloFactor, stacked: stacked,
                showsSingleText: showSingleText, wellFontSize: baseWellFontSize,
                geo: geo, plan: plan, stripeHeight: stripeHeight,
                activeFactorID: editor.activeFactorID, armedLevelID: editor.armedLevelID,
                blockWidthScale: blockScale.width
              ))
            : 1
        let wellFontSize = baseWellFontSize * fit
        let customEmpty = Preferences.shared.customEmptyWellColor
        let emptyFill = Preferences.shared.emptyWellFill(exportMode: exportMode)
        // Every Overview well gets this same tile, so by default it is pitched a
        // little stronger than the empty-well fill: it has to read as a surface, not
        // as an absence. It has no colour of its own to contrast against, so under
        // "always white" it is the tile that moves, not the ink — otherwise Overview
        // is unreadable. A chosen empty-well colour takes over both fills — Overview
        // is the stacked pills on an empty-well backdrop, and the backdrop is now
        // the user's — so the ink contrasts with *it*, exactly as on a painted well.
        let neutralFill = customEmpty ?? (textStyle.prefersDarkNeutral
            ? NSColor(white: 0.32, alpha: 1)
            : NSColor.quaternaryLabelColor.withAlphaComponent(exportMode ? 0.14 : 0.18))
        let neutralInk = customEmpty.map { $0.labelInk(textStyle) } ?? textStyle.neutralInk
        let hairline = NSColor.separatorColor.withAlphaComponent(0.6)
        let drawHairlines = geo.cell >= 4 && !coarse

        for row in 0..<format.rows {
            for col in 0..<format.cols {
                let cellRect = geo.cellRect(row: row, col: col)
                // Skip wells outside the damaged region — this is what keeps a dense
                // custom plate responsive while dragging.
                guard needsToDraw(cellRect.insetBy(dx: -1, dy: -1)) else { continue }
                let index = format.index(row: row, col: col)

                if drawHairlines {
                    hairline.setStroke()
                    let border = NSBezierPath(rect: cellRect.insetBy(dx: 0.25, dy: 0.25))
                    border.lineWidth = 0.5
                    border.stroke()
                }

                let level = resolvedLevel(index: index, plate: plate, factor: factor)
                // When stacking, the stripe sits inside the body's leftover space rather
                // than shrinking it, so the stack keeps every line the plan promised.
                let bodyRect = wellBody(
                    in: cellRect, stripeHeight: stacked.isEmpty ? stripeHeight : 0,
                    square: stacked.isEmpty
                )
                let shape = wellPath(in: bodyRect, round: editor.roundWells && stacked.isEmpty)

                // A stacked well carries the active factor's colour on its own line — the
                // band behind the label and the block beside it — so the well itself is
                // the same neutral tile Overview uses. Flooding it with that colour
                // drowned every other factor's block, which was the point of stacking.
                // Only a well too small to stack still takes the colour whole: it has
                // nothing else to show it with.
                if stacked.isEmpty, let level, let color = NSColor(hex: level.colorHex) {
                    color.setFill()
                    shape.fill()
                    color.blended(withFraction: 0.25, of: .black)?.withAlphaComponent(0.55).setStroke()
                    shape.lineWidth = 0.75
                    shape.stroke()
                    if showSingleText {
                        drawFitted(
                            level.name, in: bodyRect, maxFontSize: wellFontSize,
                            color: color.labelInk(textStyle)
                        )
                    }
                } else {
                    (mode.isOverview || !stacked.isEmpty ? neutralFill : emptyFill).setFill()
                    shape.fill()
                    if let soloFactor,
                       let name = soloFactor
                        .level(id: plate.levelID(factor: soloFactor.id, well: index))?.name
                    {
                        drawFitted(name, in: bodyRect, maxFontSize: wellFontSize, color: neutralInk)
                    }
                }

                if !stacked.isEmpty {
                    drawFactorStack(
                        in: bodyRect, factors: stacked, plate: plate, index: index,
                        plan: plan, activeFactorID: editor.activeFactorID,
                        reservedBottom: stripeHeight, neutralInk: neutralInk,
                        bandOpacity: bandOpacity, fit: fit, blockScale: blockScale
                    )
                }

                if stripeHeight > 0 {
                    // Flush with the bottom of the body when stacking, so the band and
                    // the stack's `reservedBottom` describe exactly the same space.
                    let band = stacked.isEmpty
                        ? bandBelow(cellRect: cellRect, height: stripeHeight)
                        : CGRect(x: bodyRect.minX, y: bodyRect.maxY - stripeHeight,
                                 width: bodyRect.width, height: stripeHeight)
                    drawSecondaryStripe(
                        band: band, secondary: stripeFactors, plate: plate, index: index,
                        activeFactorID: editor.activeFactorID
                    )
                }
            }
        }

        if !stacked.isEmpty {
            drawLineKey(
                stacked: stacked, striped: stripeFactors.count, hidden: hiddenFactorCount, geo: geo
            )
        }

        // Part of the picture rather than an interface hint, so it is drawn above the
        // export guard: a figure of the layout keeps its chunking. Whether an exported
        // image includes it is asked in the save panel, not decided here.
        if editor.drawsOverviewGroups, !exportMode || exportIncludesGroups {
            drawGroupOutlines(
                geo: geo, plate: plate, factors: factors, basis: editor.overviewGroupBasis
            )
        }

        guard !exportMode else { return }

        // A noted well carries the spreadsheet's comment mark: a small corner
        // triangle, screen only — figures stay clean, the notes travel in the
        // Wells sheet instead.
        if !plate.wellNotes.isEmpty {
            NSColor.labelColor.withAlphaComponent(0.45).setFill()
            for key in plate.wellNotes.keys {
                guard let well = Int(key), well >= 0, well < format.wellCount else { continue }
                let rect = geo.cellRect(row: well / format.cols, col: well % format.cols)
                let side = max(4, min(rect.width * 0.16, 7))
                let corner = NSBezierPath()
                corner.move(to: NSPoint(x: rect.maxX - 1.5 - side, y: rect.minY + 1.5))
                corner.line(to: NSPoint(x: rect.maxX - 1.5, y: rect.minY + 1.5))
                corner.line(to: NSPoint(x: rect.maxX - 1.5, y: rect.minY + 1.5 + side))
                corner.close()
                corner.fill()
            }
        }

        // Spotlight: hovering a condition row in the sidebar dims every well that is
        // not that condition, so a dense plate answers "where is this?" by itself.
        // Transient view state, drawn past the export guard on purpose.
        // Live on every card, deliberately: it reads document state rather than which
        // plate is being edited, and "hover a condition, see where it is across every
        // plate at once" is the board's best moment.
        if let spotlight = editor.spotlightLevelID, let factorID = editor.activeFactorID {
            NSColor.textBackgroundColor.withAlphaComponent(0.8).setFill()
            for row in 0..<format.rows {
                for col in 0..<format.cols {
                    let index = format.index(row: row, col: col)
                    guard plate.levelID(factor: factorID, well: index) != spotlight else { continue }
                    geo.cellRect(row: row, col: col).fill()
                }
            }
        }

        // The selection, the focus ring and the hover ring all belong to the plate being
        // edited. A card showing another plate must not draw them at the same row and
        // column, which would look exactly like a real selection.
        guard isEditable else { return }

        let accent = NSColor.controlAccentColor
        if let customSelection {
            // Discontiguous wells each get the rectangle treatment on their own —
            // one big bounding box would claim wells the user deliberately left out.
            accent.withAlphaComponent(0.10).setFill()
            accent.setStroke()
            for pos in customSelection {
                guard format.contains(row: pos.row, col: pos.col) else { continue }
                let rect = geo.cellRect(row: pos.row, col: pos.col)
                NSBezierPath(rect: rect).fill()
                let outline = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                outline.lineWidth = 2
                outline.stroke()
            }
        } else if let selection {
            let selectionRect = geo.rect(of: selection)
            accent.withAlphaComponent(0.10).setFill()
            NSBezierPath(rect: selectionRect).fill()
            accent.setStroke()
            let outline = NSBezierPath(rect: selectionRect.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()

            if !selection.isSingleWell {
                let focus = geo.cellRect(row: selection.focus.row, col: selection.focus.col)
                accent.withAlphaComponent(0.9).setStroke()
                let focusPath = NSBezierPath(rect: focus.insetBy(dx: 1.5, dy: 1.5))
                focusPath.lineWidth = 1.5
                focusPath.stroke()
            }
        }

        if let hovered = editor.hovered, format.contains(row: hovered.row, col: hovered.col) {
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            let hoverPath = NSBezierPath(rect: geo.cellRect(row: hovered.row, col: hovered.col).insetBy(dx: 1, dy: 1))
            hoverPath.lineWidth = 1
            hoverPath.stroke()
        }
    }

    /// The level shown for a well, taking any in-progress drag preview into account.
    private func resolvedLevel(index: Int, plate: Plate, factor: Factor?) -> Level? {
        guard let factor else { return nil }
        if isPaintingDrag && pendingWells.contains(index) {
            guard !pendingIsErase else { return nil }
            return factor.level(id: pendingLevelID)
        }
        return factor.level(id: plate.levelID(factor: factor.id, well: index))
    }

    /// Ramped rather than stepped: a jump here would make the number of label lines
    /// non-monotonic, so growing the window could remove a line.
    static func bodyInset(cell: CGFloat) -> CGFloat { min(2, max(1, cell * 0.1)) }

    private func wellBody(in cellRect: CGRect, stripeHeight: CGFloat, square: Bool = true) -> CGRect {
        let inset = Self.bodyInset(cell: cellRect.width)
        var rect = cellRect.insetBy(dx: inset, dy: inset)
        if stripeHeight > 0 {
            rect.size.height -= stripeHeight + 1
        }
        // Circular wells need a square box; stacked text wants the full cell width.
        if square, rect.width > rect.height {
            rect.origin.x += (rect.width - rect.height) / 2
            rect.size.width = rect.height
        }
        return rect
    }

    // MARK: - Multi-factor labels

    /// How many factors fit as text lines inside one well, and the type sizes to use.
    struct LabelPlan: Equatable {
        var lineCount: Int
        var primarySize: CGFloat
        var secondarySize: CGFloat
        var gap: CGFloat
        /// Overview ranks no factor above another, so every line shares one size,
        /// weight and colour. Everywhere else one line is the headline.
        var uniform: Bool = false

        var primaryHeight: CGFloat { primarySize * 1.18 }
        var secondaryHeight: CGFloat { secondarySize * 1.18 }

        /// Exactly one line can be the headline, so the total does not depend on *which*
        /// one it is — only on whether there is one at all. `primary: true` is the taller
        /// case and therefore the one to measure the fit against.
        func stackHeight(lines: Int, primary: Bool = true) -> CGFloat {
            guard lines > 0 else { return 0 }
            return (primary ? primaryHeight : secondaryHeight)
                + CGFloat(lines - 1) * (secondaryHeight + gap)
        }
    }

    /// Sizes are continuous functions of the cell size with no rounding, and the stack
    /// is measured against the *whole* well body. Anything else — a stepped ramp, or
    /// subtracting space for a stripe that may not be drawn — makes `lineCount` fall as
    /// the window grows, which reads as labels randomly disappearing.
    static func labelPlan(
        cell: CGFloat, mode: WellLabelMode, factorCount: Int,
        scale: CGFloat = CGFloat(Preferences.shared.canvasFontScale)
    ) -> LabelPlan {
        // The user's size multiplies every tier and the gap uniformly, so the plan is
        // exactly the unscaled plan with larger type — the continuity the tests pin
        // survives multiplication, and the fit is still measured honestly below.
        let primary = max(7, min(cell * 0.30, 13)) * scale
        let secondary = max(6.5 * scale, primary * 0.80)
        let gap = max(0.5, secondary * 0.16)
        var plan = LabelPlan(lineCount: 0, primarySize: primary, secondarySize: secondary, gap: gap)

        // Overview ranks no factor above another, so it drops the headline tier and
        // measures the stack at the supporting size. Measuring at the *smaller* size is
        // what guarantees Overview never fits fewer factors than the graded stack —
        // being the worse overview of the two would defeat the mode.
        if mode.isOverview {
            plan.primarySize = secondary
            plan.uniform = true
        }

        guard mode.stacksEveryFactor, factorCount >= 2 else { return plan }

        let available = cell - bodyInset(cell: cell) * 2
        guard plan.primaryHeight <= available else { return plan }
        var lines = 1
        while plan.stackHeight(lines: lines + 1) <= available { lines += 1 }

        plan.lineCount = min(lines, factorCount)
        if plan.lineCount < 2 { plan.lineCount = 0 }

        // With the line count settled, grow the uniform type back into the room those
        // lines were measured into — capped at the headline size, so Overview is never
        // louder than the mode it stands in for. Room for the overflow stripe is held
        // back first, or the factors that missed a line would vanish outright instead
        // of dropping to a colour band. The `secondary` floor is what keeps this from
        // ever costing the line count it was just given.
        if plan.uniform, plan.lineCount >= 2 {
            let lines = CGFloat(plan.lineCount)
            let reserved: CGFloat = factorCount > plan.lineCount ? max(3, cell * 0.15) + 2 : 0
            let fitted = (available - reserved - (lines - 1) * gap) / (lines * 1.18)
            let size = max(secondary, min(primary, fitted))
            plan.primarySize = size
            plan.secondarySize = size
        }
        return plan
    }

    private func labelPlan(cell: CGFloat, mode: WellLabelMode, factorCount: Int) -> LabelPlan {
        Self.labelPlan(cell: cell, mode: mode, factorCount: factorCount)
    }

    /// The rail that heads a stacked line — a block of the level's colour — with the
    /// inset from the well's edge before it and the gap between it and the text. Wide
    /// enough to read as a swatch of the colour rather than a tick mark beside the
    /// name: the colour is what the rail is for. `width` is a supporting line's; the
    /// headline's rail grows with its taller line to keep the block's shape, and
    /// `activeWidth` is the slot that leaves for it. Every rail is left-aligned in that
    /// slot, so the text starts at one x down the whole stack.
    ///
    /// `widthScale` is the length setting. It multiplies the width the well gives, but
    /// past a share of the body it stops: a block that kept growing would eat the name
    /// it heads, and on a dense plate the well has no room to lend. It can never make a
    /// block shorter than the unscaled one that way, so a tiny well is left as it was.
    /// Takes the shared preference by default, like `labelPlan`; tests pass their own.
    static func stackRail(
        bodyWidth: CGFloat, widthScale: CGFloat = CGFloat(Preferences.shared.stackBlockWidthScale)
    ) -> (width: CGFloat, activeWidth: CGFloat, inset: CGFloat, gap: CGFloat) {
        let base = max(3.5, min(9, bodyWidth * 0.14))
        let width = min(base * widthScale, max(base, bodyWidth * 0.35))
        return (width, width * activeRailScale, max(2.5, bodyWidth * 0.055), max(2, width * 0.45))
    }

    /// The share of a stacked line's height the block takes at the default setting.
    static let stackBlockHeightShare: CGFloat = 0.82

    /// The most a headline line is taller than a supporting one: the secondary tier is
    /// 80% of the primary and never less, so the headline's rail — which scales with
    /// its line — is never wider than this times a supporting rail.
    static let activeRailScale: CGFloat = 1.25

    /// The room a stacked line's text gets inside a well body, past the inset, the
    /// headline's rail slot and the gap after it. One formula, so the fit measured
    /// before the well loop and the drawing inside it cannot disagree about how much
    /// room there is.
    static func stackTextWidth(
        bodyWidth: CGFloat, widthScale: CGFloat = CGFloat(Preferences.shared.stackBlockWidthScale)
    ) -> CGFloat {
        let rail = stackRail(bodyWidth: bodyWidth, widthScale: widthScale)
        return bodyWidth - rail.inset * 2 - rail.activeWidth - rail.gap
    }

    /// How much of a rect `drawFitted` really has for text, once its padding is off.
    static func fittedWidth(of width: CGFloat, alignment: NSTextAlignment) -> CGFloat {
        width - (alignment == .center ? max(2, width * 0.12) : 1)
    }

    /// How small a label may be made before shrinking it further stops being a kindness
    /// and truncation is the honest answer. One number, shared by the per-label fit and
    /// the per-plate one, so the two cannot stop at different sizes.
    static let minimumLabelSize: CGFloat = 5

    /// How small `drawFitted` may shrink a label on its own before it gives up and
    /// truncates instead.
    ///
    /// A floor per tier keeps an inactive label from shrinking past the active one and
    /// inverting the visual hierarchy — but it is a limit on how far *this* shrinks a
    /// label, and it may never override the size it was handed. A fitted plate arrives
    /// already at the size the whole plate agreed on, and clamping that back up would
    /// truncate the very label the plate was sized for.
    static func fittedFloor(maxFontSize: CGFloat, minFontSize: CGFloat?) -> CGFloat {
        min(maxFontSize, max(minimumLabelSize, minFontSize ?? 7))
    }

    /// One label a plate is going to draw, and the width it has to fit into.
    struct FittedLabel: Equatable {
        var text: String
        var available: CGFloat
        var size: CGFloat
        var weight: NSFont.Weight = .medium
    }

    /// The largest fraction of the computed type size at which *every* one of these
    /// labels fits the width it was given.
    ///
    /// One number for the whole plate, because every well on a plate is the same size:
    /// the only thing that makes one label smaller than its neighbour is its own
    /// length. Fitting each label on its own leaves the plate ragged and truncates
    /// whichever name is longest; taking the minimum here shrinks them together and
    /// truncates none of them.
    ///
    /// It never returns more than 1 — fitting makes text smaller, never larger than the
    /// size the cell has earned — and no single label may pull a tier below
    /// `minimumSize`, the same floor `drawFitted` gives up and truncates at. A name long
    /// enough to need less than that pays for itself instead of the plate paying for it.
    static func fitScale(
        _ labels: [FittedLabel], minimumSize: CGFloat = minimumLabelSize,
        font: (CGFloat, NSFont.Weight) -> NSFont = {
            Preferences.shared.canvasFont(ofSize: $0, weight: $1)
        }
    ) -> CGFloat {
        var scale: CGFloat = 1
        for label in labels {
            let trimmed = label.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, label.available > 2, label.size > 0 else { continue }
            func measure(at fraction: CGFloat) -> CGFloat {
                (trimmed as NSString)
                    .size(withAttributes: [.font: font(label.size * fraction, label.weight)]).width
            }
            var width = measure(at: 1)
            guard width > label.available else { continue }

            let floor = min(1, minimumSize / label.size)
            var fraction = max(floor, label.available / width)
            // The ratio gets close, because width is nearly linear in point size — but
            // only nearly, and a scale that only nearly fits would leave `drawFitted`
            // shrinking this one label a further percent or two on its own. That is the
            // ragged plate the whole option exists to avoid, so the gap is closed here
            // by measuring, exactly as `drawFitted` closes its own. One measurement per
            // pass: this runs for every distinct name on every render.
            var attempts = 0
            while fraction > floor, attempts < 8 {
                width = measure(at: fraction)
                guard width > label.available else { break }
                fraction = max(floor, fraction * min(0.98, label.available / width))
                attempts += 1
            }
            scale = min(scale, fraction)
        }
        return scale
    }

    /// Every label this plate is going to draw, with the width it has to fit into.
    ///
    /// One entry per distinct name rather than one per well — every well is the same
    /// size, so a name that fits in one fits in all of them — which is also what keeps
    /// this affordable on every frame of a drag. Names defined but never painted are
    /// left out: a condition sitting unused in the sidebar should not shrink the plate.
    private func plateLabels(
        plate: Plate, factor: Factor?, soloFactor: Factor?, stacked: [Factor],
        showsSingleText: Bool, wellFontSize: CGFloat, geo: PlateGeometry,
        plan: LabelPlan, stripeHeight: CGFloat, activeFactorID: UUID?, armedLevelID: UUID?,
        blockWidthScale: CGFloat
    ) -> [FittedLabel] {
        // Every cell is identical, so the first one stands for all of them.
        let body = wellBody(
            in: geo.cellRect(row: 0, col: 0),
            stripeHeight: stacked.isEmpty ? stripeHeight : 0, square: stacked.isEmpty
        )
        var labels: [FittedLabel] = []

        if showsSingleText, let single = soloFactor ?? factor {
            let available = Self.fittedWidth(of: body.width, alignment: .center)
            for name in names(of: single, painted: plate, armed: armedLevelID) {
                labels.append(
                    FittedLabel(text: name, available: available, size: wellFontSize)
                )
            }
        }
        if !stacked.isEmpty {
            let available = Self.stackTextWidth(bodyWidth: body.width, widthScale: blockWidthScale)
            for line in stacked {
                // The factor being painted takes the headline tier, so it is measured
                // at the size and weight it is actually drawn at.
                let primary = !plan.uniform && line.id == activeFactorID
                for name in names(of: line, painted: plate, armed: armedLevelID) {
                    labels.append(FittedLabel(
                        text: name, available: available,
                        size: primary ? plan.primarySize : plan.secondarySize,
                        weight: primary ? .semibold : .regular
                    ))
                }
            }
        }
        return labels
    }

    /// The distinct condition names of `factor` that appear somewhere on the plate,
    /// plus the armed one — a paint stroke puts that down before the model has it, and
    /// the size must not jump when the stroke lands.
    private func names(of factor: Factor, painted plate: Plate, armed: UUID?) -> [String] {
        var used = Set(plate.assignments[factor.id.uuidString]?.compactMap { $0 } ?? [])
        if let armed, factor.levels.contains(where: { $0.id == armed }) {
            used.insert(armed.uuidString)
        }
        return factor.levels.filter { used.contains($0.id.uuidString) }.map(\.name)
    }

    /// Every canvas font routes through the shared factory, so the family setting
    /// cannot miss a label — see Preferences.canvasFont.
    private func canvasFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        Preferences.shared.canvasFont(ofSize: size, weight: weight)
    }

    /// Which stacked line carries the headline tier — bigger and semibold. It follows
    /// the factor being *painted*, not document order, so the well itself says what a
    /// click would change. nil leaves every line equal: Overview ranks none of them,
    /// and an active factor that overflowed to the colour stripe has no line to mark —
    /// emphasising line 1 instead would claim the wrong factor was armed.
    static func primarySlot(lines: [Factor], activeFactorID: UUID?, uniform: Bool) -> Int? {
        guard !uniform, let activeFactorID else { return nil }
        return lines.firstIndex { $0.id == activeFactorID }
    }

    /// One text line per factor, in document order, each headed by a block of the
    /// level's colour. Slots for unassigned factors are reserved rather than collapsed,
    /// so line 2 always means the same factor in every well.
    private func drawFactorStack(
        in bodyRect: CGRect, factors: [Factor], plate: Plate, index: Int,
        plan: LabelPlan, activeFactorID: UUID?, reservedBottom: CGFloat,
        neutralInk: NSColor, bandOpacity: CGFloat, fit: CGFloat,
        blockScale: (width: CGFloat, height: CGFloat)
    ) {
        let lineCount = min(plan.lineCount, factors.count)
        guard lineCount >= 1 else { return }
        let primarySlot = Self.primarySlot(
            lines: Array(factors.prefix(lineCount)),
            activeFactorID: activeFactorID, uniform: plan.uniform
        )

        // The stack sits on the neutral tile in every mode, so it takes the tile's ink
        // at full strength: reading it is the whole job, and the only colour on a line
        // is its rail — plus, for the factor being painted, the band behind it.
        let textColor = neutralInk
        let rail = Self.stackRail(bodyWidth: bodyRect.width, widthScale: blockScale.width)
        let textStart = bodyRect.minX + rail.inset + rail.activeWidth + rail.gap
        // Centre the stack in whatever the stripe left behind.
        let usable = bodyRect.height - reservedBottom
        let stackHeight = plan.stackHeight(lines: lineCount, primary: primarySlot != nil)
        var y = bodyRect.minY + (usable - stackHeight) / 2

        for slot in 0..<lineCount {
            let factor = factors[slot]
            let isPrimary = slot == primarySlot
            let height = isPrimary ? plan.primaryHeight : plan.secondaryHeight
            // Only the active factor is being painted, so only it previews a drag.
            let level = factor.id == activeFactorID
                ? resolvedLevel(index: index, plate: plate, factor: factor)
                : factor.level(id: plate.levelID(factor: factor.id, well: index))
            let colour = level.flatMap { NSColor(hex: $0.colorHex) }

            // A band behind the whole active line, in that line's own colour: with the
            // well no longer flooded, this is where it shows the value being painted.
            // A tint by default rather than the solid colour, so the rail keeps its
            // full colour against it and the ink stays legible on it; how strong is a
            // setting. A well with no value for the active factor keeps a faint band
            // in the ink instead — scaled with the same setting, so it can never be
            // the louder of the two — and the line a click would change still stands
            // out from the others.
            if isPrimary, height >= 8 {
                let bleed = min(1.5, plan.gap * 0.6)
                let band = CGRect(
                    x: bodyRect.minX + 1, y: y - bleed,
                    width: bodyRect.width - 2, height: height + bleed * 2
                )
                (colour?.withAlphaComponent(bandOpacity)
                    ?? textColor.withAlphaComponent(min(0.3, bandOpacity * 0.36))).setFill()
                NSBezierPath(
                    roundedRect: band, xRadius: min(3, band.height / 3), yRadius: min(3, band.height / 3)
                ).fill()
            }

            // A block rather than a capsule — a swatch of the colour, not a tick mark —
            // so the other factors' values can be read at a glance. It keeps one shape
            // on every line: 82% of the line's height by default, and as wide as that
            // makes it, so the headline's block is larger rather than stretched taller.
            // It never outgrows `activeWidth`, the slot the text column was measured
            // against. Length and height are each a setting on top of that, and the
            // block stays centred on its line whatever height it is given.
            let railWidth = rail.width * (height / plan.secondaryHeight)
            let railHeight = min(height, height * Self.stackBlockHeightShare * blockScale.height)
            let railRect = CGRect(
                x: bodyRect.minX + rail.inset, y: y + (height - railHeight) / 2,
                width: railWidth, height: railHeight
            )
            // Off the shorter side: a long, low bar rounded by its length is a capsule.
            let radius = min(2.5, min(railWidth, railHeight) * 0.22)
            if let level, let colour {
                colour.setFill()
                NSBezierPath(roundedRect: railRect, xRadius: radius, yRadius: radius).fill()
                // A wall in the ink keeps a pale rail from dissolving into the tile, and
                // a heavier one on the active line pins it to its band. Inset by half
                // the width so the stroke stays inside the rail instead of swelling it,
                // and taken as a fraction of the rail's own width — a flat value ate
                // the colour at small well sizes.
                let wall: CGFloat = isPrimary ? max(0.9, min(railWidth, railHeight) * 0.12) : 0.75
                textColor.withAlphaComponent(isPrimary ? 1 : 0.7).setStroke()
                let outline = NSBezierPath(
                    roundedRect: railRect.insetBy(dx: wall / 2, dy: wall / 2),
                    xRadius: radius, yRadius: radius
                )
                outline.lineWidth = wall
                outline.stroke()

                let textRect = CGRect(
                    x: textStart, y: y,
                    width: Self.stackTextWidth(bodyWidth: bodyRect.width, widthScale: blockScale.width),
                    height: height
                )
                let size = (isPrimary ? plan.primarySize : plan.secondarySize) * fit
                drawFitted(
                    level.name, in: textRect, maxFontSize: size, minFontSize: size * 0.85,
                    weight: isPrimary ? .semibold : .regular, alignment: .left,
                    color: isPrimary || plan.uniform
                        ? textColor : textColor.withAlphaComponent(0.86)
                )
            } else {
                textColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: railRect, xRadius: radius, yRadius: radius).fill()
            }
            y += height + plan.gap
        }
    }

    /// Names the stack order beneath the plate. Drawn in exports too — an exported
    /// image has no sidebar, so it is the only way to know what line 2 means.
    /// It lives in the padding the geometry always leaves below the plate, so it never
    /// competes with the wells for space.
    /// A line round every run of identical wells — the outline of the run itself, so an
    /// L-shaped block gets an L, and the same condition in two corners gets two outlines
    /// rather than one rectangle swallowing everything between them.
    ///
    /// Walked in *display* space so the outline is correct on a turned plate without
    /// this code knowing the plate is turned: a rotation carries adjacency with it, and
    /// `modelPosition` is the only thing here that crosses between the two spaces.
    /// The outline as line segments, so the rule can be checked without a screenshot.
    /// One segment per cell edge, deliberately unmerged: a run of them draws as one
    /// straight line anyway, and counting them is what makes the rule testable.
    static func groupOutlineSegments(
        geo: PlateGeometry, blocks: [Int?], format: PlateFormat
    ) -> [(CGPoint, CGPoint)] {
        func block(displayRow: Int, displayCol: Int) -> Int? {
            guard displayRow >= 0, displayRow < geo.displayRows,
                  displayCol >= 0, displayCol < geo.displayCols
            else { return nil }
            let pos = geo.modelPosition(displayRow: displayRow, displayCol: displayCol)
            guard format.contains(row: pos.row, col: pos.col) else { return nil }
            let index = format.index(row: pos.row, col: pos.col)
            return blocks.indices.contains(index) ? blocks[index] : nil
        }

        var segments: [(CGPoint, CGPoint)] = []
        for row in 0..<geo.displayRows {
            for col in 0..<geo.displayCols {
                let here = block(displayRow: row, displayCol: col)
                let pos = geo.modelPosition(displayRow: row, displayCol: col)
                guard format.contains(row: pos.row, col: pos.col) else { continue }
                let rect = geo.cellRect(row: pos.row, col: pos.col)

                // Each shared edge is taken once, by the cell above or to the left of
                // it; the two leading edges of the grid have no such cell, so they are
                // taken here. Drawing an edge twice would darken every internal
                // boundary against the outer ones.
                if row == 0, here != nil {
                    segments.append((CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)))
                }
                if col == 0, here != nil {
                    segments.append((CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY)))
                }
                let below = block(displayRow: row + 1, displayCol: col)
                if here != below, here != nil || below != nil {
                    segments.append((CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)))
                }
                let right = block(displayRow: row, displayCol: col + 1)
                if here != right, here != nil || right != nil {
                    segments.append((CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)))
                }
            }
        }
        return segments
    }

    private func drawGroupOutlines(
        geo: PlateGeometry, plate: Plate, factors: [Factor], basis: WellGrouping.Basis
    ) {
        let blocks = WellGrouping.blocks(plate: plate, factors: factors, basis: basis)
        let segments = Self.groupOutlineSegments(geo: geo, blocks: blocks, format: plate.format)
        guard !segments.isEmpty else { return }

        let path = NSBezierPath()
        for (from, to) in segments {
            path.move(to: from)
            path.line(to: to)
        }

        // Ink rather than accent: the accent colour is the selection's, and a block
        // outline that borrowed it would read as "these wells are selected". Both the
        // colour and the weight are Settings choices — this is taste about how a plate
        // should look, so it belongs there rather than in the document.
        Preferences.shared.groupOutlineColor(exportMode: exportMode).setStroke()
        path.lineWidth = Preferences.shared.groupOutlineWidth(cell: geo.cell)
        path.lineCapStyle = .square
        path.stroke()
    }

    private func drawLineKey(stacked: [Factor], striped: Int, hidden: Int, geo: PlateGeometry) {
        // Spans the canvas rather than the plate: a small plate sits centred, and
        // anchoring the key to it would throw away the whole left margin and clip
        // long factor names off the right edge.
        let strip = CGRect(
            x: 4, y: max(geo.frameRect.maxY, bounds.maxY - 14),
            width: max(0, bounds.width - 8),
            height: min(14, max(0, bounds.maxY - geo.frameRect.maxY))
        )
        guard strip.height >= 8, strip.width > 24 else { return }

        var parts = stacked.enumerated().map { "\($0.offset + 1) \($0.element.name)" }
        // Say what actually happened to the factors that did not get a line.
        if striped > 0 { parts.append("+\(striped) in stripe") }
        if hidden > 0 { parts.append("+\(hidden) not shown") }
        let text = "Well lines:  " + parts.joined(separator: "   ")

        // Shrink-then-ellipsise, so a long name is never cut mid-glyph — the key is the
        // only legend an exported PNG or PDF carries.
        drawFitted(
            text, in: strip, maxFontSize: 9.5, minFontSize: 7,
            weight: .medium, alignment: .left, color: NSColor.secondaryLabelColor
        )
    }

    private func wellPath(in rect: CGRect, round: Bool) -> NSBezierPath {
        round && rect.width >= 8
            ? NSBezierPath(ovalIn: rect)
            : NSBezierPath(roundedRect: rect, xRadius: min(2.5, rect.width / 5), yRadius: min(2.5, rect.width / 5))
    }

    private func bandBelow(cellRect: CGRect, height: CGFloat) -> CGRect {
        let inset: CGFloat = 2
        return CGRect(
            x: cellRect.minX + inset,
            y: cellRect.maxY - height - inset,
            width: max(1, cellRect.width - inset * 2),
            height: height
        )
    }

    private func drawSecondaryStripe(
        band: CGRect, secondary: [Factor], plate: Plate, index: Int, activeFactorID: UUID?
    ) {
        guard !secondary.isEmpty, band.width > 0 else { return }
        let segmentWidth = band.width / CGFloat(secondary.count)
        for (i, factor) in secondary.enumerated() {
            let segment = CGRect(
                x: band.minX + CGFloat(i) * segmentWidth,
                y: band.minY,
                width: segmentWidth - (secondary.count > 1 ? 0.75 : 0),
                height: band.height
            )
            // The active factor can end up in the stripe too, and it must still
            // preview a drag like every other representation of it.
            let level = factor.id == activeFactorID
                ? resolvedLevel(index: index, plate: plate, factor: factor)
                : factor.level(id: plate.levelID(factor: factor.id, well: index))
            guard let level, let color = NSColor(hex: level.colorHex) else { continue }
            color.setFill()
            NSBezierPath(roundedRect: segment, xRadius: 1, yRadius: 1).fill()
        }
    }

    /// The letters and numbers follow the grid round: transposed, the letters run along
    /// the top and the numbers down the side. Each strip is drawn from the model axis it
    /// is labelling, so a highlighted header always means the same wells are selected.
    private func drawHeaders(geo: PlateGeometry, selectedRows: Set<Int>, selectedCols: Set<Int>) {
        let accent = NSColor.controlAccentColor
        let headerFontSize = max(7, min(min(geo.headerH * 0.55, geo.cell * 0.42), 12))
            * CGFloat(Preferences.shared.canvasFontScale)
        let font = canvasFont(ofSize: headerFontSize, weight: .semibold)
        // Numbers get thinned out on a dense plate; letters are short enough to keep.
        let numberStride = geo.cell >= 15 ? 1 : (geo.cell >= 10 ? 2 : 4)

        func draw(_ label: String, in rect: CGRect, highlighted: Bool) {
            if highlighted && !exportMode {
                accent.withAlphaComponent(0.16).setFill()
                NSBezierPath(rect: rect).fill()
            }
            guard !label.isEmpty else { return }
            drawCentered(
                label, in: rect, font: font,
                color: highlighted && !exportMode ? accent : NSColor.secondaryLabelColor
            )
        }

        // Each strip is labelled from the model axis its cells belong to, which is what
        // makes the letters run backwards after a half turn — as they do on a plate you
        // have turned to face away from you.
        func label(_ well: WellPos, axisIsRow: Bool, at index: Int) -> (String, Bool) {
            if axisIsRow {
                return (WellNaming.rowLabel(well.row), selectedRows.contains(well.row))
            }
            let shown = index % numberStride == 0 || index == 0 ? "\(well.col + 1)" : ""
            return (shown, selectedCols.contains(well.col))
        }

        for index in 0..<geo.displayCols {
            let well = geo.modelPosition(displayRow: 0, displayCol: index)
            let (text, on) = label(well, axisIsRow: geo.isTurnedOnEnd, at: index)
            draw(text, in: geo.horizontalHeaderRect(index), highlighted: on)
        }

        for index in 0..<geo.displayRows {
            let well = geo.modelPosition(displayRow: index, displayCol: 0)
            let (text, on) = label(well, axisIsRow: !geo.isTurnedOnEnd, at: index)
            draw(text, in: geo.verticalHeaderRect(index), highlighted: on)
        }

        drawOrientationCorner(geo: geo)
    }

    /// The corner where the letters and numbers meet. A click turns the plate a quarter
    /// clockwise and the next click turns it back. It carries a glyph because an
    /// invisible click target is no control at all, and it replaces
    /// select-all-on-corner, which lives on ⌘A and in the Plate menu.
    private func drawOrientationCorner(geo: PlateGeometry) {
        guard !exportMode else { return }
        let rect = geo.cornerRect
        guard rect.width >= 16, rect.height >= 12 else { return }

        if hoveringCorner {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3).fill()
        }

        let size = min(rect.width - 8, rect.height - 6, 14)
        guard size >= 8 else { return }
        let ink = (hoveringCorner ? NSColor.controlAccentColor : NSColor.secondaryLabelColor)
            .withAlphaComponent(hoveringCorner ? 1 : 0.8)

        // The arrow shows the turn the *next* click will make, so it reverses once the
        // plate is already turned. A control that looks the same in both states is
        // telling you what it is rather than what it will do.
        drawTurnArrow(
            centre: CGPoint(x: rect.midX, y: rect.midY), radius: size / 2,
            clockwise: geo.quarterTurns == 0, ink: ink
        )
    }

    /// An open arc with an arrowhead on the leading end. Drawn point by point rather
    /// than with `appendArc`, whose sense of "clockwise" is the opposite of what is seen
    /// in a flipped view — deriving the arrowhead from the same parameter as the arc is
    /// what keeps the two from disagreeing.
    private func drawTurnArrow(centre: CGPoint, radius: CGFloat, clockwise: Bool, ink: NSColor) {
        guard radius >= 3.5 else { return }
        ink.setStroke()
        ink.setFill()

        // The view is flipped, so a rising angle sweeps clockwise on screen.
        let sweep: CGFloat = 260
        let from: CGFloat = clockwise ? 150 : 30
        let to = clockwise ? from + sweep : from - sweep

        let arc = NSBezierPath()
        let steps = 40
        for step in 0...steps {
            let degrees = from + (to - from) * CGFloat(step) / CGFloat(steps)
            let radians = degrees * .pi / 180
            let point = CGPoint(x: centre.x + radius * cos(radians),
                                y: centre.y + radius * sin(radians))
            step == 0 ? arc.move(to: point) : arc.line(to: point)
        }
        arc.lineWidth = max(1.2, radius * 0.22)
        arc.lineCapStyle = .round
        arc.stroke()

        let endRadians = to * .pi / 180
        let tip = CGPoint(x: centre.x + radius * cos(endRadians),
                          y: centre.y + radius * sin(endRadians))
        // Tangent in the direction of travel; the normal is just it turned a right angle.
        let way: CGFloat = clockwise ? 1 : -1
        let tangent = CGPoint(x: -sin(endRadians) * way, y: cos(endRadians) * way)
        let normal = CGPoint(x: -tangent.y, y: tangent.x)
        let reach = max(2.8, radius * 0.85)
        let half = max(2, radius * 0.55)

        let head = NSBezierPath()
        head.move(to: CGPoint(x: tip.x + tangent.x * reach, y: tip.y + tangent.y * reach))
        head.line(to: CGPoint(x: tip.x + normal.x * half, y: tip.y + normal.y * half))
        head.line(to: CGPoint(x: tip.x - normal.x * half, y: tip.y - normal.y * half))
        head.close()
        head.fill()
    }

    /// Shrinks a condition name to fit its well rather than clipping it, so
    /// "Cmpd A" and "Cmpd B" stay distinguishable. Truncates only as a last resort.
    private func drawFitted(
        _ text: String, in rect: CGRect, maxFontSize: CGFloat, minFontSize: CGFloat? = nil,
        weight: NSFont.Weight = .medium, alignment: NSTextAlignment = .center, color: NSColor
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, rect.width > 8 else { return }
        let available = Self.fittedWidth(of: rect.width, alignment: alignment)
        guard available > 2 else { return }
        let floorSize = Self.fittedFloor(maxFontSize: maxFontSize, minFontSize: minFontSize)

        let measured = (trimmed as NSString)
            .size(withAttributes: [.font: canvasFont(ofSize: maxFontSize, weight: weight)]).width
        guard measured > 0 else { return }

        // Width is close to linear in point size, so the ratio gets us nearly there;
        // hinting makes it inexact, so close the gap before giving up and trimming.
        var size = max(floorSize, min(maxFontSize, maxFontSize * available / measured))
        var font = canvasFont(ofSize: size, weight: weight)
        var width = (trimmed as NSString).size(withAttributes: [.font: font]).width
        var attempts = 0
        while width > available, size > floorSize, attempts < 8 {
            size = max(floorSize, size * min(0.97, available / width))
            font = canvasFont(ofSize: size, weight: weight)
            width = (trimmed as NSString).size(withAttributes: [.font: font]).width
            attempts += 1
        }

        var shown = trimmed
        if width > available {
            let perCharacter = width / CGFloat(trimmed.count)
            let fits = max(1, Int(available / perCharacter))
            shown = fits < trimmed.count ? String(trimmed.prefix(max(1, fits - 1))) + "…" : trimmed
        }
        draw(shown, in: rect, font: font, color: color, alignment: alignment)
    }

    private func draw(
        _ text: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment
    ) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let x = alignment == .center ? rect.midX - size.width / 2 : rect.minX
        string.draw(
            at: CGPoint(x: x, y: rect.midY - size.height / 2), withAttributes: attributes
        )
    }

    /// Draws at a point rather than into a rect: rect drawing word-wraps, which
    /// would silently swallow the second half of names like "Cmpd A".
    private func drawCentered(_ text: String, in rect: CGRect, font: NSFont, color: NSColor) {
        draw(text, in: rect, font: font, color: color, alignment: .center)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let editor, shownPlate != nil else { return }
        // On the board, a press anywhere on a card brings it forward at once — including
        // presses that land on the plate itself rather than on the card's chrome.
        (superview as? CanvasCardView)?.raiseNow()
        // A click on a read-only card means "edit that one instead" and nothing else.
        // Not also a select, and certainly not a paint: an armed brush plus a card click
        // is how a whole plate would get overwritten by one stray press.
        guard isEditable else {
            if case .card(let id) = role { editor.activatePlate(id) }
            return
        }
        window?.makeFirstResponder(self)

        let geo = geometry
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let extend = modifiers.contains(.shift)
        freeformBrush = modifiers.contains(.command)
        pendingIsErase = modifiers.contains(.option)
        pendingLevelID = editor.armedLevelID
        isPaintingDrag = pendingIsErase || pendingLevelID != nil
        pendingWells.removeAll()

        switch geo.hit(point) {
        case .well(let pos):
            dragKind = .wells
            if freeformBrush {
                // ⌘-click toggles the well in and out of the selection, the macOS
                // standard. The mouse may still turn out to be dragging — the brush
                // when a level is armed, an added rectangle when nothing is — and
                // both replay from the selection as it stood before the toggle.
                dragAnchorWell = pos
                customDragBase = editor.selectionAsPositions
                editor.toggleWell(pos)
            } else if extend, let anchor = editor.selection?.anchor ?? editor.customFocus {
                dragAnchorWell = anchor
                editor.select(WellRange(anchor: anchor, focus: pos))
            } else {
                dragAnchorWell = pos
                editor.select(WellRange(single: pos))
            }
        case .columnHeader(let col):
            dragKind = .columns
            dragAnchorLine = extend ? (editor.selection?.anchor.col ?? col) : col
            editor.select(WellRange(
                anchor: WellPos(row: 0, col: dragAnchorLine),
                focus: WellPos(row: geo.format.rows - 1, col: col)
            ))
        case .rowHeader(let row):
            dragKind = .rows
            dragAnchorLine = extend ? (editor.selection?.anchor.row ?? row) : row
            editor.select(WellRange(
                anchor: WellPos(row: dragAnchorLine, col: 0),
                focus: WellPos(row: row, col: geo.format.cols - 1)
            ))
        case .corner:
            // The corner flips the plate between upright and on its side. It used to
            // select every well; that moved to ⌘A and the Plate menu, which is where
            // anyone looked for it anyway.
            dragKind = .none
            isPaintingDrag = false
            editor.rotatePlate()
            needsDisplay = true
            return
        case .outside:
            // Clicking off the plate deselects, the way clicking empty canvas does
            // in any drawing app.
            dragKind = .none
            isPaintingDrag = false
            editor.clearSelectionMarquee()
            needsDisplay = true
            return
        }

        refreshPending(geo: geo)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditable else { return }
        guard dragKind != .none, let editor else { return }
        let geo = geometry
        let point = convert(event.locationInWindow, from: nil)

        switch dragKind {
        case .wells:
            let pos = geo.nearestWell(point)
            if freeformBrush {
                if isPaintingDrag {
                    editor.select(WellRange(anchor: dragAnchorWell ?? pos, focus: pos))
                    pendingWells.insert(geo.format.index(row: pos.row, col: pos.col))
                } else if let base = customDragBase {
                    // ⌘-drag with nothing armed adds a rectangle to the selection.
                    editor.addToSelection(base: base, rect: WellRange(anchor: dragAnchorWell ?? pos, focus: pos))
                }
                needsDisplay = true
                return
            }
            editor.select(WellRange(anchor: dragAnchorWell ?? pos, focus: pos))
        case .columns:
            let col = geo.nearestColumn(point)
            editor.select(WellRange(
                anchor: WellPos(row: 0, col: dragAnchorLine),
                focus: WellPos(row: geo.format.rows - 1, col: col)
            ))
        case .rows:
            let row = geo.nearestRow(point)
            editor.select(WellRange(
                anchor: WellPos(row: dragAnchorLine, col: 0),
                focus: WellPos(row: row, col: geo.format.cols - 1)
            ))
        case .none:
            return
        }

        refreshPending(geo: geo)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEditable else { return }
        defer {
            dragKind = .none
            isPaintingDrag = false
            pendingWells.removeAll()
            freeformBrush = false
            customDragBase = nil
            needsDisplay = true
        }
        guard isPaintingDrag, !pendingWells.isEmpty else { return }
        commitPaint(wells: Array(pendingWells))
    }

    private func refreshPending(geo: PlateGeometry) {
        guard isPaintingDrag, let editor else { return }
        if freeformBrush, dragKind == .wells { return }
        pendingWells = Set(editor.selectedWells)
    }

    private func commitPaint(wells: [Int]) {
        guard let editor else { return }
        editor.paint(
            wells: wells,
            level: pendingIsErase ? nil : pendingLevelID,
            actionName: pendingIsErase ? "Erase Wells" : "Paint Wells"
        )
    }

    override func mouseMoved(with event: NSEvent) {
        // Only the plate being edited owns the hover. Without this, moving the mouse over
        // a read-only card would draw a hover ring on the *active* plate at the same row
        // and column — a plausible-looking well, which is the worst kind of wrong.
        guard let editor, isEditable else { return }
        let geo = geometry
        let point = convert(event.locationInWindow, from: nil)
        let hit = geo.hit(point)
        let next: WellPos?
        if case .well(let pos) = hit { next = pos } else { next = nil }
        let overCorner = hit == .corner
        if next != editor.hovered || overCorner != hoveringCorner {
            editor.hovered = next
            hoveringCorner = overCorner
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard isEditable else { return }
        if editor?.hovered != nil || hoveringCorner {
            editor?.hovered = nil
            hoveringCorner = false
            needsDisplay = true
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let editor, isEditable else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command) else { return super.keyDown(with: event) }
        let shift = modifiers.contains(.shift)

        guard let characters = event.charactersIgnoringModifiers,
              let scalar = characters.unicodeScalars.first
        else { return super.keyDown(with: event) }

        switch Int(scalar.value) {
        case NSUpArrowFunctionKey:
            editor.moveCursor(dRow: -1, dCol: 0, extend: shift); return
        case NSDownArrowFunctionKey:
            editor.moveCursor(dRow: 1, dCol: 0, extend: shift); return
        case NSLeftArrowFunctionKey:
            editor.moveCursor(dRow: 0, dCol: -1, extend: shift); return
        case NSDeleteFunctionKey, 0x7F, 0x08:
            shift ? editor.clearSelectionAllFactors() : editor.clearSelection(); return
        case NSRightArrowFunctionKey:
            editor.moveCursor(dRow: 0, dCol: 1, extend: shift); return
        case 27:
            editor.disarmLevel(); return
        case 13, 3:
            editor.paintSelection(); return
        default:
            break
        }

        switch characters.lowercased() {
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            editor.armLevel(atIndex: Int(characters)! - 1)
        case "0":
            editor.armLevel(atIndex: 9)
        case "[":
            editor.cycleLevel(by: -1)
        case "]":
            editor.cycleLevel(by: 1)
        case "f", " ":
            editor.paintSelection()
        case "\t":
            editor.cycleFactor(by: shift ? -1 : 1)
        default:
            super.keyDown(with: event)
        }
    }

    /// Views get first crack at key equivalents, so guard on focus to leave
    /// ⌘C/⌘V alone while a sidebar text field is being edited.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let editor, isEditable else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command || modifiers == [.command, .shift]
                || modifiers == [.command, .option]
        else {
            return super.performKeyEquivalent(with: event)
        }
        let option = modifiers.contains(.option)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            // ⌥⌘C is the whole well — every factor — where ⌘C is the active factor as
            // cells for Excel.
            option
                ? editor.copyWells()
                : editor.copySelection(includeHeaders: modifiers.contains(.shift))
            return true
        case "x":
            guard !option else { return super.performKeyEquivalent(with: event) }
            editor.cutSelection(); return true
        case "v":
            option ? editor.pasteWells() : editor.pasteFromPasteboard(); return true
        case "a":
            guard !option else { return super.performKeyEquivalent(with: event) }
            editor.selectAllWells(); return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { editor?.copySelection() }
    @objc func cut(_ sender: Any?) { editor?.cutSelection() }
    @objc func paste(_ sender: Any?) { editor?.pasteFromPasteboard() }
    @objc func delete(_ sender: Any?) { editor?.clearSelection() }
    override func selectAll(_ sender: Any?) { editor?.selectAllWells() }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)),
             #selector(delete(_:)), #selector(selectAll(_:)):
            return editor != nil
        default:
            return true
        }
    }

    // MARK: - Image export

    /// Exposes the view's own geometry so tests can click exactly where it draws.
    func cellCentreForTesting(row: Int, col: Int) -> CGPoint {
        let rect = geometry.cellRect(row: row, col: col)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func pngData(includingGroupOutlines: Bool = true) -> Data? {
        guard bounds.width > 4, bounds.height > 4,
              let rep = bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        exportMode = true
        exportIncludesGroups = includingGroupOutlines
        cacheDisplay(in: bounds, to: rep)
        exportMode = false
        exportIncludesGroups = true
        return rep.representation(using: .png, properties: [:])
    }

    func pdfData(includingGroupOutlines: Bool = true) -> Data {
        exportMode = true
        exportIncludesGroups = includingGroupOutlines
        defer {
            exportMode = false
            exportIncludesGroups = true
        }
        return dataWithPDF(inside: bounds)
    }

    // MARK: - Printing

    /// Prints the plate as currently displayed. Uses the unmagnified document bounds,
    /// so the whole plate is printed no matter how far the user has zoomed in.
    func printPlate(jobName: String) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = bounds.width >= bounds.height ? .landscape : .portrait
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.topMargin = 24
        info.bottomMargin = 24
        info.leftMargin = 24
        info.rightMargin = 24

        exportMode = true
        defer { exportMode = false }

        let operation = NSPrintOperation(view: self, printInfo: info)
        operation.jobTitle = jobName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }
}

// MARK: - SwiftUI bridge

/// Hosts the plate in a scroll view so pinch-to-zoom works. At magnification 1 the
/// document view exactly fills the clip view, which is why zooming out never goes
/// past "whole plate in view".
struct PlateCanvas: NSViewRepresentable {
    @ObservedObject var editor: PlateEditor

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = PlateCanvasView()
        canvas.attach(editor: editor)
        // Sized by PlateScrollView.tile() rather than autoresizing, so the rule is in
        // one place and holds while magnified.
        canvas.autoresizingMask = []

        let scroll = PlateScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 10
        canvas.frame = scroll.contentView.bounds
        scroll.bind(to: editor)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let scroll = scrollView as? PlateScrollView,
              let canvas = scroll.documentView as? PlateCanvasView else { return }
        if canvas.editor !== editor { canvas.attach(editor: editor) }
        scroll.bind(to: editor)
        canvas.needsDisplay = true
    }
}

/// Lets the editor drive zoom from menu commands as well as the trackpad, and reports
/// the trackpad's changes back so the status bar can show them.
final class PlateScrollView: NSScrollView, PlateZoomController {
    private weak var editor: PlateEditor?
    private var magnifyObserver: NSObjectProtocol?

    func bind(to editor: PlateEditor) {
        self.editor = editor
        editor.zoomController = self
        if magnifyObserver == nil {
            magnifyObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.editor?.noteZoomChanged(self.magnification)
            }
        }
        editor.noteZoomChanged(magnification)
    }

    /// Applied synchronously rather than through `animator()`, so the magnification the
    /// editor publishes is always the magnification the scroll view actually has.
    func setZoom(_ value: CGFloat) {
        let clamped = min(max(value, minMagnification), maxMagnification)
        // Zoom about the middle of what is on screen, not the document origin.
        let centre = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(clamped, centeredAt: centre)
        editor?.noteZoomChanged(magnification)
    }

    /// Pins the document to the *unmagnified* viewport size. This is the invariant the
    /// whole zoom model rests on: at magnification 1 the plate exactly fits, and zooming
    /// in reveals part of that same layout rather than re-fitting a smaller plate.
    /// `contentView.frame` is used rather than `bounds`, because bounds shrinks with
    /// magnification and would feed the zoom back into the layout.
    override func tile() {
        super.tile()
        guard let document = documentView else { return }
        let target = contentView.frame.size
        if document.frame.size != target {
            document.setFrameSize(target)
        }
    }

    deinit {
        if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
    }
}

protocol PlateZoomController: AnyObject {
    func setZoom(_ value: CGFloat)
    /// The zoom that shows everything there is. The plate is pinned to its viewport, so
    /// for it "everything" is magnification 1; the board has to measure its cards.
    func fitContent()
    /// Below this, zooming out does nothing — which is how the status bar knows whether
    /// to keep offering it.
    var minimumZoom: CGFloat { get }
}

extension PlateZoomController {
    func fitContent() { setZoom(1) }
    var minimumZoom: CGFloat { 1 }
}

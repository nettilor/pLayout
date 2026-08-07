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
        let pad: CGFloat = 14
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

final class PlateCanvasView: NSView, NSUserInterfaceValidations {

    weak var editor: PlateEditor?

    private enum DragKind { case none, wells, columns, rows }
    private var dragKind: DragKind = .none
    private var dragAnchorWell: WellPos?
    private var dragAnchorLine = 0
    private var freeformBrush = false

    /// Wells the in-progress drag will write when the mouse comes up.
    private var pendingWells: Set<Int> = []
    private var pendingLevelID: UUID?
    private var pendingIsErase = false
    private var isPaintingDrag = false

    private var exportMode = false
    /// Drives the corner control's hover state; a click target with no feedback reads
    /// as decoration.
    private var hoveringCorner = false
    private var trackingArea: NSTrackingArea?
    private var cancellable: AnyCancellable?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(editor: PlateEditor) {
        self.editor = editor
        editor.canvas = self
        // Hopped through the main queue rather than the main *run loop*: run-loop
        // delivery is scheduled in the default mode only, so while the mouse is down
        // — exactly when a sidebar click happens — the redraw would wait for tracking
        // to finish. The hop itself is still needed because objectWillChange fires
        // before the value changes.
        cancellable = editor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if editor?.undoManager == nil { editor?.undoManager = window.undoManager }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder is NSWindow || self.window?.firstResponder == nil else { return }
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
        PlateGeometry(
            format: editor?.format ?? .well96, bounds: bounds,
            quarterTurns: editor?.quarterTurns ?? 0
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
        guard let editor, let plate = editor.plate else { return }
        let geo = geometry
        let format = plate.format
        let mode = editor.layout.wellLabelMode
        let textStyle = Preferences.shared.wellTextStyle
        let markerStyle = Preferences.shared.activeMarkerStyle
        // Overview has no factor being painted, so no factor colours the well. Read
        // from the mode rather than from `activeFactor` alone: that keeps the drawing
        // correct on its own terms, including when a test sets the mode directly.
        let factor = mode.isOverview ? nil : editor.activeFactor
        let selection = editor.selection?.clamped(to: format)

        (exportMode ? NSColor.white : NSColor.windowBackgroundColor).setFill()
        bounds.fill()

        NSColor.textBackgroundColor.setFill()
        NSBezierPath(roundedRect: geo.gridRect, xRadius: 3, yRadius: 3).fill()

        drawHeaders(geo: geo, selection: selection)

        let plan = labelPlan(cell: geo.cell, mode: mode, factorCount: editor.layout.factors.count)
        // Factors shown as text lines; anything left over may fall back to the colour stripe.
        let stacked = plan.lineCount >= 2 ? Array(editor.layout.factors.prefix(plan.lineCount)) : []
        let overflow = stacked.isEmpty ? [] : Array(editor.layout.factors.dropFirst(plan.lineCount))

        let showSingleText = mode.showsText && stacked.isEmpty && geo.cell >= 17
        // A well too small to stack still has to say something in Overview, so factor 1
        // takes the well's text and the rest drop to the stripe — the same shape the
        // other modes take, only without a factor having been chosen.
        let soloFactor = mode.isOverview && showSingleText ? editor.layout.factors.first : nil

        // Overview always shows the other factors — that is the whole mode — and the
        // toggle that would otherwise govern it is hidden while Overview is on.
        var secondary = (editor.showSecondaryFactors || mode.isOverview) ? editor.secondaryFactors : []
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

        let wellFontSize = max(7, min(geo.cell * 0.30, 13))
        let emptyFill = NSColor.quaternaryLabelColor.withAlphaComponent(exportMode ? 0.10 : 0.13)
        // Every Overview well gets this same tile, so it is pitched a little stronger
        // than the empty-well fill: it has to read as a surface, not as an absence.
        // It has no colour of its own to contrast against, so under "always white" it
        // is the tile that moves, not the ink — otherwise Overview is unreadable.
        let neutralFill = textStyle.prefersDarkNeutral
            ? NSColor(white: 0.32, alpha: 1)
            : NSColor.quaternaryLabelColor.withAlphaComponent(exportMode ? 0.14 : 0.18)
        let neutralInk = textStyle.neutralInk
        let hairline = NSColor.separatorColor.withAlphaComponent(0.6)
        let drawHairlines = geo.cell >= 4

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

                if let level, let color = NSColor(hex: level.colorHex) {
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
                    (mode.isOverview ? neutralFill : emptyFill).setFill()
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
                        onColour: level.flatMap { NSColor(hex: $0.colorHex) },
                        reservedBottom: stripeHeight,
                        style: textStyle, neutralInk: neutralInk, marker: markerStyle
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

        guard !exportMode else { return }

        let accent = NSColor.controlAccentColor
        if let selection {
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
    static func labelPlan(cell: CGFloat, mode: WellLabelMode, factorCount: Int) -> LabelPlan {
        let primary = max(7, min(cell * 0.30, 13))
        let secondary = max(6.5, primary * 0.80)
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

    /// Which stacked line carries the headline tier — bigger and semibold. It follows
    /// the factor being *painted*, not document order, so the well itself says what a
    /// click would change. nil leaves every line equal: Overview ranks none of them,
    /// and an active factor that overflowed to the colour stripe has no line to mark —
    /// emphasising line 1 instead would claim the wrong factor was armed.
    static func primarySlot(lines: [Factor], activeFactorID: UUID?, uniform: Bool) -> Int? {
        guard !uniform, let activeFactorID else { return nil }
        return lines.firstIndex { $0.id == activeFactorID }
    }

    /// One text line per factor, in document order, each headed by a colour rail.
    /// Slots for unassigned factors are reserved rather than collapsed, so line 2
    /// always means the same factor in every well.
    private func drawFactorStack(
        in bodyRect: CGRect, factors: [Factor], plate: Plate, index: Int,
        plan: LabelPlan, activeFactorID: UUID?, onColour: NSColor?, reservedBottom: CGFloat,
        style: WellTextStyle, neutralInk: NSColor, marker: ActiveMarkerStyle
    ) {
        let lineCount = min(plan.lineCount, factors.count)
        guard lineCount >= 1 else { return }
        let primarySlot = Self.primarySlot(
            lines: Array(factors.prefix(lineCount)),
            activeFactorID: activeFactorID, uniform: plan.uniform
        )

        // Overview puts the text on a neutral tile with nothing behind it to fight
        // with, and reading it is the whole job there, so it gets full strength.
        let textColor = onColour?.labelInk(style)
            ?? (plan.uniform ? neutralInk : neutralInk.withAlphaComponent(0.75))
        // Deliberately wider than a hairline: the rail is the only colour a stacked
        // well carries, and at 3pt it read as a tick mark rather than as the swatch
        // that ties the well back to the condition list.
        let railWidth = max(2.5, min(5.5, bodyRect.width * 0.09))
        // The active line's rail is wider as well as walled, and every rail is
        // left-aligned inside the wider one's slot, so the text still starts at one x
        // down the whole stack. A rail that grew rightwards would ripple into the text
        // and leave the column ragged.
        let activeRailWidth = railWidth * 1.45
        let inset = max(2.5, bodyRect.width * 0.055)
        let textGap = max(2, railWidth * 0.75)
        let textStart = bodyRect.minX + inset + activeRailWidth + textGap
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

            // A band behind the whole line, so what is being edited is legible from a
            // glance at the plate rather than from comparing two type sizes. Drawn in
            // the label colour, which means it lightens a dark well and darkens a pale
            // one without having to know which it is on.
            if isPrimary, height >= 8, bodyRect.width >= 24 {
                let bleed = min(1.5, plan.gap * 0.6)
                let band = CGRect(
                    x: bodyRect.minX + 1, y: y - bleed,
                    width: bodyRect.width - 2, height: height + bleed * 2
                )
                textColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(
                    roundedRect: band, xRadius: min(3, band.height / 3), yRadius: min(3, band.height / 3)
                ).fill()
            }

            let thisRail = isPrimary ? activeRailWidth : railWidth
            let railRect = CGRect(
                x: bodyRect.minX + inset, y: y + height * 0.14,
                width: thisRail, height: height * 0.72
            )
            let radius = thisRail / 2
            if let level, let colour = NSColor(hex: level.colorHex) {
                let capsule = NSBezierPath(roundedRect: railRect, xRadius: radius, yRadius: radius)
                // The well is already flooded with the active factor's colour — the fill
                // and this rail come from the same level — so a rail in that colour is
                // invisible no matter how thick a wall it is given: it reads as a hollow
                // ring, the letter O in front of the label. Where the two coincide the
                // rail becomes a solid contrasting marker instead. No colour is lost by
                // that; the colour is the entire well.
                // The active marker sits on a well already filled with its own colour, so
                // it is drawn solid and unwalled whichever style is chosen. A wall was
                // tried twice — matching the label, then contrasting with the fill — and
                // both times the ring plus a differently coloured middle read as the
                // letter **O** in front of the label at these sizes. Anything this small
                // has to be one shape in one colour.
                let isMarker = isPrimary && onColour?.hexString == colour.hexString
                if isMarker {
                    (marker == .deeperShade ? colour.contrastingShade : textColor).setFill()
                    capsule.fill()
                } else {
                    colour.setFill()
                    capsule.fill()
                    // A rail whose colour is close to the fill would otherwise disappear.
                    // Inset by half the width so a heavier stroke stays inside the capsule
                    // instead of swelling it, and taken as a *fraction* of its own rail —
                    // a flat value ate the colour core at small well sizes.
                    let wall: CGFloat = isPrimary ? max(0.9, thisRail * 0.19) : 0.75
                    textColor.withAlphaComponent(isPrimary ? 1 : 0.7).setStroke()
                    let outline = NSBezierPath(
                        roundedRect: railRect.insetBy(dx: wall / 2, dy: wall / 2),
                        xRadius: radius, yRadius: radius
                    )
                    outline.lineWidth = wall
                    outline.stroke()
                }

                let textRect = CGRect(
                    x: textStart, y: y,
                    width: bodyRect.maxX - inset - textStart, height: height
                )
                let size = isPrimary ? plan.primarySize : plan.secondarySize
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
    private func drawHeaders(geo: PlateGeometry, selection: WellRange?) {
        let accent = NSColor.controlAccentColor
        let headerFontSize = max(7, min(min(geo.headerH * 0.55, geo.cell * 0.42), 12))
        let font = NSFont.systemFont(ofSize: headerFontSize, weight: .semibold)
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
                return (WellNaming.rowLabel(well.row), selection?.containsRow(well.row) ?? false)
            }
            let shown = index % numberStride == 0 || index == 0 ? "\(well.col + 1)" : ""
            return (shown, selection?.containsCol(well.col) ?? false)
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
        let padding: CGFloat = alignment == .center ? max(2, rect.width * 0.12) : 1
        let available = rect.width - padding
        guard available > 2 else { return }
        // A floor per tier keeps an inactive label from shrinking past the active one
        // and inverting the visual hierarchy.
        let floorSize = max(6, min(minFontSize ?? 7, maxFontSize))

        let measured = (trimmed as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: maxFontSize, weight: weight)]).width
        guard measured > 0 else { return }

        // Width is close to linear in point size, so the ratio gets us nearly there;
        // hinting makes it inexact, so close the gap before giving up and trimming.
        var size = max(floorSize, min(maxFontSize, maxFontSize * available / measured))
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        var width = (trimmed as NSString).size(withAttributes: [.font: font]).width
        var attempts = 0
        while width > available, size > floorSize, attempts < 8 {
            size = max(floorSize, size * min(0.97, available / width))
            font = NSFont.systemFont(ofSize: size, weight: weight)
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
        guard let editor, editor.plate != nil else { return }
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
            if extend, let anchor = editor.selection?.anchor {
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
        guard dragKind != .none, let editor else { return }
        let geo = geometry
        let point = convert(event.locationInWindow, from: nil)

        switch dragKind {
        case .wells:
            let pos = geo.nearestWell(point)
            if freeformBrush {
                editor.select(WellRange(anchor: dragAnchorWell ?? pos, focus: pos))
                pendingWells.insert(geo.format.index(row: pos.row, col: pos.col))
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
        defer {
            dragKind = .none
            isPaintingDrag = false
            pendingWells.removeAll()
            freeformBrush = false
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
        guard let editor else { return }
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
        if editor?.hovered != nil || hoveringCorner {
            editor?.hovered = nil
            hoveringCorner = false
            needsDisplay = true
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let editor else { return super.keyDown(with: event) }
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
        guard window?.firstResponder === self, let editor else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command || modifiers == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            editor.copySelection(includeHeaders: modifiers.contains(.shift)); return true
        case "x":
            editor.cutSelection(); return true
        case "v":
            editor.pasteFromPasteboard(); return true
        case "a":
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

    func pngData() -> Data? {
        guard bounds.width > 4, bounds.height > 4,
              let rep = bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        exportMode = true
        cacheDisplay(in: bounds, to: rep)
        exportMode = false
        return rep.representation(using: .png, properties: [:])
    }

    func pdfData() -> Data {
        exportMode = true
        defer { exportMode = false }
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
}

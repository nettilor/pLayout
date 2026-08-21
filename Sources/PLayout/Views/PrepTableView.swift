import AppKit

/// The prep sheet as a drawn table.
///
/// AppKit rather than SwiftUI, and one `draw(_:)` for all three destinations — the
/// window, the printer and the offscreen render a test can assert on. HANDOFF §1: a
/// SwiftUI `List`, grouped `Form` or `ScrollView` comes back from `ImageRenderer` as the
/// yellow prohibited placeholder, so a SwiftUI table could be neither printed nor tested,
/// and two implementations of one table would drift the first time a column moved.
///
/// Custom drawing rather than `NSTableView`: this is a laid-out document with per-compound
/// headings and a warnings block, not a data grid.
final class PrepTableView: NSView {

    var plan: DilutionPlan? {
        didSet {
            guard plan != oldValue else { return }
            relayout()
        }
    }

    /// Draws as light artwork whatever the window is doing — set while printing and
    /// rendering, exactly as the plate canvas does.
    private var exportMode = false

    override var isFlipped: Bool { true }

    // MARK: - Rows

    private enum Row {
        case title(String)
        case setupLine(String)
        case compoundHeading(name: String, colour: NSColor?, detail: String)
        case columnHeader
        case tube(DilutionPlan.Step, isVehicle: Bool, flagged: Bool)
        case spacer
        case warningsHeading
        case warning(PrepWarning)
    }

    private struct LaidOutRow {
        var row: Row
        var y: CGFloat
        var height: CGFloat
    }

    private var rows: [LaidOutRow] = []
    private var laidOutWidth: CGFloat = 0

    private let inset: CGFloat = 16
    private let columnWeights: [CGFloat] = [0.13, 0.14, 0.08, 0.15, 0.13, 0.16, 0.13]
    private let columnTitles = ["Dose", "In tube", "Wells", "From", "Take", "+ Diluent", "= Make"]

    private var titleFont: NSFont { .systemFont(ofSize: 15, weight: .semibold) }
    private var headingFont: NSFont { .systemFont(ofSize: 12, weight: .semibold) }
    private var bodyFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
    private var noteFont: NSFont { .systemFont(ofSize: 10, weight: .regular) }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - laidOutWidth) > 0.5 { relayout() }
    }

    /// Takes the width of whatever is showing it and grows to whatever height that needs.
    ///
    /// A scroll view does not resize its document view, so without this the table keeps
    /// whatever width it was built with and the right-hand columns sit outside the
    /// window — which is exactly what happened the first time.
    func fitWidth(to width: CGFloat) {
        guard width > 40 else { return }
        if abs(width - bounds.width) > 0.5 || abs(bounds.height - intrinsicContentSize.height) > 0.5 {
            setFrameSize(NSSize(width: width, height: intrinsicContentSize.height))
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewResized),
            name: NSView.frameDidChangeNotification, object: clip
        )
        fitWidth(to: clip.bounds.width)
    }

    @objc private func clipViewResized() {
        fitWidth(to: (superview as? NSClipView)?.bounds.width ?? bounds.width)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func relayout() {
        rows = []
        laidOutWidth = bounds.width
        defer {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
        guard let plan, !plan.isEmpty || !plan.allWarnings.isEmpty else { return }

        let textWidth = max(80, bounds.width - inset * 2)
        var y: CGFloat = inset

        func add(_ row: Row, _ height: CGFloat) {
            rows.append(LaidOutRow(row: row, y: y, height: height))
            y += height
        }

        add(.title("Pipetting prep"), 24)
        add(.setupLine(setupLine(plan)), 16)
        add(.setupLine(volumeLine(plan)), 16)
        add(.spacer, 8)

        for compound in plan.compounds where !compound.steps.isEmpty {
            add(
                .compoundHeading(
                    name: compound.displayName,
                    colour: compound.colorHex.flatMap { NSColor(hex: $0) },
                    detail: compoundDetail(compound, plan: plan)
                ),
                22
            )
            add(.columnHeader, 18)
            for step in compound.steps {
                add(.tube(step, isVehicle: step.isVehicle, flagged: !step.warnings.isEmpty), 17)
            }
            add(.spacer, 12)
        }

        let warnings = plan.allWarnings
        if !warnings.isEmpty {
            add(.warningsHeading, 20)
            for warning in warnings {
                add(.warning(warning), height(of: warning.text, font: noteFont, width: textWidth - 14))
            }
        }
        y += inset
        if abs(frame.height - y) > 0.5 {
            setFrameSize(NSSize(width: bounds.width, height: y))
        }
    }

    private func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(bounds.height) + 4
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(40, rows.last.map { $0.y + $0.height + inset } ?? 40))
    }

    // MARK: - Lines of prose

    private func setupLine(_ plan: DilutionPlan) -> String {
        // The unit is no longer one per sheet — each drug carries its own, and says it on
        // its own heading — so it is not named up here any more.
        let parts = [plan.scopeText, "made up in \(plan.setup.diluent)", plan.setup.overage.label]
        return parts.joined(separator: "  ·  ")
    }

    private func volumeLine(_ plan: DilutionPlan) -> String {
        let setup = plan.setup
        let fold = PlateEditor.formatValue(setup.foldOverWell, significantDigits: 3)
        let added = PlateEditor.formatValue(setup.addedVolume, significantDigits: 4)
        let well = PlateEditor.formatValue(setup.wellVolume, significantDigits: 4)
        return "Add \(added) µL per well to make \(well) µL — tubes are \(fold)× working solutions"
    }

    private func compoundDetail(_ compound: DilutionPlan.Compound, plan: DilutionPlan) -> String {
        var parts: [String] = []
        if !compound.unit.isEmpty { parts.append("in \(compound.unit)") }
        if let stock = compound.stock, stock.isUsable {
            parts.append("stock \(stock.label)")
        } else {
            parts.append("no stock set")
        }
        parts.append(compound.method.label)
        return parts.joined(separator: "  ·  ")
    }

    private func cells(for step: DilutionPlan.Step, plan: DilutionPlan) -> [String] {
        func volume(_ value: Double?) -> String {
            guard let value else { return "—" }
            return PlateEditor.formatValue(value, significantDigits: 5)
        }
        let from: String
        switch step.source {
        case .stock: from = "stock"
        case .tube(let index): from = "tube \(index + 1)"
        case .neatSolvent: from = "solvent"
        case .diluentOnly: from = "—"
        }
        return [
            step.isVehicle ? "vehicle" : step.doseName,
            step.isVehicle ? "—" : PlateEditor.formatValue(step.working, significantDigits: 4),
            "\(step.wells)",
            from,
            volume(step.sourceVolume),
            volume(step.diluent),
            volume(step.total),
        ]
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if exportMode, let aqua = NSAppearance(named: .aqua) {
            aqua.performAsCurrentDrawingAppearance { render(dirtyRect) }
        } else {
            render(dirtyRect)
        }
    }

    private func render(_ dirtyRect: NSRect) {
        (exportMode ? NSColor.white : NSColor.textBackgroundColor).setFill()
        // Clipped to our own bounds. AppKit hands a subview a dirty rect covering the
        // whole damaged region, which on the canvas board is the entire viewport — and
        // filling *that* painted opaque white over every other card and the board itself.
        dirtyRect.intersection(bounds).fill()
        guard let plan else { return }

        let ink = NSColor.labelColor
        let quiet = NSColor.secondaryLabelColor
        let full = NSRect(x: inset, y: 0, width: max(0, bounds.width - inset * 2), height: 0)

        for laid in rows where laid.y + laid.height >= dirtyRect.minY && laid.y <= dirtyRect.maxY {
            let line = NSRect(x: full.minX, y: laid.y, width: full.width, height: laid.height)
            switch laid.row {
            case .title(let text):
                draw(text, in: line, font: titleFont, colour: ink)
            case .setupLine(let text):
                draw(text, in: line, font: noteFont, colour: quiet)
            case .compoundHeading(let name, let colour, let detail):
                var swatch = NSRect(x: line.minX, y: line.minY + 5, width: 9, height: 9)
                if let colour {
                    colour.setFill()
                    NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
                } else {
                    swatch = NSRect(x: line.minX, y: line.minY, width: 0, height: 0)
                }
                let nameWidth = (name as NSString).size(withAttributes: [.font: headingFont]).width
                let x = swatch.maxX + (swatch.width > 0 ? 6 : 0)
                draw(name, in: NSRect(x: x, y: line.minY, width: nameWidth + 4, height: line.height),
                     font: headingFont, colour: ink)
                draw(detail,
                     in: NSRect(x: x + nameWidth + 10, y: line.minY,
                                width: max(0, line.maxX - x - nameWidth - 10), height: line.height),
                     font: noteFont, colour: quiet)
            case .columnHeader:
                NSColor.separatorColor.setStroke()
                let rule = NSBezierPath()
                rule.move(to: NSPoint(x: line.minX, y: line.maxY - 0.5))
                rule.line(to: NSPoint(x: line.maxX, y: line.maxY - 0.5))
                rule.lineWidth = 0.5
                rule.stroke()
                drawColumns(columnTitles, in: line, font: noteFont, colour: quiet)
            case .tube(let step, let isVehicle, let flagged):
                if isVehicle {
                    NSColor.quaternaryLabelColor.withAlphaComponent(exportMode ? 0.08 : 0.12).setFill()
                    line.fill()
                }
                drawColumns(
                    cells(for: step, plan: plan), in: line, font: bodyFont,
                    colour: flagged ? NSColor.systemOrange.blended(withFraction: 0.35, of: ink) ?? ink : ink
                )
            case .spacer:
                break
            case .warningsHeading:
                draw("Before you start", in: line, font: headingFont, colour: ink)
            case .warning(let warning):
                let dot = NSRect(x: line.minX + 1, y: line.minY + 4, width: 5, height: 5)
                colour(for: warning.severity).setFill()
                NSBezierPath(ovalIn: dot).fill()
                draw(
                    warning.text,
                    in: NSRect(x: line.minX + 14, y: line.minY, width: line.width - 14, height: line.height),
                    font: noteFont, colour: warning.severity == .note ? quiet : ink, wraps: true
                )
            }
        }
    }

    private func colour(for severity: PrepWarning.Severity) -> NSColor {
        switch severity {
        case .error: return .systemRed
        case .caution: return .systemOrange
        case .note: return .tertiaryLabelColor
        }
    }

    private func drawColumns(_ cells: [String], in line: NSRect, font: NSFont, colour: NSColor) {
        var x = line.minX
        for (index, text) in cells.enumerated() {
            guard index < columnWeights.count else { break }
            let width = line.width * columnWeights[index]
            // Names left, numbers right — the two number columns people compare are
            // "Take" and "= Make", and a ragged right edge makes that comparison work.
            let alignment: NSTextAlignment = index == 0 || index == 3 ? .left : .right
            draw(
                text, in: NSRect(x: x, y: line.minY, width: width - 6, height: line.height),
                font: font, colour: colour, alignment: alignment
            )
            x += width
        }
    }

    private func draw(
        _ text: String, in rect: NSRect, font: NSFont, colour: NSColor,
        alignment: NSTextAlignment = .left, wraps: Bool = false
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: colour, .paragraphStyle: style,
        ]
        let height = (text as NSString).size(withAttributes: attributes).height
        let box = wraps
            ? rect
            : NSRect(x: rect.minX, y: rect.minY + (rect.height - height) / 2,
                     width: rect.width, height: height)
        (text as NSString).draw(in: box, withAttributes: attributes)
    }

    // MARK: - Rendering and printing

    /// Same shape as `PlateCanvasView.pngData()` — what makes any of this testable.
    func pngData() -> Data? {
        guard bounds.width > 4, bounds.height > 4,
              let rep = bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        exportMode = true
        cacheDisplay(in: bounds, to: rep)
        exportMode = false
        return rep.representation(using: .png, properties: [:])
    }

    /// A table is not a picture: fitting it to one page shrinks the type instead of
    /// turning the page, so this paginates vertically and breaks on row boundaries.
    static func print(plan: DilutionPlan, jobName: String) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = .portrait
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        info.topMargin = 30
        info.bottomMargin = 30
        info.leftMargin = 30
        info.rightMargin = 30

        // A view of its own, sized to the paper, so printing never disturbs the one on
        // screen or depends on how wide the window happens to be.
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = PrepTableView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.plan = plan
        view.setFrameSize(NSSize(width: width, height: view.intrinsicContentSize.height))
        view.exportMode = true

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = jobName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    /// AppKit will happily slice a page through the middle of a row; this moves the break
    /// up to the nearest row boundary at or above it. A plain function, so the rule is
    /// testable without a printer.
    override func adjustPageHeightNew(
        _ newBottom: UnsafeMutablePointer<CGFloat>, top: CGFloat,
        bottom proposedBottom: CGFloat, limit: CGFloat
    ) {
        newBottom.pointee = pageBottom(top: top, proposedBottom: proposedBottom)
    }

    /// The last row boundary at or above `proposedBottom`, or the proposal itself when no
    /// row straddles it. Never returns something at or above `top`, which would make no
    /// progress and loop the print operation forever.
    func pageBottom(top: CGFloat, proposedBottom: CGFloat) -> CGFloat {
        var best = proposedBottom
        for laid in rows {
            let bottom = laid.y + laid.height
            guard laid.y < proposedBottom, bottom > proposedBottom else { continue }
            best = laid.y
            break
        }
        return best > top ? best : proposedBottom
    }
}

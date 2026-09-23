import XCTest
import AppKit
@testable import PLayout

/// One type size per plate, fitted to the wells.
///
/// Every well on a plate is the same size, so the only thing that makes one label
/// smaller than its neighbour is its own length — and the longest name is the one that
/// ends up truncated. Fitted, the plate takes the largest size at which every name it
/// draws still fits, and every well uses it.
final class TextFittingTests: XCTestCase {

    /// The system font explicitly, so a family chosen in Settings cannot move a
    /// measurement — the same reason `labelPlan` takes an explicit `scale:` here.
    private let system: (CGFloat, NSFont.Weight) -> NSFont = {
        .systemFont(ofSize: $0, weight: $1)
    }

    private func label(
        _ text: String, available: CGFloat, size: CGFloat = 12, weight: NSFont.Weight = .medium
    ) -> PlateCanvasView.FittedLabel {
        PlateCanvasView.FittedLabel(text: text, available: available, size: size, weight: weight)
    }

    private func width(_ text: String, at size: CGFloat, weight: NSFont.Weight = .medium) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: system(size, weight)]).width
    }

    // MARK: - The measurement

    /// Fitting shrinks; it never grows. A plate of short names has to look exactly as
    /// it does today, or turning the option on would be a surprise everywhere.
    func testAPlateThatAlreadyFitsIsNotTouched() {
        let labels = [label("Hi", available: 200), label("DMSO", available: 200)]
        XCTAssertEqual(PlateCanvasView.fitScale(labels, font: system), 1)
        XCTAssertEqual(PlateCanvasView.fitScale([], font: system), 1, "and neither is an empty plate")
    }

    /// The point of the whole thing: the name that needs the most room sets the size,
    /// and at that size it fits — so nothing is truncated.
    func testTheLongestNameSetsTheSizeAndThenFits() {
        let long = "Vehicle control"
        // Room for 70 % of it, so the fixture asks for a real shrink without reaching
        // the readable floor — that case is its own test below.
        let room = width(long, at: 12) * 0.7
        let scale = PlateCanvasView.fitScale([label("Hi", available: room),
                                              label(long, available: room)], font: system)
        XCTAssertEqual(scale, 0.7, accuracy: 0.05)
        // Genuinely fits, not nearly: anything left over would be `drawFitted` shrinking
        // this one label further, and the plate would no longer have one size.
        XCTAssertLessThanOrEqual(width(long, at: 12 * scale), room,
                                 "the name the plate was sized for still does not fit")
    }

    /// One number for the whole plate is the feature, not a shortcut: a well whose own
    /// label had room to spare comes down with the rest, which is what stops the plate
    /// reading as ragged.
    func testAShortNameIsBroughtDownWithTheLongOne() {
        let room = width("Vehicle control 0.1% DMSO", at: 12) * 0.7
        let alone = PlateCanvasView.fitScale([label("Hi", available: room)], font: system)
        let together = PlateCanvasView.fitScale(
            [label("Hi", available: room), label("Vehicle control 0.1% DMSO", available: room)],
            font: system
        )
        XCTAssertEqual(alone, 1)
        XCTAssertLessThan(together, alone)
    }

    /// A name long enough to need unreadable type pays for itself rather than taking
    /// the plate with it. Below the floor it truncates, exactly as it does today.
    func testOneAbsurdNameCannotDragThePlateBelowTheReadableFloor() {
        let absurd = String(repeating: "wide ", count: 40)
        let scale = PlateCanvasView.fitScale(
            [label(absurd, available: 46, size: 12)], minimumSize: 6, font: system
        )
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001, "6 pt of a 12 pt tier")

        XCTAssertEqual(PlateCanvasView.minimumLabelSize, 5,
                       "and the floor the plate actually uses is 5 pt")
    }

    /// The floor limits how far `drawFitted` shrinks a label *on its own*. It must never
    /// override the size it was handed — a fitted plate arrives already at the size the
    /// whole plate agreed on, and clamping it back up would truncate the very label the
    /// plate was sized for, which is what made lowering the floor do nothing at all.
    func testAFloorNeverOverridesTheSizeALabelWasGiven() {
        // Unchanged where the max is comfortably above it.
        XCTAssertEqual(PlateCanvasView.fittedFloor(maxFontSize: 13, minFontSize: nil), 7)
        XCTAssertEqual(PlateCanvasView.fittedFloor(maxFontSize: 13, minFontSize: 11), 11,
                       "a tier keeps its own floor")
        // And never above the maximum, however small that is.
        XCTAssertEqual(PlateCanvasView.fittedFloor(maxFontSize: 5.2, minFontSize: nil), 5.2)
        XCTAssertEqual(PlateCanvasView.fittedFloor(maxFontSize: 4, minFontSize: 3.4), 4)
    }

    /// Tiers are measured as they are drawn — the headline line is bigger and semibold,
    /// so it needs more room for the same text than a supporting line does.
    func testAHeadlineLineIsMeasuredAtItsOwnTierAndWeight() {
        let name = "Vehicle control"
        let room = width(name, at: 12) * 0.8
        let headline = PlateCanvasView.fitScale(
            [label(name, available: room, size: 12, weight: .semibold)], font: system
        )
        let supporting = PlateCanvasView.fitScale(
            [label(name, available: room, size: 9.6, weight: .regular)], font: system
        )
        XCTAssertLessThan(headline, supporting)
    }

    /// The fit is measured against the width a stacked line actually gets, so the two
    /// come from one formula. A well body has to leave room for the colour rail.
    func testAStackedLineGetsLessRoomThanTheWholeWellBody() {
        let body: CGFloat = 60
        let stacked = PlateCanvasView.stackTextWidth(bodyWidth: body, widthScale: 1)
        XCTAssertLessThan(stacked, PlateCanvasView.fittedWidth(of: body, alignment: .center))
        XCTAssertGreaterThan(stacked, 0)
    }

    /// The block's length is a setting, and the name is measured against what the
    /// block leaves — so a longer block means less room, through the one formula. On
    /// a well too small to lend any, the setting is capped rather than obeyed: the
    /// block never grows into the name, and never shrinks below what the well gave.
    func testALongerBlockLeavesLessRoomForTheNameUntilTheWellRunsOut() {
        let body: CGFloat = 60
        let plain = PlateCanvasView.stackRail(bodyWidth: body, widthScale: 1)
        let long = PlateCanvasView.stackRail(bodyWidth: body, widthScale: 2)
        XCTAssertEqual(long.width, plain.width * 2, accuracy: 0.001)
        XCTAssertLessThan(
            PlateCanvasView.stackTextWidth(bodyWidth: body, widthScale: 2),
            PlateCanvasView.stackTextWidth(bodyWidth: body, widthScale: 1)
        )
        XCTAssertGreaterThan(PlateCanvasView.stackTextWidth(bodyWidth: body, widthScale: 2), body * 0.4)

        let tiny: CGFloat = 8
        XCTAssertEqual(
            PlateCanvasView.stackRail(bodyWidth: tiny, widthScale: 2).width,
            PlateCanvasView.stackRail(bodyWidth: tiny, widthScale: 1).width,
            "a well this small has no width to lend the block"
        )
        XCTAssertEqual(
            PlateCanvasView.stackRail(bodyWidth: tiny, widthScale: 0.5).width,
            PlateCanvasView.stackRail(bodyWidth: tiny, widthScale: 1).width * 0.5,
            accuracy: 0.001, "shorter is always allowed"
        )
    }

    // MARK: - Through the drawing

    /// "Hi" in A1, a name far too long for a well in A2, and enough plate to show text.
    private func editor(longName: String) -> PlateEditor {
        let document = PlateDocument()
        var layout = Layout()

        var condition = Factor(name: "Condition")
        condition.levels = [
            Level(name: "Hi", colorHex: Palette.color(at: 0)),
            Level(name: longName, colorHex: Palette.color(at: 1)),
        ]
        layout.factors = [condition]

        var plate = Plate(name: "Plate 1", format: .well96)
        for well in 0..<plate.format.wellCount {
            plate.setLevelID(
                condition.levels[well % 2].id, factor: condition.id, well: well
            )
        }
        layout.plates = [plate]
        document.layout = layout

        let editor = PlateEditor(document: document)
        editor.setWellLabelMode(.activeFactor)
        return editor
    }

    private func rendered(_ editor: PlateEditor) throws -> (NSBitmapImageRep, PlateGeometry, CGFloat) {
        let frame = NSRect(x: 0, y: 0, width: 940, height: 560)
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        let canvas = PlateCanvasView(frame: frame)
        canvas.attach(editor: editor)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.pngData())))
        let geo = PlateGeometry(format: .well96, bounds: canvas.bounds)
        return (rep, geo, CGFloat(rep.pixelsWide) / canvas.bounds.width)
    }

    /// How much ink there is inside one well. The well is flooded with its condition's
    /// colour and the label is drawn on top, so anything that is not that colour is
    /// the text — which makes the count a direct measure of how big the type is.
    /// Measured against the known colour rather than a sampled pixel: the body is a
    /// rounded shape, so a sample near its edge can land outside the fill entirely.
    private func inkPixels(
        _ rep: NSBitmapImageRep, cell: CGRect, scale: CGFloat, fill hex: String
    ) throws -> Int {
        let fill = try XCTUnwrap(NSColor(hex: hex)?.usingColorSpace(.sRGB))
        let box = cell.insetBy(dx: cell.width * 0.18, dy: cell.height * 0.3)
        var ink = 0
        for x in Int(box.minX * scale)...Int(box.maxX * scale) {
            for y in Int(box.minY * scale)...Int(box.maxY * scale) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let distance = abs(c.redComponent - fill.redComponent)
                    + abs(c.greenComponent - fill.greenComponent)
                    + abs(c.blueComponent - fill.blueComponent)
                if distance > 0.25 { ink += 1 }
            }
        }
        return ink
    }

    /// The end of it: a well whose own label had room to spare is drawn smaller once a
    /// long name joins the plate. Nothing but the option changes between the two.
    func testFittingReachesAWellThatDidNotNeedIt() throws {
        let previous = Preferences.shared.fitTextToWells
        defer { Preferences.shared.fitTextToWells = previous }

        let a1 = PlateGeometry(
            format: .well96, bounds: NSRect(x: 0, y: 0, width: 940, height: 560)
        ).cellRect(row: 0, col: 0)

        let hi = Palette.color(at: 0)
        Preferences.shared.fitTextToWells = false
        let (loose, _, scale) = try rendered(editor(longName: "Vehicle control 0.1% DMSO"))
        let unfitted = try inkPixels(loose, cell: a1, scale: scale, fill: hi)

        Preferences.shared.fitTextToWells = true
        let (tight, _, _) = try rendered(editor(longName: "Vehicle control 0.1% DMSO"))
        let fitted = try inkPixels(tight, cell: a1, scale: scale, fill: hi)

        XCTAssertGreaterThan(unfitted, 0, "A1 drew no label at all")
        XCTAssertLessThan(fitted, unfitted, "“Hi” was not brought down with the long name")
    }

    /// And when there is nothing to fit, turning it on changes not one pixel.
    func testFittingAPlateThatAlreadyFitsChangesNothing() throws {
        let previous = Preferences.shared.fitTextToWells
        defer { Preferences.shared.fitTextToWells = previous }

        func png() throws -> Data {
            let frame = NSRect(x: 0, y: 0, width: 940, height: 560)
            let window = NSWindow(
                contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
            )
            let canvas = PlateCanvasView(frame: frame)
            canvas.attach(editor: editor(longName: "Lo"))
            window.contentView = canvas
            canvas.layoutSubtreeIfNeeded()
            return try XCTUnwrap(canvas.pngData())
        }

        Preferences.shared.fitTextToWells = false
        let plain = try png()
        Preferences.shared.fitTextToWells = true
        XCTAssertEqual(try png(), plain)
    }

    // MARK: - The setting

    func testTheSettingIsOffByDefaultAndRemembered() {
        let store = UserDefaults(suiteName: "com.nettilor.playout.fit-tests")!
        store.removePersistentDomain(forName: "com.nettilor.playout.fit-tests")
        defer { store.removePersistentDomain(forName: "com.nettilor.playout.fit-tests") }

        let fresh = Preferences(defaults: store)
        XCTAssertFalse(fresh.fitTextToWells, "it changes how every existing document looks")

        fresh.fitTextToWells = true
        XCTAssertTrue(Preferences(defaults: store).fitTextToWells)

        fresh.resetToDefaults()
        XCTAssertFalse(Preferences(defaults: store).fitTextToWells)
    }
}

import AppKit
import XCTest
@testable import PLayout

/// The swatch grid reads across for "tell these two apart" and down for "same colour,
/// darker". Both of those are claims about the colours themselves, so they are checked
/// here rather than left to the eye.
final class PaletteGridTests: XCTestCase {

    private func hsb(_ hex: String) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        let c = NSColor(hex: hex)!.usingColorSpace(.sRGB)!
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    private func luminance(_ hex: String) -> CGFloat {
        NSColor(hex: hex)!.perceivedLuminance
    }

    private var everyShade: [String] {
        Palette.Family.allCases.flatMap { family in
            family.hues.flatMap { Palette.shades(of: $0) }
        }
    }

    // MARK: - Column shape

    /// The base colour has to survive untouched in the middle of its own column, or a
    /// colour the app assigned itself would show up in the picker as "custom".
    func testEachColumnKeepsItsBaseColourInTheMiddle() {
        for family in Palette.Family.allCases {
            for hue in family.hues {
                let column = Palette.shades(of: hue, count: 5)
                XCTAssertEqual(column.count, 5)
                XCTAssertTrue(
                    Palette.matches(column[2], hue),
                    "\(family.label): \(hue) came back as \(column[2])"
                )
            }
        }
    }

    func testColumnsRunLightToDark() {
        for family in Palette.Family.allCases {
            for hue in family.hues {
                let column = Palette.shades(of: hue)
                for i in 1..<column.count {
                    XCTAssertLessThan(
                        luminance(column[i]), luminance(column[i - 1]),
                        "\(family.label) \(hue): \(column[i - 1]) → \(column[i]) did not darken"
                    )
                }
            }
        }
    }

    /// Regression: interpolating towards a ceiling rather than clamping to it. Tableau's
    /// light greys sit close enough to the light end that clamping produced two steps at
    /// the identical hex — a column with a step that visibly does nothing.
    func testNoColumnRepeatsAShade() {
        for family in Palette.Family.allCases {
            for hue in family.hues {
                let column = Palette.shades(of: hue)
                XCTAssertEqual(
                    Set(column).count, column.count,
                    "\(family.label) \(hue) repeats a shade: \(column)"
                )
            }
        }
    }

    /// A pale, unsaturated swatch would paint a well that reads as never having been
    /// painted — empty wells are drawn at about #DEDEDE, luminance 0.73.
    func testNoShadeCouldBeMistakenForAnEmptyWell() {
        for shade in everyShade where hsb(shade).s < 0.15 {
            XCTAssertLessThan(
                luminance(shade), 0.72,
                "\(shade) is as pale as an unpainted well and has no hue to say otherwise"
            )
        }
    }

    // MARK: - Families

    /// Every family ends in a neutral, so "grey for the untreated arm" does not depend
    /// on which family happens to be showing. Equal widths also keep the popover from
    /// resizing as you switch.
    func testEveryFamilyIsEightColumnsEndingInANeutral() {
        for family in Palette.Family.allCases {
            XCTAssertEqual(family.hues.count, 8, family.label)
            XCTAssertLessThan(hsb(family.hues[7]).s, 0.15, "\(family.label) has no neutral column")
            XCTAssertEqual(Set(family.hues).count, 8, "\(family.label) repeats a hue")
            for hue in family.hues {
                XCTAssertNotNil(NSColor(hex: hue), "\(family.label): \(hue) is not a colour")
            }
        }
    }

    /// The colours a new factor hands out have to be findable in the grid — otherwise
    /// the picker cannot show you what you already have. Eight covers any real factor.
    func testTheAutoAssignedColoursAreAllInTheGrid() {
        let inGrid = Set(
            Palette.Family.allCases.flatMap { $0.hues }.map { NSColor(hex: $0)!.hexString }
        )
        for index in 0..<8 {
            let assigned = NSColor(hex: Palette.color(at: index))!.hexString
            XCTAssertTrue(inGrid.contains(assigned), "condition \(index + 1) gets \(assigned), which no column offers")
        }
    }

    // MARK: - The colour-blind claim

    /// Viénot–Brettel–Mollon deuteranope simulation in linear RGB — the common form of
    /// red/green colour blindness.
    private func deuteranope(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let c = NSColor(hex: hex)!.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = lin(c.redComponent), g = lin(c.greenComponent), b = lin(c.blueComponent)
        return (0.625 * r + 0.375 * g, 0.700 * r + 0.300 * g, 0.300 * g + 0.700 * b)
    }

    private func worstSeparation(_ hexes: [String]) -> CGFloat {
        var worst = CGFloat.greatestFiniteMagnitude
        for i in hexes.indices {
            for j in (i + 1)..<hexes.count {
                let a = deuteranope(hexes[i]), b = deuteranope(hexes[j])
                worst = min(worst, sqrt(pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2)))
            }
        }
        return worst
    }

    /// The popover tells the user this family "stays separable with red/green colour
    /// blindness", so the claim is measured rather than trusted. Stated as a comparison
    /// against Standard, which keeps it meaningful instead of a threshold pulled from
    /// the air: Standard's own worst pair is its green against its grey.
    func testTheColourBlindFamilySeparatesBetterThanTheStandardOne() {
        let safe = worstSeparation(Palette.Family.colourBlind.hues)
        let standard = worstSeparation(Palette.Family.standard.hues)
        XCTAssertGreaterThan(
            safe, standard * 3,
            "Okabe–Ito separated by \(safe), standard by \(standard) — the label is not earned"
        )
    }

    // MARK: - Matching

    func testMatchesSurvivesCaseAndAMissingHash() {
        XCTAssertTrue(Palette.matches("#4E79A7", "#4e79a7"))
        XCTAssertTrue(Palette.matches("4E79A7", "#4E79A7"))
        XCTAssertTrue(Palette.matches("  #4E79A7 ", "#4E79A7"))
        XCTAssertFalse(Palette.matches("#4E79A7", "#4E79A8"))
        // Neither parses, so it falls back to comparing the text itself.
        XCTAssertTrue(Palette.matches("nonsense", "NONSENSE"))
        XCTAssertFalse(Palette.matches("nonsense", "#4E79A7"))
    }

    // MARK: - Degenerate input

    func testShadesSurviveInputThatIsNotAColour() {
        XCTAssertEqual(Palette.shades(of: "not a colour", count: 3), ["not a colour", "not a colour", "not a colour"])
        XCTAssertTrue(Palette.shades(of: "#4E79A7", count: 0).isEmpty)
        XCTAssertEqual(Palette.shades(of: "#4E79A7", count: 1), ["#4E79A7"])
    }

    func testBlackAndWhiteStillProduceAUsableColumn() {
        for extreme in ["#000000", "#FFFFFF"] {
            let column = Palette.shades(of: extreme)
            XCTAssertEqual(Set(column).count, column.count, "\(extreme) → \(column)")
            for i in 1..<column.count {
                XCTAssertLessThan(luminance(column[i]), luminance(column[i - 1]), "\(extreme) → \(column)")
            }
        }
    }
}

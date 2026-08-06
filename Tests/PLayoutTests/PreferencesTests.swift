import AppKit
import XCTest
@testable import PLayout

/// The ⌘, settings are app-wide rather than part of a document, which is the whole
/// reason they need their own storage and their own way of reaching an open canvas.
final class PreferencesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "preferences-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Storage

    func testDefaultsAreTheAutomaticOnes() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.wellTextStyle, .automatic)
        XCTAssertEqual(preferences.activeMarkerStyle, .matchLabel)
    }

    func testChoicesSurviveARelaunch() {
        let preferences = Preferences(defaults: defaults)
        preferences.wellTextStyle = .alwaysWhite
        preferences.activeMarkerStyle = .deeperShade

        let reopened = Preferences(defaults: defaults)
        XCTAssertEqual(reopened.wellTextStyle, .alwaysWhite)
        XCTAssertEqual(reopened.activeMarkerStyle, .deeperShade)
    }

    /// Same leniency the document's own display settings have: a value from a newer
    /// build should fall back to something sane, not refuse to load.
    func testAnUnknownStoredValueFallsBack() {
        defaults.set("iridescent", forKey: "wellTextStyle")
        defaults.set("engraved", forKey: "activeMarkerStyle")
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.wellTextStyle, .automatic)
        XCTAssertEqual(preferences.activeMarkerStyle, .matchLabel)
    }

    func testRestoreDefaultsPutsEverythingBack() {
        let preferences = Preferences(defaults: defaults)
        preferences.wellTextStyle = .alwaysBlack
        preferences.activeMarkerStyle = .deeperShade
        preferences.resetToDefaults()
        XCTAssertEqual(preferences.wellTextStyle, .automatic)
        XCTAssertEqual(preferences.activeMarkerStyle, .matchLabel)
    }

    // MARK: - What the styles actually produce

    private func isDark(_ colour: NSColor) -> Bool { colour.perceivedLuminance < 0.5 }

    func testTheFixedStylesIgnoreTheColourUnderneath() {
        for hex in ["#FFFFFF", "#F1CE63", "#5889BC", "#000000"] {
            let colour = NSColor(hex: hex)!
            XCTAssertTrue(isDark(colour.labelInk(.alwaysBlack)), "\(hex) did not get black")
            XCTAssertFalse(isDark(colour.labelInk(.alwaysWhite)), "\(hex) did not get white")
        }
    }

    func testAutomaticStillReadsTheColour() {
        XCTAssertTrue(isDark(NSColor(hex: "#F1CE63")!.labelInk(.automatic)))
        XCTAssertFalse(isDark(NSColor(hex: "#000000")!.labelInk(.automatic)))
    }

    /// Overview's tile carries no colour to contrast against, so under "always white"
    /// it is the tile that has to move — otherwise the mode is simply unreadable.
    func testOnlyAlwaysWhiteAsksForADarkNeutralTile() {
        XCTAssertFalse(WellTextStyle.automatic.prefersDarkNeutral)
        XCTAssertFalse(WellTextStyle.alwaysBlack.prefersDarkNeutral)
        XCTAssertTrue(WellTextStyle.alwaysWhite.prefersDarkNeutral)
    }

    func testAutomaticLeavesTheNeutralInkToTheAppearance() {
        XCTAssertEqual(WellTextStyle.automatic.neutralInk, NSColor.labelColor)
        XCTAssertNotNil(WellTextStyle.alwaysBlack.fixedInk)
        XCTAssertNil(WellTextStyle.automatic.fixedInk)
    }

    // MARK: - The deeper-shade marker

    /// The marker sits on a well already filled with the colour itself, so "darker" has
    /// to mean visibly darker — not a shade that merges back into its own background.
    func testTheDeeperMarkerIsClearlyDarkerThanTheWellItSitsOn() {
        for family in Palette.Family.allCases {
            for hue in family.hues {
                let colour = NSColor(hex: hue)!
                let deep = colour.deepened
                XCTAssertLessThan(
                    deep.perceivedLuminance, colour.perceivedLuminance * 0.55,
                    "\(hue) deepened to \(deep.hexString), barely darker than the well"
                )
            }
        }
    }

    /// It has to stay recognisably the same condition, which is the only reason to
    /// prefer it over a plain marker — so the hue must survive the darkening.
    func testTheDeeperMarkerKeepsItsHue() {
        for hue in Palette.Family.standard.hues {
            let colour = NSColor(hex: hue)!.usingColorSpace(.sRGB)!
            let deep = colour.deepened.usingColorSpace(.sRGB)!
            var h1: CGFloat = 0, s1: CGFloat = 0, b1: CGFloat = 0, a: CGFloat = 0
            var h2: CGFloat = 0, s2: CGFloat = 0, b2: CGFloat = 0
            colour.getHue(&h1, saturation: &s1, brightness: &b1, alpha: &a)
            deep.getHue(&h2, saturation: &s2, brightness: &b2, alpha: &a)
            // Greys have no hue to preserve, and getHue reports 0 for them either way.
            guard s1 > 0.15 else { continue }
            XCTAssertEqual(h1, h2, accuracy: 0.02, "\(hue) changed hue when deepened")
        }
    }

    /// A near-black condition has nowhere left to go, and a marker that bottoms out at
    /// pure black stops saying which condition it is.
    func testTheDeeperMarkerDoesNotBottomOut() {
        for hex in ["#000000", "#0A0A0A", "#101820"] {
            XCTAssertGreaterThan(NSColor(hex: hex)!.deepened.perceivedLuminance, 0.005, hex)
        }
    }
}

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
        XCTAssertEqual(preferences.activeBandOpacity, 0.42)
        XCTAssertEqual(preferences.stackBlockWidthScale, 1)
        XCTAssertEqual(preferences.stackBlockHeightScale, 1)
        XCTAssertEqual(preferences.newDocumentWellShape, .round)
        XCTAssertEqual(preferences.newConditionColors, .perFactor)
        XCTAssertFalse(preferences.showFactorConditionCounts)
    }

    func testFactorConditionCountsRememberAndReset() {
        let preferences = Preferences(defaults: defaults)
        preferences.showFactorConditionCounts = true
        XCTAssertTrue(Preferences(defaults: defaults).showFactorConditionCounts)

        preferences.resetToDefaults()
        XCTAssertFalse(preferences.showFactorConditionCounts)
        XCTAssertFalse(Preferences(defaults: defaults).showFactorConditionCounts)
    }

    func testTheWellShapeDefaultIsRememberedAndReadable() {
        let preferences = Preferences(defaults: defaults)
        preferences.newDocumentWellShape = .square
        XCTAssertFalse(preferences.newDocumentWellShape.isRound)

        let reopened = Preferences(defaults: defaults)
        XCTAssertEqual(reopened.newDocumentWellShape, .square)

        defaults.set("hexagonal", forKey: "newDocumentWellShape")
        XCTAssertEqual(Preferences(defaults: defaults).newDocumentWellShape, .round)
    }

    func testChoicesSurviveARelaunch() {
        let preferences = Preferences(defaults: defaults)
        preferences.wellTextStyle = .alwaysWhite
        preferences.newConditionColors = .neverRepeat

        let reopened = Preferences(defaults: defaults)
        XCTAssertEqual(reopened.wellTextStyle, .alwaysWhite)
        XCTAssertEqual(reopened.newConditionColors, .neverRepeat)
    }

    /// Same leniency the document's own display settings have: a value from a newer
    /// build should fall back to something sane, not refuse to load.
    func testAnUnknownStoredValueFallsBack() {
        defaults.set("iridescent", forKey: "wellTextStyle")
        defaults.set("hexagonal", forKey: "newDocumentWellShape")
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.wellTextStyle, .automatic)
        XCTAssertEqual(preferences.newDocumentWellShape, .round)
    }

    func testRestoreDefaultsPutsEverythingBack() {
        let preferences = Preferences(defaults: defaults)
        preferences.wellTextStyle = .alwaysBlack
        preferences.activeBandOpacity = 0.9
        preferences.newDocumentWellShape = .square
        preferences.resetToDefaults()
        XCTAssertEqual(preferences.wellTextStyle, .automatic)
        XCTAssertEqual(preferences.activeBandOpacity, 0.42)
        XCTAssertEqual(preferences.newDocumentWellShape, .round)
    }

    /// Renaming a plate has an editor path but had no way to reach it — the tab now
    /// renames on a second click. This is the part of that worth pinning: the model
    /// refuses a blank name rather than leaving a tab with no label.
    func testRenamingAPlateTakesAndRefusesTheRightThings() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        let plateID = editor.activePlateID!

        editor.renamePlate(plateID, to: "  Screen A  ")
        XCTAssertEqual(document.layout.plates[0].name, "Screen A", "the name was not trimmed")

        editor.renamePlate(plateID, to: "   ")
        XCTAssertEqual(document.layout.plates[0].name, "Screen A", "a blank name was accepted")
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

    // MARK: - New condition colours

    func testNewConditionColoursRememberAndDecodeLeniently() {
        let preferences = Preferences(defaults: defaults)
        preferences.newConditionColors = .neverRepeat
        XCTAssertEqual(Preferences(defaults: defaults).newConditionColors, .neverRepeat)

        defaults.set("polka-dot", forKey: "newConditionColors")
        XCTAssertEqual(Preferences(defaults: defaults).newConditionColors, .perFactor)
    }

    func testFirstColourNeverRepeatsWhileTheGridLasts() {
        var used = Set<String>()
        var picked = [String]()
        for i in 0..<60 {
            let hex = Palette.firstColor(avoiding: used, fallbackIndex: i)
            XCTAssertFalse(used.contains(Palette.normalized(hex)), "repeat at pick \(i)")
            used.insert(Palette.normalized(hex))
            picked.append(hex)
        }
        // The first twenty are the plain palette in its own order, so the two modes
        // agree completely until a colour would actually have repeated.
        XCTAssertEqual(Array(picked.prefix(20)), Palette.categorical)
    }

    func testFirstColourFallsBackOnceTheGridIsSpent() {
        var used = Set(Palette.categorical.map(Palette.normalized))
        for row in 0..<5 {
            for hue in Palette.categorical {
                used.insert(Palette.normalized(Palette.shades(of: hue)[row]))
            }
        }
        XCTAssertEqual(Palette.firstColor(avoiding: used, fallbackIndex: 3), Palette.color(at: 3))
    }

    func testEverySecondFactorStartsFromTheSameBlueByDefault() {
        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        XCTAssertEqual(
            document.layout.factors[1].levels[0].colorHex,
            document.layout.factors[0].levels[0].colorHex
        )
    }

    func testNeverRepeatGivesEveryNewConditionAFreshColour() {
        let previous = Preferences.shared.newConditionColors
        Preferences.shared.newConditionColors = .neverRepeat
        defer { Preferences.shared.newConditionColors = previous }

        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        editor.addLevel()
        editor.addLevel()

        let all = document.layout.factors.flatMap(\.levels).map { Palette.normalized($0.colorHex) }
        XCTAssertEqual(Set(all).count, all.count, "a colour repeated in \(all)")
    }

    func testPastedValuesTakeFreshColoursUnderNeverRepeat() {
        let previous = Preferences.shared.newConditionColors
        Preferences.shared.newConditionColors = .neverRepeat
        defer { Preferences.shared.newConditionColors = previous }

        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        editor.setActiveFactor(document.layout.factors[1].id)
        editor.selection = WellRange(single: WellPos(row: 0, col: 0))

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("One\tTwo\tThree", forType: .string)
        editor.pasteFromPasteboard()

        let all = document.layout.factors.flatMap(\.levels).map { Palette.normalized($0.colorHex) }
        XCTAssertEqual(Set(all).count, all.count, "a colour repeated in \(all)")
    }

    func testRecolourSpreadsAcrossUnusedColoursUnderNeverRepeat() {
        let previous = Preferences.shared.newConditionColors
        Preferences.shared.newConditionColors = .neverRepeat
        defer { Preferences.shared.newConditionColors = previous }

        let document = PlateDocument()
        let editor = PlateEditor(document: document)
        editor.addFactor()
        editor.addLevel()
        // Force a collision by hand, then ask the palette to sort it out.
        let factorID = document.layout.factors[1].id
        editor.setActiveFactor(factorID)
        for level in document.layout.factors[1].levels {
            editor.setLevelColor(level.id, hex: document.layout.factors[0].levels[0].colorHex)
        }
        editor.recolorLevelsFromPalette()

        let all = document.layout.factors.flatMap(\.levels).map { Palette.normalized($0.colorHex) }
        XCTAssertEqual(Set(all).count, all.count, "a colour repeated in \(all)")
    }

    // MARK: - Empty well colour

    func testEmptyWellColourRemembersResetsAndShrugsOffGarbage() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertNil(preferences.emptyWellColorHex)

        preferences.emptyWellColorHex = "#EEF2D8"
        XCTAssertEqual(Preferences(defaults: defaults).emptyWellColorHex, "#EEF2D8")
        XCTAssertEqual(preferences.emptyWellFill(exportMode: false).hexString, "#EEF2D8")
        // A chosen colour ignores export's fainter default — it is used as it is.
        XCTAssertEqual(preferences.emptyWellFill(exportMode: true).hexString, "#EEF2D8")

        defaults.set("chartreuse", forKey: "emptyWellColorHex")
        XCTAssertNil(Preferences(defaults: defaults).emptyWellColorHex)

        preferences.resetToDefaults()
        XCTAssertNil(preferences.emptyWellColorHex)
    }

    // MARK: - Canvas background

    func testCanvasBackgroundRemembersResetsAndShrugsOffGarbage() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertNil(preferences.canvasBackgroundColorHex)
        XCTAssertEqual(preferences.canvasBackground, NSColor.underPageBackgroundColor)

        preferences.canvasBackgroundColorHex = "#20242B"
        XCTAssertEqual(Preferences(defaults: defaults).canvasBackgroundColorHex, "#20242B")
        XCTAssertEqual(preferences.canvasBackground.hexString, "#20242B")

        defaults.set("nightfall", forKey: "canvasBackgroundColorHex")
        XCTAssertNil(Preferences(defaults: defaults).canvasBackgroundColorHex)

        preferences.resetToDefaults()
        XCTAssertNil(preferences.canvasBackgroundColorHex)
    }

    /// The dots have to stay visible whatever the board is set to, so they take their
    /// contrast from the background rather than being a fixed grey.
    func testTheDotGridContrastsWithWhateverTheBoardIs() {
        let preferences = Preferences(defaults: defaults)
        preferences.canvasBackgroundColorHex = "#101214"
        let onDark = try? XCTUnwrap(preferences.canvasGrid.usingColorSpace(.sRGB))
        preferences.canvasBackgroundColorHex = "#F4F4F5"
        let onLight = try? XCTUnwrap(preferences.canvasGrid.usingColorSpace(.sRGB))

        XCTAssertGreaterThan(
            onDark!.brightnessComponent, onLight!.brightnessComponent,
            "a dark board needs pale dots and a pale board needs dark ones"
        )
    }

    // MARK: - Overview block outlines

    func testBlockOutlineColourAndThicknessRememberAndReset() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertNil(preferences.groupOutlineColorHex)
        XCTAssertEqual(preferences.groupOutlineThickness, 1.5)

        preferences.groupOutlineColorHex = "#C1440E"
        preferences.groupOutlineThickness = 3
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.groupOutlineColorHex, "#C1440E")
        XCTAssertEqual(reloaded.groupOutlineThickness, 3)
        // A chosen colour is used as it is, on screen and on paper alike.
        XCTAssertEqual(preferences.groupOutlineColor(exportMode: false).hexString, "#C1440E")
        XCTAssertEqual(preferences.groupOutlineColor(exportMode: true).hexString, "#C1440E")

        defaults.set("chartreuse", forKey: "groupOutlineColorHex")
        XCTAssertNil(Preferences(defaults: defaults).groupOutlineColorHex)

        preferences.resetToDefaults()
        XCTAssertNil(preferences.groupOutlineColorHex)
        XCTAssertEqual(preferences.groupOutlineThickness, 1.5)
    }

    /// However thick the line is set, it cannot swallow the well it is drawn round —
    /// at 1536 wells the cell is a few points across.
    func testBlockOutlineThicknessIsCappedAgainstTheCell() {
        let preferences = Preferences(defaults: defaults)
        preferences.groupOutlineThickness = 4
        XCTAssertEqual(preferences.groupOutlineWidth(cell: 60), 4, "a big cell gets what was asked for")
        XCTAssertEqual(preferences.groupOutlineWidth(cell: 8), 2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(preferences.groupOutlineWidth(cell: 1), 0.5, "never invisible")

        defaults.set(99.0, forKey: "groupOutlineThickness")
        XCTAssertEqual(Preferences(defaults: defaults).groupOutlineThickness, 4, "clamped on load")
    }

    /// The tint behind the active line is an alpha, so the store is clamped to one
    /// on the way in — a stray 5.0 would otherwise be a solid band with no way back.
    func testActiveBandOpacityRemembersClampsAndResets() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.activeBandOpacity, 0.42)

        preferences.activeBandOpacity = 0.7
        XCTAssertEqual(Preferences(defaults: defaults).activeBandOpacity, 0.7)

        defaults.set(5.0, forKey: "activeBandOpacity")
        XCTAssertEqual(Preferences(defaults: defaults).activeBandOpacity, 1, "clamped on load")
        defaults.set(0.0, forKey: "activeBandOpacity")
        XCTAssertEqual(Preferences(defaults: defaults).activeBandOpacity, 0.1, "never fully off")

        preferences.resetToDefaults()
        XCTAssertEqual(preferences.activeBandOpacity, 0.42)
        XCTAssertEqual(Preferences(defaults: defaults).activeBandOpacity, 0.42)
    }

    /// The block's length and height are two settings, not one size: a bar and a tile
    /// are different shapes. Each is a multiplier clamped to its own range on load, so
    /// a stray value in the store lands at the end of the slider rather than off the
    /// plate — a length of 50 would leave no room for a name at all.
    func testColourBlockSizesRememberClampAndReset() {
        let preferences = Preferences(defaults: defaults)
        preferences.stackBlockWidthScale = 1.6
        preferences.stackBlockHeightScale = 0.5
        let reopened = Preferences(defaults: defaults)
        XCTAssertEqual(reopened.stackBlockWidthScale, 1.6)
        XCTAssertEqual(reopened.stackBlockHeightScale, 0.5)

        defaults.set(50.0, forKey: "stackBlockWidthScale")
        defaults.set(0.0, forKey: "stackBlockHeightScale")
        XCTAssertEqual(Preferences(defaults: defaults).stackBlockWidthScale, 2, "clamped on load")
        XCTAssertEqual(Preferences(defaults: defaults).stackBlockHeightScale, 0.4, "never vanishes")
        defaults.set(0.0, forKey: "stackBlockWidthScale")
        defaults.set(9.0, forKey: "stackBlockHeightScale")
        XCTAssertEqual(Preferences(defaults: defaults).stackBlockWidthScale, 0.5)
        XCTAssertEqual(Preferences(defaults: defaults).stackBlockHeightScale, 1.2, "never taller than its line")

        preferences.resetToDefaults()
        XCTAssertEqual(preferences.stackBlockWidthScale, 1)
        XCTAssertEqual(preferences.stackBlockHeightScale, 1)
        XCTAssertEqual(Preferences(defaults: defaults).stackBlockWidthScale, 1)
        XCTAssertEqual(Preferences(defaults: defaults).stackBlockHeightScale, 1)
    }

    // MARK: - Plate text

    func testPlateFontRemembersClampsAndResets() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertNil(preferences.canvasFontFamily)
        XCTAssertEqual(preferences.canvasFontScale, 1.0)

        preferences.canvasFontFamily = "Georgia"
        preferences.canvasFontScale = 1.3
        let reopened = Preferences(defaults: defaults)
        XCTAssertEqual(reopened.canvasFontFamily, "Georgia")
        XCTAssertEqual(reopened.canvasFontScale, 1.3)

        defaults.set(9.0, forKey: "canvasFontScale")
        XCTAssertEqual(Preferences(defaults: defaults).canvasFontScale, 1.8)
        defaults.set(0.01, forKey: "canvasFontScale")
        XCTAssertEqual(Preferences(defaults: defaults).canvasFontScale, 0.7)

        preferences.resetToDefaults()
        XCTAssertNil(preferences.canvasFontFamily)
        XCTAssertEqual(preferences.canvasFontScale, 1.0)
    }

    func testCanvasFontFallsBackToTheSystemFont() {
        let preferences = Preferences(defaults: defaults)
        let system = NSFont.systemFont(ofSize: 12, weight: .medium)
        XCTAssertEqual(preferences.canvasFont(ofSize: 12, weight: .medium), system)

        preferences.canvasFontFamily = "NoSuchFamily-Anywhere"
        XCTAssertEqual(preferences.canvasFont(ofSize: 12, weight: .medium), system)

        preferences.canvasFontFamily = "Helvetica"
        let chosen = preferences.canvasFont(ofSize: 12, weight: .medium)
        XCTAssertEqual(chosen.familyName, "Helvetica")
        XCTAssertEqual(chosen.pointSize, 12)
    }

    func testTheSizeSettingScalesTheLabelPlanUniformly() {
        // A plan that does not stack is the pure case: the scaled plan must be
        // exactly the unscaled plan with larger type.
        let base = PlateCanvasView.labelPlan(cell: 40, mode: .activeFactor, factorCount: 1, scale: 1)
        let scaled = PlateCanvasView.labelPlan(cell: 40, mode: .activeFactor, factorCount: 1, scale: 1.4)
        XCTAssertEqual(scaled.primarySize, base.primarySize * 1.4, accuracy: 0.001)
        XCTAssertEqual(scaled.secondarySize, base.secondarySize * 1.4, accuracy: 0.001)
        XCTAssertEqual(scaled.gap, base.gap * 1.4, accuracy: 0.001)
    }
}

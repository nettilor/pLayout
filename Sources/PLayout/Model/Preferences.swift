import AppKit
import Combine

/// A display setting the ⌘, window can offer as a radio group: a fixed set of options,
/// each with a name and a sentence saying what choosing it costs.
protocol DisplayChoice: CaseIterable, Hashable, Identifiable {
    var label: String { get }
    var note: String { get }
}

/// How a well's label picks its colour.
///
/// The default reads the well and chooses whichever of black or white is legible on
/// it. That is the safe answer, but it means a plate can carry both — which reads as a
/// glitch to some people rather than as contrast — so the choice is offered outright.
enum WellTextStyle: String, Codable, DisplayChoice {
    case automatic
    case alwaysBlack
    case alwaysWhite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Match the well"
        case .alwaysBlack: return "Always black"
        case .alwaysWhite: return "Always white"
        }
    }

    var note: String {
        switch self {
        case .automatic:
            return "Black on light conditions, white on dark ones. Always legible, but a plate can carry both."
        case .alwaysBlack:
            return "One colour everywhere. Every colour the palette offers is light enough to read it — a very dark colour picked from Custom… will not be."
        case .alwaysWhite:
            return "One colour everywhere. Suits a dark palette; pale conditions and yellows will be hard to read."
        }
    }

    /// Overview draws on a neutral tile with no colour to contrast against, so the tile
    /// follows the ink rather than the other way round: white text gets a dark tile.
    var prefersDarkNeutral: Bool { self == .alwaysWhite }

    /// The ink this style always uses, or nil for `.automatic` — which has no answer
    /// until it is shown the colour it has to sit on.
    var fixedInk: NSColor? {
        switch self {
        case .automatic: return nil
        case .alwaysBlack: return NSColor.black.withAlphaComponent(0.85)
        case .alwaysWhite: return .white
        }
    }

    /// The ink on a well that carries no colour of its own — Overview's neutral tile.
    /// `.automatic` defers to the appearance, which is what keeps Overview readable in
    /// dark mode without the tile having to change.
    var neutralInk: NSColor { fixedInk ?? .labelColor }
}

/// The shape a new document draws its wells in. Only the starting point — the sidebar
/// keeps its own toggle, so a single layout can differ without changing the default.
enum WellShape: String, Codable, DisplayChoice {
    case round
    case square

    var id: String { rawValue }

    var label: String {
        switch self {
        case .round: return "Round"
        case .square: return "Square"
        }
    }

    var note: String {
        switch self {
        case .round:
            return "Looks like a plate. Ignored while stacked labels are showing — those need the full width of the well."
        case .square:
            return "More room for text, and what the stacking modes fall back to anyway."
        }
    }

    var isRound: Bool { self == .round }
}

/// Where a new condition's colour comes from.
///
/// The default starts the palette over for every factor, so condition 1 is the same
/// familiar blue everywhere — harmless while each factor colours only its own line of
/// a well, but in the stacked label modes two factors sharing a hue put identical
/// rails in one well. The alternative promises every condition in the document its
/// own colour.
enum NewConditionColors: String, Codable, DisplayChoice {
    case perFactor
    case neverRepeat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .perFactor: return "Start the palette over per factor"
        case .neverRepeat: return "Never repeat a colour"
        }
    }

    var note: String {
        switch self {
        case .perFactor:
            return "Every factor's first condition is the same familiar blue. Two factors can share a colour — they never paint the same line of a well."
        case .neverRepeat:
            return "A new condition takes the first colour nothing else in the document is using: the twenty hues first, then lighter and darker takes of each."
        }
    }
}

/// Where everything the app remembers *outside* a document is kept.
///
/// Under XCTest this is a scratch domain rather than the real one. A test that changes a
/// setting normally puts it back, but a run killed before its cleanup cannot — which is
/// how a test once left someone's Overview outlines bright red at 3 pt. Tests should not
/// be able to reach the preferences of the app you actually use.
enum AppDefaults {
    static let store: UserDefaults = {
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        let name = "com.nettilor.playout.tests"
        guard let scratch = UserDefaults(suiteName: name) else { return .standard }
        // Cleared on the way in, so one run cannot inherit another's leftovers.
        scratch.removePersistentDomain(forName: name)
        return scratch
    }()
}

/// App-wide display settings, shared by every open document and remembered between
/// launches. Deliberately *not* part of `Layout`: this is how someone likes to look at
/// a plate, not a property of the experiment, and it should not travel in a `.plate`
/// file to a colleague who prefers otherwise.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var wellTextStyle: WellTextStyle {
        didSet {
            guard wellTextStyle != oldValue else { return }
            defaults.set(wellTextStyle.rawValue, forKey: Self.wellTextStyleKey)
        }
    }

    /// How strongly the band behind the active factor's line is tinted with its
    /// value's colour in All factors. An alpha over the neutral tile: at 1 the band
    /// is the colour itself and the block on it can only be told apart by its wall;
    /// the default is a tint that leaves the block its full colour and the ink legible.
    @Published var activeBandOpacity: Double {
        didSet {
            guard activeBandOpacity != oldValue else { return }
            defaults.set(activeBandOpacity, forKey: Self.activeBandOpacityKey)
        }
    }

    static let activeBandOpacityRange: ClosedRange<Double> = 0.1...1
    static let defaultActiveBandOpacity: Double = 0.42

    /// How long the block of colour heading each stacked line is, as a multiplier on
    /// the width the canvas computes from the well. A multiplier rather than a point
    /// value for the same reason the type size is one: the block follows the well,
    /// and the name beside it is measured against what the block leaves. Length and
    /// height are separate settings on purpose — a bar and a tile are different
    /// shapes, and one "size" could give only the same shape larger.
    @Published var stackBlockWidthScale: Double {
        didSet {
            guard stackBlockWidthScale != oldValue else { return }
            defaults.set(stackBlockWidthScale, forKey: Self.stackBlockWidthScaleKey)
        }
    }

    /// How tall that block is, as a multiplier on its share of the line. At 1 it is
    /// the 82% of the line it has always been; the top of the range is the whole line.
    @Published var stackBlockHeightScale: Double {
        didSet {
            guard stackBlockHeightScale != oldValue else { return }
            defaults.set(stackBlockHeightScale, forKey: Self.stackBlockHeightScaleKey)
        }
    }

    static let stackBlockWidthScaleRange: ClosedRange<Double> = 0.5...2
    static let stackBlockHeightScaleRange: ClosedRange<Double> = 0.4...1.2

    /// Only read when a document opens: the sidebar toggle is the live control, and a
    /// preference that reached back into open windows would fight with it.
    @Published var newDocumentWellShape: WellShape {
        didSet {
            guard newDocumentWellShape != oldValue else { return }
            defaults.set(newDocumentWellShape.rawValue, forKey: Self.wellShapeKey)
        }
    }

    @Published var newConditionColors: NewConditionColors {
        didSet {
            guard newConditionColors != oldValue else { return }
            defaults.set(newConditionColors.rawValue, forKey: Self.newConditionColorsKey)
        }
    }

    /// The fill for wells with no value, as a hex string — or nil for the default,
    /// which follows light and dark mode. Stored as "no opinion" rather than as a
    /// copy of the default colour, so Reset genuinely restores default *behaviour*:
    /// a frozen copy would stop following the appearance the moment it was written.
    @Published var emptyWellColorHex: String? {
        didSet {
            guard emptyWellColorHex != oldValue else { return }
            if let hex = emptyWellColorHex {
                defaults.set(hex, forKey: Self.emptyWellColorKey)
            } else {
                defaults.removeObject(forKey: Self.emptyWellColorKey)
            }
        }
    }

    /// The canvas board's background — nil for the default, which follows light and dark
    /// mode. Stored as "no opinion" rather than a copy of the default, so Reset restores
    /// the *behaviour* and not a frozen colour.
    @Published var canvasBackgroundColorHex: String? {
        didSet {
            guard canvasBackgroundColorHex != oldValue else { return }
            if let hex = canvasBackgroundColorHex {
                defaults.set(hex, forKey: Self.canvasBackgroundColorKey)
            } else {
                defaults.removeObject(forKey: Self.canvasBackgroundColorKey)
            }
        }
    }

    /// The colour of the Overview block outlines — nil for the default, which follows
    /// light and dark mode the way the well ink does. Stored as "no opinion" rather
    /// than as a copy of the default, for the same reason the empty-well colour is.
    @Published var groupOutlineColorHex: String? {
        didSet {
            guard groupOutlineColorHex != oldValue else { return }
            if let hex = groupOutlineColorHex {
                defaults.set(hex, forKey: Self.groupOutlineColorKey)
            } else {
                defaults.removeObject(forKey: Self.groupOutlineColorKey)
            }
        }
    }

    /// How heavy those outlines are, in points. An absolute width rather than a
    /// multiplier: unlike the label sizes, this one is not solved against anything —
    /// what you ask for is what is drawn, up to the cap a dense plate imposes.
    @Published var groupOutlineThickness: Double {
        didSet {
            guard groupOutlineThickness != oldValue else { return }
            defaults.set(groupOutlineThickness, forKey: Self.groupOutlineThicknessKey)
        }
    }

    static let groupOutlineThicknessRange: ClosedRange<Double> = 0.5...4
    static let defaultGroupOutlineThickness: Double = 1.5

    /// The plate's typeface — nil for the system font. Scoped to the canvas (wells,
    /// headers, the line key) and to what the canvas renders: exports and print. The
    /// window's own controls keep the system font; refonting macOS chrome is neither
    /// possible nor a kindness.
    @Published var canvasFontFamily: String? {
        didSet {
            guard canvasFontFamily != oldValue else { return }
            if let family = canvasFontFamily {
                defaults.set(family, forKey: Self.canvasFontFamilyKey)
            } else {
                defaults.removeObject(forKey: Self.canvasFontFamilyKey)
            }
        }
    }

    /// A multiplier on every text size the canvas computes, not a point size: label
    /// sizes are continuous functions of the cell size and the fitting is measured,
    /// so an absolute size would fight both. Clamped on load to what stays usable.
    @Published var canvasFontScale: Double {
        didSet {
            guard canvasFontScale != oldValue else { return }
            defaults.set(canvasFontScale, forKey: Self.canvasFontScaleKey)
        }
    }

    /// Whether a plate picks one type size for all of its wells — the largest at which
    /// the longest name still fits — instead of shrinking each label on its own.
    ///
    /// Off by default: it changes how every existing document looks, and the per-label
    /// fit is what the app has always done. On, it only ever shrinks; the size above is
    /// still the ceiling.
    @Published var fitTextToWells: Bool {
        didSet {
            guard fitTextToWells != oldValue else { return }
            defaults.set(fitTextToWells, forKey: Self.fitTextToWellsKey)
        }
    }

    /// Whether each factor row in the sidebar carries its number of conditions at the
    /// trailing edge, the way condition rows carry their well count. Off by default:
    /// the count is one click away, and the sidebar earns its calm.
    @Published var showFactorConditionCounts: Bool {
        didSet {
            guard showFactorConditionCounts != oldValue else { return }
            defaults.set(showFactorConditionCounts, forKey: Self.factorConditionCountsKey)
        }
    }

    /// Whether launching the app may look at GitHub for a newer release — at most once
    /// a day, silently unless there is one. On by default; switched from the app menu
    /// beside "Check for Updates…" rather than from ⌘,, whose window has no room left
    /// for a seventh section.
    @Published var checkForUpdatesAutomatically: Bool {
        didSet {
            guard checkForUpdatesAutomatically != oldValue else { return }
            defaults.set(checkForUpdatesAutomatically, forKey: Self.checkForUpdatesKey)
        }
    }

    /// Every font the canvas draws with comes from here, so the family choice cannot
    /// miss a label. An uninstalled family falls back to the system font rather than
    /// to a crash or to Helvetica-by-surprise.
    func canvasFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard let family = canvasFontFamily else {
            return .systemFont(ofSize: size, weight: weight)
        }
        let coarse: Int
        switch weight {
        case .bold, .heavy, .black: coarse = 9
        case .semibold: coarse = 8
        case .medium: coarse = 6
        default: coarse = 5
        }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: coarse, size: size)
            ?? .systemFont(ofSize: size, weight: weight)
    }

    /// The chosen empty-well colour as a colour, or nil when the default is in force.
    var customEmptyWellColor: NSColor? {
        emptyWellColorHex.flatMap { NSColor(hex: $0) }
    }

    /// The empty-well fill, resolved: the custom colour if one is set, otherwise the
    /// appearance-following default the canvas has always used. Export keeps its
    /// slightly fainter default so paper stays clean; a chosen colour is a chosen
    /// colour, everywhere.
    func emptyWellFill(exportMode: Bool) -> NSColor {
        if let hex = emptyWellColorHex, let custom = NSColor(hex: hex) { return custom }
        return NSColor.quaternaryLabelColor.withAlphaComponent(exportMode ? 0.10 : 0.13)
    }

    /// The board's background, resolved. Unlike the plate, the board is a surface you
    /// look *at* rather than through, so a chosen colour is used exactly as chosen.
    var canvasBackground: NSColor {
        canvasBackgroundColorHex.flatMap { NSColor(hex: $0) } ?? .underPageBackgroundColor
    }

    /// The board's dot grid, which has to stay visible on whatever the background is —
    /// so it is drawn from the background's own contrasting ink rather than a fixed grey.
    var canvasGrid: NSColor {
        canvasBackground.contrastingLabelColor.withAlphaComponent(0.22)
    }

    /// The pen for the Overview block outlines. A chosen colour is used as it is, as
    /// everywhere else; the default is ink at a weight that reads over a pale tile and
    /// a dark one, a shade firmer on paper where there is no backlight to help it.
    func groupOutlineColor(exportMode: Bool) -> NSColor {
        if let hex = groupOutlineColorHex, let custom = NSColor(hex: hex) { return custom }
        return NSColor.labelColor.withAlphaComponent(exportMode ? 0.9 : 0.75)
    }

    /// The chosen thickness, capped against the cell: at 1536 wells a 4pt line would
    /// leave nothing of the well it was drawn round.
    func groupOutlineWidth(cell: CGFloat) -> CGFloat {
        min(CGFloat(groupOutlineThickness), max(0.5, cell * 0.25))
    }

    private let defaults: UserDefaults
    private static let wellTextStyleKey = "wellTextStyle"
    private static let activeBandOpacityKey = "activeBandOpacity"
    private static let stackBlockWidthScaleKey = "stackBlockWidthScale"
    private static let stackBlockHeightScaleKey = "stackBlockHeightScale"
    private static let wellShapeKey = "newDocumentWellShape"
    private static let newConditionColorsKey = "newConditionColors"
    private static let emptyWellColorKey = "emptyWellColorHex"
    private static let canvasBackgroundColorKey = "canvasBackgroundColorHex"
    private static let groupOutlineColorKey = "groupOutlineColorHex"
    private static let groupOutlineThicknessKey = "groupOutlineThickness"
    private static let canvasFontFamilyKey = "canvasFontFamily"
    private static let canvasFontScaleKey = "canvasFontScale"
    private static let fitTextToWellsKey = "fitTextToWells"
    private static let factorConditionCountsKey = "showFactorConditionCounts"
    private static let checkForUpdatesKey = "checkForUpdatesAutomatically"

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        // Decoded leniently, like the document's own display settings: a value written
        // by a newer build should fall back rather than refuse to launch.
        wellTextStyle = defaults.string(forKey: Self.wellTextStyleKey)
            .flatMap(WellTextStyle.init(rawValue:)) ?? .automatic
        let storedOpacity = defaults.object(forKey: Self.activeBandOpacityKey) as? Double
            ?? Self.defaultActiveBandOpacity
        activeBandOpacity = min(
            max(storedOpacity, Self.activeBandOpacityRange.lowerBound),
            Self.activeBandOpacityRange.upperBound
        )
        stackBlockWidthScale = Self.clamped(
            defaults.object(forKey: Self.stackBlockWidthScaleKey) as? Double ?? 1,
            to: Self.stackBlockWidthScaleRange
        )
        stackBlockHeightScale = Self.clamped(
            defaults.object(forKey: Self.stackBlockHeightScaleKey) as? Double ?? 1,
            to: Self.stackBlockHeightScaleRange
        )
        newDocumentWellShape = defaults.string(forKey: Self.wellShapeKey)
            .flatMap(WellShape.init(rawValue:)) ?? .round
        newConditionColors = defaults.string(forKey: Self.newConditionColorsKey)
            .flatMap(NewConditionColors.init(rawValue:)) ?? .perFactor
        // Validated here rather than at every read: garbage in the store behaves as
        // "no opinion", not as a black well or a crash.
        emptyWellColorHex = defaults.string(forKey: Self.emptyWellColorKey)
            .flatMap { NSColor(hex: $0) != nil ? $0 : nil }
        canvasBackgroundColorHex = defaults.string(forKey: Self.canvasBackgroundColorKey)
            .flatMap { NSColor(hex: $0) != nil ? $0 : nil }
        groupOutlineColorHex = defaults.string(forKey: Self.groupOutlineColorKey)
            .flatMap { NSColor(hex: $0) != nil ? $0 : nil }
        let storedThickness = defaults.object(forKey: Self.groupOutlineThicknessKey) as? Double
            ?? Self.defaultGroupOutlineThickness
        groupOutlineThickness = min(
            max(storedThickness, Self.groupOutlineThicknessRange.lowerBound),
            Self.groupOutlineThicknessRange.upperBound
        )
        canvasFontFamily = defaults.string(forKey: Self.canvasFontFamilyKey)
            .flatMap { $0.isEmpty ? nil : $0 }
        let storedScale = defaults.object(forKey: Self.canvasFontScaleKey) as? Double ?? 1.0
        canvasFontScale = min(max(storedScale, 0.7), 1.8)
        fitTextToWells = defaults.object(forKey: Self.fitTextToWellsKey) as? Bool ?? false
        showFactorConditionCounts = defaults.object(forKey: Self.factorConditionCountsKey) as? Bool ?? false
        checkForUpdatesAutomatically = defaults.object(forKey: Self.checkForUpdatesKey) as? Bool ?? true
    }

    /// Clamped on load, like every slider value here: a stray number in the store
    /// should land at the end of the range, not off the plate.
    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    func resetToDefaults() {
        wellTextStyle = .automatic
        activeBandOpacity = Self.defaultActiveBandOpacity
        stackBlockWidthScale = 1
        stackBlockHeightScale = 1
        newDocumentWellShape = .round
        newConditionColors = .perFactor
        emptyWellColorHex = nil
        canvasBackgroundColorHex = nil
        groupOutlineColorHex = nil
        groupOutlineThickness = Self.defaultGroupOutlineThickness
        canvasFontFamily = nil
        canvasFontScale = 1.0
        fitTextToWells = false
        showFactorConditionCounts = false
        checkForUpdatesAutomatically = true
    }
}

extension NSColor {
    /// The ink for a label drawn on this colour, under the chosen style. Named `ink`
    /// rather than `labelColor`, which would collide with `NSColor.labelColor` and
    /// resolve to the wrong one at every call site.
    func labelInk(_ style: WellTextStyle) -> NSColor {
        style.fixedInk ?? contrastingLabelColor
    }
}

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

/// How the marker on the active factor's line is filled.
///
/// It exists because that rail always *is* the well's own colour — both come from the
/// factor being painted — so left alone it is invisible. Two ways out: ignore the
/// colour and use the label's ink, or keep the colour and take it far darker.
enum ActiveMarkerStyle: String, Codable, DisplayChoice {
    case matchLabel
    case deeperShade

    var id: String { rawValue }

    var label: String {
        switch self {
        case .matchLabel: return "Match the label"
        case .deeperShade: return "Darker shade of the well"
        }
    }

    var note: String {
        switch self {
        case .matchLabel:
            return "A plain marker in the same colour as the text, so the active line reads the same way on every condition."
        case .deeperShade:
            return "Keeps the condition's own colour, taken far enough down to stand out against the well it sits on."
        }
    }
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

    @Published var activeMarkerStyle: ActiveMarkerStyle {
        didSet {
            guard activeMarkerStyle != oldValue else { return }
            defaults.set(activeMarkerStyle.rawValue, forKey: Self.activeMarkerStyleKey)
        }
    }

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

    private let defaults: UserDefaults
    private static let wellTextStyleKey = "wellTextStyle"
    private static let activeMarkerStyleKey = "activeMarkerStyle"
    private static let wellShapeKey = "newDocumentWellShape"
    private static let newConditionColorsKey = "newConditionColors"
    private static let emptyWellColorKey = "emptyWellColorHex"
    private static let canvasFontFamilyKey = "canvasFontFamily"
    private static let canvasFontScaleKey = "canvasFontScale"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Decoded leniently, like the document's own display settings: a value written
        // by a newer build should fall back rather than refuse to launch.
        wellTextStyle = defaults.string(forKey: Self.wellTextStyleKey)
            .flatMap(WellTextStyle.init(rawValue:)) ?? .automatic
        activeMarkerStyle = defaults.string(forKey: Self.activeMarkerStyleKey)
            .flatMap(ActiveMarkerStyle.init(rawValue:)) ?? .matchLabel
        newDocumentWellShape = defaults.string(forKey: Self.wellShapeKey)
            .flatMap(WellShape.init(rawValue:)) ?? .round
        newConditionColors = defaults.string(forKey: Self.newConditionColorsKey)
            .flatMap(NewConditionColors.init(rawValue:)) ?? .perFactor
        // Validated here rather than at every read: garbage in the store behaves as
        // "no opinion", not as a black well or a crash.
        emptyWellColorHex = defaults.string(forKey: Self.emptyWellColorKey)
            .flatMap { NSColor(hex: $0) != nil ? $0 : nil }
        canvasFontFamily = defaults.string(forKey: Self.canvasFontFamilyKey)
            .flatMap { $0.isEmpty ? nil : $0 }
        let storedScale = defaults.object(forKey: Self.canvasFontScaleKey) as? Double ?? 1.0
        canvasFontScale = min(max(storedScale, 0.7), 1.8)
    }

    func resetToDefaults() {
        wellTextStyle = .automatic
        activeMarkerStyle = .matchLabel
        newDocumentWellShape = .round
        newConditionColors = .perFactor
        emptyWellColorHex = nil
        canvasFontFamily = nil
        canvasFontScale = 1.0
    }
}

extension NSColor {
    /// The ink for a label drawn on this colour, under the chosen style. Named `ink`
    /// rather than `labelColor`, which would collide with `NSColor.labelColor` and
    /// resolve to the wrong one at every call site.
    func labelInk(_ style: WellTextStyle) -> NSColor {
        style.fixedInk ?? contrastingLabelColor
    }

    /// This colour pushed hard away from its own lightness, keeping its hue: the marker
    /// for a condition, drawn on a well already filled with that condition's colour.
    ///
    /// The direction is chosen from the colour rather than fixed. Almost everything the
    /// palette offers is light enough to go darker, but a dark custom colour has no room
    /// below it and has to go the other way, or the marker vanishes into its own well.
    /// Saturation rises either way, so the result deepens or brightens rather than
    /// sliding towards grey or towards white.
    ///
    /// It goes further than the swatch grid's darkest step, which stops where a
    /// near-black label would stop being readable — nothing is written on a marker, so
    /// that floor does not apply here.
    var contrastingShade: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let goDarker = perceivedLuminance > 0.16
        return NSColor(
            hue: h,
            saturation: min(1, s * (goDarker ? 1.2 : 0.85)),
            brightness: goDarker ? max(0.20, b * 0.5) : min(1, max(b * 1.9, b + 0.4)),
            alpha: 1
        )
    }
}

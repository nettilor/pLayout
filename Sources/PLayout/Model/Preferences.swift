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

    private let defaults: UserDefaults
    private static let wellTextStyleKey = "wellTextStyle"
    private static let activeMarkerStyleKey = "activeMarkerStyle"
    private static let wellShapeKey = "newDocumentWellShape"

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
    }

    func resetToDefaults() {
        wellTextStyle = .automatic
        activeMarkerStyle = .matchLabel
        newDocumentWellShape = .round
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

import AppKit

enum Palette {
    /// Categorical colours chosen for separation at small well sizes.
    ///
    /// Three of these are Tableau's own hues lifted in brightness — and nothing else —
    /// until near-black text clears `wellTextFloor` on them: the blue, the brown and
    /// the grey were the only ones dark enough to have forced a white label.
    static let categorical: [String] = [
        "#5889BC", "#F28E2B", "#59A14F", "#E15759", "#B07AA1",
        "#76B7B2", "#EDC948", "#FF9DA7", "#A17962", "#8CD17D",
        "#A0CBE8", "#FFBE7D", "#D4A6C8", "#499894", "#D7B5A6",
        "#B6992D", "#86BCB6", "#FABFD2", "#928785", "#F1CE63",
    ]

    static func color(at index: Int) -> String {
        categorical[((index % categorical.count) + categorical.count) % categorical.count]
    }

    /// Hex normalised the way `matches` compares, so it can live in a `Set`.
    static func normalized(_ hex: String) -> String {
        NSColor(hex: hex)?.hexString ?? hex.uppercased()
    }

    /// The first colour not already in `used`: the categorical hues in order, then a
    /// take on each from its shade column once the plain hues are spoken for — darker
    /// rows first, because a darker take separates from its own base far better than a
    /// tint does. About a hundred colours before it gives up and falls back to the
    /// plain per-factor cycle, which no real document reaches.
    static func firstColor(avoiding used: Set<String>, fallbackIndex: Int) -> String {
        for hex in categorical where !used.contains(normalized(hex)) { return hex }
        for row in [3, 1, 4, 0] {
            for hue in categorical {
                let candidate = shades(of: hue)[row]
                if !used.contains(normalized(candidate)) { return candidate }
            }
        }
        return color(at: fallbackIndex)
    }

    // MARK: - The swatch grid

    /// A set of hues offered in the colour popover, one per column of the grid.
    ///
    /// The last column of every family is a neutral: a control or an untreated arm
    /// wants grey, and it should not depend on which family happens to be showing.
    /// Each hue is also the *base row* of its column verbatim, which is what makes a
    /// colour the app assigned itself show up as selected rather than as "custom".
    enum Family: String, CaseIterable, Identifiable {
        case standard
        case colourBlind
        case muted

        var id: String { rawValue }

        var label: String {
            switch self {
            case .standard: return "Standard"
            case .colourBlind: return "Colour-blind"
            case .muted: return "Muted"
            }
        }

        var note: String {
            switch self {
            case .standard:
                return "Default hues for new conditions."
            case .colourBlind:
                return "Okabe–Ito: stays separable with red/green colour blindness."
            case .muted:
                return "Softer tints, for a plate that is mostly full."
            }
        }

        var hues: [String] {
            switch self {
            case .standard:
                return ["#5889BC", "#F28E2B", "#59A14F", "#E15759",
                        "#B07AA1", "#76B7B2", "#EDC948", "#928785"]
            case .colourBlind:
                // Okabe–Ito, with its blue and its black lifted in brightness to clear
                // `wellTextFloor`. Hue and saturation are untouched, and the separation
                // test confirms the set still earns the name.
                return ["#008AD7", "#56B4E9", "#009E73", "#F0E442",
                        "#E69F00", "#D86000", "#CC79A7", "#8B8B8B"]
            case .muted:
                return ["#A0CBE8", "#FFBE7D", "#8CD17D", "#FF9DA7",
                        "#D4A6C8", "#86BCB6", "#F1CE63", "#BAB0AC"]
            }
        }
    }

    /// One column of the swatch grid: steps of a single hue, lightest first, with the
    /// base colour itself in the middle so picking "the same blue, a bit darker" does
    /// not mean nudging a colour wheel.
    ///
    /// Unlike `ramp`, which is tuned for a dilution series and is load-bearing for
    /// series fill, this exists only to be looked at and clicked.
    static func shades(of baseHex: String, count: Int = 5) -> [String] {
        guard count > 0 else { return [] }
        guard let base = NSColor(hex: baseHex)?.usingColorSpace(.sRGB) else {
            return Array(repeating: baseHex, count: count)
        }
        guard count > 1 else { return [base.hexString] }

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // A tint is recognisable because of its hue. A grey has none, so it has to stay
        // dark enough not to be read as an empty well — those are drawn at about
        // #DEDEDE — and a paler grey swatch would paint a well that looks unpainted.
        // The threshold is 0.15 rather than 0, because Tableau's greys are warm ones
        // sitting around 0.08–0.09 saturation and have to count as grey here.
        let ceiling: CGFloat = s < 0.15 ? 0.80 : 0.95
        // Pure black and pure white have no headroom to ramp into, so the anchor is
        // pulled just inside the range for them. A *saturated* colour at full brightness
        // has headroom regardless — it lightens by losing saturation, not by getting
        // brighter — so the upper pull applies only to greys, or vivid bases like
        // #FF9DA7 would come back a shade off and stop matching their own swatch.
        let anchor = s < 0.15 ? min(max(b, 0.12), 0.94) : max(b, 0.12)
        let middle = (count - 1) / 2
        // The ends are interpolated towards, never clamped to, and each is held at least
        // one visible step away: clamping put two rows of Tableau's light greys at the
        // identical hex, a step that looked like it did nothing.
        let minimumStep: CGFloat = 0.03
        let lightest = max(
            anchor + minimumStep * CGFloat(max(middle, 1)),
            min(ceiling, max(0.88, anchor + 0.22))
        )
        // The dark end stops where near-black text stops being legible on it. Measured
        // at the saturation the darkest step actually uses, because saturation moves
        // luminance too — which is also why the dark steps no longer deepen saturation
        // as they used to: the extra richness cost exactly the headroom the floor needs.
        // Clamped below the anchor so the floor can never invert or collapse the ramp.
        let darkestSaturation = s
        let readable = brightness(
            hue: h, saturation: darkestSaturation, clearing: wellTextFloor
        )
        let darkest = min(
            anchor - minimumStep * CGFloat(max(count - 1 - middle, 1)),
            max(min(0.42, anchor * 0.62), readable)
        )

        return (0..<count).map { i in
            if i == middle {
                return anchor == b
                    ? base.hexString
                    : NSColor(hue: h, saturation: s, brightness: anchor, alpha: 1).hexString
            }
            if i < middle {
                let u = CGFloat(middle - i) / CGFloat(middle)
                return NSColor(
                    hue: h,
                    // Holds more of the hue than a plain tint would: at the light end
                    // the colour is all that separates the swatch from an empty well.
                    saturation: s * (1 - 0.35 * u),
                    brightness: anchor + (lightest - anchor) * u,
                    alpha: 1
                ).hexString
            }
            let u = CGFloat(i - middle) / CGFloat(count - 1 - middle)
            return NSColor(
                hue: h,
                saturation: darkestSaturation,
                brightness: anchor - (anchor - darkest) * u,
                alpha: 1
            ).hexString
        }
    }

    // MARK: - Keeping well text one colour

    /// Well labels are always the same near-black, because a label that flips to white
    /// on some conditions and not others reads as a glitch rather than as contrast.
    /// Holding that means never *offering* a colour too dark to carry it.
    ///
    /// WCAG puts 4.5:1 against black at relative luminance 0.175, and this sits just
    /// above it. The *base* hues are lifted further, to about 0.22, because the two
    /// steps below a base in its shade column have to fit underneath it and still land
    /// above this line — a base sitting exactly on the floor leaves them nowhere to go.
    static let wellTextFloor: CGFloat = 0.19

    /// The brightness at which this hue first clears `luminance`, by bisection.
    /// Relative luminance rises monotonically with brightness at a fixed hue and
    /// saturation, but *how fast* is entirely hue-dependent — a yellow clears the floor
    /// at a brightness a blue is nowhere near — so there is no closed form to use here.
    static func brightness(
        hue h: CGFloat, saturation s: CGFloat, clearing luminance: CGFloat
    ) -> CGFloat {
        func lum(_ v: CGFloat) -> CGFloat {
            NSColor(hue: h, saturation: s, brightness: v, alpha: 1).perceivedLuminance
        }
        guard lum(1) > luminance else { return 1 }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            if lum(mid) < luminance { lo = mid } else { hi = mid }
        }
        return hi
    }

    /// Hex comparison that survives case and a missing "#", so a hand-edited file
    /// still lights up the swatch it is actually using.
    static func matches(_ a: String, _ b: String) -> Bool {
        guard let x = NSColor(hex: a)?.hexString, let y = NSColor(hex: b)?.hexString else {
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        return x == y
    }

    /// Light-to-dark ramp of a single hue, for numeric factors (dose series etc.).
    static func ramp(count: Int, baseHex: String) -> [String] {
        guard count > 0 else { return [] }
        let base = NSColor(hex: baseHex) ?? NSColor(hex: "#4E79A7")!
        guard let hsb = base.usingColorSpace(.sRGB) else { return (0..<count).map { _ in baseHex } }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if count == 1 { return [baseHex] }
        // Same floor as the swatch grid: the deep end of a dilution series still has to
        // carry the same near-black label as every other well.
        let deepest = max(
            min(b, 0.92), 0.45,
            brightness(hue: h, saturation: max(s, 0.55), clearing: wellTextFloor)
        )
        return (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            let sat = 0.18 + (max(s, 0.55) - 0.18) * t
            let bri = 0.98 - (0.98 - deepest) * t
            let c = NSColor(hue: h, saturation: sat, brightness: bri, alpha: 1)
            return c.hexString
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#808080" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Relative luminance, used to pick black or white label text on a well.
    var perceivedLuminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    /// Near-black on anything the app will actually hand out — every palette colour and
    /// every shade is floored at `Palette.wellTextFloor` precisely so this never flips.
    /// A label that switches to white on some conditions and not others reads as a
    /// glitch, not as contrast.
    ///
    /// White survives only as a floor for a deliberately near-black custom colour,
    /// where black text would not be readable at all. The threshold is the real WCAG
    /// 4.5:1 limit, not the far more cautious 0.42 this used to use — that one was
    /// flipping perfectly legible mid-tones like `#4E79A7` (4.6:1) to white.
    var contrastingLabelColor: NSColor {
        perceivedLuminance > 0.175 ? NSColor.black.withAlphaComponent(0.85) : NSColor.white
    }
}

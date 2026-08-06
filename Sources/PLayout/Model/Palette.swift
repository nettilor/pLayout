import AppKit

enum Palette {
    /// Categorical colours chosen for separation at small well sizes.
    static let categorical: [String] = [
        "#4E79A7", "#F28E2B", "#59A14F", "#E15759", "#B07AA1",
        "#76B7B2", "#EDC948", "#FF9DA7", "#9C755F", "#8CD17D",
        "#A0CBE8", "#FFBE7D", "#D4A6C8", "#499894", "#D7B5A6",
        "#B6992D", "#86BCB6", "#FABFD2", "#79706E", "#F1CE63",
    ]

    static func color(at index: Int) -> String {
        categorical[((index % categorical.count) + categorical.count) % categorical.count]
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
                return ["#4E79A7", "#F28E2B", "#59A14F", "#E15759",
                        "#B07AA1", "#76B7B2", "#EDC948", "#79706E"]
            case .colourBlind:
                return ["#0072B2", "#56B4E9", "#009E73", "#F0E442",
                        "#E69F00", "#D55E00", "#CC79A7", "#666666"]
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
        let darkest = min(
            anchor - minimumStep * CGFloat(max(count - 1 - middle, 1)),
            min(0.42, anchor * 0.62)
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
                saturation: min(1, s * (1 + 0.15 * u)),
                brightness: anchor - (anchor - darkest) * u,
                alpha: 1
            ).hexString
        }
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
        return (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            let sat = 0.18 + (max(s, 0.55) - 0.18) * t
            let bri = 0.98 - (0.98 - max(min(b, 0.92), 0.45)) * t
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

    var contrastingLabelColor: NSColor {
        perceivedLuminance > 0.42 ? NSColor.black.withAlphaComponent(0.82) : NSColor.white
    }
}

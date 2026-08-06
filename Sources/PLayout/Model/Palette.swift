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

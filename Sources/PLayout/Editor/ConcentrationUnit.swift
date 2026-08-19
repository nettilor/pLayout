import Foundation

/// Just enough of a unit to know whether two concentrations can be divided.
///
/// Deliberately not a units library. Volumes are µL everywhere in this app, and the only
/// question ever asked here is "how many of the dose's unit make one of the stock's?" —
/// so a unit is a family and a scale into that family's base, and everything else is
/// left alone rather than guessed at.
struct ConcentrationUnit: Equatable {

    enum Family: Equatable {
        /// Base M. `mM`, `µM`, `nM`, and the `mol/L` spellings.
        case molar
        /// Base g/L. `mg/mL`, `µg/mL`, `ng/mL`, and the `/L` spellings.
        case massPerVolume
        /// Anything this app does not recognise — `IU/mL`, `% v/v`, a blank field.
        /// Not an error: two of these are assumed to match, which is nearly always
        /// what a lab that writes its own unit means.
        case unknown
    }

    var family: Family
    /// Multiplier into the family's base. `mM` is 0.001 of an M.
    var scale: Double
    /// As typed, trimmed — kept so a warning can quote the user's own words back.
    var text: String

    /// What one unit is worth in another, and how much that answer can be trusted.
    enum Conversion: Equatable {
        /// Both units are understood and comparable.
        case exact(Double)
        /// At least one unit is not understood, so they are taken to be the same unit.
        /// The caller warns; it does not refuse, or a lab with its own notation would
        /// be locked out of the feature entirely.
        case assumed(Double)
        /// Both understood, and not comparable — µM against mg/mL needs a molecular
        /// weight the document does not have. Refused rather than guessed: a
        /// plausible-looking wrong volume on a bench sheet is the worst output there is.
        case incompatible
    }

    /// How many of `other`'s unit make one of this one. A stock in mM against doses in
    /// µM converts by 1000.
    func conversion(to other: ConcentrationUnit) -> Conversion {
        if family == .unknown || other.family == .unknown {
            // Identical text is certainly the same unit, however exotic it is, so that
            // case is exact and silent.
            return Self.normalized(text) == Self.normalized(other.text)
                ? .exact(1) : .assumed(1)
        }
        guard family == other.family else { return .incompatible }
        guard other.scale > 0 else { return .incompatible }
        return .exact(scale / other.scale)
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> ConcentrationUnit {
        let raw = text.trimmingCharacters(in: .whitespaces)
        let key = normalized(raw)
        guard !key.isEmpty else { return ConcentrationUnit(family: .unknown, scale: 1, text: raw) }

        // A slash means "amount per volume", which covers mol/L and g/L in one rule and
        // gets every prefix combination — nmol/mL, µg/L — without a lookup table.
        if let slash = key.firstIndex(of: "/") {
            let top = String(key[key.startIndex..<slash])
            let bottom = String(key[key.index(after: slash)...])
            guard let volume = scale(of: bottom, unit: "l") else {
                return ConcentrationUnit(family: .unknown, scale: 1, text: raw)
            }
            if let moles = scale(of: top, unit: "mol") {
                return ConcentrationUnit(family: .molar, scale: moles / volume, text: raw)
            }
            if let grams = scale(of: top, unit: "g") {
                return ConcentrationUnit(family: .massPerVolume, scale: grams / volume, text: raw)
            }
            return ConcentrationUnit(family: .unknown, scale: 1, text: raw)
        }

        // Bare molarity: M, mM, µM, nM, pM.
        if let molar = scale(of: key, unit: "m") {
            return ConcentrationUnit(family: .molar, scale: molar, text: raw)
        }
        return ConcentrationUnit(family: .unknown, scale: 1, text: raw)
    }

    /// Lower-cased, spaces removed, and **both** micro signs folded to `u` — U+00B5 MICRO
    /// SIGN is what a Mac keyboard types with ⌥M and U+03BC GREEK SMALL LETTER MU is what
    /// arrives pasted out of a paper, and they are different characters.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{00B5}", with: "u")
            .replacingOccurrences(of: "\u{03BC}", with: "u")
            .filter { !$0.isWhitespace }
    }

    /// SI prefixes, as a multiplier on the unit that follows them.
    private static let prefixes: [String: Double] = [
        "": 1, "k": 1e3, "d": 1e-1, "c": 1e-2, "m": 1e-3, "u": 1e-6, "n": 1e-9, "p": 1e-12,
    ]

    /// The multiplier for `token` when it is `unit` carrying an SI prefix, or nil when it
    /// is not that unit at all.
    private static func scale(of token: String, unit: String) -> Double? {
        guard token.hasSuffix(unit) else { return nil }
        let prefix = String(token.dropLast(unit.count))
        return prefixes[prefix]
    }
}

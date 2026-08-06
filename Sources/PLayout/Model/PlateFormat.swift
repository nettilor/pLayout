import Foundation

/// Physical shape of a microplate. Row/column counts follow ANSI/SLAS standards.
struct PlateFormat: Codable, Hashable, Identifiable {
    var rows: Int
    var cols: Int

    var id: String { "\(rows)x\(cols)" }
    var wellCount: Int { rows * cols }
    var name: String { "\(wellCount)-well" }
    var detailedName: String { "\(wellCount)-well  (\(rows)×\(cols))" }

    static let well6 = PlateFormat(rows: 2, cols: 3)
    static let well12 = PlateFormat(rows: 3, cols: 4)
    static let well24 = PlateFormat(rows: 4, cols: 6)
    static let well48 = PlateFormat(rows: 6, cols: 8)
    static let well96 = PlateFormat(rows: 8, cols: 12)
    static let well384 = PlateFormat(rows: 16, cols: 24)
    static let well1536 = PlateFormat(rows: 32, cols: 48)

    static let standard: [PlateFormat] = [
        .well6, .well12, .well24, .well48, .well96, .well384, .well1536,
    ]

    /// Bounds for user-defined plates. The ceiling keeps rendering responsive and
    /// stays far inside Excel's sheet limits on export.
    static let rowRange = 1...64
    static let columnRange = 1...96

    var isStandard: Bool { Self.standard.contains(self) }

    init(rows: Int, cols: Int) {
        self.rows = min(max(rows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
        self.cols = min(max(cols, Self.columnRange.lowerBound), Self.columnRange.upperBound)
    }

    /// Clamped on the way in as well, so a hand-edited document can never produce a
    /// zero-sized plate that would divide by zero during layout.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rows: try container.decode(Int.self, forKey: .rows),
            cols: try container.decode(Int.self, forKey: .cols)
        )
    }

    func index(row: Int, col: Int) -> Int { row * cols + col }
    func row(of index: Int) -> Int { index / cols }
    func col(of index: Int) -> Int { index % cols }
    func contains(row: Int, col: Int) -> Bool {
        row >= 0 && row < rows && col >= 0 && col < cols
    }
}

enum WellNaming {
    /// 0 -> "A", 25 -> "Z", 26 -> "AA" (needed for 1536-well plates, which run A..AF).
    static func rowLabel(_ row: Int) -> String {
        guard row >= 0 else { return "?" }
        var out = ""
        var n = row
        repeat {
            out = String(UnicodeScalar(UInt8(65 + n % 26))) + out
            n = n / 26 - 1
        } while n >= 0
        return out
    }

    /// Inverse of `rowLabel`. Returns nil for anything that is not pure letters.
    static func rowIndex(_ label: String) -> Int? {
        let s = label.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty, s.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        var n = 0
        for ch in s.unicodeScalars {
            n = n * 26 + (Int(ch.value) - 64)
        }
        return n - 1
    }

    static func colLabel(_ col: Int, padded: Bool) -> String {
        padded ? String(format: "%02d", col + 1) : "\(col + 1)"
    }

    static func wellLabel(row: Int, col: Int, padded: Bool) -> String {
        rowLabel(row) + colLabel(col, padded: padded)
    }

    /// Parses "A1", "a01", "H12" into a position.
    static func parseWell(_ text: String) -> (row: Int, col: Int)? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let letters = s.prefix { $0.isLetter }
        let digits = s.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty,
              let row = rowIndex(String(letters)),
              let num = Int(digits), num >= 1
        else { return nil }
        return (row, num - 1)
    }
}

import Foundation

// MARK: - Level

/// One value a factor can take, e.g. "10 µM" or "HeLa".
struct Level: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorHex: String

    init(id: UUID = UUID(), name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

// MARK: - Factor

enum FactorKind: String, Codable, Hashable {
    case categorical
    case numeric
}

/// An independent variable painted onto the plate. A document may hold several,
/// so a single well can carry a cell line *and* a drug *and* a dose.
struct Factor: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: FactorKind = .categorical
    var unit: String = ""
    var levels: [Level] = []

    init(id: UUID = UUID(), name: String, kind: FactorKind = .categorical, unit: String = "", levels: [Level] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.unit = unit
        self.levels = levels
    }

    var displayName: String { unit.isEmpty ? name : "\(name) (\(unit))" }

    func level(id: UUID?) -> Level? {
        guard let id else { return nil }
        return levels.first { $0.id == id }
    }

    func level(named name: String) -> Level? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return levels.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == key }
    }

    func index(of id: UUID) -> Int? { levels.firstIndex { $0.id == id } }

    /// Adds a level with the given name if absent, returning its id either way.
    mutating func ensureLevel(named name: String) -> UUID {
        let clean = name.trimmingCharacters(in: .whitespaces)
        if let existing = level(named: clean) { return existing.id }
        let level = Level(name: clean, colorHex: Palette.color(at: levels.count))
        levels.append(level)
        return level.id
    }
}

// MARK: - Display

/// How much text each well carries. `.allFactors` is what makes a multi-factor
/// layout readable without hovering every well; `.overview` is that same stack with
/// nothing being painted, so the plate can be read rather than edited.
enum WellLabelMode: String, Codable, CaseIterable, Identifiable {
    case none
    case activeFactor
    case allFactors
    case overview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .activeFactor: return "Active factor"
        case .allFactors: return "All factors"
        case .overview: return "Overview"
        }
    }

    /// What the segmented picker shows: four full labels overflow a sidebar-width
    /// control, and "Text in wells" above it already supplies the missing noun.
    var shortLabel: String {
        switch self {
        case .none: return "None"
        case .activeFactor: return "Active"
        case .allFactors: return "All"
        case .overview: return "Overview"
        }
    }

    var showsText: Bool { self != .none }

    /// The modes that give every factor its own line inside the well.
    var stacksEveryFactor: Bool { self == .allFactors || self == .overview }

    /// Overview reads the plate instead of editing it: no factor is active, so
    /// clicking selects without painting and every well gets the same neutral tile.
    var isOverview: Bool { self == .overview }
}

// MARK: - Saved states

/// A bookmark of the experimental design — every factor and every plate — so a
/// combination can be tried out and abandoned. Deliberately stores the same fields
/// as `Layout` minus its own snapshot list, which is what keeps it from nesting.
struct LayoutSnapshot: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var savedAt: Date
    var factors: [Factor]
    var plates: [Plate]

    init(id: UUID = UUID(), name: String, savedAt: Date, factors: [Factor], plates: [Plate]) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.factors = factors
        self.plates = plates
    }
}

// MARK: - Plate

struct Plate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var format: PlateFormat
    /// factor id (string) -> per-well level id (string), indexed row-major. nil = unassigned.
    var assignments: [String: [String?]] = [:]

    init(id: UUID = UUID(), name: String, format: PlateFormat = .well96) {
        self.id = id
        self.name = name
        self.format = format
    }

    func levelID(factor: UUID, well: Int) -> UUID? {
        guard let column = assignments[factor.uuidString],
              well >= 0, well < column.count,
              let raw = column[well]
        else { return nil }
        return UUID(uuidString: raw)
    }

    mutating func setLevelID(_ level: UUID?, factor: UUID, well: Int) {
        guard well >= 0, well < format.wellCount else { return }
        var column = assignments[factor.uuidString] ?? []
        if column.count != format.wellCount {
            column = Self.resized(column, to: format.wellCount)
        }
        column[well] = level?.uuidString
        if column.contains(where: { $0 != nil }) {
            assignments[factor.uuidString] = column
        } else {
            assignments.removeValue(forKey: factor.uuidString)
        }
    }

    func assignedWellCount(factor: UUID, level: UUID) -> Int {
        guard let column = assignments[factor.uuidString] else { return 0 }
        let key = level.uuidString
        return column.reduce(0) { $0 + ($1 == key ? 1 : 0) }
    }

    /// Changes the plate size, keeping each well's values at the same row/column.
    mutating func changeFormat(to newFormat: PlateFormat) {
        guard newFormat != format else { return }
        var remapped: [String: [String?]] = [:]
        for (factorKey, column) in assignments {
            var fresh = [String?](repeating: nil, count: newFormat.wellCount)
            for row in 0..<min(format.rows, newFormat.rows) {
                for col in 0..<min(format.cols, newFormat.cols) {
                    let old = format.index(row: row, col: col)
                    guard old < column.count else { continue }
                    fresh[newFormat.index(row: row, col: col)] = column[old]
                }
            }
            if fresh.contains(where: { $0 != nil }) { remapped[factorKey] = fresh }
        }
        format = newFormat
        assignments = remapped
    }

    /// True when shrinking to `newFormat` would drop wells that currently hold a value.
    func formatChangeWouldLoseData(_ newFormat: PlateFormat) -> Bool {
        guard newFormat.rows < format.rows || newFormat.cols < format.cols else { return false }
        for column in assignments.values {
            for row in 0..<format.rows {
                for col in 0..<format.cols {
                    guard row >= newFormat.rows || col >= newFormat.cols else { continue }
                    let idx = format.index(row: row, col: col)
                    if idx < column.count, column[idx] != nil { return true }
                }
            }
        }
        return false
    }

    /// Forces every factor's column to match this plate's well count.
    mutating func normalizeAssignments() {
        for (key, column) in assignments {
            guard column.count != format.wellCount else { continue }
            let fixed = Self.resized(column, to: format.wellCount)
            if fixed.contains(where: { $0 != nil }) {
                assignments[key] = fixed
            } else {
                assignments.removeValue(forKey: key)
            }
        }
    }

    private static func resized(_ column: [String?], to count: Int) -> [String?] {
        if column.count == count { return column }
        if column.count > count { return Array(column.prefix(count)) }
        return column + [String?](repeating: nil, count: count - column.count)
    }
}

// MARK: - Layout (the document's value)

struct Layout: Codable, Hashable {
    var formatVersion: Int = 1
    var factors: [Factor] = []
    var plates: [Plate] = []
    var padWellLabels: Bool = false
    var wellLabelMode: WellLabelMode = .activeFactor
    /// Draws the plate on its side — rows across, columns down. Purely how it is shown:
    /// no well changes its id, its values or its place in the file. It lives with the
    /// document rather than in Preferences because exports and printing render the
    /// plate as displayed, so the orientation has to travel with the layout.
    var transposedView: Bool = false
    var snapshots: [LayoutSnapshot] = []
    var notes: String = ""

    /// Enough saved states to experiment freely, bounded so a document cannot grow
    /// without limit. The oldest is dropped once this is reached.
    static let maxSnapshots = 20

    init(
        formatVersion: Int = 1,
        factors: [Factor] = [],
        plates: [Plate] = [],
        padWellLabels: Bool = false,
        wellLabelMode: WellLabelMode = .activeFactor,
        transposedView: Bool = false,
        snapshots: [LayoutSnapshot] = [],
        notes: String = ""
    ) {
        self.formatVersion = formatVersion
        self.factors = factors
        self.plates = plates
        self.padWellLabels = padWellLabels
        self.wellLabelMode = wellLabelMode
        self.transposedView = transposedView
        self.snapshots = snapshots
        self.notes = notes
    }

    /// Written by hand rather than synthesized: Swift's generated decoder ignores
    /// stored-property defaults, so every new field would otherwise make previously
    /// saved documents fail to open with `keyNotFound`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        factors = try container.decodeIfPresent([Factor].self, forKey: .factors) ?? []
        plates = try container.decodeIfPresent([Plate].self, forKey: .plates) ?? []
        padWellLabels = try container.decodeIfPresent(Bool.self, forKey: .padWellLabels) ?? false
        // Decoded leniently so a file written by a newer build still opens here.
        wellLabelMode = (try? container.decodeIfPresent(WellLabelMode.self, forKey: .wellLabelMode))
            .flatMap { $0 } ?? .activeFactor
        transposedView = try container.decodeIfPresent(Bool.self, forKey: .transposedView) ?? false
        snapshots = try container.decodeIfPresent([LayoutSnapshot].self, forKey: .snapshots) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""

        // A hand-edited or truncated file can carry a well column that no longer
        // matches its plate; normalise once here so nothing downstream has to care.
        for index in plates.indices {
            plates[index].normalizeAssignments()
        }
    }

    static func starter() -> Layout {
        let factor = Factor(
            name: "Condition",
            levels: [
                Level(name: "Untreated", colorHex: Palette.color(at: 0)),
                Level(name: "Vehicle", colorHex: Palette.color(at: 1)),
                Level(name: "Treated", colorHex: Palette.color(at: 2)),
            ]
        )
        return Layout(factors: [factor], plates: [Plate(name: "Plate 1", format: .well96)])
    }

    func factor(id: UUID?) -> Factor? {
        guard let id else { return nil }
        return factors.first { $0.id == id }
    }

    func factorIndex(id: UUID?) -> Int? {
        guard let id else { return nil }
        return factors.firstIndex { $0.id == id }
    }

    /// Human-readable value of a factor at a well, or nil when unassigned.
    func valueName(plate: Int, factor: Factor, well: Int) -> String? {
        guard plates.indices.contains(plate) else { return nil }
        guard let levelID = plates[plate].levelID(factor: factor.id, well: well) else { return nil }
        return factor.level(id: levelID)?.name
    }

    /// Drops levels that no plate references any more.
    mutating func pruneUnusedLevels(factorID: UUID) {
        guard let fi = factorIndex(id: factorID) else { return }
        let used = Set(plates.flatMap { $0.assignments[factorID.uuidString] ?? [] }.compactMap { $0 })
        factors[fi].levels.removeAll { !used.contains($0.id.uuidString) }
    }

    mutating func removeLevel(_ levelID: UUID, from factorID: UUID) {
        guard let fi = factorIndex(id: factorID) else { return }
        factors[fi].levels.removeAll { $0.id == levelID }
        let key = levelID.uuidString
        for pi in plates.indices {
            guard var column = plates[pi].assignments[factorID.uuidString] else { continue }
            for i in column.indices where column[i] == key { column[i] = nil }
            if column.contains(where: { $0 != nil }) {
                plates[pi].assignments[factorID.uuidString] = column
            } else {
                plates[pi].assignments.removeValue(forKey: factorID.uuidString)
            }
        }
    }

    mutating func removeFactor(_ factorID: UUID) {
        factors.removeAll { $0.id == factorID }
        for pi in plates.indices {
            plates[pi].assignments.removeValue(forKey: factorID.uuidString)
        }
    }

    // MARK: - Saved states

    /// Bookmarks the design as it stands. Returns the number of old states dropped
    /// to stay inside `maxSnapshots`.
    @discardableResult
    mutating func captureSnapshot(at date: Date) -> Int {
        let used = Set(snapshots.map(\.name))
        var n = snapshots.count + 1
        while used.contains("State \(n)") { n += 1 }

        snapshots.append(
            LayoutSnapshot(name: "State \(n)", savedAt: date, factors: factors, plates: plates)
        )
        let excess = max(0, snapshots.count - Self.maxSnapshots)
        if excess > 0 { snapshots.removeFirst(excess) }
        return excess
    }

    /// Puts the design back to a saved state. Display settings and the saved-state
    /// list itself are left alone — reverting should not also change how you are
    /// looking at the plate, or throw away your other bookmarks.
    mutating func restoreSnapshot(_ id: UUID) -> Bool {
        guard let snapshot = snapshots.first(where: { $0.id == id }) else { return false }
        factors = snapshot.factors
        plates = snapshot.plates
        return true
    }

    mutating func renameSnapshot(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        snapshots[index].name = trimmed
    }

    mutating func removeSnapshot(_ id: UUID) {
        snapshots.removeAll { $0.id == id }
    }

    /// The saved state the design currently matches, if any — what tells the toolbar
    /// whether to show a filled bookmark. The newest match wins.
    func snapshotMatchingCurrentDesign() -> LayoutSnapshot? {
        snapshots.last { $0.factors == factors && $0.plates == plates }
    }

    /// Unique factor name so exported spreadsheet columns never collide.
    func uniqueFactorName(base: String) -> String {
        let existing = Set(factors.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var n = 2
        while existing.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    func uniquePlateName(base: String) -> String {
        let existing = Set(plates.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var n = 2
        while existing.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}

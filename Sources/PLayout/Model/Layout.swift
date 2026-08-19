import Foundation

// MARK: - Level

/// What is in the tube on the shelf. A level name only ever carries the *dose*, so this
/// is the one concentration the document has to be told before it can work out what to
/// pipette. The unit is free text like `Factor.unit`, and read by `ConcentrationUnit`.
struct StockConcentration: Codable, Hashable {
    var value: Double
    var unit: String

    init(value: Double, unit: String) {
        self.value = value
        self.unit = unit
    }

    /// Hand-written for the reason every type in this file is: a synthesized decoder
    /// ignores stored-property defaults, so a field added later would break saved files.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent(Double.self, forKey: .value) ?? 0
        unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? ""
    }

    var isUsable: Bool { value > 0 }

    /// "10 mM", or "10" when no unit was given.
    var label: String {
        let number = PlateEditor.formatValue(value, significantDigits: 4)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}

/// One value a factor can take, e.g. "10 µM" or "HeLa".
struct Level: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorHex: String
    /// Only meaningful on a level of the compound factor — the stock that condition is
    /// diluted from. nil everywhere else, which is also what every document written
    /// before the prep sheet decodes to.
    ///
    /// It lives here rather than in a table on `Layout` because of lifetime: a side
    /// table would need a matching prune in `removeLevel`, `removeFactor` and
    /// `pruneUnusedLevels`, and a missed one leaves a stock pointing at a condition that
    /// no longer exists. Here, deleting the condition takes its stock with it.
    var stock: StockConcentration?

    init(id: UUID = UUID(), name: String, colorHex: String, stock: StockConcentration? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.stock = stock
    }

    /// Hand-written like the rest of this file. `id`, `name` and `colorHex` are decoded
    /// strictly — a level missing those is corrupt and should fail loudly, exactly as
    /// `Plate` treats its own three — while anything added since uses `decodeIfPresent`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        stock = try container.decodeIfPresent(StockConcentration.self, forKey: .stock)
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
    /// The colour override exists for the never-repeat setting, whose choice depends
    /// on the whole document — which a single factor cannot see.
    mutating func ensureLevel(named name: String, colorHex: String? = nil) -> UUID {
        let clean = name.trimmingCharacters(in: .whitespaces)
        if let existing = level(named: clean) { return existing.id }
        let level = Level(name: clean, colorHex: colorHex ?? Palette.color(at: levels.count))
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

// MARK: - Orientation

/// Which way round a plate is drawn — a rotation of the picture, never of the data.
enum PlateOrientation: String, Codable, Hashable {
    /// Lie the plate down: turned only when it is taller than it is wide. A real plate
    /// is wider than it is tall, so this is what a layout should open as, and it is why
    /// the setting is three-valued rather than a plain Bool — "not yet decided" has to
    /// be tellable from "deliberately upright".
    case automatic
    /// Rows across, columns down — the way the wells are indexed.
    case upright
    /// A quarter turn clockwise from upright.
    case turned

    /// Quarter turns clockwise for a plate of this shape.
    func quarterTurns(for format: PlateFormat) -> Int {
        switch self {
        case .automatic: return format.rows > format.cols ? 1 : 0
        case .upright: return 0
        case .turned: return 1
        }
    }
}

// MARK: - Saved states

/// A bookmark of the experimental design — every factor and every plate — so a
/// combination can be tried out and abandoned. Deliberately stores the same fields
/// as `Layout` minus its own snapshot list, which is what keeps it from nesting.
struct LayoutSnapshot: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var savedAt: Date
    /// The plate this state belongs to. A state is a bookmark of *one* plate's layout,
    /// so switching plates shows a different list. nil means a state written before
    /// that was true, which still restores the whole document.
    var plateID: UUID?
    var factors: [Factor]
    var plates: [Plate]

    init(
        id: UUID = UUID(), name: String, savedAt: Date, plateID: UUID? = nil,
        factors: [Factor], plates: [Plate]
    ) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.plateID = plateID
        self.factors = factors
        self.plates = plates
    }

    /// Hand-written for the same reason `Layout`'s is: the synthesized decoder ignores
    /// stored-property defaults, so adding `plateID` would make every document that
    /// already has saved states fail to open with `keyNotFound`.
    ///
    /// A state from before this field that holds exactly one plate is adopted by it —
    /// which is every single-plate document, so those keep working per-plate rather
    /// than becoming permanent whole-document states.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "State"
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date(timeIntervalSince1970: 0)
        factors = try container.decodeIfPresent([Factor].self, forKey: .factors) ?? []
        plates = try container.decodeIfPresent([Plate].self, forKey: .plates) ?? []
        plateID = try container.decodeIfPresent(UUID.self, forKey: .plateID)
            ?? (plates.count == 1 ? plates[0].id : nil)
    }

    /// True when this state belongs to the given plate, or predates per-plate states
    /// and therefore belongs to all of them.
    func belongs(to plateID: UUID?) -> Bool {
        self.plateID == nil || self.plateID == plateID
    }
}

// MARK: - Plate

struct Plate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var format: PlateFormat
    /// factor id (string) -> per-well level id (string), indexed row-major. nil = unassigned.
    var assignments: [String: [String?]] = [:]
    /// well index (string) -> note. String keys because Swift encodes an Int-keyed
    /// dictionary as a flat array, which nothing else can read back.
    var wellNotes: [String: String] = [:]
    /// A note about the whole plate.
    var note: String = ""

    init(id: UUID = UUID(), name: String, format: PlateFormat = .well96) {
        self.id = id
        self.name = name
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, format, assignments, wellNotes, note
    }

    /// Hand-written for the same reason `Layout` and `LayoutSnapshot` are: the
    /// synthesized decoder ignores stored-property defaults, so the notes fields
    /// would make every earlier `.plate` fail to open. The third type in this file
    /// to need it, exactly as predicted when the second did.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        format = try container.decode(PlateFormat.self, forKey: .format)
        assignments = try container.decodeIfPresent([String: [String?]].self, forKey: .assignments) ?? [:]
        wellNotes = try container.decodeIfPresent([String: String].self, forKey: .wellNotes) ?? [:]
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    func note(well: Int) -> String? {
        guard let text = wellNotes[String(well)], !text.isEmpty else { return nil }
        return text
    }

    mutating func setNote(_ text: String?, well: Int) {
        guard well >= 0, well < format.wellCount else { return }
        let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if clean.isEmpty {
            wellNotes.removeValue(forKey: String(well))
        } else {
            wellNotes[String(well)] = clean
        }
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
        // Notes stay with their row and column too; one on a well the smaller
        // plate no longer has goes the way of that well's values.
        var keptNotes: [String: String] = [:]
        for row in 0..<min(format.rows, newFormat.rows) {
            for col in 0..<min(format.cols, newFormat.cols) {
                if let text = wellNotes[String(format.index(row: row, col: col))] {
                    keptNotes[String(newFormat.index(row: row, col: col))] = text
                }
            }
        }
        format = newFormat
        assignments = remapped
        wellNotes = keptNotes
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

// MARK: - Pipetting

/// How much more than the wells strictly need each tube should hold, so there is
/// something left in the trough when the last well is filled.
///
/// A flat struct rather than an enum with associated values: it decodes leniently like
/// everything else here, and switching mode does not throw away the number already typed.
struct Overage: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case percent
        case percentWithMinimum
        case fixed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .percent: return "Percentage"
            case .percentWithMinimum: return "Percentage, at least"
            case .fixed: return "Fixed volume"
            }
        }
    }

    var mode: Mode = .percent
    var percent: Double = 20
    /// µL. The floor under `.percentWithMinimum`, and the whole extra under `.fixed`.
    var minimumExtra: Double = 50
    var fixedExtra: Double = 50

    init(mode: Mode = .percent, percent: Double = 20, minimumExtra: Double = 50, fixedExtra: Double = 50) {
        self.mode = mode
        self.percent = percent
        self.minimumExtra = minimumExtra
        self.fixedExtra = fixedExtra
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decodeIfPresent(Mode.self, forKey: .mode)).flatMap { $0 } ?? .percent
        percent = try container.decodeIfPresent(Double.self, forKey: .percent) ?? 20
        minimumExtra = try container.decodeIfPresent(Double.self, forKey: .minimumExtra) ?? 50
        fixedExtra = try container.decodeIfPresent(Double.self, forKey: .fixedExtra) ?? 50
    }

    /// The extra µL on top of what the wells themselves take.
    func extra(onWellsVolume base: Double) -> Double {
        switch mode {
        case .percent: return max(0, base * percent / 100)
        case .percentWithMinimum: return max(max(0, base * percent / 100), max(0, minimumExtra))
        case .fixed: return max(0, fixedExtra)
        }
    }

    /// Printed in the table header, so the paper says which rule made the numbers.
    var label: String {
        func number(_ value: Double) -> String {
            PlateEditor.formatValue(value, significantDigits: 4)
        }
        switch mode {
        case .percent: return "+\(number(percent)) %"
        case .percentWithMinimum: return "+\(number(percent)) %, at least \(number(minimumExtra)) µL"
        case .fixed: return "+\(number(fixedExtra)) µL"
        }
    }
}

/// The bench parameters behind the prep sheet.
///
/// In the document rather than in `Preferences` because they describe *this experiment* —
/// the well volume of a 384 is not a matter of taste — and because `Exporter.workbook`
/// only ever sees a `Layout`, which is what lets the prep tab exist without threading a
/// new argument through every export path.
struct PrepSetup: Codable, Hashable {
    var doseFactorID: UUID?
    /// nil means one series for the whole plate rather than one per compound.
    var compoundFactorID: UUID?
    /// nil means every plate in the document.
    var plateID: UUID?
    /// µL in the well *after* the addition.
    var wellVolume: Double = 100
    /// µL of working solution pipetted into each well. Together with `wellVolume` this
    /// is what separates "spike 10 µL of a 10× stock" from "replace the medium with
    /// 100 µL of 1×" — a single well volume silently assumes the latter.
    var addedVolume: Double = 100
    var overage: Overage = Overage()
    /// The stock, when no compound factor is chosen and there is therefore no condition
    /// to hang one on. Ignored once a compound factor is picked — each compound's own
    /// stock lives on its condition, where deleting the condition takes it with it.
    var stock: StockConcentration?
    /// µL. Warnings only: nothing is refused for being small, it is flagged.
    var minimumPipetteVolume: Double = 2
    /// What the tubes are made up in, for the printout to name.
    var diluent: String = "medium"
    var includeInWorkbook: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        doseFactorID = try container.decodeIfPresent(UUID.self, forKey: .doseFactorID)
        compoundFactorID = try container.decodeIfPresent(UUID.self, forKey: .compoundFactorID)
        plateID = try container.decodeIfPresent(UUID.self, forKey: .plateID)
        wellVolume = try container.decodeIfPresent(Double.self, forKey: .wellVolume) ?? 100
        addedVolume = try container.decodeIfPresent(Double.self, forKey: .addedVolume) ?? 100
        overage = try container.decodeIfPresent(Overage.self, forKey: .overage) ?? Overage()
        stock = try container.decodeIfPresent(StockConcentration.self, forKey: .stock)
        minimumPipetteVolume = try container.decodeIfPresent(Double.self, forKey: .minimumPipetteVolume) ?? 2
        diluent = try container.decodeIfPresent(String.self, forKey: .diluent) ?? "medium"
        includeInWorkbook = try container.decodeIfPresent(Bool.self, forKey: .includeInWorkbook) ?? true
    }

    /// How many times more concentrated a tube is than the well it goes into.
    var foldOverWell: Double {
        guard addedVolume > 0 else { return 1 }
        return wellVolume / addedVolume
    }
}

// MARK: - Layout (the document's value)

struct Layout: Codable, Hashable {
    /// Fields that no longer exist but may still be sitting in a saved file.
    private enum RetiredKeys: String, CodingKey {
        case transposedView
        case quarterTurns
    }

    var formatVersion: Int = 1
    var factors: [Factor] = []
    var plates: [Plate] = []
    var padWellLabels: Bool = false
    var wellLabelMode: WellLabelMode = .activeFactor
    /// Which way round the plate is drawn. Purely how it is shown: no well changes its
    /// id, its values or its place in the file. It lives with the document rather than
    /// in Preferences because exports and printing render the plate as displayed, so
    /// the orientation has to travel with the layout.
    var orientation: PlateOrientation = .automatic
    var snapshots: [LayoutSnapshot] = []
    var notes: String = ""
    /// The pipetting prep parameters, nil until the prep window is opened and a dose
    /// factor picked — which is what keeps every document written before it byte-identical
    /// after a round trip.
    var prep: PrepSetup?

    /// Enough saved states to experiment freely, bounded so a document cannot grow
    /// without limit. The oldest is dropped once this is reached.
    static let maxSnapshots = 20

    init(
        formatVersion: Int = 1,
        factors: [Factor] = [],
        plates: [Plate] = [],
        padWellLabels: Bool = false,
        wellLabelMode: WellLabelMode = .activeFactor,
        orientation: PlateOrientation = .automatic,
        snapshots: [LayoutSnapshot] = [],
        notes: String = "",
        prep: PrepSetup? = nil
    ) {
        self.formatVersion = formatVersion
        self.factors = factors
        self.plates = plates
        self.padWellLabels = padWellLabels
        self.wellLabelMode = wellLabelMode
        self.orientation = orientation
        self.snapshots = snapshots
        self.notes = notes
        self.prep = prep
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
        // Two short-lived predecessors, both read through their own key type — the
        // synthesized `CodingKeys` only knows about properties that still exist.
        // `transposedView` was a mirror rather than a turn; `quarterTurns` was a
        // four-way cycle. Either one having been set means the user had turned the
        // plate, so both land on `.turned`.
        let legacy = try? decoder.container(keyedBy: RetiredKeys.self)
        let wasMirrored = (try? legacy?.decodeIfPresent(Bool.self, forKey: .transposedView)) ?? nil
        let oldTurns = (try? legacy?.decodeIfPresent(Int.self, forKey: .quarterTurns)) ?? nil
        orientation = try container.decodeIfPresent(PlateOrientation.self, forKey: .orientation)
            ?? (wasMirrored == true || (oldTurns ?? 0) != 0 ? .turned : .automatic)
        snapshots = try container.decodeIfPresent([LayoutSnapshot].self, forKey: .snapshots) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        prep = try container.decodeIfPresent(PrepSetup.self, forKey: .prep)

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

    /// Every state saved for one plate, oldest first.
    func snapshots(for plateID: UUID?) -> [LayoutSnapshot] {
        snapshots.filter { $0.belongs(to: plateID) }
    }

    /// Bookmarks one plate as it stands. Returns the number of old states dropped to
    /// stay inside `maxSnapshots`.
    ///
    /// The factors go in alongside it because a plate's wells are meaningless without
    /// the levels they point at — but only this plate's own wells are recorded, so a
    /// state for Plate 1 can never put Plate 2 back.
    @discardableResult
    mutating func captureSnapshot(at date: Date, plate plateID: UUID) -> Int {
        guard let plate = plates.first(where: { $0.id == plateID }) else { return 0 }
        // Numbered within the plate, since that is the list it will appear in.
        let used = Set(snapshots(for: plateID).map(\.name))
        var n = snapshots(for: plateID).count + 1
        while used.contains("State \(n)") { n += 1 }

        snapshots.append(
            LayoutSnapshot(
                name: "State \(n)", savedAt: date, plateID: plateID,
                factors: factors, plates: [plate]
            )
        )
        let excess = max(0, snapshots.count - Self.maxSnapshots)
        if excess > 0 { snapshots.removeFirst(excess) }
        return excess
    }

    /// Puts one plate back to a saved state. Display settings and the saved-state list
    /// itself are left alone — reverting should not also change how you are looking at
    /// the plate, or throw away your other bookmarks.
    mutating func restoreSnapshot(_ id: UUID) -> Bool {
        guard let snapshot = snapshots.first(where: { $0.id == id }) else { return false }
        reinstateFactors(from: snapshot)

        guard let plateID = snapshot.plateID else {
            // Written before states were per-plate, so it still means the whole document.
            plates = snapshot.plates
            return true
        }
        guard let saved = snapshot.plates.first(where: { $0.id == plateID }) else { return false }
        if let index = plates.firstIndex(where: { $0.id == plateID }) {
            plates[index] = saved
        } else {
            plates.append(saved)
        }
        return true
    }

    /// Adds back the factors and levels this state needs and the document has since
    /// lost, without removing anything.
    ///
    /// Deliberately a merge and not a replacement. A state now covers one plate, so
    /// reverting it must not undo factor edits made *for another plate* — doing that
    /// would strand the other plate's wells on levels that no longer exist, which shows
    /// up as blank wells rather than as an error.
    private mutating func reinstateFactors(from snapshot: LayoutSnapshot) {
        for saved in snapshot.factors {
            guard let index = factors.firstIndex(where: { $0.id == saved.id }) else {
                factors.append(saved)
                continue
            }
            for level in saved.levels where !factors[index].levels.contains(where: { $0.id == level.id }) {
                factors[index].levels.append(level)
            }
        }
    }

    mutating func renameSnapshot(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        snapshots[index].name = trimmed
    }

    mutating func removeSnapshot(_ id: UUID) {
        snapshots.removeAll { $0.id == id }
    }

    /// The saved state this plate currently matches, if any — what tells the toolbar
    /// whether to show a filled bookmark. The newest match wins.
    ///
    /// Only the plate is compared, not the factors. A state governs one plate's wells,
    /// so renaming a level elsewhere should not quietly un-fill the bookmark on a plate
    /// whose layout has not moved at all.
    func snapshotMatching(plate plateID: UUID?) -> LayoutSnapshot? {
        guard let plateID, let plate = plates.first(where: { $0.id == plateID }) else { return nil }
        return snapshots.last { $0.plateID == plateID && $0.plates.first == plate }
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

extension Layout {
    /// Every colour any condition in the document is using, normalised for membership
    /// tests. `excluding` leaves one factor's own levels out — recolouring a factor
    /// replaces those, so they must not count against the choice.
    func usedLevelColors(excluding factorID: UUID? = nil) -> Set<String> {
        Set(
            factors
                .filter { $0.id != factorID }
                .flatMap(\.levels)
                .map { Palette.normalized($0.colorHex) }
        )
    }
}

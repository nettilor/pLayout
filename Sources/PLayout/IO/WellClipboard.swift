import AppKit

/// A block of wells carrying *every* factor's value, so a piece of a design can be
/// lifted whole — onto another part of the plate, another plate, or another document.
///
/// The plain `⌘C` clipboard is one factor as text, because its job is to land in Excel.
/// This one is the other half of that: nothing to read by eye, everything needed to
/// rebuild the wells exactly. Two flavours go on the pasteboard — this type, which the
/// app reads back, and a joined text grid for anything else — and only the private type
/// is ever read here, so a round trip inside pLayout cannot quietly degrade to strings.
///
/// Factors and conditions travel **by name**, not by id: the ids of another document
/// mean nothing in this one, and a name is what a person would match them by anyway.
struct WellClipboard: Codable, Equatable {

    /// One factor's slice of the block.
    struct Column: Codable, Equatable {
        var name: String
        var unit: String
        var kind: FactorKind
        /// Row-major, `rows * cols` entries. nil is a well that had no value for this
        /// factor, and pastes as one — a copied blank is a blank.
        var values: [String?]
        /// Condition name → colour, so a value this document has never seen arrives
        /// looking the way it did in the one it came from.
        var colors: [String: String]
        /// Set when this factor is a drug, so one copied into another document arrives
        /// still knowing it is made by dilution and what from. It rides beside `unit`
        /// because it is the same kind of thing — a property of the factor, not of any
        /// one of its conditions.
        var dilution: Dilution?

        init(
            name: String, unit: String = "", kind: FactorKind = .categorical,
            values: [String?], colors: [String: String] = [:], dilution: Dilution? = nil
        ) {
            self.name = name
            self.unit = unit
            self.kind = kind
            self.values = values
            self.colors = colors
            self.dilution = dilution
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
            kind = try c.decodeIfPresent(FactorKind.self, forKey: .kind) ?? .categorical
            values = try c.decodeIfPresent([String?].self, forKey: .values) ?? []
            colors = try c.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
            dilution = try c.decodeIfPresent(Dilution.self, forKey: .dilution)
        }
    }

    var rows: Int
    var cols: Int
    var factors: [Column]

    static let pasteboardType = NSPasteboard.PasteboardType("com.nettilor.playout.wells")

    /// What the text flavour puts between two factors' values in one cell. The same
    /// separator the workbook's one-cell map uses, and remembered with it — a lab that
    /// has chosen how a well should read wants it to read that way everywhere.
    static var textSeparator: String { WorkbookJointMap.remembered.resolvedSeparator }

    var wellCount: Int { rows * cols }
    var isEmpty: Bool { rows <= 0 || cols <= 0 || factors.isEmpty }

    init(rows: Int, cols: Int, factors: [Column]) {
        self.rows = rows
        self.cols = cols
        self.factors = factors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 0
        cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 0
        factors = try c.decodeIfPresent([Column].self, forKey: .factors) ?? []
    }

    // MARK: - Capture

    /// Reads a rectangle of wells out of a plate. Every factor comes along, including
    /// the ones with nothing painted in this block: an absent value is part of the
    /// design, and dropping the column would make the paste leave stale values behind.
    static func capture(plate: Plate, factors: [Factor], range: WellRange) -> WellClipboard {
        let range = range.clamped(to: plate.format)
        let columns = factors.map { factor -> Column in
            var values: [String?] = []
            var colors: [String: String] = [:]
            values.reserveCapacity(range.wellCount)
            for row in range.minRow...range.maxRow {
                for col in range.minCol...range.maxCol {
                    let well = plate.format.index(row: row, col: col)
                    guard let id = plate.levelID(factor: factor.id, well: well),
                          let level = factor.level(id: id)
                    else {
                        values.append(nil)
                        continue
                    }
                    values.append(level.name)
                    colors[level.name] = level.colorHex
                }
            }
            return Column(
                name: factor.name, unit: factor.unit, kind: factor.kind,
                values: values, colors: colors, dilution: factor.dilution
            )
        }
        return WellClipboard(rows: range.rowCount, cols: range.colCount, factors: columns)
    }

    func value(factor: Int, row: Int, col: Int) -> String? {
        guard factors.indices.contains(factor), row >= 0, col >= 0, row < rows, col < cols else {
            return nil
        }
        let index = row * cols + col
        guard factors[factor].values.indices.contains(index) else { return nil }
        return factors[factor].values[index]
    }

    /// The block as one string per well, for everything that is not pLayout.
    func joinedGrid(separator: String = WellClipboard.textSeparator) -> [[String]] {
        guard rows > 0, cols > 0 else { return [] }
        return (0..<rows).map { row in
            (0..<cols).map { col in
                factors.indices
                    .compactMap { value(factor: $0, row: row, col: col) }
                    .filter { !$0.isEmpty }
                    .joined(separator: separator)
            }
        }
    }

    // MARK: - Pasteboard

    func write(to pasteboard: NSPasteboard = .general) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.pasteboardType)
        pasteboard.setString(TSV.serialize(joinedGrid()), forType: .string)
    }

    static func read(from pasteboard: NSPasteboard = .general) -> WellClipboard? {
        guard let data = pasteboard.data(forType: pasteboardType),
              let clipboard = try? JSONDecoder().decode(WellClipboard.self, from: data),
              !clipboard.isEmpty
        else { return nil }
        return clipboard
    }

    /// True when the pasteboard holds a block of wells rather than plain text — which
    /// is what lets ⌘V do the right thing with either.
    static func isOnPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.data(forType: pasteboardType) != nil
    }

    // MARK: - Apply

    struct Report: Equatable {
        var wells = 0
        var createdFactors = 0
        var createdConditions = 0
    }

    /// Writes the block into a layout at a top-left corner, creating whatever it needs.
    ///
    /// Kept here rather than in `PlateEditor` so it can be tested on a plain `Layout`;
    /// the editor's job is only to wrap it in one undo step.
    @discardableResult
    func apply(to layout: inout Layout, plateIndex: Int, atRow originRow: Int, col originCol: Int) -> Report {
        var report = Report()
        guard layout.plates.indices.contains(plateIndex) else { return report }
        let format = layout.plates[plateIndex].format

        for (columnIndex, column) in factors.enumerated() {
            let name = column.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            // Matched by name, created when this document has never heard of it —
            // which is what makes a block travel between documents rather than only
            // within one.
            var factorIndex = layout.factors.firstIndex {
                $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
            }
            if factorIndex == nil {
                // The dilution travels only with a factor being *created* here. The rule
                // is the one the per-condition stock followed before it moved: a stock
                // already set in this document is bench reality, and a paste does not
                // overrule it — only now it is one fact per factor rather than one per
                // condition.
                layout.factors.append(
                    Factor(
                        name: name, kind: column.kind, unit: column.unit,
                        dilution: column.dilution
                    )
                )
                factorIndex = layout.factors.count - 1
                report.createdFactors += 1
            }
            guard let fi = factorIndex else { continue }
            let factorID = layout.factors[fi].id

            for row in 0..<rows {
                let r = originRow + row
                guard r >= 0, r < format.rows else { continue }
                for col in 0..<cols {
                    let c = originCol + col
                    guard c >= 0, c < format.cols else { continue }
                    let well = format.index(row: r, col: c)
                    guard let raw = value(factor: columnIndex, row: row, col: col),
                          !raw.trimmingCharacters(in: .whitespaces).isEmpty
                    else {
                        layout.plates[plateIndex].setLevelID(nil, factor: factorID, well: well)
                        continue
                    }
                    let value = raw.trimmingCharacters(in: .whitespaces)
                    let existing = layout.factors[fi].level(named: value)
                    if existing == nil { report.createdConditions += 1 }
                    let levelID = layout.factors[fi].ensureLevel(
                        named: value,
                        colorHex: existing == nil
                            ? colorForNewLevel(named: value, in: layout, factor: fi, column: column)
                            : nil
                    )
                    layout.plates[plateIndex].setLevelID(levelID, factor: factorID, well: well)
                }
            }
        }

        // Only the wells that actually landed on the plate — a block pasted near the
        // right-hand edge is clipped, and saying otherwise would overstate it.
        let landedRows = (0..<rows).filter { (0..<format.rows).contains(originRow + $0) }.count
        let landedCols = (0..<cols).filter { (0..<format.cols).contains(originCol + $0) }.count
        report.wells = landedRows * landedCols
        return report
    }

    /// The colour a value gets when this document has to create it: the one it wore
    /// where it was copied from, unless never-repeat is on and something here already
    /// has it — that promise is document-wide, and a paste is no exception to it.
    private func colorForNewLevel(
        named value: String, in layout: Layout, factor: Int, column: Column
    ) -> String {
        let fallback = PlateEditor.newLevelColor(in: layout, fallback: layout.factors[factor].levels.count)
        guard let stored = column.colors[value], !stored.isEmpty else { return fallback }
        let mustBeUnique = Preferences.shared.newConditionColors == .neverRepeat
        if mustBeUnique, layout.usedLevelColors().contains(Palette.normalized(stored)) { return fallback }
        return stored
    }
}

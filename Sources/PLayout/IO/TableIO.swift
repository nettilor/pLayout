import Foundation

/// Tab-separated text is what Excel puts on the pasteboard, so it is the
/// interchange format for copy/paste in both directions.
enum TSV {
    static func serialize(_ grid: [[String]]) -> String {
        grid.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [[String]] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return [] }
        let rows = lines.map { $0.components(separatedBy: "\t") }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { row in row + Array(repeating: "", count: width - row.count) }
    }

    /// Excel users routinely copy a plate map *including* its A–H / 1–12 headers.
    /// Detect that shape and strip it so the paste lands on the right wells.
    static func strippingPlateHeaders(_ grid: [[String]]) -> [[String]] {
        guard grid.count >= 2, let first = grid.first, first.count >= 2 else { return grid }

        // Every label has to actually be there. Letting a blank cell count as "looks like
        // a header" meant a block that merely had nothing painted along its top row and
        // left edge passed all three tests, and a plain ⌘V of it landed one row up and
        // one column left — dropping the very row and column whose emptiness was the
        // point, so they never cleared the wells they covered. An absent header is not a
        // header, and a half-present one is no evidence: guessing wrong here moves every
        // value by a well, while declining to strip a real header is visible at once.
        let topLooksNumeric = first.dropFirst().enumerated().allSatisfy { offset, cell in
            Int(cell.trimmingCharacters(in: .whitespaces)) == offset + 1
        }
        let cornerEmpty = first[0].trimmingCharacters(in: .whitespaces).isEmpty
        let leftLooksAlpha = grid.dropFirst().enumerated().allSatisfy { offset, row in
            WellNaming.rowIndex(row.first ?? "") == offset
        }

        guard cornerEmpty, topLooksNumeric, leftLooksAlpha else { return grid }
        return grid.dropFirst().map { Array($0.dropFirst()) }
    }
}

enum CSV {
    static func serialize(_ grid: [[String]]) -> String {
        grid.map { row in row.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private static func field(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            if inQuotes {
                if ch == "\"" {
                    if let peek = nextChar() {
                        if peek == "\"" { field.append("\"") } else { inQuotes = false; pending = peek }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\r":
                    continue
                default: field.append(ch)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // Only the artefact of the file's final newline, which is a row of one empty
        // field. A plate map's blank row arrives as N blank cells and *means* something:
        // those wells are empty and importing it clears them. Dropping every all-empty
        // row made the file extension decide which wells changed — the same map cleared
        // row H as .tsv and left it painted as .csv. This is TSV's rule, which drops
        // empty lines and keeps a line of tabs.
        while let last = rows.last, last.count == 1, last[0].isEmpty { rows.removeLast() }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }
}

// MARK: - Workbook / tidy-table construction

/// How the colour-coded plate maps are arranged in an exported workbook.
enum WorkbookLayout: String, CaseIterable, Identifiable, Codable {
    /// One sheet per factor per plate — easiest to paste from into another tool.
    case sheetPerFactor
    /// Every factor stacked on one sheet per plate, each map under its factor name.
    case allFactorsOneSheet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sheetPerFactor: return "One sheet per factor"
        case .allFactorsOneSheet: return "All factors on one sheet"
        }
    }

    var detail: String {
        switch self {
        case .sheetPerFactor:
            return "A separate tab for each factor, ready to paste elsewhere."
        case .allFactorsOneSheet:
            return "One tab per plate, each map headed by its factor name."
        }
    }

    private static let defaultsKey = "workbookSheetLayout"

    /// Remembered between exports, since a lab tends to want the same shape every time.
    static var remembered: WorkbookLayout {
        AppDefaults.store.string(forKey: defaultsKey)
            .flatMap(WorkbookLayout.init(rawValue:)) ?? .sheetPerFactor
    }

    func remember() {
        AppDefaults.store.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Which plates an exported workbook covers. Chosen in the save panel beside the
/// sheet arrangement, and remembered the same way. "Active" is relative — whichever
/// plate is being looked at come the next export — so remembering it is safe.
enum WorkbookScope: String, CaseIterable, Codable {
    case allPlates
    case activePlate

    private static let defaultsKey = "workbookScope"

    static var remembered: WorkbookScope {
        AppDefaults.store.string(forKey: defaultsKey)
            .flatMap(WorkbookScope.init(rawValue:)) ?? .allPlates
    }

    func remember() {
        AppDefaults.store.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// The optional one-cell plate map: every factor's value for a well joined into a
/// single string, for tools that want one label per well. Chosen in the save panel
/// beside the arrangement, and remembered the same way.
struct WorkbookJointMap {
    var enabled: Bool
    /// As typed in the panel; blank falls back to "+" at build time, so clearing
    /// the field never silently glues values together with nothing between them.
    var separator: String

    static let fallbackSeparator = "+"
    var resolvedSeparator: String { separator.isEmpty ? Self.fallbackSeparator : separator }

    private static let enabledKey = "workbookJointMapEnabled"
    private static let separatorKey = "workbookJointMapSeparator"

    static var remembered: WorkbookJointMap {
        WorkbookJointMap(
            enabled: AppDefaults.store.bool(forKey: enabledKey),
            separator: AppDefaults.store.string(forKey: separatorKey) ?? ""
        )
    }

    func remember() {
        AppDefaults.store.set(enabled, forKey: Self.enabledKey)
        AppDefaults.store.set(separator, forKey: Self.separatorKey)
    }
}

enum Exporter {

    /// A full workbook: colour-coded plate maps arranged per `sheetLayout`, plus a
    /// tidy one-row-per-well sheet for analysis and a legend. A non-nil
    /// `jointSeparator` adds one extra map per plate with every factor's value
    /// joined into a single cell.
    static func workbook(
        from layout: Layout, sheetLayout: WorkbookLayout = .sheetPerFactor,
        onlyPlate plateID: UUID? = nil, jointSeparator: String? = nil
    ) -> Data {
        // The scope is one filter, applied here so the maps, the Wells sheet and the
        // legend can never disagree about which plates are in the file. An id that
        // matches nothing keeps the whole document rather than emitting an empty
        // workbook for a plate deleted mid-export.
        var layout = layout
        if let plateID {
            let kept = layout.plates.filter { $0.id == plateID }
            if !kept.isEmpty {
                layout.plates = kept
                // The prep sheet counts wells across whatever plates it is handed, so a
                // setup scoped to a plate this workbook does not contain would count
                // none at all. One filter at the top, and nothing downstream disagrees.
                if let scoped = layout.prep?.plateID, scoped != plateID {
                    layout.prep?.plateID = plateID
                }
            }
        }
        var sheets: [XLSX.Sheet] = []

        switch sheetLayout {
        case .sheetPerFactor:
            for plate in layout.plates {
                for factor in layout.factors {
                    sheets.append(mapSheet(plate: plate, factor: factor))
                }
            }
        case .allFactorsOneSheet:
            for plate in layout.plates {
                sheets.append(combinedSheet(plate: plate, factors: layout.factors))
            }
        }

        if let jointSeparator {
            for plate in layout.plates {
                sheets.append(jointMapSheet(plate: plate, factors: layout.factors, separator: jointSeparator))
            }
        }

        sheets.append(tidySheet(layout: layout))
        // Appended after Wells, and only when there is a drug to collapse — the same
        // opt-in rule the Prep tab follows, and no extra control in the save panel.
        if layout.factors.contains(where: { $0.dilution != nil }) {
            sheets.append(tidyLongSheet(layout: layout))
        }
        sheets.append(legendSheet(layout: layout))
        // Last, so no existing workbook changes shape, and only when the document has a
        // prep setup — which is the opt-in, and why there is no extra save-panel control.
        // A plan with nothing to make can still have something to say — an added volume
        // larger than the well comes back with no compounds at all and the refusal in
        // `warnings` — so the tab has to survive on either. Gating on tubes alone dropped
        // the sheet from precisely the export whose message the bench most needs, while
        // the window and the printout (which test `!isEmpty || !allWarnings.isEmpty`)
        // showed it. A plan with neither still adds no tab, so no empty sheet is emitted.
        // `!= false`, not `== true`: marking a factor is the opt-in now, so a document
        // that marks a drug and never opens the prep window still earns its tab.
        if layout.prep?.includeInWorkbook != false,
           let plan = DilutionPlan.make(from: layout),
           !plan.isEmpty || !plan.allWarnings.isEmpty {
            sheets.append(prepSheet(plan: plan))
        }
        return XLSX.build(sheets: sheets)
    }

    /// The one-cell map: every factor's value for the well in one string, document
    /// order, missing values skipped. No fill colour — no single factor owns the cell.
    private static func jointMapSheet(plate: Plate, factors: [Factor], separator: String) -> XLSX.Sheet {
        var rows: [[XLSX.Cell]] = []

        var header: [XLSX.Cell] = [.header("")]
        for c in 0..<plate.format.cols {
            header.append(.header("\(c + 1)"))
        }
        rows.append(header)

        for r in 0..<plate.format.rows {
            var row: [XLSX.Cell] = [.header(WellNaming.rowLabel(r))]
            for c in 0..<plate.format.cols {
                let well = plate.format.index(row: r, col: c)
                let joined = factors.compactMap { factor -> String? in
                    guard let levelID = plate.levelID(factor: factor.id, well: well) else { return nil }
                    return factor.level(id: levelID)?.name
                }.joined(separator: separator)
                row.append(XLSX.Cell(
                    value: joined.isEmpty ? .blank : .text(joined),
                    fillHex: nil, bold: false, centered: true
                ))
            }
            rows.append(row)
        }

        return XLSX.Sheet(
            name: "\(plate.name) · Combined",
            // The joined strings are several words long, so these columns get about
            // twice the width of a single-factor map's.
            rows: rows,
            columnWidths: [5] + Array(repeating: 24.0, count: plate.format.cols),
            freezeRows: 1,
            freezeCols: 1
        )
    }

    /// Header row plus one row per plate row — the map itself, without a sheet around it.
    private static func mapRows(plate: Plate, factor: Factor) -> [[XLSX.Cell]] {
        var rows: [[XLSX.Cell]] = []

        var header: [XLSX.Cell] = [.header("")]
        for c in 0..<plate.format.cols {
            header.append(.header("\(c + 1)"))
        }
        rows.append(header)

        for r in 0..<plate.format.rows {
            var row: [XLSX.Cell] = [.header(WellNaming.rowLabel(r))]
            for c in 0..<plate.format.cols {
                let well = plate.format.index(row: r, col: c)
                if let levelID = plate.levelID(factor: factor.id, well: well),
                   let level = factor.level(id: levelID) {
                    let value: XLSX.Value = factor.kind == .numeric
                        ? (Double(level.name).map { XLSX.Value.number($0) } ?? .text(level.name))
                        : .text(level.name)
                    row.append(XLSX.Cell(value: value, fillHex: level.colorHex, bold: false, centered: true))
                } else {
                    row.append(XLSX.Cell(value: .blank, fillHex: nil, bold: false, centered: true))
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static func columnWidths(for format: PlateFormat) -> [Double] {
        [5] + Array(repeating: 11.0, count: format.cols)
    }

    private static func mapSheet(plate: Plate, factor: Factor) -> XLSX.Sheet {
        XLSX.Sheet(
            name: "\(plate.name) · \(factor.name)",
            rows: mapRows(plate: plate, factor: factor),
            columnWidths: columnWidths(for: plate.format),
            freezeRows: 1,
            freezeCols: 1
        )
    }

    /// Every factor's map stacked down one sheet, each under its own heading.
    private static func combinedSheet(plate: Plate, factors: [Factor]) -> XLSX.Sheet {
        var rows: [[XLSX.Cell]] = []
        for (index, factor) in factors.enumerated() {
            // A genuinely empty row emits no <row> element but still advances the
            // row counter, which is exactly the gap we want between blocks.
            if index > 0 { rows.append([]) }
            rows.append([XLSX.Cell(value: .text(factor.displayName), bold: true)])
            rows.append(contentsOf: mapRows(plate: plate, factor: factor))
        }
        // No frozen header row here: each block brings its own.
        return XLSX.Sheet(
            name: plate.name,
            rows: rows,
            columnWidths: columnWidths(for: plate.format),
            freezeRows: 0,
            freezeCols: 1
        )
    }

    static func tidyGrid(layout: Layout, includeUnassigned: Bool = true) -> [[String]] {
        let multiPlate = layout.plates.count > 1
        // The Note column exists only when something is noted — an always-empty
        // column is clutter in a table meant to go straight into analysis.
        let anyNotes = layout.plates.contains { !$0.wellNotes.isEmpty }
        var header: [String] = []
        if multiPlate { header.append("Plate") }
        header.append(contentsOf: ["Well", "Row", "Column"])
        header.append(contentsOf: layout.factors.map { $0.displayName })
        if anyNotes { header.append("Note") }

        var grid: [[String]] = [header]
        for plate in layout.plates {
            for r in 0..<plate.format.rows {
                for c in 0..<plate.format.cols {
                    let well = plate.format.index(row: r, col: c)
                    let values = layout.factors.map { factor -> String in
                        guard let id = plate.levelID(factor: factor.id, well: well) else { return "" }
                        return factor.level(id: id)?.name ?? ""
                    }
                    if !includeUnassigned && values.allSatisfy({ $0.isEmpty }) { continue }
                    var row: [String] = []
                    if multiPlate { row.append(plate.name) }
                    row.append(WellNaming.wellLabel(row: r, col: c, padded: layout.padWellLabels))
                    row.append(WellNaming.rowLabel(r))
                    row.append("\(c + 1)")
                    row.append(contentsOf: values)
                    if anyNotes { row.append(plate.note(well: well) ?? "") }
                    grid.append(row)
                }
            }
        }
        return grid
    }

    /// The same wells in long form: one row per well **per drug**, with the dilution
    /// factors collapsed into `Compound` / `Concentration` / `Unit` columns.
    ///
    /// `tidyGrid` gives one column per factor, which is right until a plate carries
    /// several drugs — then each is a column that is blank wherever the others are not.
    /// Long is the shape analysis actually wants: group by compound, plot against
    /// concentration, no reshaping first.
    ///
    /// A well with two drugs on it emits two rows, identical but for those three
    /// columns — that is the whole point of the shape. A well with none emits one row
    /// with them blank, because its other factors are still data and dropping the row
    /// would silently lose the well. `Unit` is always there even when every drug agrees,
    /// so a reader's code never has to branch on whether it is a column or a suffix.
    static func tidyLongGrid(layout: Layout, includeUnassigned: Bool = true) -> [[String]] {
        let multiPlate = layout.plates.count > 1
        let anyNotes = layout.plates.contains { !$0.wellNotes.isEmpty }
        let drugs = layout.factors.filter { $0.dilution != nil }
        let others = layout.factors.filter { $0.dilution == nil }

        var header: [String] = []
        if multiPlate { header.append("Plate") }
        header.append(contentsOf: ["Well", "Row", "Column"])
        header.append(contentsOf: others.map { $0.displayName })
        // `name`, not `displayName`: the unit has a column of its own here.
        header.append(contentsOf: ["Compound", "Concentration", "Unit"])
        if anyNotes { header.append("Note") }

        var grid: [[String]] = [header]
        for plate in layout.plates {
            for r in 0..<plate.format.rows {
                for c in 0..<plate.format.cols {
                    let well = plate.format.index(row: r, col: c)
                    func value(_ factor: Factor) -> String {
                        guard let id = plate.levelID(factor: factor.id, well: well) else { return "" }
                        return factor.level(id: id)?.name ?? ""
                    }
                    let otherValues = others.map(value)
                    let painted = drugs.compactMap { drug -> (Factor, String)? in
                        let name = value(drug)
                        return name.isEmpty ? nil : (drug, name)
                    }
                    // Decided across every factor before the fan-out, so a well is kept
                    // or dropped once rather than once per drug.
                    if !includeUnassigned, otherValues.allSatisfy(\.isEmpty), painted.isEmpty {
                        continue
                    }

                    func row(_ compound: String, _ concentration: String, _ unit: String) -> [String] {
                        var row: [String] = []
                        if multiPlate { row.append(plate.name) }
                        row.append(WellNaming.wellLabel(row: r, col: c, padded: layout.padWellLabels))
                        row.append(WellNaming.rowLabel(r))
                        row.append("\(c + 1)")
                        row.append(contentsOf: otherValues)
                        row.append(contentsOf: [compound, concentration, unit])
                        if anyNotes { row.append(plate.note(well: well) ?? "") }
                        return row
                    }

                    if painted.isEmpty {
                        grid.append(row("", "", ""))
                    } else {
                        for (drug, name) in painted { grid.append(row(drug.name, name, drug.unit)) }
                    }
                }
            }
        }
        return grid
    }

    /// The bench recipe as a sheet: what to put in which tube, and how much of it.
    ///
    /// Volumes arrive already rounded to what a pipette can be set to — the writer has no
    /// number formats, so a raw 138.6666 would print in full.
    private static func prepSheet(plan: DilutionPlan) -> XLSX.Sheet {
        var rows: [[XLSX.Cell]] = []
        let setup = plan.setup

        func line(_ label: String, _ value: String) {
            rows.append([XLSX.Cell(value: .text(label), bold: true), .text(value)])
        }
        func volume(_ value: Double?) -> XLSX.Cell {
            guard let value else { return .text("—") }
            return XLSX.Cell(value: .number(value))
        }

        rows.append([XLSX.Cell(value: .text("Pipetting prep"), bold: true)])
        line("Covers", plan.scopeText)
        line(
            "Each well holds",
            "\(number(setup.wellVolume)) µL, of which \(number(setup.addedVolume)) µL is added"
                + " — tubes are \(number(setup.foldOverWell))× working solutions"
        )
        line("Make extra", setup.overage.label)
        line("Diluent", setup.diluent)

        for compound in plan.compounds where !compound.steps.isEmpty {
            // Every heading names its unit: a bare "0.9" on a bench sheet is a question,
            // not an instruction. Concentrations are in this drug's own unit, volumes are
            // always µL — and "In tube" is only shown when it differs from the dose,
            // which at 1× it does not.
            let suffix = compound.unit.isEmpty ? "" : " (\(compound.unit))"
            var headings = ["Dose\(suffix)"]
            if setup.tubesAreConcentrated { headings.append("In tube\(suffix)") }
            headings += ["Wells", "From", "Take (µL)", "+ Diluent (µL)", "= Make (µL)"]
            rows.append([])
            var heading = [
                XLSX.Cell(
                    value: .text(compound.displayName), fillHex: compound.colorHex,
                    bold: true, centered: false
                ),
            ]
            // Each drug says its own unit here rather than the sheet naming one for all
            // of them — a plan can hold a series in µM beside one in ng/mL.
            if !compound.unit.isEmpty { heading.append(.text("in \(compound.unit)")) }
            // `isUsable`, not just non-nil: a stock of 0 is one nothing can be diluted
            // from, which is why the plan refuses to use it and warns. Printing
            // "stock 0 mM" reads as a measured concentration and contradicts both the
            // window and the printout, which call that "no stock set".
            let stock = compound.stock.flatMap { $0.isUsable ? "stock \($0.label)" : nil }
            heading.append(.text(stock ?? "no stock set"))
            heading.append(.text(compound.method.label))
            rows.append(heading)
            rows.append(
                headings.map { XLSX.Cell.header($0) }
            )
            for step in compound.steps {
                let from: String
                switch step.source {
                case .stock: from = "stock"
                case .tube(let index): from = "tube \(index + 1)"
                case .neatSolvent: from = "solvent"
                case .diluentOnly: from = "—"
                }
                var cells = [XLSX.Cell.text(step.isVehicle ? "vehicle" : step.doseName)]
                if setup.tubesAreConcentrated {
                    cells.append(
                        step.isVehicle ? .text("—") : XLSX.Cell(value: .number(step.working))
                    )
                }
                cells += [
                    XLSX.Cell(value: .number(Double(step.wells))),
                    .text(from),
                    volume(step.sourceVolume),
                    volume(step.diluent),
                    volume(step.total),
                ]
                rows.append(cells)
            }
        }

        let warnings = plan.allWarnings
        if !warnings.isEmpty {
            rows.append([])
            rows.append([XLSX.Cell(value: .text("Before you start"), bold: true)])
            for warning in warnings {
                rows.append([.text(""), .text(warning.text)])
            }
        }

        return XLSX.Sheet(
            name: "Prep", rows: rows,
            columnWidths: setup.tubesAreConcentrated
                ? [16, 14, 8, 12, 14, 16, 15] : [16, 8, 12, 14, 16, 15],
            freezeRows: 0, freezeCols: 0
        )
    }

    private static func number(_ value: Double) -> String {
        PlateEditor.formatValue(value, significantDigits: 4)
    }

    private static func tidySheet(layout: Layout) -> XLSX.Sheet {
        let leading = (layout.plates.count > 1 ? 1 : 0) + 3
        let numericColumns = Set(layout.factors.enumerated().compactMap { index, factor in
            factor.kind == .numeric ? leading + index : nil
        })
        return sheet(named: "Wells", grid: tidyGrid(layout: layout), numeric: numericColumns)
    }

    /// The long form: `Compound` / `Concentration` / `Unit` instead of a column per drug.
    /// Only worth a sheet when the document has a drug to collapse.
    private static func tidyLongSheet(layout: Layout) -> XLSX.Sheet {
        let grid = tidyLongGrid(layout: layout)
        // The concentration is the second of the three trailing columns, before any Note.
        let anyNotes = layout.plates.contains { !$0.wellNotes.isEmpty }
        let width = grid.first?.count ?? 0
        let concentration = width - (anyNotes ? 1 : 0) - 2
        return sheet(named: "Wells (long)", grid: grid, numeric: [concentration])
    }

    /// Shared so the two grids cannot disagree about headers, widths or which columns
    /// arrive as numbers. Numeric columns are given by index into the finished grid,
    /// rather than worked out again from arithmetic over the leading columns.
    private static func sheet(
        named name: String, grid: [[String]], numeric: Set<Int>
    ) -> XLSX.Sheet {
        var rows: [[XLSX.Cell]] = []
        for (i, row) in grid.enumerated() {
            if i == 0 {
                rows.append(row.map { .header($0) })
            } else {
                rows.append(row.enumerated().map { column, text in
                    if numeric.contains(column), let n = Double(text) {
                        return XLSX.Cell(value: .number(n))
                    }
                    return .text(text)
                })
            }
        }
        let widths = grid.first.map { header in
            header.map { Double(max(9, min(24, $0.count + 4))) }
        } ?? []
        return XLSX.Sheet(name: name, rows: rows, columnWidths: widths, freezeRows: 1, freezeCols: 0)
    }

    private static func legendSheet(layout: Layout) -> XLSX.Sheet {
        var rows: [[XLSX.Cell]] = [[.header("Factor"), .header("Level"), .header("Colour"), .header("Wells")]]
        for factor in layout.factors {
            for level in factor.levels {
                let count = layout.plates.reduce(0) {
                    $0 + $1.assignedWellCount(factor: factor.id, level: level.id)
                }
                rows.append([
                    .text(factor.displayName),
                    XLSX.Cell(value: .text(level.name), fillHex: level.colorHex, bold: false, centered: false),
                    .text(level.colorHex),
                    XLSX.Cell(value: .number(Double(count))),
                ])
            }
        }
        // Plate notes are about the plate, not any well, so the legend carries them.
        let noted = layout.plates.filter { !$0.note.isEmpty }
        if !noted.isEmpty {
            rows.append([])
            rows.append([XLSX.Cell(value: .text("Plate notes"), bold: true)])
            for plate in noted {
                rows.append([.text(plate.name), .text(plate.note)])
            }
        }
        return XLSX.Sheet(name: "Legend", rows: rows, columnWidths: [22, 22, 12, 8], freezeRows: 1)
    }
}

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

        let topLooksNumeric = first.dropFirst().enumerated().allSatisfy { offset, cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || Int(t) == offset + 1
        }
        let cornerEmpty = first[0].trimmingCharacters(in: .whitespaces).isEmpty
        let leftLooksAlpha = grid.dropFirst().enumerated().allSatisfy { offset, row in
            let t = row.first?.trimmingCharacters(in: .whitespaces) ?? ""
            return t.isEmpty || WellNaming.rowIndex(t) == offset
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
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
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
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(WorkbookLayout.init(rawValue:)) ?? .sheetPerFactor
    }

    func remember() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
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
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(WorkbookScope.init(rawValue:)) ?? .allPlates
    }

    func remember() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
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
            enabled: UserDefaults.standard.bool(forKey: enabledKey),
            separator: UserDefaults.standard.string(forKey: separatorKey) ?? ""
        )
    }

    func remember() {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        UserDefaults.standard.set(separator, forKey: Self.separatorKey)
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
            if !kept.isEmpty { layout.plates = kept }
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
        sheets.append(legendSheet(layout: layout))
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
        var header: [String] = []
        if multiPlate { header.append("Plate") }
        header.append(contentsOf: ["Well", "Row", "Column"])
        header.append(contentsOf: layout.factors.map { $0.displayName })

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
                    grid.append(row)
                }
            }
        }
        return grid
    }

    private static func tidySheet(layout: Layout) -> XLSX.Sheet {
        let grid = tidyGrid(layout: layout)
        let numericColumns = Set(layout.factors.enumerated().compactMap { index, factor in
            factor.kind == .numeric ? index : nil
        })
        let leading = (layout.plates.count > 1 ? 1 : 0) + 3

        var rows: [[XLSX.Cell]] = []
        for (i, row) in grid.enumerated() {
            if i == 0 {
                rows.append(row.map { .header($0) })
            } else {
                rows.append(row.enumerated().map { column, text in
                    if column >= leading, numericColumns.contains(column - leading), let n = Double(text) {
                        return XLSX.Cell(value: .number(n))
                    }
                    return .text(text)
                })
            }
        }
        let widths = grid.first.map { header in
            header.map { Double(max(9, min(24, $0.count + 4))) }
        } ?? []
        return XLSX.Sheet(name: "Wells", rows: rows, columnWidths: widths, freezeRows: 1, freezeCols: 0)
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
        return XLSX.Sheet(name: "Legend", rows: rows, columnWidths: [22, 22, 12, 8], freezeRows: 1)
    }
}

import Foundation

/// Builds a small but valid .xlsx workbook (SpreadsheetML) with solid cell fills,
/// so an exported plate map keeps the colours you painted with.
enum XLSX {

    enum Value: Equatable {
        case blank
        case text(String)
        case number(Double)
    }

    struct Cell {
        var value: Value
        /// Palette colour applied as a solid fill, or nil for no fill.
        var fillHex: String? = nil
        var bold: Bool = false
        var centered: Bool = false

        static func text(_ s: String) -> Cell { Cell(value: .text(s)) }
        static func header(_ s: String) -> Cell { Cell(value: .text(s), fillHex: "#EDEDED", bold: true, centered: true) }
        static let blank = Cell(value: .blank)
    }

    struct Sheet {
        var name: String
        var rows: [[Cell]]
        var columnWidths: [Double] = []
        var freezeRows: Int = 0
        var freezeCols: Int = 0
    }

    // MARK: - Build

    static func build(sheets: [Sheet]) -> Data {
        let sheets = uniquelyNamed(sheets)

        // Collect every distinct (fill, bold, centered) combination into a style table.
        var styleKeys: [StyleKey] = [StyleKey(fillHex: nil, bold: false, centered: false)]
        var styleIndexOf: [StyleKey: Int] = [styleKeys[0]: 0]
        for sheet in sheets {
            for row in sheet.rows {
                for cell in row {
                    let key = StyleKey(fillHex: cell.fillHex?.uppercased(), bold: cell.bold, centered: cell.centered)
                    if styleIndexOf[key] == nil {
                        styleIndexOf[key] = styleKeys.count
                        styleKeys.append(key)
                    }
                }
            }
        }

        var parts: [ZipWriter.Entry] = []
        parts.append(.init(path: "[Content_Types].xml", data: contentTypes(sheetCount: sheets.count).utf8Data))
        parts.append(.init(path: "_rels/.rels", data: rootRels.utf8Data))
        parts.append(.init(path: "xl/workbook.xml", data: workbook(sheets: sheets).utf8Data))
        parts.append(.init(path: "xl/_rels/workbook.xml.rels", data: workbookRels(sheetCount: sheets.count).utf8Data))
        parts.append(.init(path: "xl/styles.xml", data: styles(styleKeys).utf8Data))
        for (i, sheet) in sheets.enumerated() {
            parts.append(.init(
                path: "xl/worksheets/sheet\(i + 1).xml",
                data: worksheet(sheet, styleIndexOf: styleIndexOf).utf8Data
            ))
        }
        return ZipWriter.archive(entries: parts)
    }

    // MARK: - Style table

    private struct StyleKey: Hashable {
        var fillHex: String?
        var bold: Bool
        var centered: Bool
    }

    private static func styles(_ keys: [StyleKey]) -> String {
        // Fill 0 (none) and fill 1 (gray125) are mandated by the spec; ours start at 2.
        var fills: [String] = []
        var fillIndexOf: [String: Int] = [:]
        for key in keys {
            guard let hex = key.fillHex, fillIndexOf[hex] == nil else { continue }
            fillIndexOf[hex] = fills.count + 2
            fills.append(hex)
        }

        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#

        // 0 regular dark, 1 bold dark, 2 regular white, 3 bold white
        xml += #"<fonts count="4">"#
        xml += #"<font><sz val="11"/><color theme="1"/><name val="Calibri"/></font>"#
        xml += #"<font><b/><sz val="11"/><color theme="1"/><name val="Calibri"/></font>"#
        xml += #"<font><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>"#
        xml += #"<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>"#
        xml += "</fonts>"

        xml += #"<fills count="\#(fills.count + 2)">"#
        xml += #"<fill><patternFill patternType="none"/></fill>"#
        xml += #"<fill><patternFill patternType="gray125"/></fill>"#
        for hex in fills {
            xml += #"<fill><patternFill patternType="solid"><fgColor rgb="FF\#(hex.dropFirst())"/><bgColor indexed="64"/></patternFill></fill>"#
        }
        xml += "</fills>"

        xml += #"<borders count="2">"#
        xml += "<border><left/><right/><top/><bottom/><diagonal/></border>"
        xml += #"<border><left style="thin"><color rgb="FFD0D0D0"/></left><right style="thin"><color rgb="FFD0D0D0"/></right><top style="thin"><color rgb="FFD0D0D0"/></top><bottom style="thin"><color rgb="FFD0D0D0"/></bottom><diagonal/></border>"#
        xml += "</borders>"

        xml += #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
        xml += #"<cellXfs count="\#(keys.count)">"#
        for key in keys {
            let fillID = key.fillHex.flatMap { fillIndexOf[$0] } ?? 0
            let light = key.fillHex.map { needsLightText($0) } ?? false
            let fontID = (key.bold ? 1 : 0) + (light ? 2 : 0)
            let borderID = key.fillHex == nil ? 0 : 1
            var attrs = #"numFmtId="0" fontId="\#(fontID)" fillId="\#(fillID)" borderId="\#(borderID)""#
            if fillID != 0 { attrs += #" applyFill="1""# }
            if borderID != 0 { attrs += #" applyBorder="1""# }
            if key.bold || light { attrs += #" applyFont="1""# }
            if key.centered {
                xml += #"<xf \#(attrs) applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>"#
            } else {
                xml += "<xf \(attrs)/>"
            }
        }
        xml += "</cellXfs>"
        xml += #"<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>"#
        xml += "</styleSheet>"
        return xml
    }

    /// True when white text reads better than black on this fill.
    private static func needsLightText(_ hex: String) -> Bool {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return false }
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = lin(Double((v >> 16) & 0xFF) / 255)
        let g = lin(Double((v >> 8) & 0xFF) / 255)
        let b = lin(Double(v & 0xFF) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b <= 0.42
    }

    // MARK: - Parts

    private static func worksheet(_ sheet: Sheet, styleIndexOf: [StyleKey: Int]) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#

        xml += "<sheetViews><sheetView workbookViewId=\"0\">"
        if sheet.freezeRows > 0 || sheet.freezeCols > 0 {
            let topLeft = reference(row: sheet.freezeRows, col: sheet.freezeCols)
            var pane = "<pane"
            if sheet.freezeCols > 0 { pane += #" xSplit="\#(sheet.freezeCols)""# }
            if sheet.freezeRows > 0 { pane += #" ySplit="\#(sheet.freezeRows)""# }
            pane += #" topLeftCell="\#(topLeft)" activePane="bottomRight" state="frozen"/>"#
            xml += pane
        }
        xml += "</sheetView></sheetViews>"

        if !sheet.columnWidths.isEmpty {
            xml += "<cols>"
            for (i, width) in sheet.columnWidths.enumerated() {
                xml += #"<col min="\#(i + 1)" max="\#(i + 1)" width="\#(String(format: "%.2f", width))" customWidth="1"/>"#
            }
            xml += "</cols>"
        }

        xml += "<sheetData>"
        for (r, row) in sheet.rows.enumerated() {
            let cells = row.enumerated().compactMap { (c, cell) -> String? in
                let key = StyleKey(fillHex: cell.fillHex?.uppercased(), bold: cell.bold, centered: cell.centered)
                let style = styleIndexOf[key] ?? 0
                let ref = reference(row: r, col: c)
                let styleAttr = style == 0 ? "" : #" s="\#(style)""#
                switch cell.value {
                case .blank:
                    return style == 0 ? nil : #"<c r="\#(ref)"\#(styleAttr)/>"#
                case .number(let n):
                    return #"<c r="\#(ref)"\#(styleAttr)><v>\#(formatNumber(n))</v></c>"#
                case .text(let s):
                    guard !s.isEmpty else {
                        return style == 0 ? nil : #"<c r="\#(ref)"\#(styleAttr)/>"#
                    }
                    return #"<c r="\#(ref)"\#(styleAttr) t="inlineStr"><is><t xml:space="preserve">\#(escape(s))</t></is></c>"#
                }
            }
            guard !cells.isEmpty else { continue }
            xml += #"<row r="\#(r + 1)">"# + cells.joined() + "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    private static func workbook(sheets: [Sheet]) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"#
        for (i, sheet) in sheets.enumerated() {
            xml += #"<sheet name="\#(escape(sheet.name))" sheetId="\#(i + 1)" r:id="rId\#(i + 1)"/>"#
        }
        xml += "</sheets></workbook>"
        return xml
    }

    private static func workbookRels(sheetCount: Int) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for i in 1...max(sheetCount, 1) {
            xml += #"<Relationship Id="rId\#(i)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(i).xml"/>"#
        }
        xml += #"<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        xml += "</Relationships>"
        return xml
    }

    private static func contentTypes(sheetCount: Int) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
        xml += #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
        xml += #"<Default Extension="xml" ContentType="application/xml"/>"#
        xml += #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
        for i in 1...max(sheetCount, 1) {
            xml += #"<Override PartName="/xl/worksheets/sheet\#(i).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }
        xml += #"<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
        xml += "</Types>"
        return xml
    }

    private static let rootRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#

    // MARK: - Helpers

    /// Zero-based row/column to an A1-style reference.
    static func reference(row: Int, col: Int) -> String {
        var n = col
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters + "\(row + 1)"
    }

    private static func formatNumber(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
        return String(format: "%.10g", n)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // XML 1.0 forbids most control characters outright.
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// Excel sheet names: max 31 chars, no []:*?/\, and must be unique.
    private static func uniquelyNamed(_ sheets: [Sheet]) -> [Sheet] {
        var used = Set<String>()
        return sheets.map { sheet in
            var name = sheet.name.filter { !"[]:*?/\\".contains($0) }
            if name.isEmpty { name = "Sheet" }
            if name.count > 31 { name = String(name.prefix(31)) }
            var candidate = name
            var n = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(n))"
                candidate = String(name.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(candidate.lowercased())
            var copy = sheet
            copy.name = candidate
            return copy
        }
    }
}

private extension String {
    var utf8Data: Data { Data(self.utf8) }
}

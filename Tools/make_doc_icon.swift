// Renders PlateDocument.iconset — a document sheet carrying a grey data grid,
// badged bottom-right with the app icon the way VS Code badges its files. The
// palette and well colouring are kept in step with make_icon.swift on purpose:
// the badge *is* the app icon, so the two have to read as a pair.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "PlateDocument.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let palette = ["#4E79A7", "#F28E2B", "#59A14F", "#E15759", "#B07AA1", "#76B7B2"]

func color(_ hex: String) -> NSColor {
    var s = hex
    s.removeFirst()
    let v = UInt32(s, radix: 16)!
    return NSColor(
        srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
        green: CGFloat((v >> 8) & 0xFF) / 255,
        blue: CGFloat(v & 0xFF) / 255,
        alpha: 1
    )
}

// The app icon's own well colouring: column-wise blocks, faded down the rows,
// with an empty margin ring. Copied from make_icon.swift so the badge matches.
func appIconWellColor(row: Int, col: Int) -> NSColor? {
    if col == 0 || col == 7 { return nil }
    let block = (col - 1) / 2
    guard row >= 1, row <= 6 else { return nil }
    return color(palette[block % palette.count]).withAlphaComponent(row <= 3 ? 1.0 : 0.62)
}

// The app icon, drawn into an arbitrary rect. `detail` drops the well grid as
// the badge shrinks: the 8x8 turns to mush well before the plate outline does.
func drawAppIcon(in rect: NSRect, detail: Int) {
    let dimension = rect.width
    let plate = rect.insetBy(dx: dimension * 0.06, dy: dimension * 0.06)
    let radius = dimension * 0.20

    let body = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    NSGradient(
        colors: [NSColor(white: 0.99, alpha: 1), NSColor(white: 0.90, alpha: 1)]
    )?.draw(in: body, angle: -90)
    NSColor(white: 0.55, alpha: 0.45).setStroke()
    body.lineWidth = max(1, dimension * 0.02)
    body.stroke()

    switch detail {
    case 3:
        let rows = 8, cols = 8
        let grid = plate.insetBy(dx: dimension * 0.085, dy: dimension * 0.085)
        let cell = min(grid.width / CGFloat(cols), grid.height / CGFloat(rows))
        let originX = grid.midX - cell * CGFloat(cols) / 2
        let originY = grid.midY - cell * CGFloat(rows) / 2
        for row in 0..<rows {
            for col in 0..<cols {
                let well = NSRect(
                    x: originX + CGFloat(col) * cell,
                    y: originY + CGFloat(rows - 1 - row) * cell,
                    width: cell, height: cell
                ).insetBy(dx: cell * 0.13, dy: cell * 0.13)
                (appIconWellColor(row: row, col: col) ?? NSColor(white: 0.80, alpha: 0.55)).setFill()
                NSBezierPath(ovalIn: well).fill()
            }
        }
    case 2:
        // Past ~100pt the empty margin ring is what turns to mush first, so drop
        // it and keep the six colour columns that carry the reading.
        let rows = 4, cols = 6
        let grid = plate.insetBy(dx: dimension * 0.10, dy: dimension * 0.10)
        let cell = min(grid.width / CGFloat(cols), grid.height / CGFloat(rows))
        let originX = grid.midX - cell * CGFloat(cols) / 2
        let originY = grid.midY - cell * CGFloat(rows) / 2
        for row in 0..<rows {
            for col in 0..<cols {
                let well = NSRect(
                    x: originX + CGFloat(col) * cell,
                    y: originY + CGFloat(rows - 1 - row) * cell,
                    width: cell, height: cell
                ).insetBy(dx: cell * 0.13, dy: cell * 0.13)
                color(palette[col / 2]).withAlphaComponent(row < 2 ? 1.0 : 0.62).setFill()
                NSBezierPath(ovalIn: well).fill()
            }
        }
    case 1:
        // Three colour blocks, two dose rows — the same reading, coarser again.
        let rows = 2, cols = 3
        let grid = plate.insetBy(dx: dimension * 0.13, dy: dimension * 0.13)
        let cell = min(grid.width / CGFloat(cols), grid.height / CGFloat(rows))
        let originX = grid.midX - cell * CGFloat(cols) / 2
        let originY = grid.midY - cell * CGFloat(rows) / 2
        for row in 0..<rows {
            for col in 0..<cols {
                let well = NSRect(
                    x: originX + CGFloat(col) * cell,
                    y: originY + CGFloat(rows - 1 - row) * cell,
                    width: cell, height: cell
                ).insetBy(dx: cell * 0.1, dy: cell * 0.1)
                color(palette[col]).withAlphaComponent(row == 0 ? 1.0 : 0.62).setFill()
                NSBezierPath(ovalIn: well).fill()
            }
        }
    default:
        // At 32pt and below only the colours survive: three stripes, no wells.
        let grid = plate.insetBy(dx: dimension * 0.10, dy: dimension * 0.14)
        let stripe = grid.width / 3
        for col in 0..<3 {
            color(palette[col]).setFill()
            NSRect(
                x: grid.minX + CGFloat(col) * stripe, y: grid.minY,
                width: stripe, height: grid.height
            ).insetBy(dx: stripe * 0.12, dy: 0).fill()
        }
    }
}

func render(size: Int) -> Data {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()

    // The sheet: portrait, with the top-right corner turned back.
    let pageWidth = dimension * 0.66
    let pageHeight = dimension * 0.84
    let left = (dimension - pageWidth) / 2
    let right = left + pageWidth
    let bottom = (dimension - pageHeight) / 2
    let top = bottom + pageHeight
    let fold = dimension * 0.19
    let corner = dimension * 0.035

    let sheet = NSBezierPath()
    sheet.move(to: NSPoint(x: left, y: bottom + corner))
    sheet.appendArc(from: NSPoint(x: left, y: bottom), to: NSPoint(x: right, y: bottom), radius: corner)
    sheet.appendArc(from: NSPoint(x: right, y: bottom), to: NSPoint(x: right, y: top - fold), radius: corner)
    sheet.appendArc(from: NSPoint(x: right, y: top - fold), to: NSPoint(x: right - fold, y: top), radius: corner * 0.7)
    sheet.appendArc(from: NSPoint(x: right - fold, y: top), to: NSPoint(x: left, y: top), radius: corner * 0.7)
    sheet.appendArc(from: NSPoint(x: left, y: top), to: NSPoint(x: left, y: bottom), radius: corner)
    sheet.close()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = dimension * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -dimension * 0.012)
    shadow.set()

    NSGradient(
        colors: [NSColor(white: 1.0, alpha: 1), NSColor(white: 0.94, alpha: 1)]
    )?.draw(in: sheet, angle: -90)

    NSShadow().set()
    NSColor(white: 0.55, alpha: 0.35).setStroke()
    sheet.lineWidth = max(1, dimension * 0.005)
    sheet.stroke()

    // The turned-back corner, filling the notch the sheet path cut out.
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: right - fold, y: top))
    flap.line(to: NSPoint(x: right, y: top - fold))
    flap.line(to: NSPoint(x: right - fold, y: top - fold))
    flap.close()
    NSGradient(
        colors: [NSColor(white: 0.72, alpha: 1), NSColor(white: 0.88, alpha: 1)]
    )?.draw(in: flap, angle: -45)
    NSColor(white: 0.55, alpha: 0.35).setStroke()
    flap.lineWidth = max(1, dimension * 0.005)
    flap.stroke()

    // The page content: a grey 3x4 array of cells, standing in for the layout
    // table the way VS Code's grey bars stand in for lines of code. It sits in
    // the upper half so the badge below never covers a cell.
    let gridRows = 4, gridCols = 3
    let contentWidth = pageWidth * 0.70
    let contentHeight = pageHeight * 0.25
    let content = NSRect(
        x: left + pageWidth * 0.13,
        y: top - fold - dimension * 0.03 - contentHeight,
        width: contentWidth, height: contentHeight
    )
    let cellWidth = content.width / CGFloat(gridCols)
    let cellHeight = content.height / CGFloat(gridRows)
    let gapX = cellWidth * 0.14
    let gapY = cellHeight * 0.26
    NSColor(white: 0.75, alpha: 1).setFill()
    for row in 0..<gridRows {
        for col in 0..<gridCols {
            let cell = NSRect(
                x: content.minX + CGFloat(col) * cellWidth,
                y: content.maxY - CGFloat(row + 1) * cellHeight,
                width: cellWidth - gapX, height: cellHeight - gapY
            )
            let radius = min(cell.height * 0.25, dimension * 0.012)
            NSBezierPath(roundedRect: cell, xRadius: radius, yRadius: radius).fill()
        }
    }

    // The badge: the app icon itself, bottom-right, on a white sticker rim that
    // lifts it off the sheet and off whatever the sheet is sitting on.
    let badgeSize = dimension * 0.40
    let badge = NSRect(
        x: right - badgeSize * 0.72,
        y: bottom - badgeSize * 0.07,
        width: badgeSize, height: badgeSize
    )
    let rimInset = badgeSize * 0.055
    let rim = NSBezierPath(
        roundedRect: badge.insetBy(dx: rimInset, dy: rimInset),
        xRadius: badgeSize * 0.20, yRadius: badgeSize * 0.20
    )
    let badgeShadow = NSShadow()
    badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    badgeShadow.shadowBlurRadius = dimension * 0.028
    badgeShadow.shadowOffset = NSSize(width: 0, height: -dimension * 0.008)
    badgeShadow.set()
    NSColor.white.setStroke()
    rim.lineWidth = badgeSize * 0.16
    rim.stroke()
    NSShadow().set()
    rim.stroke()

    let badgePixels = badgeSize
    let detail = badgePixels >= 150 ? 3 : (badgePixels >= 70 ? 2 : (badgePixels >= 34 ? 1 : 0))
    drawAppIcon(in: badge, detail: detail)

    image.unlockFocus()

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: dimension, height: dimension))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in sizes {
    let data = render(size: size)
    let scale = size / 2
    try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/icon_\(size)x\(size).png"))
    if sizes.contains(scale) {
        try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/icon_\(scale)x\(scale)@2x.png"))
    }
}
print("wrote \(outputDirectory)")

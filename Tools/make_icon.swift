// Renders AppIcon.iconset — a stylised 96-well plate with painted conditions.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
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

// Column-wise blocks, the way a dose-response plate actually looks.
func wellColor(row: Int, col: Int) -> NSColor? {
    if col == 0 || col == 7 { return nil }
    let block = (col - 1) / 2
    guard row >= 1, row <= 6 else { return nil }
    return color(palette[block % palette.count]).withAlphaComponent(row <= 3 ? 1.0 : 0.62)
}

func render(size: Int) -> Data {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()

    let bounds = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    let inset = dimension * 0.06
    let plate = bounds.insetBy(dx: inset, dy: inset)
    let radius = dimension * 0.20

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = dimension * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -dimension * 0.012)
    shadow.set()

    let body = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    NSGradient(
        colors: [NSColor(white: 0.99, alpha: 1), NSColor(white: 0.90, alpha: 1)]
    )?.draw(in: body, angle: -90)

    NSShadow().set()
    NSColor(white: 0.55, alpha: 0.45).setStroke()
    body.lineWidth = max(1, dimension * 0.006)
    body.stroke()

    let rows = 8, cols = 8
    let grid = plate.insetBy(dx: dimension * 0.085, dy: dimension * 0.085)
    let cell = min(grid.width / CGFloat(cols), grid.height / CGFloat(rows))
    let originX = grid.midX - cell * CGFloat(cols) / 2
    let originY = grid.midY - cell * CGFloat(rows) / 2

    for row in 0..<rows {
        for col in 0..<cols {
            let rect = NSRect(
                x: originX + CGFloat(col) * cell,
                y: originY + CGFloat(rows - 1 - row) * cell,
                width: cell, height: cell
            ).insetBy(dx: cell * 0.13, dy: cell * 0.13)
            let path = NSBezierPath(ovalIn: rect)
            if let fill = wellColor(row: row, col: col) {
                fill.setFill()
                path.fill()
            } else {
                NSColor(white: 0.80, alpha: 0.55).setFill()
                path.fill()
            }
        }
    }

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

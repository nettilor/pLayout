// Renders the disk-image window background at 1x and 2x — the drag-to-Applications
// arrow and the first-launch steps. Finder draws it behind the real icons, whose
// positions are set by make_dmg.sh and must agree with the geometry here.
// Usage: swift make_dmg_background.swift <output-directory>
import AppKit

let W: CGFloat = 640, H: CGFloat = 420
let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// Everything is laid out from the top-left, the way Finder positions icons;
// this converts a top-left rect into AppKit's bottom-left space.
func rect(_ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: H - yTop - h, width: w, height: h)
}

func draw() {
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // The arrow between where the app icon sits and where Applications sits.
    let arrowY = H - 160
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 240, y: arrowY))
    shaft.line(to: NSPoint(x: 384, y: arrowY))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    NSColor(white: 0.66, alpha: 1).setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 382, y: arrowY + 11))
    head.line(to: NSPoint(x: 402, y: arrowY))
    head.line(to: NSPoint(x: 382, y: arrowY - 11))
    head.close()
    NSColor(white: 0.66, alpha: 1).setFill()
    head.fill()

    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    NSAttributedString(
        string: "Drag pLayout into Applications",
        attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor(white: 0.25, alpha: 1),
            .paragraphStyle: centred,
        ]
    ).draw(in: rect(0, 248, W, 24))

    // The first-launch panel.
    let panel = NSBezierPath(roundedRect: rect(28, 286, W - 56, 106), xRadius: 12, yRadius: 12)
    NSColor(white: 0.965, alpha: 1).setFill()
    panel.fill()
    NSColor(white: 0.84, alpha: 1).setStroke()
    panel.lineWidth = 1
    panel.stroke()

    NSAttributedString(
        string: "The first time you open it",
        attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor(white: 0.2, alpha: 1),
        ]
    ).draw(in: rect(48, 298, W - 96, 20))

    let steps = [
        "1   macOS will say it could not verify pLayout — click Done, not Move to Trash.",
        "2   Open System Settings → Privacy & Security, scroll down, and click Open Anyway.",
        "3   That is the whole ritual, and it is only ever asked for once.",
    ]
    for (index, step) in steps.enumerated() {
        NSAttributedString(
            string: step,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor(white: 0.35, alpha: 1),
            ]
        ).draw(in: rect(48, 324 + CGFloat(index) * 20, W - 96, 18))
    }
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// One pixel per point, deliberately. Finder on macOS 26 ignores the image's
// resolution tags and draws window backgrounds at pixel size — a 2x page,
// whether alone at 144 dpi or in a multi-page hidpi TIFF, comes out double,
// showing the left half of the design. Slightly soft on retina but correct
// everywhere; measured, both ways, before being given up on.
let tiff = render(scale: 1).representation(using: .tiff, properties: [:])!
try tiff.write(to: URL(fileURLWithPath: "\(outputDirectory)/background.tiff"))
print("wrote \(outputDirectory)/background.tiff")

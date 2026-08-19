import CoreGraphics
import Foundation

/// Where everything sits on the board.
///
/// Pure, and evaluated **at display time**: a card that has never been moved is placed by
/// this function rather than written into the document. That matters more than it looks —
/// the app autosaves in place, so writing placements on entry would mean that merely
/// *looking* at a layout on the board rewrote the file.
enum CanvasArrangement {

    static let gap: CGFloat = 28
    /// The card's own chrome, above the content.
    static let titleBarHeight: CGFloat = 26
    static let prepSize = CGSize(width: 620, height: 520)
    static let noteSize = CGSize(width: 240, height: 180)

    /// The prep card's identity. Fixed, so the card view survives a reload and a drag
    /// writes back to the same item.
    static let prepItemID = UUID(uuidString: "5D3E9C10-0000-4000-A000-000000000001")!

    /// A card big enough to read the plate inside it.
    ///
    /// A request, not a contract: `PlateGeometry` solves its cell size to fit whatever
    /// bounds it is handed, so a card that comes out slightly small only means slightly
    /// smaller wells — never a broken layout. That is why approximating the header strips
    /// here is safe.
    static func size(forPlate format: PlateFormat, quarterTurns: Int, cell: CGFloat = 24) -> CGSize {
        let onEnd = quarterTurns % 2 == 1
        let across = CGFloat(onEnd ? format.rows : format.cols)
        let down = CGFloat(onEnd ? format.cols : format.rows)
        let headerW = max(26, min(cell * 1.05, 54))
        let headerH = max(18, min(cell * 0.8, 34))
        return CGSize(
            width: (across * cell + headerW + 28).rounded(),
            height: (down * cell + headerH + 28 + titleBarHeight).rounded()
        )
    }

    /// The first free slot on a `gap`-spaced grid that touches nothing already placed.
    /// Deterministic — same inputs, same frame, every run — which is what keeps the board
    /// from restacking itself between launches.
    static func nextFrame(of size: CGSize, avoiding placed: [CGRect], wrapWidth: CGFloat = 2600) -> CGRect {
        let stepX = size.width + gap
        let stepY = size.height + gap
        let columns = max(1, Int((wrapWidth / stepX).rounded(.down)))
        var slot = 0
        while slot < 4096 {
            let candidate = CGRect(
                x: gap + CGFloat(slot % columns) * stepX,
                y: gap + CGFloat(slot / columns) * stepY,
                width: size.width, height: size.height
            )
            if !placed.contains(where: { $0.intersects(candidate.insetBy(dx: -1, dy: -1)) }) {
                return candidate
            }
            slot += 1
        }
        // Nothing free in a very crowded board: stack below everything rather than
        // silently landing on top of something.
        let bottom = placed.map(\.maxY).max() ?? 0
        return CGRect(x: gap, y: bottom + gap, width: size.width, height: size.height)
    }

    /// The board as it should be shown: saved items in their saved places, in their saved
    /// order, and everything else auto-placed around them.
    ///
    /// Auto-placed plate cards take the plate's own id so a card view survives a reload
    /// and a later drag writes back to the same item.
    static func resolved(
        saved: CanvasLayout?, plates: [Plate], orientation: PlateOrientation, includesPrep: Bool
    ) -> [CanvasItem] {
        let dismissed = Set(saved?.dismissedPlates ?? [])
        let plateIDs = Set(plates.map(\.id)).subtracting(dismissed)
        let includesPrep = includesPrep && !(saved?.hidesPrep ?? false)
        var items: [CanvasItem] = []

        // Saved items first, in their stored z-order, minus anything that no longer exists.
        for item in saved?.items ?? [] {
            switch item.kind {
            case .plate:
                guard let id = item.plateID, plateIDs.contains(id) else { continue }
                items.append(item)
            case .prep:
                guard includesPrep else { continue }
                items.append(item)
            case .note:
                items.append(item)
            }
        }

        var placed = items.map(\.frame.rect)

        for plate in plates where plateIDs.contains(plate.id)
            && !items.contains(where: { $0.kind == .plate && $0.plateID == plate.id }) {
            let turns = (plate.orientation ?? orientation).quarterTurns(for: plate.format)
            let size = size(forPlate: plate.format, quarterTurns: turns)
            let frame = nextFrame(of: size, avoiding: placed)
            placed.append(frame)
            items.append(
                CanvasItem(id: plate.id, kind: .plate, plateID: plate.id, frame: CanvasFrame(frame))
            )
        }

        if includesPrep, !items.contains(where: { $0.kind == .prep }) {
            let frame = nextFrame(of: prepSize, avoiding: placed)
            placed.append(frame)
            items.append(CanvasItem(id: prepItemID, kind: .prep, frame: CanvasFrame(frame)))
        }

        return items
    }

    /// The board's extent: everything on it plus room to pan into. Clamped to the
    /// top-left quadrant so the scrollers keep a sane range.
    static func extent(of items: [CanvasItem], margin: CGFloat = 400) -> CGRect {
        let frames = items.map(\.frame.rect)
        guard let union = frames.dropFirst().reduce(frames.first, { $0?.union($1) }) else {
            return CGRect(x: 0, y: 0, width: 1200, height: 800)
        }
        return CGRect(
            x: 0, y: 0,
            width: max(union.maxX + margin, 1200),
            height: max(union.maxY + margin, 800)
        )
    }
}

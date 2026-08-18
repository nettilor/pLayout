import Foundation

/// Which wells are the same, and which of them sit together.
///
/// Overview shows every factor at once, which answers "what is in this well" and not
/// "where does this block start and stop" — on a 384 the eye has to compare stacks of
/// text well by well. Drawing a line round each run of identical wells turns the plate
/// back into the blocks it was designed as.
///
/// Model space throughout: a rotation carries adjacency with it, so a block is the same
/// block whichever way round the plate is drawn.
enum WellGrouping {

    /// What makes two wells "the same". Either every factor agrees, or one named
    /// factor does — the coarse view, for when the fine one boxes every well on its own.
    enum Basis: Equatable {
        case allFactors
        case factor(UUID)
    }

    /// One key per well index; wells sharing a key are the same condition. nil marks a
    /// well with nothing to group — no value at all under this basis — so empty wells
    /// never join up into a block of their own.
    static func keys(plate: Plate, factors: [Factor], basis: Basis) -> [String?] {
        let wells = plate.format.wellCount
        switch basis {
        case .factor(let id):
            guard factors.contains(where: { $0.id == id }) else {
                return [String?](repeating: nil, count: wells)
            }
            return (0..<wells).map { plate.levelID(factor: id, well: $0)?.uuidString }
        case .allFactors:
            guard !factors.isEmpty else { return [String?](repeating: nil, count: wells) }
            return (0..<wells).map { well in
                var parts: [String] = []
                var any = false
                for factor in factors {
                    if let id = plate.levelID(factor: factor.id, well: well) {
                        parts.append(id.uuidString)
                        any = true
                    } else {
                        parts.append("")
                    }
                }
                // A completely empty well is not a condition, so it is left out rather
                // than boxed together with every other empty well on the plate.
                return any ? parts.joined(separator: "\u{1}") : nil
            }
        }
    }

    /// Connected runs of equal key, four-neighbour. Returns a block number per well
    /// index, nil for a well in no block.
    ///
    /// Runs, not bounding boxes: the same condition in two corners of the plate is two
    /// blocks, and a rectangle drawn round both would enclose everything between them.
    /// An L-shaped block stays one block and gets an L-shaped outline.
    static func blocks(plate: Plate, factors: [Factor], basis: Basis) -> [Int?] {
        let format = plate.format
        let keys = keys(plate: plate, factors: factors, basis: basis)
        var blocks = [Int?](repeating: nil, count: format.wellCount)
        var next = 0

        for start in 0..<format.wellCount where blocks[start] == nil {
            guard let key = keys[start] else { continue }
            let id = next
            next += 1
            var stack = [start]
            blocks[start] = id
            while let well = stack.popLast() {
                let row = well / format.cols
                let col = well % format.cols
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let r = row + dr
                    let c = col + dc
                    guard r >= 0, r < format.rows, c >= 0, c < format.cols else { continue }
                    let neighbour = format.index(row: r, col: c)
                    guard blocks[neighbour] == nil, keys[neighbour] == key else { continue }
                    blocks[neighbour] = id
                    stack.append(neighbour)
                }
            }
        }
        return blocks
    }
}

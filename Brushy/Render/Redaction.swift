import CoreGraphics

/// The Redact tool (§5): blocks — fitted evenly into a dragged box, or on a
/// grid anchored at the canvas's top-left for the brush — filled either with the average of what each block covers (Pixelate) or
/// with one colour (Solid). Shuffle permutes the averaged blocks among
/// themselves, so their ORDER — what de-pixelation attacks match rendered
/// guesses against — is gone while the look (and palette) stays.
///
/// Pure geometry and buffer work, unit-tested separately from the store.
enum Redaction {
    enum Mode: String, CaseIterable, Identifiable {
        case pixelate = "Pixelate"
        case solid = "Solid"
        var id: Self { self }
    }

    enum Style: String, CaseIterable, Identifiable {
        case box = "Box"
        case brush = "Brush"
        var id: Self { self }
    }

    static let blockSizes = [5, 10, 15, 20, 30, 40, 60]

    /// A block: column `x` from the left, row `y` from the TOP.
    struct Cell: Hashable, Comparable {
        let x: Int
        let y: Int
        static func < (a: Cell, b: Cell) -> Bool { (a.y, a.x) < (b.y, b.x) }
    }

    /// Canvas-space (y-up) rect of `cell`, clipped to the canvas — blocks on
    /// the right and bottom edges may be partial.
    static func canvasRect(of cell: Cell, blockSize b: Int, canvasSize: CGSize) -> CGRect {
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        let x0 = cell.x * b, x1 = min(x0 + b, w)
        let r0 = cell.y * b, r1 = min(r0 + b, h)
        return CGRect(x: x0, y: h - r1, width: max(0, x1 - x0), height: max(0, r1 - r0))
    }

    private static func gridSize(blockSize b: Int, canvasSize: CGSize) -> (cols: Int, rows: Int) {
        ((Int(canvasSize.width) + b - 1) / b, (Int(canvasSize.height) + b - 1) / b)
    }

    /// Every block that `rect` (canvas space) touches.
    static func cells(in rect: CGRect, blockSize b: Int, canvasSize: CGSize) -> Set<Cell> {
        let r = rect.standardized.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !r.isNull, r.width > 0, r.height > 0, b > 0 else { return [] }
        let h = canvasSize.height, side = CGFloat(b)
        let x0 = Int((r.minX / side).rounded(.down)), x1 = Int((r.maxX / side).rounded(.up)) - 1
        let y0 = Int(((h - r.maxY) / side).rounded(.down))
        let y1 = Int(((h - r.minY) / side).rounded(.up)) - 1
        guard x0 <= x1, y0 <= y1 else { return [] }
        var result = Set<Cell>()
        for y in y0...y1 { for x in x0...x1 { result.insert(Cell(x: x, y: y)) } }
        return result
    }

    /// Box mode: `rect` (rounded to whole pixels, clipped to the canvas)
    /// split into a grid of near-`blockSize` blocks that fits it exactly —
    /// counts round to the nearest whole block and sizes absorb the rest, so
    /// there are no slivers. Ordered top row first, left to right.
    static func blocks(fitting rect: CGRect, blockSize: Int, canvasSize: CGSize) -> [CGRect] {
        let r = rect.standardized.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !r.isNull, blockSize > 0 else { return [] }
        let x0 = Int(r.minX.rounded()), x1 = Int(r.maxX.rounded())
        let y0 = Int(r.minY.rounded()), y1 = Int(r.maxY.rounded())
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0 else { return [] }
        let cols = max(1, Int((Double(w) / Double(blockSize)).rounded()))
        let rows = max(1, Int((Double(h) / Double(blockSize)).rounded()))
        var result: [CGRect] = []
        for j in 0..<rows {
            let top = y1 - j * h / rows, bottom = y1 - (j + 1) * h / rows
            for i in 0..<cols {
                let left = x0 + i * w / cols, right = x0 + (i + 1) * w / cols
                result.append(CGRect(x: left, y: bottom, width: right - left, height: top - bottom))
            }
        }
        return result
    }

    /// Brush mode: the grid blocks a brush of `widthInBlocks` covers along a segment: those
    /// whose centres lie within half the width of it, plus the block under
    /// each end so even a 1-block brush always lands.
    static func cells(alongSegment a: CGPoint, _ b: CGPoint, widthInBlocks: Int,
                      blockSize: Int, canvasSize: CGSize) -> Set<Cell> {
        guard blockSize > 0 else { return [] }
        let side = CGFloat(blockSize)
        let radius = CGFloat(max(1, widthInBlocks)) * side / 2
        let reach = CGRect.aabb(of: [a, b]).insetBy(dx: -radius, dy: -radius)
        let grid = gridSize(blockSize: blockSize, canvasSize: canvasSize)
        var result = Set<Cell>()
        for cell in cells(in: reach, blockSize: blockSize, canvasSize: canvasSize) {
            let center = CGPoint(x: (CGFloat(cell.x) + 0.5) * side,
                                 y: canvasSize.height - (CGFloat(cell.y) + 0.5) * side)
            if distance(from: center, toSegment: a, b) <= radius { result.insert(cell) }
        }
        for end in [a, b] {
            let cell = Cell(x: Int((end.x / side).rounded(.down)),
                            y: Int(((canvasSize.height - end.y) / side).rounded(.down)))
            if (0..<grid.cols).contains(cell.x), (0..<grid.rows).contains(cell.y) {
                result.insert(cell)
            }
        }
        return result
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return (p - a).length }
        let t = min(1, max(0, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared))
        return (p - (a + CGPoint(x: ab.x * t, y: ab.y * t))).length
    }

    /// Brush cells as block rects, top row first.
    static func blocks(of cells: Set<Cell>, blockSize: Int, canvasSize: CGSize) -> [CGRect] {
        cells.sorted().map { canvasRect(of: $0, blockSize: blockSize, canvasSize: canvasSize) }
            .filter { !$0.isEmpty }
    }

    /// The blocks as one path (one rect each), canvas space — the live preview.
    static func path(of blocks: [CGRect]) -> CGPath {
        let path = CGMutablePath()
        path.addRects(blocks)
        return path
    }

    /// Canvas-space bounds of the blocks (whole pixels), or nil when empty.
    static func bounds(of blocks: [CGRect]) -> CGRect? {
        guard let first = blocks.first else { return nil }
        return blocks.dropFirst().reduce(first) { $0.union($1) }
    }

    /// A premultiplied RGBA8 buffer with row 0 at the TOP (§3 — the usual flip).
    struct Buffer {
        var bytes: UnsafeMutableRawPointer
        var bytesPerRow: Int
        /// Canvas-space rect the buffer covers (whole pixels).
        var canvasRect: CGRect

        /// Byte offset of canvas pixel (x, y), y-up.
        func offset(x: Int, y: Int) -> Int {
            let row = Int(canvasRect.maxY) - 1 - y
            return row * bytesPerRow + (x - Int(canvasRect.minX)) * 4
        }
    }

    /// Writes the redaction into `target` (normally the whole canvas),
    /// replacing whatever those blocks (whole-pixel canvas rects) held.
    /// Pixelate averages each block of `composite` (which must cover every
    /// block); Solid writes `solid`.
    static func apply(blocks rects: [CGRect], mode: Mode, shuffle: Bool, solid: [UInt8],
                      composite: Buffer?, into target: Buffer,
                      using rng: inout some RandomNumberGenerator) {
        var colors: [[UInt8]]
        switch mode {
        case .solid:
            colors = Array(repeating: solid, count: rects.count)
        case .pixelate:
            guard let composite else { return }
            colors = rects.map { average(of: $0, in: composite) }
            if shuffle { colors.shuffle(using: &rng) }
        }
        for (rect, color) in zip(rects, colors) where !rect.isEmpty {
            fill(rect, with: color, in: target)
        }
    }

    private static func average(of rect: CGRect, in buffer: Buffer) -> [UInt8] {
        var sums = [Int](repeating: 0, count: 4)
        let count = Int(rect.width) * Int(rect.height)
        guard count > 0 else { return [0, 0, 0, 0] }
        for y in Int(rect.minY)..<Int(rect.maxY) {
            var offset = buffer.offset(x: Int(rect.minX), y: y)
            for _ in 0..<Int(rect.width) {
                for c in 0..<4 { sums[c] += Int(buffer.bytes.load(fromByteOffset: offset + c, as: UInt8.self)) }
                offset += 4
            }
        }
        return sums.map { UInt8(($0 + count / 2) / count) }
    }

    private static func fill(_ rect: CGRect, with color: [UInt8], in buffer: Buffer) {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            var offset = buffer.offset(x: Int(rect.minX), y: y)
            for _ in 0..<Int(rect.width) {
                for c in 0..<4 { buffer.bytes.storeBytes(of: color[c], toByteOffset: offset + c, as: UInt8.self) }
                offset += 4
            }
        }
    }
}

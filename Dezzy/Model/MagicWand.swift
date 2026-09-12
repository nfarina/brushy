import CoreGraphics

/// Magic Wand: the pixel test, the region search, and the trace that turns the
/// region into the path a `SelectionState` holds (§5).
///
/// The region is traced along pixel boundaries into a path, which is exact for
/// the hard-edged region a tolerance test produces; `MaskFactory` antialiases
/// that path when it rasterises it, so the wand's edge lands soft the way
/// Photoshop's does. `path(from:width:height:)` is also what traces a coverage
/// channel's 50% contour for `SelectionState.coverage(_:rect:)`.
enum MagicWand {
    /// RGBA8, premultiplied, row 0 at TOP — the layout `CGContext` hands back,
    /// and flipped relative to canvas space (§4).
    struct Pixels {
        let data: [UInt8]
        let width: Int
        let height: Int

        init(data: [UInt8], width: Int, height: Int) {
            self.data = data
            self.width = width
            self.height = height
        }

        func offset(x: Int, y: Int) -> Int { (y * width + x) * 4 }
    }

    /// Tolerance is the largest per-channel difference (0…255) still counted
    /// as the same colour, alpha included — so a wand click on transparency
    /// selects the transparent run rather than everything pale.
    static func region(in pixels: Pixels, seedX: Int, seedY: Int,
                       tolerance: Int, contiguous: Bool) -> [Bool] {
        let width = pixels.width, height = pixels.height
        var mask = [Bool](repeating: false, count: width * height)
        guard seedX >= 0, seedY >= 0, seedX < width, seedY < height else { return mask }

        let seed = pixels.offset(x: seedX, y: seedY)
        let target = (pixels.data[seed], pixels.data[seed + 1],
                      pixels.data[seed + 2], pixels.data[seed + 3])
        func matches(_ index: Int) -> Bool {
            let base = index * 4
            func diff(_ a: UInt8, _ b: UInt8) -> Int { abs(Int(a) - Int(b)) }
            return max(diff(pixels.data[base], target.0),
                       diff(pixels.data[base + 1], target.1),
                       diff(pixels.data[base + 2], target.2),
                       diff(pixels.data[base + 3], target.3)) <= tolerance
        }

        guard contiguous else {
            for index in 0..<(width * height) where matches(index) { mask[index] = true }
            return mask
        }

        // Scanline flood: whole runs at a time, so the stack holds a handful of
        // seeds per row rather than one entry per pixel.
        var stack = [(x: seedX, y: seedY)]
        while let (startX, y) = stack.popLast() {
            let row = y * width
            guard !mask[row + startX], matches(row + startX) else { continue }
            var left = startX
            while left > 0, !mask[row + left - 1], matches(row + left - 1) { left -= 1 }
            var right = startX
            while right < width - 1, !mask[row + right + 1], matches(row + right + 1) { right += 1 }
            for x in left...right { mask[row + x] = true }

            for neighbourY in [y - 1, y + 1] where neighbourY >= 0 && neighbourY < height {
                let neighbourRow = neighbourY * width
                var x = left
                while x <= right {
                    if !mask[neighbourRow + x], matches(neighbourRow + x) {
                        stack.append((x, neighbourY))
                        while x <= right, matches(neighbourRow + x) { x += 1 }
                    }
                    x += 1
                }
            }
        }
        return mask
    }

    /// Traces `mask`'s boundary into a canvas-space path (y-up, so buffer rows
    /// flip). Each boundary pixel side becomes a directed edge with the region
    /// on its left, so outer loops come out counter-clockwise and holes
    /// clockwise — the winding a non-zero fill needs to punch the holes out.
    static func path(from mask: [Bool], width: Int, height: Int) -> CGPath {
        struct Vertex: Hashable {
            let x: Int
            let y: Int
        }
        var edges: [Vertex: [Vertex]] = [:]
        func addEdge(_ from: Vertex, _ to: Vertex) { edges[from, default: []].append(to) }

        for row in 0..<height {
            let y = height - 1 - row // canvas space is y-up
            for x in 0..<width where mask[row * width + x] {
                let inside = { (dx: Int, drow: Int) -> Bool in
                    let nx = x + dx, nrow = row + drow
                    guard nx >= 0, nrow >= 0, nx < width, nrow < height else { return false }
                    return mask[nrow * width + nx]
                }
                if !inside(0, 1) { addEdge(Vertex(x: x, y: y), Vertex(x: x + 1, y: y)) }
                if !inside(1, 0) { addEdge(Vertex(x: x + 1, y: y), Vertex(x: x + 1, y: y + 1)) }
                if !inside(0, -1) { addEdge(Vertex(x: x + 1, y: y + 1), Vertex(x: x, y: y + 1)) }
                if !inside(-1, 0) { addEdge(Vertex(x: x, y: y + 1), Vertex(x: x, y: y)) }
            }
        }

        let path = CGMutablePath()
        while let start = edges.keys.first {
            var loop: [Vertex] = []
            var current = start
            // Walk the loop, consuming edges. A vertex where four boundary
            // corners meet has two outgoing edges; either choice closes a
            // valid loop, and the other is picked up by a later walk.
            while var outgoing = edges[current], let next = outgoing.popLast() {
                if outgoing.isEmpty { edges[current] = nil } else { edges[current] = outgoing }
                loop.append(current)
                current = next
                if current == start { break }
            }
            guard loop.count >= 4 else { continue }
            // Drop the midpoints of straight runs: a rectangle should be four
            // points, not one per pixel along its sides.
            var points: [Vertex] = []
            for (index, vertex) in loop.enumerated() {
                let previous = loop[(index + loop.count - 1) % loop.count]
                let next = loop[(index + 1) % loop.count]
                let straight = (previous.x == vertex.x && vertex.x == next.x)
                    || (previous.y == vertex.y && vertex.y == next.y)
                if !straight { points.append(vertex) }
            }
            guard points.count >= 3 else { continue }
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            for vertex in points.dropFirst() {
                path.addLine(to: CGPoint(x: vertex.x, y: vertex.y))
            }
            path.closeSubpath()
        }
        return path
    }
}

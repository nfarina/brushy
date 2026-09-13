import CoreGraphics
import CoreVideo
import Vision

/// Select → Select Subject (added on owner request — a deliberate
/// exception): Vision's foreground-instance mask, vectorized into an ordinary
/// selection path so the result composes with marching ants, feather,
/// Add Layer Mask, and every Select operation.
///
/// Two halves, kept separate from the store/menu glue:
///  - `subjectPath(in:)` — the blocking Vision wrapper (call it off the main
///    thread); returns the subject outline in SOURCE space (y-up, the space
///    `layer.transform` maps from).
///  - `contourPath(values:width:height:threshold:)` — the pure
///    marching-squares vectorizer, unit-tested on its own.
enum SubjectMask {

    enum Failure: LocalizedError, Equatable {
        /// Vision ran but reported no foreground instances (or the mask was
        /// empty after thresholding).
        case noSubject
        /// The mask pixel buffer arrived in a format this build does not read.
        case unsupportedMaskFormat(OSType)

        var errorDescription: String? {
            switch self {
            case .noSubject:
                return "No subject was found."
            case .unsupportedMaskFormat(let format):
                return "Vision returned a mask in an unsupported pixel format (\(format))."
            }
        }
    }

    /// Soft-mask values at or above this count as subject. 0.5 is the
    /// conventional midpoint for Vision's confidence-style masks.
    static let maskThreshold: Float = 0.5

    // MARK: - Vision wrapper

    /// Runs `VNGenerateForegroundInstanceMaskRequest` on `image` (all detected
    /// instances combined, like Photoshop's Select Subject) and returns the
    /// subject outline as a path in source space: y-up, one unit per source
    /// pixel. Blocking — seconds on first use while the model loads.
    ///
    /// Throws `Failure.noSubject` when Vision finds nothing, or rethrows the
    /// underlying Vision error (model unavailable, unsupported OS, …).
    static func subjectPath(in image: CGImage) throws -> CGPath {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else {
            throw Failure.noSubject
        }
        let buffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances, from: handler)
        let mask = try floatMask(of: buffer)
        guard let rowPath = contourPath(values: mask.values, width: mask.width,
                                        height: mask.height,
                                        threshold: maskThreshold) else {
            throw Failure.noSubject
        }
        // The mask buffer is row-0-at-top (like every mask buffer — invariant
        // 6); source space is y-up. Flip, and scale in case Vision's "scaled
        // to the input image" mask rounds to slightly different dimensions.
        let flip = CGAffineTransform(a: CGFloat(image.width) / CGFloat(mask.width),
                                     b: 0, c: 0,
                                     d: -CGFloat(image.height) / CGFloat(mask.height),
                                     tx: 0, ty: CGFloat(image.height))
        let sourcePath = CGMutablePath()
        sourcePath.addPath(rowPath, transform: flip)
        return sourcePath
    }

    /// Reads a one-component Vision mask buffer into a row-major float array
    /// (row 0 = the top row of the image the mask was computed for).
    private static func floatMask(of buffer: CVPixelBuffer)
        throws -> (values: [Float], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw Failure.unsupportedMaskFormat(format)
        }
        var values = [Float](repeating: 0, count: width * height)
        switch format {
        case kCVPixelFormatType_OneComponent32Float:
            for row in 0..<height {
                let rowPtr = (base + row * bytesPerRow)
                    .assumingMemoryBound(to: Float32.self)
                for col in 0..<width {
                    let v = rowPtr[col]
                    values[row * width + col] = v.isFinite ? v : 0
                }
            }
        case kCVPixelFormatType_OneComponent16Half:
            for row in 0..<height {
                let rowPtr = (base + row * bytesPerRow)
                    .assumingMemoryBound(to: Float16.self)
                for col in 0..<width {
                    let v = Float(rowPtr[col])
                    values[row * width + col] = v.isFinite ? v : 0
                }
            }
        case kCVPixelFormatType_OneComponent8:
            for row in 0..<height {
                let rowPtr = (base + row * bytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                for col in 0..<width {
                    values[row * width + col] = Float(rowPtr[col]) / 255
                }
            }
        default:
            throw Failure.unsupportedMaskFormat(format)
        }
        return (values, width, height)
    }

    // MARK: - Marching squares (pure geometry)

    /// A grid edge between two adjacent samples, used to key contour
    /// crossings so segments from neighbouring cells chain exactly.
    private struct EdgeKey: Hashable {
        var horizontal: Bool
        var i: Int
        var j: Int
    }

    /// Marching-squares iso-contour of a row-major float grid (row 0 first)
    /// at `threshold` (which must be > 0), with linear interpolation for
    /// subpixel crossings. The grid is padded with a zero border so every
    /// contour closes.
    ///
    /// Coordinates are "row space": x right, y DOWN, the value for
    /// (col, row) sampled at (col + 0.5, row + 0.5) — callers flip into y-up
    /// source space. Outer boundaries and holes come back with opposite
    /// windings, so the result fills correctly under the non-zero rule (the
    /// rule `MaskFactory` and `SelectionState` use). Returns nil when no
    /// value reaches the threshold.
    static func contourPath(values: [Float], width: Int, height: Int,
                            threshold: Float) -> CGPath? {
        guard width > 0, height > 0, values.count == width * height,
              threshold > 0 else { return nil }

        // Sample grid with a one-sample zero border: sample (i, j) is pixel
        // (i - 1, j - 1) at position (i - 0.5, j - 0.5).
        let sw = width + 2
        var inside = [Bool](repeating: false, count: sw * (height + 2))
        var anyInside = false
        for row in 0..<height {
            let rowBase = row * width
            let insideBase = (row + 1) * sw + 1
            for col in 0..<width where values[rowBase + col] >= threshold {
                inside[insideBase + col] = true
                anyInside = true
            }
        }
        guard anyInside else { return nil }

        func value(_ i: Int, _ j: Int) -> Float {
            guard i >= 1, i <= width, j >= 1, j <= height else { return 0 }
            let v = values[(j - 1) * width + (i - 1)]
            return v.isFinite ? v : 0
        }
        // The crossing point on a grid edge, interpolated between the edge's
        // two sample values. Computed from the canonical (undirected) edge so
        // both cells sharing the edge get bit-identical points.
        func crossing(_ key: EdgeKey) -> CGPoint {
            let v0 = value(key.i, key.j)
            let v1 = key.horizontal ? value(key.i + 1, key.j)
                                    : value(key.i, key.j + 1)
            var f = Double(threshold - v0) / Double(v1 - v0)
            if !f.isFinite { f = 0.5 }
            f = min(max(f, 0), 1)
            let x = Double(key.i) - 0.5
            let y = Double(key.j) - 0.5
            return key.horizontal ? CGPoint(x: x + f, y: y)
                                  : CGPoint(x: x, y: y + f)
        }

        struct Segment {
            var from: EdgeKey
            var to: EdgeKey
            var p0: CGPoint
            var p1: CGPoint
        }
        var segments: [Segment] = []
        var byFrom: [EdgeKey: Int] = [:]

        // Each cell spans samples (i, j)…(i+1, j+1). Walk its edges clockwise
        // in row space — top, right, bottom, left — collecting threshold
        // crossings. The boundary of the inside region leaves a cell edge at
        // an in→out crossing and re-enters at the next out→in crossing, so
        // pairing each exit with the cyclically next entry keeps the inside on
        // the right of every emitted segment: consistent chirality, holes
        // wound opposite to outers, and saddle cells resolved consistently.
        for j in 0...height {
            let rowA = j * sw
            let rowB = rowA + sw
            for i in 0...width {
                let tl = inside[rowA + i], tr = inside[rowA + i + 1]
                let bl = inside[rowB + i], br = inside[rowB + i + 1]
                if tl == tr, tr == br, br == bl { continue }
                let walk: [(from: Bool, to: Bool, edge: EdgeKey)] = [
                    (tl, tr, EdgeKey(horizontal: true, i: i, j: j)),       // top
                    (tr, br, EdgeKey(horizontal: false, i: i + 1, j: j)),  // right
                    (br, bl, EdgeKey(horizontal: true, i: i, j: j + 1)),   // bottom
                    (bl, tl, EdgeKey(horizontal: false, i: i, j: j)),      // left
                ]
                let crossings = walk.filter { $0.from != $0.to }
                for (index, c) in crossings.enumerated() where c.from {
                    var k = (index + 1) % crossings.count
                    while crossings[k].from { k = (k + 1) % crossings.count }
                    let entry = crossings[k].edge
                    byFrom[c.edge] = segments.count
                    segments.append(Segment(from: c.edge, to: entry,
                                            p0: crossing(c.edge),
                                            p1: crossing(entry)))
                }
            }
        }

        // Chain segments head-to-tail into closed loops. Every crossed grid
        // edge is the `from` of exactly one segment and the `to` of exactly
        // one other, so following `byFrom` walks each loop once; the visited
        // guards keep malformed input from ever looping forever.
        let path = CGMutablePath()
        var visited = [Bool](repeating: false, count: segments.count)
        for start in segments.indices where !visited[start] {
            var points: [CGPoint] = [segments[start].p0]
            var index = start
            while !visited[index] {
                visited[index] = true
                let segment = segments[index]
                points.append(segment.p1)
                guard let next = byFrom[segment.to] else { break }
                index = next
            }
            // The loop closes back onto its first crossing — drop the
            // duplicate before simplifying.
            if let last = points.last, points.count > 1,
               abs(last.x - points[0].x) < 1e-9, abs(last.y - points[0].y) < 1e-9 {
                points.removeLast()
            }
            let loop = mergingCollinear(points)
            guard loop.count >= 3 else { continue }
            path.move(to: loop[0])
            for point in loop.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        return path.isEmpty ? nil : path
    }

    /// Drops points that sit exactly on the segment between their neighbours
    /// (long straight runs on flat mask plateaus). Lossless: only exact
    /// collinearity (within 1e-9) is merged, so the filled region is
    /// unchanged and fidelity to the mask is preserved.
    private static func mergingCollinear(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var out: [CGPoint] = []
        out.reserveCapacity(points.count)
        func collinear(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
            abs((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)) < 1e-9
        }
        for point in points {
            while out.count >= 2,
                  collinear(out[out.count - 2], out[out.count - 1], point) {
                out.removeLast()
            }
            out.append(point)
        }
        // Wrap-around: the seam between the last and first points.
        while out.count >= 3, collinear(out[out.count - 2], out[out.count - 1], out[0]) {
            out.removeLast()
        }
        while out.count >= 3, collinear(out[out.count - 1], out[0], out[1]) {
            out.removeFirst()
        }
        return out
    }
}

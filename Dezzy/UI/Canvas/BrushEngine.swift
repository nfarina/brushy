import Accelerate
import CoreGraphics
import Foundation

/// The Stage B brush engine. A stroke lives in the *target's* pixel space
/// (mask texture space or a paint layer's source space, both row 0 = top):
///
/// - Stamps are laid along the interpolated path between mouse events at 15%
///   of the brush diameter — without this, fast strokes render as dots.
/// - Hardness maps to a falloff curve on each stamp: ~Gaussian at 0%, a 1px
///   antialiased edge at 100%.
/// - Stamp alpha accumulates multiplicatively within the stroke (flow), and
///   the whole stroke applies at `opacityCeiling`: a 50% stroke crossing
///   itself stays at 50%; a second stroke compounds.
///
/// The live preview and the final bake share the same math: `coverageImage()`
/// (coverage × ceiling, 8-bit gray over the dirty rect) feeds a
/// CIBlendWithMask both per-frame during the stroke and once at commit.
struct BrushStroke {
    enum Target: Equatable {
        case mask(layerID: UUID)
        case paintLayer(layerID: UUID)
        /// The Quick Mask channel: canvas-sized, canvas-aligned, no layer.
        case quickMask
    }

    let target: Target
    let isEraser: Bool
    /// Paint colour for paint layers (sRGB straight).
    let color: CGColor
    /// Gray value painted onto masks (foreground luminance; 0 for the eraser).
    let maskValue: UInt8
    /// The stroke's opacity ceiling, 0…1.
    let opacityCeiling: Double
    /// Stamp radius in target pixels.
    let radius: CGFloat
    /// 0…1.
    let hardness: Double
    let targetWidth: Int
    let targetHeight: Int

    /// Accumulated stamp coverage (0…255), row 0 = top.
    private(set) var coverage: [UInt8]
    /// Dirty bounds in buffer coordinates (rows from top), inclusive.
    private(set) var dirtyMin: (col: Int, row: Int)? = nil
    private(set) var dirtyMax: (col: Int, row: Int)? = nil

    private var lastPoint: CGPoint?
    private var residualDistance: CGFloat = 0

    init(target: Target, isEraser: Bool, color: CGColor, maskValue: UInt8,
         opacityCeiling: Double, radius: CGFloat, hardness: Double,
         targetWidth: Int, targetHeight: Int) {
        self.target = target
        self.isEraser = isEraser
        self.color = color
        self.maskValue = maskValue
        self.opacityCeiling = min(max(opacityCeiling, 0.01), 1)
        self.radius = max(0.5, radius)
        self.hardness = min(max(hardness, 0), 1)
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        coverage = [UInt8](repeating: 0, count: targetWidth * targetHeight)
    }

    /// nil for the Quick Mask, which belongs to no layer.
    var layerID: UUID? {
        switch target {
        case .mask(let id), .paintLayer(let id): return id
        case .quickMask: return nil
        }
    }

    // MARK: - Stroke building

    /// Extends the stroke to a point in the target's y-up local space,
    /// stamping along the way at 15% of the diameter.
    mutating func extend(toLocal pointYUp: CGPoint) {
        let point = CGPoint(x: pointYUp.x, y: CGFloat(targetHeight) - pointYUp.y)
        guard let last = lastPoint else {
            addStamp(at: point)
            lastPoint = point
            return
        }
        let spacing = max(0.5, radius * 2 * 0.15)
        let delta = point - last
        let distance = delta.length
        guard distance > 1e-6 else { return }
        let direction = delta * (1 / distance)
        var travelled = spacing - residualDistance
        while travelled <= distance {
            addStamp(at: last + direction * travelled)
            travelled += spacing
        }
        residualDistance = distance - (travelled - spacing)
        lastPoint = point
    }

    /// One radial-falloff stamp, accumulated with flow
    /// (c' = 1 − (1−c)(1−a): overlapping stamps build a solid interior while
    /// the outer falloff stays smooth).
    private mutating func addStamp(at center: CGPoint) {
        // `center` is a mouse point through the inverse layer transform, so a
        // near-degenerate transform can push it far outside Int's range.
        let minCol = max(0, floor(center.x - radius - 1).saturatingInt)
        let maxCol = min(targetWidth - 1, ceil(center.x + radius + 1).saturatingInt)
        let minRow = max(0, floor(center.y - radius - 1).saturatingInt)
        let maxRow = min(targetHeight - 1, ceil(center.y + radius + 1).saturatingInt)
        guard minCol <= maxCol, minRow <= maxRow else { return }

        // Hard core out to `core`, falling to 0 at `radius` with a smooth
        // quartic (Gaussian-like) curve. Hardness 100% leaves a sub-pixel
        // ramp — a 1px antialiased edge, not a binary one.
        let core = min(radius - 0.75, radius * CGFloat(hardness))
        let fringe = max(radius - core, 1e-3)
        let coreSq = core > 0 ? core * core : -1
        let radiusSq = radius * radius
        let width = targetWidth

        // Hot path (60–120Hz × stamp area): unsafe buffer + squared-distance
        // early-outs keep this fast even in unoptimized builds.
        coverage.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for row in minRow...maxRow {
                let dy = (CGFloat(row) + 0.5) - center.y
                let dySq = dy * dy
                let rowBase = base + row * width
                for col in minCol...maxCol {
                    let dx = (CGFloat(col) + 0.5) - center.x
                    let dSq = dx * dx + dySq
                    if dSq >= radiusSq { continue }
                    var alpha: CGFloat = 1
                    if dSq > coreSq {
                        let t = (dSq.squareRoot() - core) / fringe
                        let s = 1 - t * t
                        alpha = s * s
                        if alpha <= 0.002 { continue }
                    }
                    let existing = CGFloat(rowBase[col])
                    let updated = existing + alpha * (255 - existing)
                    rowBase[col] = UInt8(min(255, updated.rounded()))
                }
            }
        }
        dirtyMin = (min(dirtyMin?.col ?? minCol, minCol), min(dirtyMin?.row ?? minRow, minRow))
        dirtyMax = (max(dirtyMax?.col ?? maxCol, maxCol), max(dirtyMax?.row ?? maxRow, maxRow))
    }

    // MARK: - Emission

    /// Coverage × opacity ceiling as an 8-bit gray image over the dirty rect,
    /// plus its origin in the target's y-up space. Shared by preview and bake.
    func coverageImage() -> (image: CGImage, originYUp: CGPoint)? {
        guard let dirtyMin, let dirtyMax else { return nil }
        let width = dirtyMax.col - dirtyMin.col + 1
        let height = dirtyMax.row - dirtyMin.row + 1
        // Rebuilt per preview over the whole dirty region (megapixels for a
        // long stroke, at display rate) — one strided vImage table-lookup
        // applies the opacity ceiling and extracts the dirty rect in a single
        // SIMD pass, fast even in unoptimized builds.
        var lut = [Pixel_8](repeating: 0, count: 256)
        for value in 0..<256 {
            lut[value] = Pixel_8((Double(value) * opacityCeiling).rounded())
        }
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let dst = buffer.baseAddress else { return }
            coverage.withUnsafeBufferPointer { src in
                guard let s = src.baseAddress else { return }
                let srcOrigin = s + (dirtyMin.row * targetWidth + dirtyMin.col)
                var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: srcOrigin),
                                           height: vImagePixelCount(height),
                                           width: vImagePixelCount(width),
                                           rowBytes: targetWidth)
                var dstBuf = vImage_Buffer(data: dst,
                                           height: vImagePixelCount(height),
                                           width: vImagePixelCount(width),
                                           rowBytes: width)
                lut.withUnsafeBufferPointer { table in
                    guard let tableBase = table.baseAddress else { return }
                    _ = vImageTableLookUp_Planar8(&srcBuf, &dstBuf, tableBase,
                                                  vImage_Flags(kvImageNoFlags))
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width,
                                  space: DezzyColorSpace.gray,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            return nil
        }
        let originYUp = CGPoint(x: CGFloat(dirtyMin.col),
                                y: CGFloat(targetHeight - (dirtyMax.row + 1)))
        return (image, originYUp)
    }
}

/// What the renderer needs to preview an in-progress stroke.
struct StrokePreview {
    var layerID: UUID
    var targetsMask: Bool
    var coverageImage: CGImage
    var originYUp: CGPoint
    /// Mask target: the painted gray value. Paint target: the brush colour
    /// (nil for the eraser, which blends toward transparency).
    var maskValue: UInt8
    var paintColor: CGColor?
    var isEraser: Bool
}

extension BrushStroke {
    /// Stands in for `layerID` in a Quick Mask preview, which never reaches the
    /// renderer's per-layer preview path — the store bakes it straight into the
    /// channel.
    static let noLayerID = UUID()

    func preview() -> StrokePreview? {
        guard let (image, origin) = coverageImage() else { return nil }
        let targetsMask: Bool
        switch target {
        case .mask, .quickMask: targetsMask = true
        case .paintLayer: targetsMask = false
        }
        return StrokePreview(layerID: layerID ?? Self.noLayerID,
                             targetsMask: targetsMask,
                             coverageImage: image,
                             originYUp: origin,
                             maskValue: maskValue,
                             paintColor: isEraser ? nil : color,
                             isEraser: isEraser)
    }
}

import CoreGraphics
import Foundation

/// Partial coverage for a selection whose edge a path cannot express: the
/// alpha channel Photoshop's selections are made of, carried alongside the
/// path rather than instead of it.
///
/// Sources are the two places a selection genuinely starts life as pixels —
/// Quick Mask, and ⌘-clicking a layer to load its alpha. Everything else
/// stays pure geometry.
struct SelectionAlpha: Equatable {
    /// The canvas-space rect the buffer covers, integral. Coverage outside it
    /// is zero, so this must contain the whole selection.
    let rect: CGRect
    /// `rect`-sized 8-bit coverage, 255 = fully selected. Row 0 is the TOP
    /// row, like every other mask buffer in the app (§4).
    var texture: MaskTexture
}

/// The active selection: a normalized path in canvas space, optionally with a
/// coverage channel.
/// Not part of `Document` (it is not persisted), but it *is* included in undo
/// snapshots so Cmd+Z restores selection changes the way Photoshop does.
///
/// **When `alpha` is present it IS the coverage** — the path is then its 50%
/// contour, kept for the marching ants, for bounds (crop, Layer via Copy) and
/// for every operation that can only clip to geometry. Multiplying the two
/// would clip away the outer half of a soft edge, so nothing does: consumers
/// read `alpha` when it exists and `path` when it does not
/// (`MaskFactory` is where that choice is made once).
///
/// A path-only selection is the common case and behaves exactly as it always
/// has. Any operation that reshapes the path — the boolean combines, Select ▸
/// Modify, a non-translation Transform Selection — drops the alpha rather than
/// let the two disagree; `DocumentStore` says so in a toast when it happens.
struct SelectionState: Equatable {
    /// nil means "no selection" (everything acts as selected for editing ops,
    /// and Add Layer Mask produces a reveal-all mask).
    private(set) var path: CGPath?
    /// Coverage, when this selection has soft or partial edges.
    private(set) var alpha: SelectionAlpha?

    static let empty = SelectionState(path: nil)

    init(path: CGPath?, alpha: SelectionAlpha? = nil) {
        self.path = path
        self.alpha = alpha
    }

    var isEmpty: Bool { path == nil }
    var hasAlpha: Bool { alpha != nil }

    enum CombineMode {
        case replace
        case add
        case subtract
        case intersect

        /// Photoshop's selection modifiers: ⇧ adds, ⌥ subtracts, both intersect.
        init(shift: Bool, option: Bool) {
            switch (shift, option) {
            case (true, true): self = .intersect
            case (true, false): self = .add
            case (false, true): self = .subtract
            case (false, false): self = .replace
            }
        }
    }

    /// Geometry in, geometry out: the result is path-only, so any coverage the
    /// old selection carried is gone (see the type's note).
    func combining(_ newPath: CGPath, mode: CombineMode) -> SelectionState {
        let result: CGPath?
        switch mode {
        case .replace:
            result = newPath
        case .add:
            result = path.map { $0.union(newPath) } ?? newPath
        case .subtract:
            guard let path else { return .empty }
            result = path.subtracting(newPath)
        case .intersect:
            guard let path else { return .empty }
            result = path.intersection(newPath)
        }
        guard let result, !result.isEmpty, !result.boundingBoxOfPath.isEmpty else { return .empty }
        return SelectionState(path: result.normalized())
    }

    /// Combines another whole selection — typically a ⌘⇧/⌘⌥-clicked layer's
    /// alpha — into this one. Two path-only selections use the exact booleans
    /// above. If either side has coverage, both are rasterised over the union
    /// of their bounds and combined per pixel the way Photoshop's channel
    /// arithmetic does (add = max, subtract = a·(1−b), intersect = a·b), so
    /// soft edges survive instead of being dropped.
    func combining(_ other: SelectionState, mode: CombineMode) -> SelectionState {
        if mode == .replace { return other }
        if isEmpty { return mode == .add ? other : .empty }
        if other.isEmpty { return mode == .intersect ? .empty : self }
        if !hasAlpha, !other.hasAlpha, let otherPath = other.path {
            return combining(otherPath, mode: mode)
        }
        let rect = coverageBounds.union(other.coverageBounds).integral
        var result = coverageTexture(over: rect)
        let operand = other.coverageTexture(over: rect)
        result.mutate { data in
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                operand.data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    guard let a = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let b = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    for index in 0..<min(raw.count, source.count) {
                        let x = Int(a[index]), y = Int(b[index])
                        switch mode {
                        case .add: a[index] = UInt8(max(x, y))
                        case .subtract: a[index] = UInt8((x * (255 - y) + 127) / 255)
                        case .intersect: a[index] = UInt8((x * y + 127) / 255)
                        case .replace: a[index] = UInt8(y)
                        }
                    }
                }
            }
        }
        return .coverage(result, rect: rect)
    }

    /// Everything this selection covers: the coverage buffer's rect when there
    /// is one (a soft edge reaches past the 50% contour), else the path's box.
    private var coverageBounds: CGRect {
        alpha?.rect ?? path?.boundingBoxOfPath ?? .null
    }

    /// Select ▸ Inverse. With coverage this inverts the channel exactly
    /// (255 − v over the canvas), which is what Photoshop's Inverse does and
    /// the one boolean worth keeping soft — invert-after-Select-Subject is too
    /// common to hand back a hard edge.
    func inverted(in canvasRect: CGRect) -> SelectionState {
        if alpha != nil {
            let rect = canvasRect.integral
            var texture = coverageTexture(over: rect)
            texture.mutate { data in
                data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    for index in 0..<raw.count { bytes[index] = 255 &- bytes[index] }
                }
            }
            return .coverage(texture, rect: rect)
        }
        let canvasPath = CGPath(rect: canvasRect, transform: nil)
        guard let path else { return SelectionState(path: canvasPath) }
        let inverted = canvasPath.subtracting(path)
        guard !inverted.isEmpty, !inverted.boundingBoxOfPath.isEmpty else { return .empty }
        return SelectionState(path: inverted.normalized())
    }

    // MARK: - Coverage

    /// A selection made of pixels: the 50% contour becomes the path (the ants,
    /// and every geometry-only consumer), the buffer becomes the coverage.
    ///
    /// A buffer that is already binary — a rectangle taken in and out of Quick
    /// Mask, a hard-edged layer loaded as a selection — keeps no alpha at all,
    /// so an operation that could not have softened anything does not leave a
    /// coverage channel behind for later ops to drop noisily.
    ///
    /// A channel with nothing above 50% traces no contour and so becomes no
    /// selection at all: there would be no outline to show and nothing to
    /// grab. Photoshop draws the same line in the same place — that is what its
    /// "no pixels are more than 50% selected" warning is about.
    static func coverage(_ texture: MaskTexture, rect: CGRect) -> SelectionState {
        let width = texture.width, height = texture.height
        guard width > 0, height > 0, rect.width >= 1, rect.height >= 1 else { return .empty }
        let data = texture.data
        var covered = [Bool](repeating: false, count: width * height)
        var isBinary = true
        for index in 0..<(width * height) {
            let value = data[index]
            if value >= 128 { covered[index] = true }
            if value != 0 && value != 255 { isBinary = false }
        }
        let traced = MagicWand.path(from: covered, width: width, height: height)
        guard !traced.isEmpty else { return .empty }
        var shift = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        guard let path = traced.copy(using: &shift), !path.boundingBoxOfPath.isEmpty else {
            return .empty
        }
        return SelectionState(path: path.normalized(),
                              alpha: isBinary ? nil
                                              : SelectionAlpha(rect: rect, texture: texture))
    }

    /// This selection's coverage over `rect` (canvas space, integral), row 0 at
    /// top: the alpha channel re-framed, or the path rasterised when there is
    /// none. The single place coverage is produced from a selection.
    func coverageTexture(over rect: CGRect) -> MaskTexture {
        let width = max(1, rect.width.rounded().saturatingInt)
        let height = max(1, rect.height.rounded().saturatingInt)
        var data = Data(count: width * height) // zero-filled = unselected
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: BrushyColorSpace.gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            if let alpha {
                // Same grid, so this is a blit; `.none` keeps it one even when
                // a crop has left the two rects offset by a fraction.
                ctx.interpolationQuality = .none
                if let image = alpha.texture.cgImage { ctx.draw(image, in: alpha.rect) }
            } else if let path {
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.addPath(path)
                ctx.fillPath(using: .winding)
            }
        }
        return MaskTexture(width: width, height: height, data: data)
    }
}

// MARK: - Select > Modify morphology

// Pure geometry for Select > Modify > Grow / Contract / Border and
// Select > Transform Selection. Kept on the value type (like `combining` /
// `inverted`) so it stays unit-testable independently of the controller.
//
// All three Modify operations are built from the same primitive: stroking the
// selection boundary produces the band ("annulus") of the stroke width centred
// on the edge. Grow unions that band on, Contract subtracts it, Border *is*
// the band. The path representation is what keeps `MaskFactory` exact — do not
// replace this with raster morphology.
extension SelectionState {
    /// Select > Modify radii/widths are clamped to match the feather field's
    /// 1...250 px range.
    static let modifyRadiusRange: ClosedRange<CGFloat> = 1 ... 250

    private static func clampedModifyRadius(_ value: CGFloat) -> CGFloat {
        min(max(value, modifyRadiusRange.lowerBound), modifyRadiusRange.upperBound)
    }

    /// The band of `width` px centred on the boundary of `path`.
    /// `path` must already be normalized — stroking a self-intersecting lasso
    /// path produces winding artefacts.
    private static func boundaryBand(of path: CGPath, width: CGFloat) -> CGPath {
        path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    /// Shared "collapse degenerate results to `.empty`" rule (same guard as
    /// `combining` / `inverted`).
    private init(normalizing path: CGPath) {
        if path.isEmpty || path.boundingBoxOfPath.isEmpty {
            self = .empty
        } else {
            self.init(path: path.normalized())
        }
    }

    /// Expands the selection outward by `radius` px (round joins round off
    /// convex corners, as in Photoshop). Deliberately *not* clipped to the
    /// canvas rect: selections outside the canvas are meaningful because layer
    /// content outside the canvas survives crop.
    func grown(by radius: CGFloat) -> SelectionState {
        guard let path else { return .empty }
        let radius = Self.clampedModifyRadius(radius)
        let base = path.normalized()
        return SelectionState(normalizing: base.union(Self.boundaryBand(of: base, width: 2 * radius)))
    }

    /// Contracts the selection inward by `radius` px. Collapses to `.empty`
    /// when the radius reaches the shape's half-width — that is correct, and
    /// the caller still commits the empty result because the user asked for it.
    func contracted(by radius: CGFloat) -> SelectionState {
        guard let path else { return .empty }
        let radius = Self.clampedModifyRadius(radius)
        let base = path.normalized()
        return SelectionState(normalizing: base.subtracting(Self.boundaryBand(of: base, width: 2 * radius)))
    }

    /// Replaces the selection with the band of `width` px centred on its
    /// boundary (Photoshop's Border is centred on the edge; match that).
    func bordered(width: CGFloat) -> SelectionState {
        guard let path else { return .empty }
        let width = Self.clampedModifyRadius(width)
        let base = path.normalized()
        return SelectionState(normalizing: Self.boundaryBand(of: base, width: width))
    }

    /// Rectangular Marquee geometry, snapped to the pixel grid so the
    /// selection covers whole pixels as in Photoshop. Unsnapped, a drag at a
    /// fractional zoom lands between pixels and Fill / Image > Crop leave
    /// anti-aliased partial pixels along the edges.
    ///
    /// `square` (⇧ held mid-drag) forces equal sides, the longer drag axis
    /// winning; `fromCenter` (⌥ held mid-drag) makes `anchor` the centre, not
    /// a corner. The anchor snaps first and the drag extent rounds to whole
    /// pixels, so a snapped square stays square and a centred rect symmetric.
    static func marqueeRect(from anchor: CGPoint, to current: CGPoint,
                            square: Bool = false, fromCenter: Bool = false) -> CGRect {
        let origin = CGPoint(x: anchor.x.rounded(), y: anchor.y.rounded())
        var dx = (current.x - origin.x).rounded()
        var dy = (current.y - origin.y).rounded()
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        let start = fromCenter ? CGPoint(x: origin.x - dx, y: origin.y - dy) : origin
        let end = CGPoint(x: origin.x + dx, y: origin.y + dy)
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Image > Crop's frame: the selection's bounding box, expanded outward to
    /// whole pixels and clipped to the canvas. A lasso crops to its bounds, as
    /// in Photoshop. nil when there is no selection or it misses the canvas.
    func cropRect(in canvasRect: CGRect) -> CGRect? {
        guard let path else { return nil }
        let rect = path.boundingBoxOfPath.integral.intersection(canvasRect)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    /// The selection mapped through `transform` (canvas space → canvas space).
    /// Commit step of Select > Transform Selection, of Crop's shift, and of
    /// dragging the outline. A degenerate (zero-scale) transform collapses to
    /// `.empty`.
    ///
    /// A whole-pixel translation carries the coverage with it — the buffer just
    /// sits somewhere else on the grid, no resampling — which is what keeps
    /// Crop and outline drags lossless. Anything else (scale, rotation, a
    /// sub-pixel shift) would have to resample the channel, so it drops it.
    func transformed(by transform: CGAffineTransform) -> SelectionState {
        guard let path else { return .empty }
        var transform = transform
        guard let mapped = path.copy(using: &transform) else { return self }
        guard let alpha, transform.isWholePixelTranslation else {
            return SelectionState(normalizing: mapped)
        }
        guard !mapped.isEmpty, !mapped.boundingBoxOfPath.isEmpty else { return .empty }
        let moved = SelectionAlpha(rect: alpha.rect.offsetBy(dx: transform.tx, dy: transform.ty),
                                   texture: alpha.texture)
        return SelectionState(path: mapped.normalized(), alpha: moved)
    }
}

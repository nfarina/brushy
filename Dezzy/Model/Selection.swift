import CoreGraphics

/// The active selection, as a normalized path in canvas space.
/// Not part of `Document` (it is not persisted), but it *is* included in undo
/// snapshots so Cmd+Z restores selection changes the way Photoshop does.
struct SelectionState: Equatable {
    /// nil means "no selection" (everything acts as selected for editing ops,
    /// and Add Layer Mask produces a reveal-all mask).
    private(set) var path: CGPath?

    static let empty = SelectionState(path: nil)

    var isEmpty: Bool { path == nil }

    enum CombineMode {
        case replace
        case add
        case subtract
    }

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
        }
        guard let result, !result.isEmpty, !result.boundingBoxOfPath.isEmpty else { return .empty }
        return SelectionState(path: result.normalized())
    }

    func inverted(in canvasRect: CGRect) -> SelectionState {
        let canvasPath = CGPath(rect: canvasRect, transform: nil)
        guard let path else { return SelectionState(path: canvasPath) }
        let inverted = canvasPath.subtracting(path)
        guard !inverted.isEmpty, !inverted.boundingBoxOfPath.isEmpty else { return .empty }
        return SelectionState(path: inverted.normalized())
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
    /// Commit step of Select > Transform Selection. A degenerate (zero-scale)
    /// transform collapses to `.empty`.
    func transformed(by transform: CGAffineTransform) -> SelectionState {
        guard let path else { return .empty }
        var transform = transform
        guard let mapped = path.copy(using: &transform) else { return self }
        return SelectionState(normalizing: mapped)
    }
}

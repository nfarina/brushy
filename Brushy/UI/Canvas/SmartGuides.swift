import CoreGraphics

/// smart guides: while moving or scaling, snap (within ~6 *screen* px) when
/// the layer's edges or centre align with the canvas edges/centre or any other
/// visible layer's edges/centre, and describe the magenta lines to draw.
struct SmartGuideLine: Equatable {
    enum Axis { case vertical, horizontal }
    var axis: Axis
    /// Canvas coordinate of the line (x for vertical, y for horizontal).
    var position: CGFloat
    var start: CGFloat
    var end: CGFloat
}

enum SmartGuides {
    static let screenThreshold: CGFloat = 6

    /// A uniform grid lattice offered to snapping. Kept as
    /// step + origin rather than materialised line targets: rounding finds
    /// the nearest line in O(1), where a 1 px grid over a 6000 px canvas
    /// would otherwise mean thousands of targets per mouse event — and,
    /// unlike guide targets, grid lines deliberately produce no magenta
    /// feedback (Photoshop shows none for grid snapping; the visible grid
    /// itself is the feedback).
    struct Grid: Equatable {
        var step: CGFloat
        /// A canvas point the lattice passes through on each axis. The x
        /// lattice anchors at the canvas left edge; the y lattice at the
        /// canvas *top* (origin.y = canvas height), matching the top-down
        /// rulers and Photoshop's top-left grid origin.
        var origin: CGPoint = .zero

        func nearestX(to value: CGFloat) -> CGFloat {
            origin.x + ((value - origin.x) / step).rounded() * step
        }

        func nearestY(to value: CGFloat) -> CGFloat {
            origin.y + ((value - origin.y) / step).rounded() * step
        }
    }

    struct Targets {
        var xs: [(value: CGFloat, rect: CGRect)] = []
        var ys: [(value: CGFloat, rect: CGRect)] = []
        var grid: Grid?

        var gridLineX: ((CGFloat) -> CGFloat)? { grid.map { g in { g.nearestX(to: $0) } } }
        var gridLineY: ((CGFloat) -> CGFloat)? { grid.map { g in { g.nearestY(to: $0) } } }
    }

    /// The single insertion point for what snapping considers:
    /// canvas edges/centre, other layers' edges/centres (smart guides),
    /// user guides, and the grid. Guide targets carry the full canvas rect so
    /// the magenta feedback line spans the canvas. `canvasEdges: false` drops
    /// the canvas/centre targets while keeping guide + grid snapping — the
    /// Transform Selection diet.
    static func targets(canvasRect: CGRect,
                        otherLayerBounds: [CGRect],
                        guides: [Guide] = [],
                        grid: Grid? = nil,
                        canvasEdges: Bool = true) -> Targets {
        var targets = Targets()
        let rects = (canvasEdges ? [canvasRect] : []) + otherLayerBounds
        for rect in rects where !rect.isEmpty {
            for x in [rect.minX, rect.midX, rect.maxX] { targets.xs.append((x, rect)) }
            for y in [rect.minY, rect.midY, rect.maxY] { targets.ys.append((y, rect)) }
        }
        for guide in guides {
            switch guide.axis {
            case .vertical: targets.xs.append((guide.position, canvasRect))
            case .horizontal: targets.ys.append((guide.position, canvasRect))
            }
        }
        if let grid, grid.step > 0 { targets.grid = grid }
        return targets
    }

    /// Move snapping: adjusts a raw drag delta so the moved bounds align with
    /// the nearest target within `threshold` (canvas units). Grid lines
    /// compete with the discrete targets by the same nearest-wins rule.
    static func snappedMoveDelta(movingBounds: CGRect,
                                 rawDelta: CGPoint,
                                 targets: Targets,
                                 threshold: CGFloat) -> (delta: CGPoint, guides: [SmartGuideLine]) {
        let moved = movingBounds.offsetBy(dx: rawDelta.x, dy: rawDelta.y)
        var dx: CGFloat? = nil
        for candidate in [moved.minX, moved.midX, moved.maxX] {
            for target in targets.xs.map(\.value) + [targets.grid?.nearestX(to: candidate)].compactMap({ $0 }) {
                let d = target - candidate
                if abs(d) <= threshold && abs(d) < abs(dx ?? .infinity) { dx = d }
            }
        }
        var dy: CGFloat? = nil
        for candidate in [moved.minY, moved.midY, moved.maxY] {
            for target in targets.ys.map(\.value) + [targets.grid?.nearestY(to: candidate)].compactMap({ $0 }) {
                let d = target - candidate
                if abs(d) <= threshold && abs(d) < abs(dy ?? .infinity) { dy = d }
            }
        }
        let delta = CGPoint(x: rawDelta.x + (dx ?? 0), y: rawDelta.y + (dy ?? 0))
        let final = movingBounds.offsetBy(dx: delta.x, dy: delta.y)
        return (delta, guides(for: final, targets: targets))
    }

    /// Scale snapping for a uniform corner drag: every canvas point moves as
    /// `anchor + f·(p₀ - anchor)`, so an AABB edge can be solved for the f that
    /// lands it on a target.
    static func snappedUniformScale(_ f: CGFloat,
                                    anchorCanvas: CGPoint,
                                    unscaledBounds: CGRect,
                                    targets: Targets,
                                    threshold: CGFloat) -> CGFloat {
        var best: (f: CGFloat, error: CGFloat)? = nil
        func consider(edge: CGFloat, anchor: CGFloat,
                      axisTargets: [(value: CGFloat, rect: CGRect)],
                      gridLine: ((CGFloat) -> CGFloat)?) {
            let span = edge - anchor
            guard abs(span) > 1e-6 else { return }
            let current = anchor + f * span
            for target in axisTargets.map(\.value) + [gridLine?(current)].compactMap({ $0 }) {
                let error = abs(target - current)
                if error <= threshold && error < (best?.error ?? .infinity) {
                    best = ((target - anchor) / span, error)
                }
            }
        }
        for edge in [unscaledBounds.minX, unscaledBounds.maxX] {
            consider(edge: edge, anchor: anchorCanvas.x, axisTargets: targets.xs,
                     gridLine: targets.gridLineX)
        }
        for edge in [unscaledBounds.minY, unscaledBounds.maxY] {
            consider(edge: edge, anchor: anchorCanvas.y, axisTargets: targets.ys,
                     gridLine: targets.gridLineY)
        }
        return best?.f ?? f
    }

    /// Per-axis scale snapping (edge handles / Shift-unconstrained corners).
    /// `gridLine` maps a coordinate to the nearest grid line on that axis
    /// (`Targets.gridLineX`/`gridLineY`), nil when the grid is off.
    static func snappedAxisScale(_ f: CGFloat,
                                 anchor: CGFloat,
                                 unscaledEdges: [CGFloat],
                                 axisTargets: [(value: CGFloat, rect: CGRect)],
                                 gridLine: ((CGFloat) -> CGFloat)? = nil,
                                 threshold: CGFloat) -> CGFloat {
        var best: (f: CGFloat, error: CGFloat)? = nil
        for edge in unscaledEdges {
            let span = edge - anchor
            guard abs(span) > 1e-6 else { continue }
            let current = anchor + f * span
            for target in axisTargets.map(\.value) + [gridLine?(current)].compactMap({ $0 }) {
                let error = abs(target - current)
                if error <= threshold && error < (best?.error ?? .infinity) {
                    best = ((target - anchor) / span, error)
                }
            }
        }
        return best?.f ?? f
    }

    /// The magenta lines: every target coordinate the bounds now align with
    /// (within a hair), spanning the union of both rects.
    static func guides(for bounds: CGRect, targets: Targets) -> [SmartGuideLine] {
        var lines: [SmartGuideLine] = []
        let epsilon: CGFloat = 0.5
        for candidate in [bounds.minX, bounds.midX, bounds.maxX] {
            for (target, rect) in targets.xs where abs(target - candidate) < epsilon {
                let line = SmartGuideLine(axis: .vertical, position: target,
                                          start: min(bounds.minY, rect.minY),
                                          end: max(bounds.maxY, rect.maxY))
                if !lines.contains(line) { lines.append(line) }
            }
        }
        for candidate in [bounds.minY, bounds.midY, bounds.maxY] {
            for (target, rect) in targets.ys where abs(target - candidate) < epsilon {
                let line = SmartGuideLine(axis: .horizontal, position: target,
                                          start: min(bounds.minX, rect.minX),
                                          end: max(bounds.maxX, rect.maxX))
                if !lines.contains(line) { lines.append(line) }
            }
        }
        return lines
    }
}

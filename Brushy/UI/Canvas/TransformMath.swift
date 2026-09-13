import CoreGraphics

/// Pure geometry for the transform gestures. All Photoshop-parity semantics
/// live here so they are unit-testable:
///   - corner drag: proportional by default; Shift *un*constrains
///   - Option: scale from the centre instead of the opposite corner/edge
///   - edge drag: one axis
///   - rotation: delta from the box centre; Shift snaps to 15° increments
enum TransformMath {
    /// Minimum |scale factor| — prevents a degenerate (non-invertible) layer.
    static let minimumScale: CGFloat = 0.004

    /// Raw scale factors for a handle drag, in the layer's local (source) axes.
    static func scaleFactors(handle: TransformHandle,
                             initial: CGAffineTransform,
                             sourceRect: CGRect,
                             currentCanvasPoint: CGPoint,
                             proportional: Bool,
                             fromCenter: Bool) -> (fx: CGFloat, fy: CGFloat) {
        guard initial.isInvertible else { return (1, 1) }
        let local = currentCanvasPoint.applying(initial.inverted())
        let anchor = fromCenter ? sourceRect.center : handle.opposite.localPoint(in: sourceRect)
        let start = handle.localPoint(in: sourceRect)

        var fx: CGFloat = 1
        var fy: CGFloat = 1
        if handle.isCorner && proportional {
            // Project the drag onto the original diagonal — uniform by default.
            let d = start - anchor
            let f = (local - anchor).dot(d) / max(d.dot(d), 1e-9)
            fx = f; fy = f
        } else {
            if handle.scalesX { fx = safeRatio(local.x - anchor.x, start.x - anchor.x) }
            if handle.scalesY { fy = safeRatio(local.y - anchor.y, start.y - anchor.y) }
        }
        return (clampScale(fx), clampScale(fy))
    }

    static func scaled(handle: TransformHandle,
                       initial: CGAffineTransform,
                       sourceRect: CGRect,
                       currentCanvasPoint: CGPoint,
                       proportional: Bool,
                       fromCenter: Bool) -> CGAffineTransform {
        let anchor = fromCenter ? sourceRect.center : handle.opposite.localPoint(in: sourceRect)
        let (fx, fy) = scaleFactors(handle: handle, initial: initial, sourceRect: sourceRect,
                                    currentCanvasPoint: currentCanvasPoint,
                                    proportional: proportional, fromCenter: fromCenter)
        return scaleAboutLocalAnchor(initial: initial, anchor: anchor, fx: fx, fy: fy)
    }

    static func scaleAboutLocalAnchor(initial: CGAffineTransform, anchor: CGPoint,
                                      fx: CGFloat, fy: CGFloat) -> CGAffineTransform {
        let about = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(scaleX: fx, y: fy))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
        return about.concatenating(initial)
    }

    static func rotated(initial: CGAffineTransform,
                        sourceRect: CGRect,
                        startCanvasPoint: CGPoint,
                        currentCanvasPoint: CGPoint,
                        snapTo15Degrees: Bool) -> CGAffineTransform {
        let center = sourceRect.center.applying(initial)
        let a0 = atan2(startCanvasPoint.y - center.y, startCanvasPoint.x - center.x)
        let a1 = atan2(currentCanvasPoint.y - center.y, currentCanvasPoint.x - center.x)
        var delta = a1 - a0
        if snapTo15Degrees {
            let step = CGFloat.pi / 12
            delta = (delta / step).rounded() * step
        }
        let about = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: delta))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return initial.concatenating(about)
    }

    static func moved(initial: CGAffineTransform, delta: CGPoint) -> CGAffineTransform {
        initial.concatenating(CGAffineTransform(translationX: delta.x, y: delta.y))
    }

    /// Shift-constrained move: project the delta onto the nearest 45° axis.
    static func constrainedTo45(_ delta: CGPoint) -> CGPoint {
        guard delta.length > 1e-9 else { return delta }
        let step = CGFloat.pi / 4
        let angle = (atan2(delta.y, delta.x) / step).rounded() * step
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let projected = delta.dot(direction)
        return CGPoint(x: direction.x * projected, y: direction.y * projected)
    }

    private static func safeRatio(_ numerator: CGFloat, _ denominator: CGFloat) -> CGFloat {
        abs(denominator) < 1e-9 ? 1 : numerator / denominator
    }

    private static func clampScale(_ f: CGFloat) -> CGFloat {
        guard f.isFinite else { return 1 }
        if abs(f) < minimumScale { return f < 0 ? -minimumScale : minimumScale }
        return f
    }
}

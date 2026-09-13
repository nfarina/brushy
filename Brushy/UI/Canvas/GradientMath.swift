import CoreGraphics

/// Gradient tool (G). The headline use is a black→white
/// linear ramp on a mask, the standard two-photo blend.

/// Options-bar gradient shape.
enum GradientShape: String, CaseIterable, Identifiable {
    case linear
    case radial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .radial: return "Radial"
        }
    }
}

/// In-progress gradient drag vector, canvas space — the overlay draws it as a
/// rubber-band line while the mouse is down; the bake happens on mouse-up.
struct GradientLine: Equatable {
    var start: CGPoint
    var end: CGPoint
}

/// Pure gradient-parameter geometry, per the TransformMath convention: the
/// mask bake in `DocumentStore` maps every pixel through these functions, and
/// the unit tests exercise them directly.
enum GradientMath {
    /// Position of `point` along the start→end vector as a unit parameter,
    /// clamped to 0...1: the entire region before the start point takes the
    /// start colour and everything past the end takes the end colour —
    /// Photoshop fills the whole target, not just the dragged span. The value
    /// is the perpendicular projection onto the vector, so it is constant
    /// along lines perpendicular to the drag.
    static func linearParameter(of point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let vector = end - start
        let lengthSquared = vector.dot(vector)
        guard lengthSquared > 0 else { return 0 }
        return min(max((point - start).dot(vector) / lengthSquared, 0), 1)
    }

    /// Radial variant: 0 at the drag start (the centre), 1 at radius
    /// |end − start|, clamped to the end colour beyond the radius.
    static func radialParameter(of point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let radius = (end - start).length
        guard radius > 0 else { return 0 }
        return min((point - start).length / radius, 1)
    }

    /// The unit ramp parameter for `point`, with `reversed` swapping the two
    /// ends (t → 1 − t) — exactly what the options-bar Reverse checkbox does.
    static func parameter(of point: CGPoint, start: CGPoint, end: CGPoint,
                          shape: GradientShape, reversed: Bool) -> CGFloat {
        let t: CGFloat
        switch shape {
        case .linear: t = linearParameter(of: point, start: start, end: end)
        case .radial: t = radialParameter(of: point, start: start, end: end)
        }
        return reversed ? 1 - t : t
    }
}

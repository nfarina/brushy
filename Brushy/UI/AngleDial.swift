import AppKit
import SwiftUI

/// Pure geometry behind `AngleDial`, unit-tested separately like
/// `TransformMath`.
enum AngleDialMath {
    /// The Photoshop angle (degrees, 0 = right, 90 = up, −180…180) of `point`
    /// seen from `center`, in SwiftUI's y-down view coordinates. `snapping`
    /// rounds to 15°, the ⇧-drag step.
    static func angle(of point: CGPoint, around center: CGPoint, snapping: Bool = false) -> Double {
        var degrees = atan2(Double(center.y - point.y), Double(point.x - center.x)) * 180 / .pi
        if snapping { degrees = (degrees / 15).rounded() * 15 }
        return normalized(degrees)
    }

    /// Folds any angle into −180…180, the range `LayerEffects.Bounds.degrees`
    /// stores (−180 and 180 are the same direction; 180 wins).
    static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    /// Unit vector for an angle, in y-down view coordinates.
    static func direction(_ degrees: Double) -> CGVector {
        let radians = degrees * .pi / 180
        return CGVector(dx: cos(radians), dy: -sin(radians))
    }
}

/// Photoshop's light-angle dial, plus what the number means: the sun sits on
/// the rim where the light comes from, and the square in the middle shows
/// which way its shadow falls. Drag anywhere on it; ⇧ snaps to 15°.
struct AngleDial: View {
    /// Degrees, Photoshop's convention (the direction the light comes FROM).
    let angle: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    /// Inner effects draw their shadow inside the layer, on the light side.
    var castsInward = false

    private let diameter: CGFloat = 44

    var body: some View {
        let radius = diameter / 2
        let light = AngleDialMath.direction(angle)
        let shadowSign: CGFloat = castsInward ? 1 : -1
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.06))
            Circle()
                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            // Shadow first, so the square sits on top of it.
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.55))
                .frame(width: 12, height: 12)
                .blur(radius: 1.2)
                .offset(x: light.dx * 4 * shadowSign, y: light.dy * 4 * shadowSign)
                .opacity(castsInward ? 0 : 1)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.9))
                .frame(width: 12, height: 12)
                .overlay {
                    if castsInward {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.black.opacity(0.6), lineWidth: 2)
                            .blur(radius: 0.8)
                            .offset(x: light.dx * 1.5, y: light.dy * 1.5)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
            Path { path in
                path.move(to: CGPoint(x: radius, y: radius))
                path.addLine(to: CGPoint(x: radius + light.dx * (radius - 5),
                                         y: radius + light.dy * (radius - 5)))
            }
            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .offset(x: light.dx * (radius - 5), y: light.dy * (radius - 5))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let snapping = NSEvent.modifierFlags.contains(.shift)
                onChange(AngleDialMath.angle(of: value.location,
                                             around: CGPoint(x: radius, y: radius),
                                             snapping: snapping))
            }
            .onEnded { _ in onEnd() })
        .help("Drag to aim the light · ⇧ snaps to 15°")
        .accessibilityElement()
        .accessibilityLabel("Light angle")
        .accessibilityValue("\(Int(angle.rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 5 : -5
            onChange(AngleDialMath.normalized(angle + step))
            onEnd()
        }
    }
}

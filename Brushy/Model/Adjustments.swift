import CoreGraphics
import Foundation

/// Adjustment layers — Photoshop's Levels, Curves and Hue/Saturation. A layer
/// with no pixels of its own that re-renders everything below it, so the
/// correction stays editable forever, which is this app's whole model (§2).
///
/// The maths here is pure and tested on its own; `RenderEngine` applies the
/// same curves through Core Image, on gamma-encoded values as Photoshop does
/// (§7), and the editors graph it.
enum AdjustmentSpec: Codable, Equatable {
    case levels(Levels)
    case curves(Curves)
    case hueSaturation(HueSaturation)

    var displayName: String {
        switch self {
        case .levels: return "Levels"
        case .curves: return "Curves"
        case .hueSaturation: return "Hue/Saturation"
        }
    }

    var systemImage: String {
        switch self {
        case .levels: return "slider.horizontal.3"
        case .curves: return "point.topleft.down.curvedto.point.bottomright.up"
        case .hueSaturation: return "paintpalette"
        }
    }

    /// True once the adjustment would actually change something — an untouched
    /// one renders as a no-op and the renderer skips it.
    var isActive: Bool {
        switch self {
        case .levels(let levels): return levels != Levels()
        case .curves(let curves): return curves != Curves()
        case .hueSaturation(let hs): return hs != HueSaturation()
        }
    }

    /// Photoshop's Levels: black and white input points with a midtone gamma
    /// between them, remapped into an output range. All 0…1.
    struct Levels: Codable, Equatable {
        var inputBlack: Double = 0
        var inputWhite: Double = 1
        /// Midtone control, 0.1…9.99 — above 1 lightens, as in Photoshop.
        var gamma: Double = 1
        var outputBlack: Double = 0
        var outputWhite: Double = 1

        func apply(_ value: Double) -> Double {
            let span = max(inputWhite - inputBlack, 1e-6)
            let normalized = min(max((value - inputBlack) / span, 0), 1)
            let curved = pow(normalized, 1 / min(max(gamma, 0.1), 9.99))
            return outputBlack + curved * (outputWhite - outputBlack)
        }
    }

    /// A five-point tone curve. Five because that is what Core Image's
    /// `CIToneCurve` takes; `apply` evaluates the same Catmull-Rom spline CI
    /// draws between them, so the editor's graph is what the pixels get.
    struct Curves: Codable, Equatable {
        /// Ordered by x (0, 0.25, 0.5, 0.75, 1); only the y values move.
        var outputs: [Double] = [0, 0.25, 0.5, 0.75, 1]

        static let inputs: [Double] = [0, 0.25, 0.5, 0.75, 1]

        var points: [CGPoint] {
            zip(Self.inputs, outputs).map { CGPoint(x: $0, y: $1) }
        }

        func apply(_ value: Double) -> Double {
            let x = min(max(value, 0), 1)
            let step = 0.25
            let segment = min(Int(x / step), 3)
            let t = (x - Double(segment) * step) / step
            // Catmull-Rom needs a neighbour either side; the ends repeat.
            func output(_ index: Int) -> Double {
                outputs[min(max(index, 0), outputs.count - 1)]
            }
            let p0 = output(segment - 1), p1 = output(segment)
            let p2 = output(segment + 1), p3 = output(segment + 2)
            let value = 0.5 * ((2 * p1)
                + (-p0 + p2) * t
                + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)
            return min(max(value, 0), 1)
        }
    }

    /// Hue rotation in degrees, saturation and lightness as Photoshop's
    /// −100…100 percentages.
    struct HueSaturation: Codable, Equatable {
        var hue: Double = 0
        var saturation: Double = 0
        var lightness: Double = 0
    }

    /// Adjustment layers carry no pixels, but `Layer.source` is not optional —
    /// every layer has one — so they hold this 1×1 transparent placeholder.
    /// Nothing ever samples it: the renderer branches on the kind first.
    static func placeholderSource() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: BrushyColorSpace.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        return ctx.makeImage()
    }
}

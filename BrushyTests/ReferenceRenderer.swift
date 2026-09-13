import CoreGraphics
import Foundation

/// Independent CPU compositor used to generate "analytic" golden references.
///
/// Deliberately shares no code with the production pipeline: its own transfer
/// functions, double-precision premultiplied source-over in linear light, and
/// closed-form (erf) Gaussian feather. To keep the math exact it supports only
/// what the analytic fixtures need:
///   - Display P3-tagged, fully opaque inputs (no colour matrix involved)
///   - integer-translation transforms (no resampling kernel involved)
///   - Display P3 output
/// Anything else throws, so a fixture can't silently claim analytic authority
/// it doesn't have.
enum ReferenceRenderError: Error {
    case unsupportedTransform(String)
    case unsupportedInput(String)
    case unsupportedOutput(String)
}

enum ReferenceRenderer {
    static func render(spec: FixtureSpec, fixturesDir: URL) throws -> CGImage {
        guard spec.outputProfile == "displayP3" else {
            throw ReferenceRenderError.unsupportedOutput("analytic fixtures must output displayP3")
        }
        let W = spec.canvas.width
        let H = spec.canvas.height
        // Premultiplied linear P3, indexed by row-from-top.
        var buffer = [Double](repeating: 0, count: W * H * 4)

        for layerSpec in spec.layers where layerSpec.visible ?? true {
            let t = layerSpec.transform
            guard t.count == 6, t[0] == 1, t[1] == 0, t[2] == 0, t[3] == 1,
                  t[4] == t[4].rounded(), t[5] == t[5].rounded() else {
                throw ReferenceRenderError.unsupportedTransform(
                    "analytic fixtures use integer translations only: \(t)")
            }
            let tx = Int(t[4]), ty = Int(t[5])
            let url = fixturesDir.appendingPathComponent(layerSpec.source)
            let cgImage = try loadPNG(url)
            guard cgImage.colorSpace?.name == BrushyColorSpace.displayP3.name else {
                throw ReferenceRenderError.unsupportedInput("\(layerSpec.source) must be Display P3")
            }
            let src = try rawRGBA8(cgImage)
            let opacity = layerSpec.opacity ?? 1

            let mask = layerSpec.mask
            var profileX: [Double] = []
            var profileY: [Double] = []
            if let mask {
                guard mask.selectionRect.count == 4,
                      mask.selectionRect.allSatisfy({ $0 == $0.rounded() }) else {
                    throw ReferenceRenderError.unsupportedInput(
                        "analytic mask rects must be integer-aligned")
                }
                let r = mask.selectionRect
                let sigma = mask.feather / 2
                profileX = Self.discreteProfile(count: W, lo: Int(r[0]), hi: Int(r[0] + r[2]), sigma: sigma)
                profileY = Self.discreteProfile(count: H, lo: Int(r[1]), hi: Int(r[1] + r[3]), sigma: sigma)
            }

            for row in 0..<src.height {
                // Canvas row (from top) for this source row, from the y-up translate.
                let canvasRow = row + (H - src.height - ty)
                guard canvasRow >= 0 && canvasRow < H else { continue }
                for col in 0..<src.width {
                    let canvasCol = col + tx
                    guard canvasCol >= 0 && canvasCol < W else { continue }
                    let p = src[col, row]
                    guard p.a == 255 else {
                        throw ReferenceRenderError.unsupportedInput(
                            "\(layerSpec.source) must be fully opaque")
                    }
                    var alpha = opacity
                    if mask != nil {
                        // The pipeline stores the blurred mask as 8-bit,
                        // quantised once after the separable float blur.
                        let m = profileX[canvasCol] * profileY[H - 1 - canvasRow]
                        alpha *= (m * 255).rounded() / 255
                    }
                    guard alpha > 0 else { continue }
                    let rLin = decode(Double(p.r) / 255)
                    let gLin = decode(Double(p.g) / 255)
                    let bLin = decode(Double(p.b) / 255)
                    let i = (canvasRow * W + canvasCol) * 4
                    buffer[i] = rLin * alpha + buffer[i] * (1 - alpha)
                    buffer[i + 1] = gLin * alpha + buffer[i + 1] * (1 - alpha)
                    buffer[i + 2] = bLin * alpha + buffer[i + 2] * (1 - alpha)
                    buffer[i + 3] = alpha + buffer[i + 3] * (1 - alpha)
                }
            }
        }

        return GeneratedImages.image(width: W, height: H,
                                     colorSpace: BrushyColorSpace.displayP3) { x, y in
            let i = (y * W + x) * 4
            let a = buffer[i + 3]
            guard a > 0 else { return (0, 0, 0, 0) }
            func out(_ v: Double) -> UInt8 {
                UInt8((encode(min(max(v / a, 0), 1)) * 255).rounded())
            }
            return (out(buffer[i]), out(buffer[i + 1]), out(buffer[i + 2]),
                    UInt8((a * 255).rounded()))
        }
    }

    /// 1D blurred profile of an integer-aligned interval [lo, hi), matching the
    /// pipeline's pinned feather definition — discrete Gaussian, radius ⌈3σ⌉,
    /// sum-normalised taps — but implemented independently in double precision.
    /// The separable 2D blur of a rect is the product of its two 1D profiles.
    private static func discreteProfile(count: Int, lo: Int, hi: Int, sigma: Double) -> [Double] {
        guard sigma > 0 else {
            return (0..<count).map { ($0 >= lo && $0 < hi) ? 1 : 0 }
        }
        let radius = max(1, Int(ceil(3 * sigma)))
        var taps = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        return (0..<count).map { k in
            var value = 0.0
            for j in -radius...radius where (k - j) >= lo && (k - j) < hi {
                value += taps[j + radius]
            }
            return value
        }
    }

    // Display P3 uses the sRGB transfer curve.
    private static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

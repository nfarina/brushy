import CoreGraphics
import Foundation

/// Deterministic image builders, used by the demo document and the test
/// fixtures. Pixels are computed byte-for-byte (no CG drawing paths involved),
/// so generated inputs are exactly reproducible.
enum GeneratedImages {
    /// Builds an RGBA8 image by evaluating `pixel(col, rowFromTop)`.
    /// Returned bytes are straight (unpremultiplied) RGBA tagged with `space`.
    static func image(width: Int, height: Int,
                      colorSpace: CGColorSpace,
                      pixel: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width {
                    let (r, g, b, a) = pixel(col, row)
                    let i = (row * width + col) * 4
                    bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = a
                }
            }
        }
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func solid(width: Int, height: Int,
                      r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255,
                      colorSpace: CGColorSpace) -> CGImage {
        image(width: width, height: height, colorSpace: colorSpace) { _, _ in (r, g, b, a) }
    }

    /// Horizontal gradient, `from` at the left edge to `to` at the right edge.
    static func horizontalGradient(width: Int, height: Int,
                                   from: (UInt8, UInt8, UInt8),
                                   to: (UInt8, UInt8, UInt8),
                                   colorSpace: CGColorSpace) -> CGImage {
        image(width: width, height: height, colorSpace: colorSpace) { col, _ in
            let t = width > 1 ? Double(col) / Double(width - 1) : 0
            func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
                UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded())
            }
            return (mix(from.0, to.0), mix(from.1, to.1), mix(from.2, to.2), 255)
        }
    }

    /// Gradient with a checker pattern mixed in — busy content that makes
    /// resampling differences visible in recorded fixtures.
    static func gradientChecker(width: Int, height: Int,
                                square: Int,
                                colorSpace: CGColorSpace) -> CGImage {
        image(width: width, height: height, colorSpace: colorSpace) { col, row in
            let t = width > 1 ? Double(col) / Double(width - 1) : 0
            let dark = ((col / square) + (row / square)) % 2 == 0
            let r = UInt8((t * 255).rounded())
            let g: UInt8 = dark ? 40 : 200
            let b = UInt8(((1 - t) * 255).rounded())
            return (r, g, b, 255)
        }
    }
}

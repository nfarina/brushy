import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

enum TestPaths {
    static let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixturesDir = testsDir.appendingPathComponent("Fixtures")
    static let inputsDir = fixturesDir.appendingPathComponent("inputs")
    static let referencesDir = fixturesDir.appendingPathComponent("references")
    static let repoRoot = testsDir.deletingLastPathComponent()
    static let outputDir = repoRoot.appendingPathComponent("test-output")

    /// Run with TEST_RUNNER_RECORD_FIXTURES=1 in the xcodebuild environment to
    /// (re)generate fixture inputs, specs and reference images.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["RECORD_FIXTURES"] == "1"
    }

    static func ensureDirs() throws {
        let fm = FileManager.default
        for dir in [fixturesDir, inputsDir, referencesDir, outputDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// 8-bit RGBA pixels drawn through a premultiplied context in a known colour
/// space. Row 0 is the top of the image. Comparisons are exact where alpha is
/// 0 or 255 (premultiplication is lossless there); fixtures keep final alpha
/// binary for that reason.
struct RawImage {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    subscript(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
    }
}

enum TestImageError: Error {
    case contextFailed
    case loadFailed(URL)
    case encodeFailed(URL)
}

/// Decodes `image` into raw RGBA8. When `space` is nil the image's own colour
/// space is used (no conversion — byte-exact for 8-bit RGBA sources); passing a
/// different space performs a ColorSync conversion (used to build the
/// "colorsync" reference kind).
func rawRGBA8(_ image: CGImage, in space: CGColorSpace? = nil) throws -> RawImage {
    let target = space ?? image.colorSpace ?? BrushyColorSpace.sRGB
    let width = image.width, height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let ok = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
        guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: target,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return false
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard ok else { throw TestImageError.contextFailed }
    return RawImage(width: width, height: height, rgba: data)
}

func loadPNG(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw TestImageError.loadFailed(url)
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        throw TestImageError.encodeFailed(url)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw TestImageError.encodeFailed(url) }
}

// MARK: - Pixel diffing

struct DiffStats {
    var maxColorDelta = 0
    var maxAlphaDelta = 0
    var deviatingPixels = 0
    var totalPixels = 0

    var summary: String {
        "maxColorΔ=\(maxColorDelta) maxAlphaΔ=\(maxAlphaDelta) " +
        "deviating=\(deviatingPixels)/\(totalPixels)"
    }
}

/// Fails a pixel on any colour-channel deviation greater than `colorTolerance`
/// (compared where both alphas are non-zero, since RGB is meaningless under
/// alpha 0) or any alpha deviation greater than `alphaTolerance`.
func comparePixels(actual: RawImage, reference: RawImage,
                   colorTolerance: Int, alphaTolerance: Int) -> (DiffStats, [Bool]) {
    precondition(actual.width == reference.width && actual.height == reference.height)
    var stats = DiffStats()
    stats.totalPixels = actual.width * actual.height
    var deviations = [Bool](repeating: false, count: stats.totalPixels)
    for y in 0..<actual.height {
        for x in 0..<actual.width {
            let a = actual[x, y]
            let r = reference[x, y]
            let alphaDelta = abs(Int(a.a) - Int(r.a))
            stats.maxAlphaDelta = max(stats.maxAlphaDelta, alphaDelta)
            var colorDelta = 0
            if a.a > 0 && r.a > 0 {
                colorDelta = max(abs(Int(a.r) - Int(r.r)),
                                 max(abs(Int(a.g) - Int(r.g)), abs(Int(a.b) - Int(r.b))))
                stats.maxColorDelta = max(stats.maxColorDelta, colorDelta)
            }
            if alphaDelta > alphaTolerance || colorDelta > colorTolerance {
                stats.deviatingPixels += 1
                deviations[y * actual.width + x] = true
            }
        }
    }
    return (stats, deviations)
}

/// Visual diff: the reference dimmed to grayscale, deviating pixels solid red.
func writeDiffImage(reference: RawImage, deviations: [Bool], to url: URL) throws {
    let image = GeneratedImages.image(width: reference.width, height: reference.height,
                                      colorSpace: BrushyColorSpace.sRGB) { x, y in
        if deviations[y * reference.width + x] { return (255, 0, 0, 255) }
        let p = reference[x, y]
        let weighted: Double = 0.3 * Double(p.r) + 0.6 * Double(p.g) + 0.1 * Double(p.b)
        let luma = UInt8(weighted * 0.45)
        return (luma, luma, luma, 255)
    }
    try writePNG(image, to: url)
}

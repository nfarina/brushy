import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum ImageImportError: LocalizedError {
    case unreadable(URL)
    case undecodable(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Could not open “\(url.lastPathComponent)”."
        case .undecodable(let url): return "“\(url.lastPathComponent)” is not a decodable image."
        }
    }
}

/// Import policy:
/// - The embedded ICC profile is honoured; untagged images are assumed sRGB.
///   The colour conversion into the P3 working space happens in floating point
///   inside Core Image at render time, so RGB sources keep their original bytes —
///   equivalent to converting at import, without an 8-bit quantisation step.
/// - EXIF orientation is baked in (an exact 90°-multiple pixel permutation).
/// - Non-RGB colour models (CMYK, indexed, grayscale) are converted to RGBA in
///   the working space once, at import.
enum ImageImporter {
    /// What this app will decode into memory.
    ///
    /// Compressed image formats let a few hundred bytes describe an enormous
    /// raster, so the size of the DATA says nothing about the size of the
    /// decode — and `kCGImageSourceShouldCacheImmediately` (used everywhere
    /// here, deliberately: wants the pixels, not a lazy proxy) turns that
    /// into an immediate allocation. Both routes into the app carry untrusted
    /// data: a `.brushy` package is a folder of PNGs the user can swap, and the
    /// clipboard takes whatever any process on the machine put there.
    enum Limits {
        /// Sanity ceiling per side. Deliberately NOT
        /// `Document.canvasSizeLimits` (16384): a layer's source is not a
        /// canvas, it can be much larger than the frame it is placed in, and a
        /// stitched panorama past 16384 px on its long edge is an ordinary
        /// photograph. Capping per-side at the canvas limit would have made
        /// documents that already exist fail to reopen.
        static let maxDimension = 65_536

        /// The real bound is on the DECODE, not the shape: 4 bytes per pixel
        /// for RGBA8. 1 GiB is ~268 megapixels — a 16384² square, or a
        /// 30000×8900 panorama — comfortably past any real photograph and far
        /// short of the 400-megapixel PNG that fits in 380 KB on disk.
        static let maxImageDecodedBytes = 1 << 30

        /// Across one document's sources and masks together: a package is as
        /// easily bombed with a thousand modest images as with one huge one.
        static let maxDocumentDecodedBytes = 4 << 30

        /// `.brushy` layer records. Generous; rules out only the absurd.
        static let maxLayers = 4_096
    }

    /// Running total for one document's decodes, so many modest images are
    /// bounded the same way one huge image is.
    struct DecodeBudget {
        private var spent = 0

        mutating func charge(_ bytes: Int) -> Bool {
            let (total, overflow) = spent.addingReportingOverflow(bytes)
            guard !overflow, total <= Limits.maxDocumentDecodedBytes else { return false }
            spent = total
            return true
        }
    }

    /// Pixel dimensions straight from the ImageIO properties — no pixels
    /// decoded, which is the whole point: it is what lets a caller refuse an
    /// image before paying for it.
    static func pixelDimensions(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Decodes image 0 only if it is within `Limits`, charging `budget` when
    /// one is supplied. Returns nil rather than throwing so the existing
    /// "couldn't decode" paths handle an oversized image identically to a
    /// corrupt one.
    static func decodeBounded(_ source: CGImageSource,
                              budget: inout DecodeBudget?) -> CGImage? {
        guard let (width, height) = pixelDimensions(of: source),
              width <= Limits.maxDimension, height <= Limits.maxDimension else { return nil }
        // 4 bytes per pixel is the decoded RGBA8 footprint; deep images cost
        // more, so this is a floor on the true cost, which is the right side
        // to err on for a budget that exists to stop runaway allocation.
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !byteOverflow, bytes <= Limits.maxImageDecodedBytes else { return nil }
        if budget != nil {
            guard budget!.charge(bytes) else { return nil }
        }
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Convenience for the callers that decode a single image with no
    /// document-wide budget to answer to.
    static func decodeBounded(_ source: CGImageSource) -> CGImage? {
        var none: DecodeBudget?
        return decodeBounded(source, budget: &none)
    }

    static func importImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageImportError.unreadable(url)
        }
        guard let image = decodeBounded(source) else {
            throw ImageImportError.undecodable(url)
        }
        var orientation = CGImagePropertyOrientation.up
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = props[kCGImagePropertyOrientation] as? UInt32,
           let parsed = CGImagePropertyOrientation(rawValue: raw) {
            orientation = parsed
        }
        return normalize(image, orientation: orientation)
    }

    static func normalize(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) -> CGImage {
        var result = image
        if let space = result.colorSpace, space.model == .rgb {
            if space.name == nil && space.copyICCData() == nil {
                // Device RGB with no profile: assume sRGB without touching pixels.
                result = result.copy(colorSpace: BrushyColorSpace.sRGB) ?? result
            }
        } else {
            result = convertedToWorkingRGBA(result) ?? result
        }
        if orientation != .up {
            result = bakingOrientation(orientation, into: result) ?? result
        }
        return result
    }

    /// One-time conversion for non-RGB sources (CMYK, indexed, grayscale…).
    private static func convertedToWorkingRGBA(_ image: CGImage) -> CGImage? {
        let deep = image.bitsPerComponent > 8
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                                  space: BrushyColorSpace.displayP3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Bakes EXIF orientation with an exact pixel permutation. Uses a
    /// colour-management-free CIContext so the bytes pass through untouched.
    private static func bakingOrientation(_ orientation: CGImagePropertyOrientation,
                                          into image: CGImage) -> CGImage? {
        let oriented = CIImage(cgImage: image).oriented(orientation)
        let format: CIFormat = image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let space = image.colorSpace else { return nil }
        return Self.passthroughContext.createCGImage(
            oriented, from: oriented.extent, format: format, colorSpace: space)
    }

    private static let passthroughContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
    ])
}

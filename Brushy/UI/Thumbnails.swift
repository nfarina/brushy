import AppKit
import CoreGraphics

/// Layer/mask thumbnails, cached on the immutable source/mask identity.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func layerThumbnail(for layer: Layer) -> NSImage {
        let key = "src-\(layer.sourceID.uuidString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = Self.render(layer.source, checkerboard: true)
        cache.setObject(image, forKey: key)
        return image
    }

    func maskThumbnail(for mask: Mask) -> NSImage {
        // Keyed on the buffer's identity, which now changes with its bytes.
        // This was the hash of an ObjectIdentifier — an address, hashed —
        // so it could collide outright AND go stale when a freed Storage's
        // address was reused, showing another layer's mask in this row.
        let key = "mask-\(mask.texture.storageIdentity.uuidString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = mask.texture.cgImage.map { Self.render($0, checkerboard: false) } ?? NSImage()
        cache.setObject(image, forKey: key)
        return image
    }

    private static func render(_ source: CGImage, checkerboard: Bool,
                               maxSide: CGFloat = 44) -> NSImage {
        let w = CGFloat(source.width), h = CGFloat(source.height)
        let scale = min(maxSide / max(w, 1), maxSide / max(h, 1), 1)
        let size = CGSize(width: max(1, (w * scale).rounded()),
                          height: max(1, (h * scale).rounded()))
        let image = NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            if checkerboard {
                ctx.setFillColor(CGColor(gray: 0.72, alpha: 1))
                ctx.fill(rect)
                ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
                let square: CGFloat = 5
                var row = 0
                var y: CGFloat = 0
                while y < rect.height {
                    var x: CGFloat = row % 2 == 0 ? square : 0
                    while x < rect.width {
                        ctx.fill(CGRect(x: x, y: y, width: square, height: square))
                        x += square * 2
                    }
                    y += square
                    row += 1
                }
            }
            ctx.interpolationQuality = .medium
            ctx.draw(source, in: rect)
            return true
        }
        return image
    }
}

import CoreGraphics

/// Image ▸ Trim… geometry (Photoshop's Trim dialog): which pixels count as
/// content, and the canvas rect that keeps them on the sides being trimmed.
enum TrimBounds {
    enum Basis: String, CaseIterable, Identifiable {
        case transparentPixels = "Transparent Pixels"
        case topLeftColor = "Top Left Pixel Color"
        case bottomRightColor = "Bottom Right Pixel Color"
        var id: Self { self }
    }

    struct Sides: Equatable {
        var top = true, bottom = true, left = true, right = true
    }

    /// Canvas-space (y-up) bounds of the content in a premultiplied RGBA8
    /// buffer whose row 0 is the TOP row (§3 — the usual mask flip), or nil
    /// when nothing counts as content. Transparent Pixels: any alpha.
    /// A corner colour: any pixel whose four bytes differ from that corner's.
    static func contentRect(rgba: UnsafeRawBufferPointer, width: Int, height: Int,
                            bytesPerRow: Int, basis: Basis) -> CGRect? {
        guard width > 0, height > 0 else { return nil }
        let words = rgba.bindMemory(to: UInt32.self)
        let wordsPerRow = bytesPerRow / 4
        let isContent: (UInt32) -> Bool
        switch basis {
        case .transparentPixels:
            // Alpha is the last byte; read it bytewise so endianness can't matter.
            var alphaMask: UInt32 = 0
            withUnsafeMutableBytes(of: &alphaMask) { $0[3] = 0xFF }
            isContent = { $0 & alphaMask != 0 }
        case .topLeftColor:
            let corner = words[0]
            isContent = { $0 != corner }
        case .bottomRightColor:
            let corner = words[(height - 1) * wordsPerRow + width - 1]
            isContent = { $0 != corner }
        }
        var minRow = Int.max, maxRow = -1, minCol = Int.max, maxCol = -1
        for row in 0..<height {
            let base = row * wordsPerRow
            var first = -1
            for col in 0..<width where isContent(words[base + col]) { first = col; break }
            guard first >= 0 else { continue }
            var last = first
            for col in stride(from: width - 1, to: max(first, maxCol), by: -1)
            where isContent(words[base + col]) {
                last = col; break
            }
            minRow = min(minRow, row); maxRow = row
            minCol = min(minCol, first); maxCol = max(maxCol, last)
        }
        guard maxRow >= 0 else { return nil }
        return CGRect(x: minCol, y: height - 1 - maxRow,
                      width: maxCol - minCol + 1, height: maxRow - minRow + 1)
    }

    /// `contentRect` of a rendered image, read through an RGBA8 context in
    /// the image's own colour space so equal colours stay equal bytes.
    static func contentRect(of image: CGImage, basis: Basis) -> CGRect? {
        let w = image.width, h = image.height
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return contentRect(rgba: UnsafeRawBufferPointer(start: data, count: ctx.bytesPerRow * h),
                           width: w, height: h, bytesPerRow: ctx.bytesPerRow, basis: basis)
    }

    /// The canvas after trimming only `sides` in to `content` (canvas space,
    /// y-up: top is maxY). Untrimmed sides keep the canvas edge.
    static func trimmedRect(canvas: CGRect, content: CGRect, sides: Sides) -> CGRect {
        let minX = sides.left ? content.minX : canvas.minX
        let maxX = sides.right ? content.maxX : canvas.maxX
        let minY = sides.bottom ? content.minY : canvas.minY
        let maxY = sides.top ? content.maxY : canvas.maxY
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

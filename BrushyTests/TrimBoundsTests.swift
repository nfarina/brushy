import CoreGraphics
import XCTest

final class TrimBoundsTests: XCTestCase {

    /// One string per row, TOP row first: "." transparent, "#" opaque red,
    /// "w" opaque white. Rows are padded to check bytesPerRow is honoured.
    private func content(_ rows: [String], _ basis: TrimBounds.Basis) -> CGRect? {
        let w = rows[0].count, h = rows.count, stride = (w + 2) * 4
        var bytes = [UInt8](repeating: 0, count: stride * h)
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() {
                let px: [UInt8] = ch == "#" ? [255, 0, 0, 255] : ch == "w" ? [255, 255, 255, 255] : [0, 0, 0, 0]
                bytes.replaceSubrange(r * stride + c * 4 ..< r * stride + c * 4 + 4, with: px)
            }
        }
        return bytes.withUnsafeBytes {
            TrimBounds.contentRect(rgba: $0, width: w, height: h, bytesPerRow: stride, basis: basis)
        }
    }

    func testTransparentPixelsBoundsAreCanvasSpaceYUp() {
        let rect = content([
            "......",
            "..#...",
            "....#.",
            "......",
            "......",
        ], .transparentPixels)
        // Rows 1–2 from the top of a 5-row buffer are canvas y 2…3.
        XCTAssertEqual(rect, CGRect(x: 2, y: 2, width: 3, height: 2))
    }

    func testCornerColorBases() {
        let rows = [
            "wwwww",
            "w#www",
            "www#.",
        ]
        // Top-left is white: the red pixels and the transparent corner are content.
        XCTAssertEqual(content(rows, .topLeftColor), CGRect(x: 1, y: 0, width: 4, height: 2))
        // Bottom-right is transparent: every opaque pixel is content.
        XCTAssertEqual(content(rows, .bottomRightColor), CGRect(x: 0, y: 0, width: 5, height: 3))
        XCTAssertEqual(content(rows, .transparentPixels), CGRect(x: 0, y: 0, width: 5, height: 3))
    }

    func testNothingToKeepIsNil() {
        XCTAssertNil(content(["...", "..."], .transparentPixels))
        XCTAssertNil(content(["ww", "ww"], .topLeftColor))
    }

    func testTrimmedRectHonoursSides() {
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 80)
        let content = CGRect(x: 10, y: 5, width: 50, height: 40)
        XCTAssertEqual(TrimBounds.trimmedRect(canvas: canvas, content: content, sides: .init()),
                       content)
        let topAndLeftOnly = TrimBounds.Sides(top: true, bottom: false, left: true, right: false)
        XCTAssertEqual(TrimBounds.trimmedRect(canvas: canvas, content: content, sides: topAndLeftOnly),
                       CGRect(x: 10, y: 0, width: 90, height: 45))
    }

    func testReadsARenderedImage() {
        let ctx = CGContext(data: nil, width: 50, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        ctx.fill(CGRect(x: 10, y: 5, width: 7, height: 3)) // CGContext is y-up too
        XCTAssertEqual(TrimBounds.contentRect(of: ctx.makeImage()!, basis: .transparentPixels),
                       CGRect(x: 10, y: 5, width: 7, height: 3))
        XCTAssertEqual(TrimBounds.contentRect(of: ctx.makeImage()!, basis: .topLeftColor),
                       CGRect(x: 10, y: 5, width: 7, height: 3))
    }
}

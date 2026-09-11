import CoreGraphics
import CoreImage
import XCTest

/// The canvas display should read as pixels: hard-edged squares when zoomed
/// in, and a transparency checkerboard that travels with the canvas.
final class DisplayPixelTests: XCTestCase {
    private let engine = RenderEngine.shared

    /// RGBA8 sRGB pixel at (x, y), y measured from the TOP of `bounds`.
    private func pixel(_ image: CIImage, bounds: CGRect, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let cg = engine.context.createCGImage(image, from: bounds, format: .RGBA8,
                                              colorSpace: DezzyColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: DezzyColorSpace.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (y * cg.width + x) * 4
        return (data[i], data[i + 1], data[i + 2])
    }

    func testMagnifiedPixelsHaveHardEdges() {
        let srgb = DezzyColorSpace.sRGB
        var document = Document(canvasSize: CGSize(width: 2, height: 1))
        document.layers = [
            Layer(name: "red", source: GeneratedImages.solid(width: 1, height: 1, r: 255, g: 0, b: 0,
                                                             colorSpace: srgb)),
            Layer(name: "blue", source: GeneratedImages.solid(width: 1, height: 1, r: 0, g: 0, b: 255,
                                                              colorSpace: srgb),
                  transform: CGAffineTransform(translationX: 1, y: 0)),
        ]
        let bounds = CGRect(x: 0, y: 0, width: 16, height: 8)
        let image = engine.displayImage(for: document,
                                        viewTransform: CGAffineTransform(scaleX: 8, y: 8),
                                        viewPixelBounds: bounds, contentScale: 1)
        // Device pixels 7 and 8 straddle the boundary between the two document
        // pixels; smoothing would blend both towards purple.
        let left = pixel(image, bounds: bounds, x: 7, y: 4)
        let right = pixel(image, bounds: bounds, x: 8, y: 4)
        XCTAssertGreaterThan(left.r, 240, "last device pixel of the red square — got \(left)")
        XCTAssertLessThan(left.b, 15, "last device pixel of the red square — got \(left)")
        XCTAssertGreaterThan(right.b, 240, "first device pixel of the blue square — got \(right)")
        XCTAssertLessThan(right.r, 15, "first device pixel of the blue square — got \(right)")
    }

    /// A 20×20 canvas filled black edge to edge, on a layer that runs on into
    /// transparency past every canvas edge — the state after select, fill,
    /// crop.
    private func blackCanvasOverTransparency() -> Document {
        let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: DezzyColorSpace.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        var document = Document(canvasSize: CGSize(width: 20, height: 20))
        document.layers = [Layer(name: "filled", source: ctx.makeImage()!,
                                 transform: CGAffineTransform(translationX: -10, y: -10))]
        return document
    }

    /// No zoom may leave a sliver of checkerboard along the canvas edge: the
    /// outermost device pixels are content, the next ones out are surround.
    func testCanvasEdgesShowNoCheckerboardSliver() {
        let document = blackCanvasOverTransparency()
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 160)
        let surround = pixel(engine.displayImage(for: Document(canvasSize: CGSize(width: 1, height: 1)),
                                                 viewTransform: CGAffineTransform(translationX: 500, y: 0),
                                                 viewPixelBounds: bounds, contentScale: 1),
                             bounds: bounds, x: 80, y: 80).r
        for (scale, offset) in [(CGFloat(7.3), CGFloat(0.4)), (0.63, 10.37), (0.3, 20.6)] {
            let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset, ty: offset)
            let edges = CGRect(x: 0, y: 0, width: 20, height: 20)
                .applying(DisplayGeometry.pixelAligned(transform, canvasSize: document.canvasSize))
            let image = engine.displayImage(for: document, viewTransform: transform,
                                            viewPixelBounds: bounds, contentScale: 1)
            let row = Int(bounds.height - edges.midY)
            for (x, inside) in [(Int(edges.minX), true), (Int(edges.maxX) - 1, true),
                                (Int(edges.minX) - 1, false), (Int(edges.maxX), false)]
                where x >= 0 && x < Int(bounds.width) {
                let r = pixel(image, bounds: bounds, x: x, y: row).r
                if inside {
                    XCTAssertLessThanOrEqual(r, surround,
                                             "scale \(scale): edge column \(x) shows checkerboard (r=\(r))")
                } else {
                    XCTAssertEqual(r, surround, "scale \(scale): column \(x) outside the canvas")
                }
            }
        }
    }

    /// The overlay's pixel grid lines must fall exactly where the magnified
    /// composite switches from one document pixel to the next.
    func testPixelGridLinesMatchTheRenderedPixelBoundaries() {
        let srgb = DezzyColorSpace.sRGB
        var document = Document(canvasSize: CGSize(width: 3, height: 1))
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255)]
        document.layers = colors.enumerated().map { i, c in
            Layer(name: "p\(i)", source: GeneratedImages.solid(width: 1, height: 1, r: c.0, g: c.1, b: c.2,
                                                               colorSpace: srgb),
                  transform: CGAffineTransform(translationX: CGFloat(i), y: 0))
        }
        let transform = CGAffineTransform(a: 7.3, b: 0, c: 0, d: 7.3, tx: 0.4, ty: 0)
        let bounds = CGRect(x: 0, y: 0, width: 24, height: 8)
        let image = engine.displayImage(for: document, viewTransform: transform,
                                        viewPixelBounds: bounds, contentScale: 1)
        let aligned = DisplayGeometry.pixelAligned(transform, canvasSize: document.canvasSize)
        let columns = DisplayGeometry.pixelGridLines(aligned: aligned, canvasSize: document.canvasSize,
                                                     visible: bounds).columns
        XCTAssertEqual(columns.count, 2)
        func dominant(_ x: Int) -> Int {
            let p = pixel(image, bounds: bounds, x: x, y: 4)
            return [p.r, p.g, p.b].enumerated().max { $0.element < $1.element }!.offset
        }
        for (k, column) in zip(1..., columns) {
            XCTAssertEqual(dominant(column), k, "grid column \(column) starts document pixel \(k)")
            XCTAssertEqual(dominant(column - 1), k - 1, "column \(column - 1) still shows pixel \(k - 1)")
        }
    }

    func testCheckerboardScrollsWithTheCanvas() {
        let document = Document(canvasSize: CGSize(width: 32, height: 32))
        let bounds = CGRect(x: 0, y: 0, width: 48, height: 32)
        func render(panX: CGFloat) -> CIImage {
            engine.displayImage(for: document,
                                viewTransform: CGAffineTransform(translationX: panX, y: 0),
                                viewPixelBounds: bounds, contentScale: 1)
        }
        // Same canvas pixel, panned one checker square (8 px) apart: a
        // screen-anchored board would show the other colour.
        let before = pixel(render(panX: 0), bounds: bounds, x: 4, y: 4)
        let after = pixel(render(panX: 8), bounds: bounds, x: 12, y: 4)
        XCTAssertEqual(before.r, after.r, "checker colour under a canvas pixel must not change when panning")
    }
}

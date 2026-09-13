import CoreGraphics
import CoreImage
import Foundation
import Metal
import XCTest

/// performance target: 60fps interactive drag with 8 layers at 6000×4000.
/// Simulates the interactive case — the display graph rebuilt every frame with
/// a moving layer (so nothing benefits from output caching), rendered at a
/// 2560×1440 viewport, fit zoom (which exercises the Lanczos display path).
final class PerformanceTests: XCTestCase {
    func testInteractiveFrameTimeWith8LayersAt6000x4000() throws {
        let engine = RenderEngine.shared
        guard let device = engine.device, let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device available")
        }

        var document = Document(canvasSize: CGSize(width: 6000, height: 4000))
        for i in 0..<8 {
            let source = Self.perfSource(index: i)
            var layer = Layer(name: "P\(i)", source: source)
            if i > 0 {
                let scale = 0.28 + CGFloat(i) * 0.02
                layer.transform = CGAffineTransform(rotationAngle: CGFloat(i) * 0.23)
                    .scaledBy(x: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: CGFloat((i * 830) % 4200),
                                                     y: CGFloat((i * 1170) % 2600)))
            }
            document.layers.append(layer)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 2560, height: 1440, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Could not create render target")
        }

        let viewBounds = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let fitScale = 2560.0 / 6000.0

        func renderFrame(_ frame: Int) throws {
            // Move the top layer a little every frame, like an interactive drag.
            var doc = document
            doc.layers[7].transform = doc.layers[7].transform
                .concatenating(CGAffineTransform(translationX: CGFloat(frame), y: CGFloat(frame / 2)))
            let viewTransform = CGAffineTransform(scaleX: fitScale, y: fitScale)
            let image = engine.displayImage(for: doc,
                                            viewTransform: viewTransform,
                                            viewPixelBounds: viewBounds,
                                            contentScale: 2)
            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
            destination.colorSpace = BrushyColorSpace.displayP3
            _ = try engine.context.startTask(toRender: image, to: destination)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        for frame in 0..<3 { try renderFrame(frame) } // warmup: texture uploads etc.

        let frames = 20
        let start = CFAbsoluteTimeGetCurrent()
        for frame in 0..<frames { try renderFrame(frame + 10) }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let msPerFrame = elapsed / Double(frames) * 1000
        print("PERF: \(String(format: "%.2f", msPerFrame)) ms/frame " +
              "(60fps budget: 16.7ms) — 8 layers @ 6000×4000, 2560×1440 viewport")

        XCTAssertLessThan(msPerFrame, 16.8,
                          "Interactive frame time \(String(format: "%.2f", msPerFrame))ms misses the 60fps target — report the bottleneck rather than caching rasters")
    }

    /// Big busy source, built through CGContext (speed matters more than
    /// byte-determinism here).
    private static func perfSource(index: Int) -> CGImage {
        let width = 6000, height = 4000
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: BrushyColorSpace.displayP3,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(colorSpace: BrushyColorSpace.displayP3,
                              components: [CGFloat(index % 3 == 0 ? 1 : 0.2), 0.4, 0.8, 1])!,
                      CGColor(colorSpace: BrushyColorSpace.displayP3,
                              components: [0.9, CGFloat(index % 2 == 0 ? 0.8 : 0.1), 0.2, 1])!]
        let gradient = CGGradient(colorsSpace: BrushyColorSpace.displayP3,
                                  colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient,
                               start: .zero,
                               end: CGPoint(x: width, y: height), options: [])
        // Deterministic scatter of rectangles for high-frequency content.
        var seed = UInt64(index * 7919 + 13)
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
        }
        for _ in 0..<300 {
            ctx.setFillColor(CGColor(colorSpace: BrushyColorSpace.displayP3,
                                     components: [next(), next(), next(), 1])!)
            ctx.fill(CGRect(x: next() * 5800, y: next() * 3800,
                            width: 20 + next() * 400, height: 20 + next() * 400))
        }
        return ctx.makeImage()!
    }
}

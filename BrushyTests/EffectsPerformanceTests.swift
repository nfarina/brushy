import CoreGraphics
import CoreImage
import Foundation
import Metal
import XCTest

/// Frame cost of layer effects, kept in its own suite for the reason
/// `GroupPerformanceTests` is: the budget test is order-fragile at suite
/// scale, so perf lives apart and is trusted only when run on its own
/// (`-only-testing:BrushyTests/EffectsPerformanceTests`).
///
/// Two things are being guarded, and neither is "effects are free":
///
/// 1. A layer whose style is switched off must cost NOTHING — the render
///    engine's fast path has to stay on the pre-effects graph.
/// 2. A styled layer must cost a bounded multiple of an unstyled one. The
///    failure this catches is an effect graph whose region of interest
///    escapes the layer's bounds (an unclamped blur, an infinite-extent
///    generator), which shows up as an order-of-magnitude cliff rather than
///    a few milliseconds.
final class EffectsPerformanceTests: XCTestCase {
    private let p3 = BrushyColorSpace.displayP3

    /// Six 1600×1200 layers over a 2000×1400 canvas, drawn to a 1600×1000
    /// viewport — a realistic interactive frame, small enough to stay quick.
    private func scene(styled: Bool, enabled: Bool = true) -> Document {
        var document = Document(canvasSize: CGSize(width: 2000, height: 1400))
        for index in 0..<6 {
            var layer = Layer(name: "L\(index)", source: Self.source(index: index))
            layer.transform = CGAffineTransform(translationX: CGFloat(index * 60),
                                                y: CGFloat(index * 30))
            if styled {
                var shadow = DropShadowEffect()
                shadow.distance = 12
                shadow.size = 18
                layer.effects.dropShadow = shadow
                var stroke = StrokeEffect()
                stroke.size = 4
                layer.effects.stroke = stroke
                var glow = OuterGlowEffect()
                glow.size = 14
                layer.effects.outerGlow = glow
                layer.effects.isEnabled = enabled
            }
            document.layers.append(layer)
        }
        return document
    }

    private func msPerFrame(_ document: Document) throws -> Double {
        let engine = RenderEngine.shared
        guard let device = engine.device, let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device available")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1600, height: 1000, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Could not create render target")
        }
        let viewBounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let scale = 1600.0 / 2000.0

        func renderFrame(_ frame: Int) throws {
            var moved = document
            moved.layers[5].transform = moved.layers[5].transform
                .concatenating(CGAffineTransform(translationX: CGFloat(frame), y: 0))
            let image = engine.displayImage(for: moved,
                                            viewTransform: CGAffineTransform(scaleX: scale, y: scale),
                                            viewPixelBounds: viewBounds,
                                            contentScale: 2)
            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
            destination.colorSpace = BrushyColorSpace.displayP3
            _ = try engine.context.startTask(toRender: image, to: destination)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        for frame in 0..<3 { try renderFrame(frame) }
        let frames = 15
        let start = CFAbsoluteTimeGetCurrent()
        for frame in 0..<frames { try renderFrame(frame + 10) }
        return (CFAbsoluteTimeGetCurrent() - start) / Double(frames) * 1000
    }

    func testStyledLayersStayWithinABoundedMultipleOfUnstyled() throws {
        let plain = try msPerFrame(scene(styled: false))
        let styled = try msPerFrame(scene(styled: true))
        print("PERF: plain \(String(format: "%.2f", plain))ms/frame, " +
              "styled \(String(format: "%.2f", styled))ms/frame " +
              "(6 layers × drop shadow + outer glow + stroke)")
        XCTAssertLessThan(styled, max(plain * 8, 40),
                          "styled frames cost \(String(format: "%.1f", styled))ms against " +
                          "\(String(format: "%.1f", plain))ms plain — check the effect graph's " +
                          "region of interest is still bounded by the layer")
    }

    /// The fast path: effects present but switched off must render at
    /// unstyled cost, since `LayerEffects.isActive` should keep the whole
    /// effect graph out of the frame.
    func testSwitchedOffEffectsCostNothing() throws {
        let plain = try msPerFrame(scene(styled: false))
        let inactive = try msPerFrame(scene(styled: true, enabled: false))
        print("PERF: plain \(String(format: "%.2f", plain))ms/frame, " +
              "effects-off \(String(format: "%.2f", inactive))ms/frame")
        XCTAssertLessThan(inactive, max(plain * 1.6, 12),
                          "a switched-off style must not reach the render graph")
    }

    private static func source(index: Int) -> CGImage {
        let width = 1600, height = 1200
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: BrushyColorSpace.displayP3,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: BrushyColorSpace.displayP3,
                                 components: [CGFloat(index) / 6, 0.4, 0.8, 1])!)
        // An inset fill leaves transparent margins, so the effects have a real
        // alpha edge to work from rather than a full-bleed rectangle.
        ctx.fill(CGRect(x: 120, y: 90, width: width - 240, height: height - 180))
        return ctx.makeImage()!
    }
}

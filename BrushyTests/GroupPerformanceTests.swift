import CoreGraphics
import CoreImage
import Foundation
import Metal
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// frame budget with pass-through groups present. Lives in its own suite —
/// like PerformanceTests and BrushPerformanceTests — because frame-time
/// measurements are order-fragile at full-suite scale (accumulated in-process
/// state slows Core Image renders ~2×; see the verification protocol note):
/// perf suites are skipped in the functional pass and verified in isolation.
final class GroupPerformanceTests: XCTestCase {
    /// The interactive scenario with the 8 layers inside pass-through
    /// groups (one nested): pass-through adds ZERO Core Image nodes, so the
    /// frame budget must hold exactly as ungrouped.
    func testInteractiveFrameTimeWithPassThroughGroups() throws {
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
        // Groups: layers 1-4 in one folder, 5-6 in a folder nested in another
        // holding 5-7 — all pass-through.
        let a = LayerGroup(name: "A")
        let b = LayerGroup(name: "B")
        let c = LayerGroup(name: "C", parentID: b.id)
        document.groups = [a, b, c]
        for i in 1...4 { document.layers[i].groupID = a.id }
        for i in 5...6 { document.layers[i].groupID = c.id }
        document.layers[7].groupID = b.id

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

        for frame in 0..<3 { try renderFrame(frame) }
        let frames = 20
        let start = CFAbsoluteTimeGetCurrent()
        for frame in 0..<frames { try renderFrame(frame + 10) }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let msPerFrame = elapsed / Double(frames) * 1000
        print("PERF-GROUPS: \(String(format: "%.2f", msPerFrame)) ms/frame " +
              "(60fps budget: 16.7ms) — 8 layers @ 6000×4000 in pass-through groups")
        XCTAssertLessThan(msPerFrame, 16.8,
                          "pass-through groups must not cost frame budget")
    }

    /// Same construction as PerformanceTests.perfSource (private there).
    private static func perfSource(index: Int) -> CGImage {
        let width = 6000, height = 4000
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: BrushyColorSpace.displayP3,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.9, 0.2, 0.2), (0.2, 0.8, 0.3), (0.2, 0.4, 0.9), (0.9, 0.8, 0.2),
            (0.8, 0.3, 0.8), (0.3, 0.8, 0.8), (0.9, 0.6, 0.3), (0.5, 0.5, 0.9),
        ]
        let (r, g, b) = colors[index % colors.count]
        ctx.setFillColor(CGColor(colorSpace: BrushyColorSpace.displayP3,
                                 components: [r, g, b, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(colorSpace: BrushyColorSpace.displayP3,
                                 components: [r * 0.5, g * 0.5, b * 0.5, 1])!)
        for i in stride(from: 0, to: width, by: 250) {
            ctx.fill(CGRect(x: i, y: (i * 7) % height, width: 125, height: 500))
        }
        return ctx.makeImage()!
    }
}

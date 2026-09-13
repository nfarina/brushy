import CoreGraphics
import CoreImage
import Foundation
import Metal
import XCTest

/// Worst-case interactive painting: a long stroke across a screenshot-sized
/// (2644×2000) masked layer, measuring the full per-event cost — stamp
/// accumulation + preview image build + composite render at a 2560×1440
/// viewport. The whole chain must stay inside a 120Hz event budget.
final class BrushPerformanceTests: XCTestCase {
    func testBrushStrokeEventCostOnLargeDocument() throws {
        let engine = RenderEngine.shared
        guard let device = engine.device, let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        var document = Document(canvasSize: CGSize(width: 2644, height: 2000))
        var layer = Layer(name: "photo",
                          source: GeneratedImages.gradientChecker(
                            width: 2644, height: 2000, square: 64,
                            colorSpace: BrushyColorSpace.displayP3))
        layer.mask = Mask(texture: MaskTexture(width: 2644, height: 2000, fill: 255),
                          isEnabled: true)
        document.layers = [layer]
        let store = DocumentStore(document: document)
        store.maskTargeted = true
        store.brushSize = 80
        store.brushHardness = 60
        store.viewport.viewSize = CGSize(width: 1280, height: 720)
        store.viewport.fit(canvasSize: document.canvasSize)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 2560, height: 1440, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        let viewBounds = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let viewTransform = store.viewport.viewTransform
            .concatenating(CGAffineTransform(scaleX: 2, y: 2))

        func renderFrame() throws {
            let image = engine.displayImage(for: store.document,
                                            viewTransform: viewTransform,
                                            viewPixelBounds: viewBounds,
                                            contentScale: 2,
                                            stroke: store.strokePreview)
            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
            destination.colorSpace = BrushyColorSpace.displayP3
            _ = try engine.context.startTask(toRender: image, to: destination)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        // Warm up texture uploads.
        try renderFrame()

        let events = 180
        store.beginBrushStroke(at: CGPoint(x: 60, y: 100), eraser: false)
        let start = CFAbsoluteTimeGetCurrent()
        var strokeSeconds = 0.0
        var renderSeconds = 0.0
        for step in 1...events {
            let t = CGFloat(step) / CGFloat(events)
            // A long diagonal wiggle across most of the canvas — the dirty
            // region grows to multi-megapixel size.
            let point = CGPoint(x: 60 + t * 2400,
                                y: 100 + t * 1700 + sin(t * 14) * 120)
            let t0 = CFAbsoluteTimeGetCurrent()
            store.continueBrushStroke(to: point)
            let t1 = CFAbsoluteTimeGetCurrent()
            try renderFrame()
            let t2 = CFAbsoluteTimeGetCurrent()
            strokeSeconds += t1 - t0
            renderSeconds += t2 - t1
        }
        let perEventMs = (CFAbsoluteTimeGetCurrent() - start) / Double(events) * 1000
        print(String(format: "PERF-BRUSH-SPLIT: stroke %.2f ms, render %.2f ms per event",
                     strokeSeconds / Double(events) * 1000,
                     renderSeconds / Double(events) * 1000))

        let bakeStart = CFAbsoluteTimeGetCurrent()
        store.endBrushStroke()
        let bakeMs = (CFAbsoluteTimeGetCurrent() - bakeStart) * 1000

        print(String(format: "PERF-BRUSH: %.2f ms/event (budget 16.7), bake %.0f ms",
                     perEventMs, bakeMs))
        XCTAssertLessThan(perEventMs, 16.7,
                          "painting must keep up with the display refresh")
        XCTAssertLessThan(bakeMs, 400, "stroke commit must feel instant")
    }
}

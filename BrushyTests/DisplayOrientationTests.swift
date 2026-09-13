import CoreGraphics
import CoreImage
import Metal
import XCTest

/// Pins the orientation of the CanvasMetalView render path.
///
/// Convention (verified on glass against a screen recording of the running
/// app, 2026-08-15): CIRenderDestination(mtlTexture:) writes CI's y-up content
/// with the canvas BOTTOM at texture row 0, and macOS MTKView — living in
/// AppKit's flipped layer-geometry world — presents texture row 0 at the
/// layer's BOTTOM. The two cancel: rendering with no flip displays upright.
/// (Compensating with a y-flip, as a naive reading of texture memory suggests,
/// mirrors the canvas vertically on screen and makes vertical drags feel
/// inverted.)
final class DisplayOrientationTests: XCTestCase {
    func testDisplayRenderMatchesMetalPresentation() throws {
        let engine = RenderEngine.shared
        guard let device = engine.device, let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        let p3 = BrushyColorSpace.displayP3
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        document.layers = [
            Layer(name: "blue bottom",
                  source: GeneratedImages.solid(width: 64, height: 32, r: 0, g: 0, b: 255,
                                                colorSpace: p3)),
            Layer(name: "red top",
                  source: GeneratedImages.solid(width: 64, height: 32, r: 255, g: 0, b: 0,
                                                colorSpace: p3),
                  transform: CGAffineTransform(translationX: 0, y: 32)),
        ]

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!

        // Exactly what CanvasMetalView does per frame: identity viewport,
        // backing scale 1, NO flip.
        let image = engine.displayImage(for: document,
                                        viewTransform: .identity,
                                        viewPixelBounds: CGRect(x: 0, y: 0, width: 64, height: 64),
                                        contentScale: 1)
        let commandBuffer = queue.makeCommandBuffer()!
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        destination.colorSpace = BrushyColorSpace.sRGB
        _ = try engine.context.startTask(toRender: image, to: destination)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var row0 = [UInt8](repeating: 0, count: 64 * 4)
        var row63 = [UInt8](repeating: 0, count: 64 * 4)
        texture.getBytes(&row0, bytesPerRow: 64 * 4,
                         from: MTLRegionMake2D(0, 0, 64, 1), mipmapLevel: 0)
        texture.getBytes(&row63, bytesPerRow: 64 * 4,
                         from: MTLRegionMake2D(0, 63, 64, 1), mipmapLevel: 0)

        // Texture row 0 displays at the layer's BOTTOM on macOS, so it must
        // hold the canvas bottom (blue); the last row holds the canvas top.
        let row0Pixel = (r: row0[128], g: row0[129], b: row0[130])
        let row63Pixel = (r: row63[128], g: row63[129], b: row63[130])
        XCTAssertGreaterThan(row0Pixel.b, 200,
                             "texture row 0 (screen bottom) must hold the canvas bottom (blue) — got \(row0Pixel)")
        XCTAssertLessThan(row0Pixel.r, 80)
        XCTAssertGreaterThan(row63Pixel.r, 200,
                             "last texture row (screen top) must hold the canvas top (red) — got \(row63Pixel)")
        XCTAssertLessThan(row63Pixel.b, 80)
    }
}

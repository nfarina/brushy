import AppKit
import CoreImage
import Metal
import MetalKit

/// CAMetalLayer-backed canvas. Each draw builds the CIImage graph fresh
/// and renders the region of interest only. The layer is colour-managed:
/// rgba16Float contents tagged Display P3, matched to the display by the
/// window server.
final class CanvasMetalView: MTKView {
    unowned let store: DocumentStore
    private var commandQueue: MTLCommandQueue?

    init(store: DocumentStore) {
        self.store = store
        super.init(frame: .zero, device: RenderEngine.shared.device)
        commandQueue = device?.makeCommandQueue()
        colorPixelFormat = .rgba16Float
        colorspace = BrushyColorSpace.displayP3
        framebufferOnly = false
        autoResizeDrawable = true
        enableSetNeedsDisplay = true
        isPaused = true
        clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable,
              let queue = commandQueue,
              drawableSize.width > 0, drawableSize.height > 0 else { return }
        // No y-flip here: CIRenderDestination writes CI's y-up content with
        // canvas-bottom at texture row 0, and macOS MTKView (AppKit's flipped
        // layer geometry) presents row 0 at the layer's BOTTOM — so the result
        // is upright as-is. Verified on glass 2026-08-15; adding a flip here
        // mirrors the canvas vertically. Pinned by DisplayOrientationTests.
        let scale = window?.backingScaleFactor ?? 2
        let pixelTransform = store.viewport.viewTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(origin: .zero, size: drawableSize)
        let image = RenderEngine.shared.displayImage(for: store.document,
                                                     viewTransform: pixelTransform,
                                                     viewPixelBounds: bounds,
                                                     contentScale: scale,
                                                     stroke: store.strokePreview,
                                                     excludingLayer: store.textSession?.layerID,
                                                     quickMask: store.quickMask)
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        let destination = CIRenderDestination(mtlTexture: drawable.texture,
                                              commandBuffer: commandBuffer)
        destination.colorSpace = BrushyColorSpace.displayP3
        do {
            _ = try RenderEngine.shared.context.startTask(toRender: image, to: destination)
        } catch {
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

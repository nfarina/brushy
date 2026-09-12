import CoreGraphics
import Foundation
import XCTest

/// Layer ▸ Rasterize Layer and the prompt that offers it — the escape hatch
/// from "an imported photo's pixels are never rewritten" (invariant 5).
final class RasterizeTests: XCTestCase {
    private func makeStore() -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: CGSize(width: 200, height: 150))
        document.layers = [Layer(name: "Photo",
                                 source: GeneratedImages.solid(width: 100, height: 100,
                                                               r: 220, g: 40, b: 40,
                                                               colorSpace: DezzyColorSpace.sRGB),
                                 transform: CGAffineTransform(translationX: 20, y: 20),
                                 isPaintable: false)]
        let store = DocumentStore(document: document)
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        store.selectLayer(document.layers[0].id)
        return (store, undoManager)
    }

    private func pixel(_ store: DocumentStore, at point: CGPoint) -> (r: UInt8, a: UInt8) {
        let engine = RenderEngine.shared
        guard let cg = engine.context.createCGImage(
            engine.compositeImage(for: store.document),
            from: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBA8, colorSpace: DezzyColorSpace.sRGB) else { return (0, 0) }
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: DezzyColorSpace.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (data[0], data[3])
    }

    func testRasterizingAPhotoBakesItIntoPaintablePixels() {
        let (store, um) = makeStore()
        let original = store.document.layers[0]
        XCTAssertTrue(store.canRasterizeSelectedLayer)

        um.beginUndoGrouping()
        store.rasterizeLayer(original.id)
        um.endUndoGrouping()

        let baked = store.document.layers[0]
        XCTAssertTrue(baked.isPaintable, "pixels can land on it now")
        XCTAssertNotEqual(baked.sourceID, original.sourceID)
        XCTAssertEqual(um.undoActionName, "Rasterize Layer")
        XCTAssertEqual(baked.canvasBounds, original.canvasBounds, "it looks identical")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 50, y: 50)).a, 250)
        XCTAssertFalse(store.canRasterizeSelectedLayer, "already pixels")

        um.undo()
        XCTAssertEqual(store.document.layers[0].sourceID, original.sourceID,
                       "undo brings the photo's own bytes back")
        XCTAssertFalse(store.document.layers[0].isPaintable)
    }

    func testRasterizingKeepsTheMaskReframedOntoTheNewGrid() {
        let (store, um) = makeStore()
        store.featherAmount = 0
        um.beginUndoGrouping()
        store.combineSelection(CGPath(rect: CGRect(x: 30, y: 30, width: 40, height: 40),
                                      transform: nil), mode: .replace)
        um.endUndoGrouping()
        um.beginUndoGrouping()
        store.addLayerMask() // reveals only the selection
        um.endUndoGrouping()

        um.beginUndoGrouping()
        store.rasterizeLayer(store.document.layers[0].id)
        um.endUndoGrouping()

        XCTAssertNotNil(store.document.layers[0].mask, "the mask stays a mask")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 50, y: 50)).a, 250,
                             "and still reveals the same pixels")
        XCTAssertEqual(pixel(store, at: CGPoint(x: 90, y: 90)).a, 0, "and hides the same ones")
    }

    func testPaintingAPhotoRasterizesItOnTheSpotAndPaints() {
        let (store, um) = makeStore()
        store.activeTool = .brush
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        store.brushSize = 20
        store.brushHardness = 100
        store.brushOpacity = 100

        um.beginUndoGrouping()
        store.beginBrushStroke(at: CGPoint(x: 50, y: 50), eraser: false)
        store.continueBrushStroke(to: CGPoint(x: 60, y: 50))
        store.endBrushStroke()
        um.endUndoGrouping()

        XCTAssertTrue(store.document.layers[0].isPaintable, "the click itself rasterized it")
        XCTAssertEqual(pixel(store, at: CGPoint(x: 55, y: 50)).r, 0, "blue paint, no red left")
        XCTAssertNotNil(store.toast, "and it says so, without a dialog in the way")
        XCTAssertTrue(store.toast?.message.contains("Rasterized") ?? false)

        // Two steps: the rasterize, then the stroke.
        um.undo()
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 55, y: 50)).r, 200, "the paint came off")
        um.undo()
        XCTAssertFalse(store.document.layers[0].isPaintable, "and the photo is a photo again")
    }

    func testFillRasterizesAndFillsInOneGo() {
        let (store, um) = makeStore()
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        um.beginUndoGrouping()
        store.fillSelection()
        um.endUndoGrouping()

        XCTAssertTrue(store.document.layers[0].isPaintable)
        XCTAssertEqual(pixel(store, at: CGPoint(x: 50, y: 50)).r, 0, "the fill went through")
        XCTAssertNotNil(store.toast)
    }

    func testErasingAPhotoRasterizesItRatherThanHidingBehindAMask() {
        let (store, um) = makeStore()
        store.activeTool = .eraser
        store.brushSize = 20
        store.brushHardness = 100
        store.brushOpacity = 100

        um.beginUndoGrouping()
        store.beginBrushStroke(at: CGPoint(x: 50, y: 50), eraser: true)
        store.continueBrushStroke(to: CGPoint(x: 60, y: 50))
        store.endBrushStroke()
        um.endUndoGrouping()

        XCTAssertTrue(store.document.layers[0].isPaintable)
        XCTAssertNil(store.document.layers[0].mask, "no mask invented behind your back")
        XCTAssertEqual(pixel(store, at: CGPoint(x: 55, y: 50)).a, 0, "the pixels really went")
        XCTAssertNotNil(store.toast)
    }

    func testAnExplicitlyTargetedMaskStillTakesThePaint() {
        let (store, um) = makeStore()
        um.beginUndoGrouping()
        store.addLayerMask()
        um.endUndoGrouping()
        store.maskTargeted = true // what clicking the mask thumbnail does
        store.activeTool = .brush
        store.brushSize = 20
        store.brushHardness = 100
        store.brushOpacity = 100
        let sourceID = store.document.layers[0].sourceID

        um.beginUndoGrouping()
        store.beginBrushStroke(at: CGPoint(x: 50, y: 50), eraser: false)
        store.continueBrushStroke(to: CGPoint(x: 60, y: 50))
        store.endBrushStroke()
        um.endUndoGrouping()

        XCTAssertFalse(store.document.layers[0].isPaintable, "the photo was left alone")
        XCTAssertEqual(store.document.layers[0].sourceID, sourceID)
        XCTAssertNil(store.toast, "nothing surprising happened, so nothing to announce")
    }
}

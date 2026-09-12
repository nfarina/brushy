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

    func testRasterizingAppliesAnEnabledMaskIntoThePixels() {
        let (store, um) = makeStore()
        store.featherAmount = 0
        um.beginUndoGrouping()
        store.combineSelection(CGPath(rect: CGRect(x: 30, y: 30, width: 40, height: 40),
                                      transform: nil), mode: .replace)
        um.endUndoGrouping()
        um.beginUndoGrouping()
        store.addLayerMask() // reveals only the selection
        um.endUndoGrouping()
        XCTAssertNotNil(store.document.layers[0].mask)

        um.beginUndoGrouping()
        store.rasterizeLayer(store.document.layers[0].id)
        um.endUndoGrouping()

        XCTAssertNil(store.document.layers[0].mask, "the mask became alpha")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 50, y: 50)).a, 250, "kept what it revealed")
        XCTAssertEqual(pixel(store, at: CGPoint(x: 90, y: 90)).a, 0, "and what it hid is gone")

        um.undo()
        XCTAssertNotNil(store.document.layers[0].mask, "undo restores the mask")
    }

    func testPaintingAPhotoAsksToRasterizeAndThenPaints() {
        let (store, um) = makeStore()
        store.activeTool = .brush
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        store.beginBrushStroke(at: CGPoint(x: 50, y: 50), eraser: false)
        let prompt = store.rasterizePrompt
        XCTAssertNotNil(prompt, "painting a photo asks first")
        XCTAssertEqual(prompt?.layerName, "Photo")
        XCTAssertNil(store.strokePreview, "and paints nothing until answered")

        um.beginUndoGrouping()
        store.resolveRasterizePrompt(.rasterize)
        um.endUndoGrouping()
        XCTAssertTrue(store.document.layers[0].isPaintable)
        XCTAssertNil(store.rasterizePrompt)

        // Photoshop drops the click that raised the prompt; drawing again works.
        um.beginUndoGrouping()
        store.beginBrushStroke(at: CGPoint(x: 50, y: 50), eraser: false)
        store.continueBrushStroke(to: CGPoint(x: 60, y: 50))
        store.endBrushStroke()
        um.endUndoGrouping()
        XCTAssertEqual(pixel(store, at: CGPoint(x: 55, y: 50)).r, 0, "blue paint, no red left")
    }

    func testFillOnAPhotoRunsItselfAgainAfterRasterizing() {
        let (store, um) = makeStore()
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        store.fillSelection()
        XCTAssertNotNil(store.rasterizePrompt)

        um.beginUndoGrouping()
        store.resolveRasterizePrompt(.rasterize)
        um.endUndoGrouping()

        XCTAssertTrue(store.document.layers[0].isPaintable)
        XCTAssertEqual(pixel(store, at: CGPoint(x: 50, y: 50)).r, 0,
                       "the fill it asked about went through")
    }

    func testAddLayerMaskAnswerLeavesThePhotoIntact() {
        let (store, um) = makeStore()
        let sourceID = store.document.layers[0].sourceID
        store.activeTool = .brush
        store.beginBrushStroke(at: CGPoint(x: 50, y: 50), eraser: false)

        um.beginUndoGrouping()
        store.resolveRasterizePrompt(.addMask)
        um.endUndoGrouping()

        XCTAssertNotNil(store.document.layers[0].mask)
        XCTAssertFalse(store.document.layers[0].isPaintable, "still a photo")
        XCTAssertEqual(store.document.layers[0].sourceID, sourceID)
    }

    func testCancellingChangesNothing() {
        let (store, _) = makeStore()
        let before = store.document
        let entries = store.historyEntries.count
        store.activeTool = .brush
        store.beginBrushStroke(at: CGPoint(x: 50, y: 50), eraser: false)

        store.resolveRasterizePrompt(.cancel)

        XCTAssertNil(store.rasterizePrompt)
        XCTAssertEqual(store.historyEntries.count, entries)
        XCTAssertEqual(store.document.layers[0].sourceID, before.layers[0].sourceID)
        XCTAssertFalse(store.document.layers[0].isPaintable)
    }

    func testErasingAPhotoStillHidesThroughAMaskWithoutAsking() {
        let (store, um) = makeStore()
        store.activeTool = .eraser
        um.beginUndoGrouping()
        store.beginBrushStroke(at: CGPoint(x: 50, y: 50), eraser: true)
        store.continueBrushStroke(to: CGPoint(x: 60, y: 50))
        store.endBrushStroke()
        um.endUndoGrouping()

        XCTAssertNil(store.rasterizePrompt, "erasing loses nothing, so it needn't ask")
        XCTAssertNotNil(store.document.layers[0].mask)
        XCTAssertFalse(store.document.layers[0].isPaintable)
    }
}

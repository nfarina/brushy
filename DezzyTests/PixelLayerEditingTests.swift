import AppKit
import CoreGraphics
import Foundation
import XCTest

/// Editing pixel layers the way Photoshop lets you: paint past a layer's
/// bounds, load a layer as a selection, Layer via Copy / Cut, and arrivals
/// consuming the blank layer you made for them.
final class PixelLayerEditingTests: XCTestCase {
    /// 200×150 canvas holding a small opaque "chunk" at (40,40)–(60,60), the
    /// shape a pasted fragment arrives in.
    private func makeStore() -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: CGSize(width: 200, height: 150))
        document.layers = [Layer(name: "Chunk",
                                 source: GeneratedImages.solid(width: 20, height: 20,
                                                               r: 220, g: 40, b: 40,
                                                               colorSpace: DezzyColorSpace.sRGB),
                                 transform: CGAffineTransform(translationX: 40, y: 40),
                                 isPaintable: true)]
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

    private func group(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping(); body(); um.endUndoGrouping()
    }

    // MARK: - Painting past a layer's edge

    func testPaintingOutsideTheLayerGrowsItsGrid() {
        let (store, um) = makeStore()
        store.activeTool = .brush
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        store.brushSize = 16
        store.brushHardness = 100
        store.brushOpacity = 100

        group(um) {
            store.beginBrushStroke(at: CGPoint(x: 120, y: 100), eraser: false) // far from the chunk
            store.continueBrushStroke(to: CGPoint(x: 130, y: 100))
            store.endBrushStroke()
        }

        XCTAssertEqual(store.document.layers.count, 1, "still one layer — it just got bigger")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 125, y: 100)).a, 250,
                             "paint outside the old bounds must land, not clip")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 50, y: 50)).a, 250,
                             "and the original pixels stay put")

        um.undo()
        XCTAssertEqual(pixel(store, at: CGPoint(x: 125, y: 100)).a, 0)
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 50, y: 50)).a, 250)
    }

    func testFillingOutsideTheLayerGrowsItToo() {
        let (store, um) = makeStore()
        store.featherAmount = 0
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        group(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 100, y: 90, width: 30, height: 30),
                                          transform: nil), mode: .replace)
        }

        group(um) { store.fillSelection() }

        XCTAssertEqual(store.document.layers.count, 1)
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 115, y: 105)).a, 250)
        XCTAssertEqual(pixel(store, at: CGPoint(x: 115, y: 105)).r, 0, "blue, as asked")
    }

    func testGrowthStopsAtTheCanvasEdge() {
        let (store, _) = makeStore()
        let layer = store.document.layers[0]
        let grown = DocumentStore.grown(layer,
                                        toCover: CGRect(x: -500, y: -500, width: 2000, height: 2000),
                                        canvasRect: store.document.canvasRect).layer
        XCTAssertEqual(grown.canvasBounds, store.document.canvasRect,
                       "a runaway request is capped at the canvas")
        XCTAssertNotEqual(grown.sourceID, layer.sourceID)
    }

    // MARK: - Arrivals and blank layers

    func testPastingIntoABlankLayerReusesIt() throws {
        let (store, um) = makeStore()
        group(um) { store.addPaintLayer() } // the blank layer you make to paste into
        XCTAssertEqual(store.document.layers.count, 2)
        let blankID = try XCTUnwrap(store.selectedLayerID)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dezzy-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let chunk = GeneratedImages.solid(width: 20, height: 20, r: 10, g: 200, b: 10,
                                          colorSpace: DezzyColorSpace.sRGB)
        pasteboard.writeObjects([NSImage(cgImage: chunk, size: NSSize(width: 20, height: 20))])

        group(um) { store.paste(from: pasteboard) }

        XCTAssertEqual(store.document.layers.count, 2,
                       "the empty layer was reused, not stacked under a new one")
        XCTAssertFalse(store.document.layers.contains { $0.id == blankID })
        XCTAssertEqual(store.document.layers[1].name, "Pasted Layer")
    }

    func testAnArrivalStacksAboveALayerThatHasPixels() {
        let (store, um) = makeStore() // the chunk layer is selected and not blank
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dezzy-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let chunk = GeneratedImages.solid(width: 20, height: 20, r: 10, g: 200, b: 10,
                                          colorSpace: DezzyColorSpace.sRGB)
        pasteboard.writeObjects([NSImage(cgImage: chunk, size: NSSize(width: 20, height: 20))])

        group(um) { store.paste(from: pasteboard) }

        XCTAssertEqual(store.document.layers.count, 2, "nothing was consumed")
    }

    // MARK: - Loading a layer as a selection

    func testCommandClickLoadsTheLayersPixelsAsASelection() throws {
        let (store, _) = makeStore()
        store.selectPixels(of: store.document.layers[0].id)

        let bounds = try XCTUnwrap(store.selection.path?.boundingBoxOfPath)
        XCTAssertEqual(bounds, CGRect(x: 40, y: 40, width: 20, height: 20),
                       "the chunk's own pixels, traced")
    }

    // MARK: - Layer via Copy / Cut

    func testLayerViaCopyLiftsThePixelsAndLeavesTheOriginal() {
        let (store, um) = makeStore()
        store.featherAmount = 0
        group(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 40, y: 40, width: 10, height: 20),
                                          transform: nil), mode: .replace)
        }

        group(um) { store.layerViaCopy() }

        XCTAssertEqual(store.document.layers.count, 2)
        XCTAssertEqual(store.document.layers[1].name, "Layer via Copy")
        XCTAssertEqual(um.undoActionName, "Layer via Copy")
        XCTAssertTrue(store.selection.isEmpty, "the pixels are a layer now, so the selection goes")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 45, y: 50)).a, 250,
                             "the original still has its pixels")
        // Hiding the copy proves the original was untouched underneath.
        group(um) { store.setLayerVisibility(store.document.layers[1].id, false) }
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 45, y: 50)).a, 250)
    }

    func testLayerViaCutTakesThePixelsOutOfTheSource() {
        let (store, um) = makeStore()
        store.featherAmount = 0
        group(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 40, y: 40, width: 10, height: 20),
                                          transform: nil), mode: .replace)
        }

        group(um) { store.layerViaCut() }

        XCTAssertEqual(store.document.layers.count, 2)
        XCTAssertEqual(store.document.layers[1].name, "Layer via Cut")
        group(um) { store.setLayerVisibility(store.document.layers[1].id, false) }
        XCTAssertEqual(pixel(store, at: CGPoint(x: 45, y: 50)).a, 0,
                       "with the cut layer hidden, the hole shows")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 55, y: 50)).a, 250,
                             "the rest of the layer is untouched")
    }

    func testLayerViaCopyWithNoSelectionDuplicatesTheLayer() {
        let (store, um) = makeStore()
        group(um) { store.layerViaCopy() }

        XCTAssertEqual(store.document.layers.count, 2)
        XCTAssertEqual(um.undoActionName, "Duplicate Layer",
                       "⌘J with nothing selected duplicates, as in Photoshop")
    }

    func testLayerViaCutRasterizesASmartLayerFirst() {
        var document = Document(canvasSize: CGSize(width: 200, height: 150))
        document.layers = [Layer(name: "Photo",
                                 source: GeneratedImages.solid(width: 100, height: 100,
                                                               r: 220, g: 40, b: 40,
                                                               colorSpace: DezzyColorSpace.sRGB),
                                 transform: CGAffineTransform(translationX: 20, y: 20),
                                 isPaintable: false)]
        let store = DocumentStore(document: document)
        store.selectLayer(document.layers[0].id)
        store.featherAmount = 0
        store.combineSelection(CGPath(rect: CGRect(x: 30, y: 30, width: 20, height: 20),
                                      transform: nil), mode: .replace)

        store.layerViaCut()

        XCTAssertTrue(store.document.layers[0].isPaintable, "cutting needs its own pixels")
        XCTAssertNotNil(store.toast)
        XCTAssertEqual(store.document.layers.count, 2)
    }
}

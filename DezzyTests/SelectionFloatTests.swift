import CoreGraphics
import Foundation
import XCTest

/// Move and ⌘T acting on the SELECTION rather than the whole layer
/// (Photoshop's floating selection). Paint layers stamp the pixels back down
/// into themselves; an imported photo keeps its bytes and gets a hide-mask,
/// with the float staying a layer of its own — invariant 5 applied to moving
/// pixels.
final class SelectionFloatTests: XCTestCase {
    private func makeStore(paintable: Bool) -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: CGSize(width: 200, height: 150))
        document.layers = [Layer(name: paintable ? "Layer 1" : "Photo",
                                 source: GeneratedImages.solid(width: 100, height: 100,
                                                               r: 220, g: 40, b: 40,
                                                               colorSpace: DezzyColorSpace.sRGB),
                                 transform: CGAffineTransform(translationX: 20, y: 20),
                                 isPaintable: paintable)]
        let store = DocumentStore(document: document)
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        store.selectLayer(document.layers[0].id)
        return (store, undoManager)
    }

    /// `groupsByEvent` is off in these tests, so every commit — the selection
    /// included — has to sit inside an explicit undo group.
    private func selectSquare(_ store: DocumentStore) {
        store.featherAmount = 0
        store.undoManager?.beginUndoGrouping()
        store.combineSelection(CGPath(rect: CGRect(x: 30, y: 30, width: 40, height: 40),
                                      transform: nil), mode: .replace)
        store.undoManager?.endUndoGrouping()
    }

    /// The composited canvas at a canvas point, as sRGB bytes.
    private func pixel(_ store: DocumentStore, at point: CGPoint) -> (r: UInt8, a: UInt8) {
        let engine = RenderEngine.shared
        let image = engine.compositeImage(for: store.document)
        guard let cg = engine.context.createCGImage(
            image, from: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBA8, colorSpace: DezzyColorSpace.sRGB) else { return (0, 0) }
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: DezzyColorSpace.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (data[0], data[3])
    }

    private func moveFloat(_ store: DocumentStore, _ float: DocumentStore.SelectionFloat,
                           dx: CGFloat) {
        store.setLiveLayerTransform(float.floatLayerID,
                                    float.initialTransform
                                        .concatenating(CGAffineTransform(translationX: dx, y: 0)))
    }

    func testMovingASelectionOnAPaintLayerStampsThePixelsBackDown() throws {
        let (store, um) = makeStore(paintable: true)
        selectSquare(store)
        let originalSourceID = store.document.layers[0].sourceID

        um.beginUndoGrouping()
        let float = try XCTUnwrap(store.beginSelectionFloat())
        XCTAssertEqual(store.document.layers.count, 2, "the float rides above its layer mid-drag")
        moveFloat(store, float, dx: 60)
        store.landSelectionFloat()
        um.endUndoGrouping()

        XCTAssertEqual(store.document.layers.count, 1, "the float stamped back into the paint layer")
        XCTAssertNotEqual(store.document.layers[0].sourceID, originalSourceID,
                          "new pixels, fresh sourceID")
        XCTAssertEqual(um.undoActionName, "Move Selection")
        XCTAssertEqual(pixel(store, at: CGPoint(x: 50, y: 50)).a, 0, "the hole is transparent")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 110, y: 50)).a, 250,
                             "the pixels landed 60px to the right")
        XCTAssertEqual(store.selection.path?.boundingBoxOfPath.minX, 90,
                       "the selection travelled with the pixels")

        um.undo()
        XCTAssertEqual(store.document.layers[0].sourceID, originalSourceID)
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 50, y: 50)).a, 250, "undo fills the hole")
    }

    func testMovingASelectionOnAPhotoRasterizesItAndMovesThePixelsInPlace() throws {
        let (store, um) = makeStore(paintable: false)
        selectSquare(store)
        let photoSourceID = store.document.layers[0].sourceID

        um.beginUndoGrouping()
        let float = try XCTUnwrap(store.beginSelectionFloat())
        moveFloat(store, float, dx: 60)
        store.landSelectionFloat()
        um.endUndoGrouping()

        XCTAssertEqual(store.document.layers.count, 1,
                       "no stray layer: the photo rasterized and its pixels moved")
        XCTAssertTrue(store.document.layers[0].isPaintable)
        XCTAssertNil(store.document.layers[0].mask, "and nothing was masked behind the user's back")
        XCTAssertNotNil(store.toast, "the toast says the layer was rasterized")
        XCTAssertEqual(pixel(store, at: CGPoint(x: 50, y: 50)).a, 0, "the hole is a real hole")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 110, y: 50)).a, 250)

        um.undo()
        XCTAssertEqual(store.document.layers[0].sourceID, photoSourceID,
                       "undo brings the untouched photo back")
        XCTAssertFalse(store.document.layers[0].isPaintable)
    }

    func testOptionDragDuplicatesTheSelectedPixelsInsteadOfMovingThem() throws {
        let (store, um) = makeStore(paintable: true)
        selectSquare(store)

        um.beginUndoGrouping()
        let float = try XCTUnwrap(store.beginSelectionFloat(cutting: false))
        moveFloat(store, float, dx: 60)
        store.landSelectionFloat()
        um.endUndoGrouping()

        XCTAssertEqual(um.undoActionName, "Duplicate Selection")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 50, y: 50)).a, 250,
                             "the original pixels stayed put")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 110, y: 50)).a, 250, "and a copy landed")
    }

    func testCommandTGrabsTheSelectionAndEscapePutsItBack() throws {
        let (store, _) = makeStore(paintable: true)
        selectSquare(store)

        store.enterTransformMode()
        let session = try XCTUnwrap(store.transformSession)
        XCTAssertEqual(session.layerID, store.selectionFloat?.floatLayerID,
                       "⌘T transforms the floated pixels, not the whole layer")
        XCTAssertEqual(session.sourceRect.size, CGSize(width: 40, height: 40),
                       "the box is the selection's bounds")

        store.cancelTransformSession()
        XCTAssertNil(store.selectionFloat)
        XCTAssertEqual(store.document.layers.count, 1)
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 50, y: 50)).a, 250, "Esc refills the hole")
    }

    func testCommandTWithoutMovingAnythingLeavesNoHistory() {
        let (store, _) = makeStore(paintable: true)
        selectSquare(store)
        let entries = store.historyEntries.count

        store.enterTransformMode()
        store.commitTransformSession()

        XCTAssertEqual(store.historyEntries.count, entries)
        XCTAssertEqual(store.document.layers.count, 1)
        XCTAssertNil(store.selectionFloat)
    }

    /// The whole gesture through the real controller, as the mouse drives it.
    /// Releasing the mouse leaves the pixels floating; they land when the
    /// selection's life ends.
    func testMoveToolDragFloatsThePixelsUntilTheSelectionEnds() throws {
        let (store, um) = makeStore(paintable: true)
        selectSquare(store)
        store.activeTool = .move
        let controller = CanvasController(store: store)

        um.beginUndoGrouping()
        drag(controller, store, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 90, y: 50))
        um.endUndoGrouping()

        XCTAssertNotNil(store.selectionFloat, "the pixels keep floating after mouse-up")
        XCTAssertEqual(store.document.layers.count, 2)
        XCTAssertEqual(store.liveSelectionPath?.boundingBoxOfPath.minX, 70,
                       "the ants ride with the pixels while they float")
        XCTAssertEqual(store.selection.path?.boundingBoxOfPath.minX, 30,
                       "the committed selection hasn't moved yet")

        um.beginUndoGrouping()
        store.deselect()
        um.endUndoGrouping()
        XCTAssertNil(store.selectionFloat)
        XCTAssertEqual(store.document.layers.count, 1, "landing stamped the float back down")
        XCTAssertEqual(pixel(store, at: CGPoint(x: 50, y: 50)).a, 0)
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 90, y: 50)).a, 250)
    }

    /// The point of floating: a second drag pushes the SAME pixels along
    /// instead of cutting a fresh hole out of where they just landed.
    func testASecondDragMovesTheSamePixelsWithoutCuttingAgain() {
        let (store, um) = makeStore(paintable: true)
        selectSquare(store)
        store.activeTool = .move
        let controller = CanvasController(store: store)
        let entriesBefore = store.historyEntries.count

        um.beginUndoGrouping()
        drag(controller, store, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 90, y: 50))
        drag(controller, store, from: CGPoint(x: 90, y: 50), to: CGPoint(x: 120, y: 50))
        um.endUndoGrouping()
        XCTAssertEqual(store.document.layers.count, 2, "still one float, not two")

        um.beginUndoGrouping()
        store.deselect()
        um.endUndoGrouping()

        XCTAssertEqual(store.historyEntries.count, entriesBefore + 2,
                       "both drags land as a single Move Selection, then Deselect")
        XCTAssertEqual(pixel(store, at: CGPoint(x: 50, y: 50)).a, 0, "one hole, where they started")
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 90, y: 50)).a, 250,
                             "the pixels they travelled over are undisturbed")
        // Had the second drag re-lifted, it would have cut from the committed
        // selection — still the empty hole — and landed nothing here.
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 120, y: 50)).a, 250,
                             "the same pixels arrived at the far end")
    }

    func testArrowKeysNudgeTheSelectedPixels() {
        let (store, _) = makeStore(paintable: true)
        selectSquare(store)
        store.activeTool = .move

        store.nudgeSelectedLayer(dx: 3, dy: 0)
        store.nudgeSelectedLayer(dx: 3, dy: 0)
        XCTAssertNotNil(store.selectionFloat, "nudging lifts the pixels and keeps them floating")
        XCTAssertEqual(store.liveSelectionPath?.boundingBoxOfPath.minX, 36)

        store.deselect()
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 56, y: 50)).a, 250)
        XCTAssertEqual(pixel(store, at: CGPoint(x: 32, y: 50)).a, 0)
    }

    func testDeleteClearsTheSelectedPixelsRatherThanTheLayer() {
        let (store, um) = makeStore(paintable: true)
        selectSquare(store)

        um.beginUndoGrouping()
        store.clearSelection()
        um.endUndoGrouping()

        XCTAssertEqual(um.undoActionName, "Clear")
        XCTAssertEqual(store.document.layers.count, 1, "the layer survives")
        XCTAssertEqual(pixel(store, at: CGPoint(x: 50, y: 50)).a, 0)
        XCTAssertGreaterThan(pixel(store, at: CGPoint(x: 25, y: 25)).a, 250,
                             "only the selected pixels went")
    }

    private func drag(_ controller: CanvasController, _ store: DocumentStore,
                      from: CGPoint, to: CGPoint) {
        controller.mouseDown(at: store.viewport.toView(from), modifiers: [], clickCount: 1)
        controller.mouseDragged(to: store.viewport.toView(to), modifiers: [])
        controller.mouseUp(at: store.viewport.toView(to), modifiers: [], clickCount: 1)
    }

    /// A click with the Move tool while a selection is up must not leave a
    /// stray lift behind.
    func testMoveToolClickWithoutDraggingLeavesNoHistory() {
        let (store, _) = makeStore(paintable: true)
        selectSquare(store)
        store.activeTool = .move
        let controller = CanvasController(store: store)
        let entries = store.historyEntries.count

        let point = store.viewport.toView(CGPoint(x: 50, y: 50))
        controller.mouseDown(at: point, modifiers: [], clickCount: 1)
        controller.mouseUp(at: point, modifiers: [], clickCount: 1)

        XCTAssertEqual(store.historyEntries.count, entries)
        XCTAssertNil(store.selectionFloat)
        XCTAssertEqual(store.document.layers.count, 1)
    }
}

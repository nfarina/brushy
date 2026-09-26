import AppKit
import CoreGraphics
import XCTest

/// Photoshop's opacity digit keys: the digit rule, the store's single history
/// entry for a two-digit pair, and the controller's routing to the brush.
final class OpacityKeysTests: XCTestCase {
    private let source = GeneratedImages.solid(width: 8, height: 8, r: 90, g: 120, b: 200,
                                               colorSpace: BrushyColorSpace.displayP3)

    private func makeStore() -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        document.layers = ["a", "b"].map { Layer(name: $0, source: source) }
        let store = DocumentStore(document: document)
        let undo = UndoManager()
        undo.levelsOfUndo = 100
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    private func grouped(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    func testDigitRule() {
        XCTAssertEqual(OpacityKeys.percent(digit: 5, following: nil), 50)
        XCTAssertEqual(OpacityKeys.percent(digit: 0, following: nil), 100)
        XCTAssertEqual(OpacityKeys.percent(digit: 5, following: 4), 45)
        XCTAssertEqual(OpacityKeys.percent(digit: 0, following: 0), 0)
        XCTAssertEqual(OpacityKeys.percent(digit: 5, following: 0), 5)
    }

    func testTwoDigitsMakeOneUndoStep() {
        let (store, um) = makeStore()
        let id = try! XCTUnwrap(store.selectedLayerID)
        let controller = CanvasController(store: store)
        store.activeTool = .move

        grouped(um) { controller.opacityDigit(4, at: 10) }
        XCTAssertEqual(store.document[layerID: id]?.opacity, 0.4)
        // The amending key registers no undo of its own (it rewrites the
        // first key's entry), so it is not wrapped in a manual group here.
        controller.opacityDigit(5, at: 10.2)
        XCTAssertEqual(store.document[layerID: id]!.opacity, 0.45, accuracy: 1e-6)
        XCTAssertEqual(store.historyEntries.map(\.actionName), ["New", "Change Opacity"])

        // Too late to pair: a fresh single-digit entry.
        grouped(um) { controller.opacityDigit(7, at: 11.5) }
        XCTAssertEqual(store.document[layerID: id]!.opacity, 0.7, accuracy: 1e-6)
        XCTAssertEqual(store.historyEntries.count, 3)

        um.undo()
        XCTAssertEqual(store.document[layerID: id]!.opacity, 0.45, accuracy: 1e-6)
        um.undo()
        XCTAssertEqual(store.document[layerID: id]?.opacity, 1)
        XCTAssertEqual(um.undoMenuItemTitle, "Undo")
        XCTAssertFalse(um.canUndo)
    }

    func testAppliesToEverySelectedLayer() {
        let (store, um) = makeStore()
        let ids = store.document.layers.map(\.id)
        store.selectLayer(ids[0])
        store.toggleLayerSelection(ids[1])
        grouped(um) { store.setOpacityFromKeys(percent: 30, amendingPrevious: false) }
        XCTAssertEqual(store.document.layers.map(\.opacity), [0.3, 0.3])
        XCTAssertEqual(um.undoActionName, "Change Opacity")
    }

    func testBrushToolsSetBrushOpacityNotTheLayer() {
        let (store, _) = makeStore()
        let controller = CanvasController(store: store)
        store.activeTool = .brush
        controller.opacityDigit(3, at: 1)
        XCTAssertEqual(store.brushOpacity, 30)
        controller.opacityDigit(0, at: 5)
        controller.opacityDigit(0, at: 5.1)
        XCTAssertEqual(store.brushOpacity, 1, "brush opacity bottoms out at 1%")
        XCTAssertEqual(store.document.layers.map(\.opacity), [1, 1])
        XCTAssertEqual(store.historyEntries.count, 1)
    }
}

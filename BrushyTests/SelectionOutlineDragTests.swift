import AppKit
import CoreGraphics
import XCTest

/// Photoshop's other selection drag: with a marquee or lasso tool active, a
/// press INSIDE the selection moves the outline, leaving the pixels alone.
/// Driven through the real controller; the default viewport (zoom 1, origin
/// zero) makes view points and canvas points the same.
final class SelectionOutlineDragTests: XCTestCase {
    private func makeController(tool: Tool = .marquee) -> (DocumentStore, CanvasController) {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        document.layers = [Layer(name: "Paint",
                                 source: GeneratedImages.solid(width: 400, height: 300,
                                                               r: 200, g: 40, b: 40,
                                                               colorSpace: BrushyColorSpace.sRGB),
                                 isPaintable: true)]
        let store = DocumentStore(document: document)
        store.selectLayer(document.layers[0].id)
        store.activeTool = tool
        store.combineSelection(CGPath(rect: CGRect(x: 100, y: 100, width: 80, height: 60),
                                      transform: nil), mode: .replace)
        return (store, CanvasController(store: store))
    }

    func testDraggingInsideTheSelectionMovesTheOutlineNotThePixels() throws {
        let (store, controller) = makeController()
        let pixelsBefore = store.document

        controller.mouseDown(at: CGPoint(x: 140, y: 130), modifiers: [], clickCount: 1)
        controller.mouseDragged(to: CGPoint(x: 160, y: 120), modifiers: [])
        XCTAssertEqual(store.previewSelectionPath?.boundingBox,
                       CGRect(x: 120, y: 90, width: 80, height: 60),
                       "the outline follows the drag live")
        XCTAssertTrue(store.movingSelectionOutline, "so the old outline stops drawing under it")
        controller.mouseUp(at: CGPoint(x: 160, y: 120), modifiers: [], clickCount: 1)

        XCTAssertEqual(try XCTUnwrap(store.selection.path?.boundingBoxOfPath),
                       CGRect(x: 120, y: 90, width: 80, height: 60))
        XCTAssertNil(store.previewSelectionPath)
        XCTAssertFalse(store.movingSelectionOutline)
        XCTAssertEqual(store.document, pixelsBefore, "no pixel moved, and no float was lifted")
        XCTAssertNil(store.selectionFloat)
        XCTAssertEqual(store.historyEntries.last?.actionName, "Move Selection Outline")
    }

    func testTheLassoMovesTheOutlineToo() throws {
        let (store, controller) = makeController(tool: .lasso)
        controller.mouseDown(at: CGPoint(x: 140, y: 130), modifiers: [], clickCount: 1)
        controller.mouseDragged(to: CGPoint(x: 150, y: 130), modifiers: [])
        controller.mouseUp(at: CGPoint(x: 150, y: 130), modifiers: [], clickCount: 1)

        XCTAssertEqual(try XCTUnwrap(store.selection.path?.boundingBoxOfPath),
                       CGRect(x: 110, y: 100, width: 80, height: 60),
                       "and does not draw a new lasso from inside the selection")
    }

    func testShiftInsideTheSelectionStillStartsANewMarquee() throws {
        let (store, controller) = makeController()
        controller.mouseDown(at: CGPoint(x: 140, y: 130), modifiers: [.shift], clickCount: 1)
        controller.mouseDragged(to: CGPoint(x: 240, y: 230), modifiers: [.shift])
        controller.mouseUp(at: CGPoint(x: 240, y: 230), modifiers: [.shift], clickCount: 1)

        // ⇧ means add-to-selection, so the union is wider than either piece.
        XCTAssertEqual(try XCTUnwrap(store.selection.path?.boundingBoxOfPath),
                       CGRect(x: 100, y: 100, width: 140, height: 130))
    }

    func testDraggingOutsideTheSelectionDrawsANewOne() throws {
        let (store, controller) = makeController()
        controller.mouseDown(at: CGPoint(x: 10, y: 10), modifiers: [], clickCount: 1)
        controller.mouseDragged(to: CGPoint(x: 50, y: 40), modifiers: [])
        controller.mouseUp(at: CGPoint(x: 50, y: 40), modifiers: [], clickCount: 1)

        XCTAssertEqual(try XCTUnwrap(store.selection.path?.boundingBoxOfPath),
                       CGRect(x: 10, y: 10, width: 40, height: 30))
    }

    func testAClickInsideTheSelectionLeavesItExactlyWhereItWas() throws {
        let (store, controller) = makeController()
        let before = try XCTUnwrap(store.selection.path?.boundingBoxOfPath)
        let entries = store.historyEntries.count

        controller.mouseDown(at: CGPoint(x: 140, y: 130), modifiers: [], clickCount: 1)
        controller.mouseUp(at: CGPoint(x: 140, y: 130), modifiers: [], clickCount: 1)

        XCTAssertEqual(store.selection.path?.boundingBoxOfPath, before)
        XCTAssertEqual(store.historyEntries.count, entries, "a click is not an edit")
    }
}

import AppKit
import CoreGraphics
import XCTest

/// Photoshop's Rectangular Marquee modifiers, driven through the real
/// controller: Space mid-drag moves the rectangle being drawn, ⇧ held
/// mid-drag squares it, ⌥ held mid-drag draws it from the centre — while ⇧/⌥
/// at mouse-down still choose add/subtract. The geometry itself is covered by
/// `SelectionModifyTests`. The default viewport (zoom 1, origin zero) makes
/// view points and canvas points the same here.
final class MarqueeGestureTests: XCTestCase {
    private func makeController() -> (DocumentStore, CanvasController) {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 400, height: 300)))
        store.activeTool = .marquee
        return (store, CanvasController(store: store))
    }

    func testSpaceMovesTheRectangleBeingDrawnThenSizingResumes() throws {
        let (store, controller) = makeController()
        let originBefore = store.viewport.origin
        controller.mouseDown(at: CGPoint(x: 20, y: 30), modifiers: [], clickCount: 1)
        controller.mouseDragged(to: CGPoint(x: 70, y: 60), modifiers: [])

        controller.spaceDown = true
        controller.mouseDragged(to: CGPoint(x: 170, y: 110), modifiers: [])
        XCTAssertEqual(store.viewport.origin, originBefore, "Space mid-marquee must not pan")
        XCTAssertEqual(store.previewSelectionPath?.boundingBox,
                       CGRect(x: 120, y: 80, width: 50, height: 30),
                       "the rectangle moves with the pointer, keeping its size")
        controller.spaceDown = false

        controller.mouseDragged(to: CGPoint(x: 200, y: 150), modifiers: [])
        controller.mouseUp(at: CGPoint(x: 200, y: 150), modifiers: [], clickCount: 1)
        XCTAssertEqual(try XCTUnwrap(store.selection.path?.boundingBox),
                       CGRect(x: 120, y: 80, width: 80, height: 70),
                       "sizing resumes from the moved anchor")
    }

    func testShiftSquaresAndOptionCentresWhenPressedMidDrag() throws {
        let (store, controller) = makeController()
        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: [], clickCount: 1)
        controller.mouseDragged(to: CGPoint(x: 140, y: 120), modifiers: [])

        controller.modifiersChanged([.shift])
        XCTAssertEqual(store.previewSelectionPath?.boundingBox,
                       CGRect(x: 100, y: 100, width: 40, height: 40))
        controller.modifiersChanged([.shift, .option])
        XCTAssertEqual(store.previewSelectionPath?.boundingBox,
                       CGRect(x: 60, y: 60, width: 80, height: 80))

        controller.mouseUp(at: CGPoint(x: 140, y: 120), modifiers: [.shift, .option], clickCount: 1)
        XCTAssertEqual(try XCTUnwrap(store.selection.path?.boundingBox),
                       CGRect(x: 60, y: 60, width: 80, height: 80),
                       "keys pressed after mouse-down constrain but don't change the replace mode")
    }

    func testShiftAtMouseDownAddsAndReleasingItUnconstrains() throws {
        let (store, controller) = makeController()
        store.combineSelection(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil),
                               mode: .replace)
        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: [.shift], clickCount: 1)
        controller.mouseDragged(to: CGPoint(x: 150, y: 120), modifiers: []) // ⇧ released
        controller.mouseUp(at: CGPoint(x: 150, y: 120), modifiers: [], clickCount: 1)
        XCTAssertEqual(try XCTUnwrap(store.selection.path?.boundingBox),
                       CGRect(x: 0, y: 0, width: 150, height: 120),
                       "added to the existing selection, and not squared once ⇧ was let go")
    }
}

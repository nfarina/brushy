import AppKit
import CoreGraphics
import XCTest

// No `@testable import Dezzy` — see the note atop ClipboardTests.swift.

/// Space pans the canvas mid-gesture WITHOUT cancelling the active tool
/// (`CanvasController.mouseDragged` returns early while `spaceDown`), and
/// `mouseUp` then derives the shape/gradient endpoint from the mouse-up
/// position — which is a *different screen point* by then. (The marquee is the
/// exception: Space mid-marquee moves the rectangle instead, as in Photoshop —
/// see `MarqueeGestureTests`.)
///
/// It nonetheless lands correctly, and these tests exist to keep it that way.
/// The reason it works is not obvious from either function alone: the pan
/// applies exactly the mouse delta (`pan(by: viewPoint - lastViewPoint)`) and
/// `Viewport.pan` is unclamped, so the two cancel —
///
///     before:  c = (v − o) / zoom
///     after:   c = ((v + d) − (o + d)) / zoom
///
/// — leaving the canvas point under the cursor unchanged. That equivalence is
/// load-bearing and entirely implicit: clamping `Viewport.pan` to keep the
/// canvas on screen, or panning by anything other than the raw mouse delta,
/// would silently start landing gestures where the user never dragged, with
/// the error growing with the distance panned.
///
/// The shape tool pads its layer symmetrically around the dragged rectangle,
/// so the new layer's centre is the drag's centre.
final class SpacePanGestureTests: XCTestCase {
    private func makeStore() -> DocumentStore {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        document.layers = [Layer(name: "bg",
                                 source: GeneratedImages.solid(width: 400, height: 300,
                                                               r: 200, g: 200, b: 200,
                                                               colorSpace: DezzyColorSpace.sRGB))]
        return DocumentStore(document: document)
    }

    private func makeShapeController(_ store: DocumentStore) -> CanvasController {
        let controller = CanvasController(store: store)
        store.activeTool = .shape
        store.shapeStyle.kind = .rectangle
        return controller
    }

    /// Drag a shape, hold space and pan a long way, then release. The shape
    /// must cover the rectangle that was dragged, not one shifted by the pan.
    func testShapeIgnoresAPanThatHappensBeforeMouseUp() throws {
        let store = makeStore()
        let controller = makeShapeController(store)

        let startCanvas = CGPoint(x: 50, y: 60)
        let endCanvas = CGPoint(x: 150, y: 160)
        controller.mouseDown(at: store.viewport.toView(startCanvas), modifiers: [], clickCount: 1)
        controller.mouseDragged(to: store.viewport.toView(endCanvas), modifiers: [])

        // Space-pan without moving the mouse in canvas terms: the pointer
        // stays put on screen while the document slides under it.
        let heldViewPoint = store.viewport.toView(endCanvas)
        let originBefore = store.viewport.origin
        controller.spaceDown = true
        controller.mouseDragged(to: heldViewPoint + CGPoint(x: 90, y: 70), modifiers: [])
        controller.spaceDown = false
        XCTAssertNotEqual(store.viewport.origin, originBefore,
                          "the test is only meaningful if the pan actually moved the viewport")
        controller.mouseUp(at: heldViewPoint + CGPoint(x: 90, y: 70),
                           modifiers: [], clickCount: 1)

        XCTAssertEqual(store.document.layers.count, 2, "the drag created a shape layer")
        let bounds = try XCTUnwrap(store.document.layers.last).canvasBounds
        XCTAssertEqual(bounds.midX, (startCanvas.x + endCanvas.x) / 2, accuracy: 1)
        XCTAssertEqual(bounds.midY, (startCanvas.y + endCanvas.y) / 2, accuracy: 1)
    }

    /// A drag that RESUMES after the pan must use where it resumed to. Guards
    /// the obvious over-correction: freezing the endpoint at the pre-pan point
    /// would pass the test above and break this one.
    func testShapeUsesTheResumedEndpointAfterAPan() throws {
        let store = makeStore()
        let controller = makeShapeController(store)

        let startCanvas = CGPoint(x: 20, y: 20)
        controller.mouseDown(at: store.viewport.toView(startCanvas), modifiers: [], clickCount: 1)
        controller.mouseDragged(to: store.viewport.toView(CGPoint(x: 60, y: 60)), modifiers: [])

        controller.spaceDown = true
        controller.mouseDragged(to: store.viewport.toView(CGPoint(x: 60, y: 60))
                                    + CGPoint(x: 40, y: 40), modifiers: [])
        controller.spaceDown = false

        // Carry on dragging to a genuinely new canvas point.
        let resumed = CGPoint(x: 200, y: 180)
        controller.mouseDragged(to: store.viewport.toView(resumed), modifiers: [])
        controller.mouseUp(at: store.viewport.toView(resumed), modifiers: [], clickCount: 1)

        let bounds = try XCTUnwrap(store.document.layers.last).canvasBounds
        XCTAssertEqual(bounds.midX, (startCanvas.x + resumed.x) / 2, accuracy: 1,
                       "the resumed endpoint must win")
        XCTAssertEqual(bounds.midY, (startCanvas.y + resumed.y) / 2, accuracy: 1)
    }

    /// A plain click still deselects: no drag was ever applied, so there is no
    /// recorded endpoint and the fallback has to be the mouse-up point.
    func testPlainClickStillDeselects() {
        let store = makeStore()
        let controller = CanvasController(store: store)
        store.activeTool = .marquee
        store.combineSelection(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      transform: nil), mode: .replace)

        let point = store.viewport.toView(CGPoint(x: 200, y: 150))
        controller.mouseDown(at: point, modifiers: [], clickCount: 1)
        controller.mouseUp(at: point, modifiers: [], clickCount: 1)
        XCTAssertTrue(store.selection.isEmpty, "a click with no drag deselects")
    }
}

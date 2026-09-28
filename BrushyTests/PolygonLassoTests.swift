import AppKit
import CoreGraphics
import XCTest

/// Polygonal Lasso: the pure geometry, then the click sequence through the
/// real controller (default viewport: view points = canvas points).
final class PolygonLassoTests: XCTestCase {
    private func makeController() -> (DocumentStore, CanvasController) {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 400, height: 300)))
        store.activeTool = .lasso
        store.lassoStyle = .polygonal
        return (store, CanvasController(store: store))
    }

    private func click(_ controller: CanvasController, _ x: CGFloat, _ y: CGFloat,
                       count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        controller.mouseDown(at: CGPoint(x: x, y: y), modifiers: modifiers, clickCount: count)
        controller.mouseUp(at: CGPoint(x: x, y: y), modifiers: modifiers, clickCount: count)
    }

    func testGeometry() {
        XCTAssertTrue(PolygonLasso.closes(at: CGPoint(x: 104, y: 103), firstVertex: CGPoint(x: 100, y: 100),
                                          vertexCount: 3))
        XCTAssertFalse(PolygonLasso.closes(at: CGPoint(x: 104, y: 103), firstVertex: CGPoint(x: 100, y: 100),
                                           vertexCount: 2), "a closed outline needs three vertices")
        XCTAssertFalse(PolygonLasso.closes(at: CGPoint(x: 110, y: 100), firstVertex: CGPoint(x: 100, y: 100),
                                           vertexCount: 5))
        XCTAssertEqual(PolygonLasso.nextVertex(after: .zero, toward: CGPoint(x: 50, y: 3), constrained: true).y,
                       0, accuracy: 1e-9)
        XCTAssertNil(PolygonLasso.closedPath(vertices: [.zero, CGPoint(x: 1, y: 1)]))
    }

    func testClicksPlaceVerticesAndClickingTheStartCloses() throws {
        let (store, controller) = makeController()
        click(controller, 100, 100)
        click(controller, 200, 100)
        controller.hover(at: CGPoint(x: 200, y: 180))
        XCTAssertEqual(store.previewSelectionPath?.boundingBoxOfPath,
                       CGRect(x: 100, y: 100, width: 100, height: 80), "the band follows the pointer")
        click(controller, 200, 200)
        XCTAssertTrue(store.selection.isEmpty, "nothing is selected until the outline closes")
        click(controller, 103, 102)
        XCTAssertNil(store.previewSelectionPath)
        let path = try XCTUnwrap(store.selection.path)
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 100, y: 100, width: 100, height: 100))
        XCTAssertTrue(path.contains(CGPoint(x: 180, y: 120)))
        XCTAssertFalse(path.contains(CGPoint(x: 120, y: 180)), "a triangle, not the box")
    }

    func testDoubleClickAndReturnClose() throws {
        let (store, controller) = makeController()
        click(controller, 10, 10)
        click(controller, 60, 10)
        click(controller, 60, 60)
        click(controller, 60, 60, count: 2)
        XCTAssertEqual(try XCTUnwrap(store.selection.path).boundingBoxOfPath,
                       CGRect(x: 10, y: 10, width: 50, height: 50))

        store.deselect()
        click(controller, 10, 10)
        click(controller, 60, 10)
        click(controller, 10, 60)
        controller.handleReturn()
        XCTAssertFalse(store.selection.isEmpty)
    }

    func testDeleteTakesBackAVertexAndEscapeCancels() throws {
        let (store, controller) = makeController()
        click(controller, 10, 10)
        click(controller, 60, 10)
        click(controller, 300, 250)
        XCTAssertTrue(controller.removeLastPolygonVertex())
        click(controller, 60, 60)
        controller.handleReturn()
        XCTAssertEqual(try XCTUnwrap(store.selection.path).boundingBoxOfPath,
                       CGRect(x: 10, y: 10, width: 50, height: 50))

        store.deselect()
        click(controller, 10, 10)
        click(controller, 60, 10)
        controller.handleEscape()
        XCTAssertNil(store.previewSelectionPath)
        XCTAssertFalse(controller.removeLastPolygonVertex(), "⌫ is back to its usual meaning")
        XCTAssertTrue(store.selection.isEmpty)
    }

    func testSwitchingToolOrStyleEndsThePolygon() {
        let (store, controller) = makeController()
        click(controller, 10, 10)
        click(controller, 60, 10)
        store.lassoStyle = .freehand
        XCTAssertNil(store.previewSelectionPath)
        store.lassoStyle = .polygonal
        click(controller, 200, 200)
        XCTAssertEqual(store.previewSelectionPath?.boundingBoxOfPath.origin, CGPoint(x: 200, y: 200),
                       "a fresh polygon, not the abandoned one")
        store.activeTool = .marquee
        XCTAssertNil(store.previewSelectionPath)
        XCTAssertFalse(controller.removeLastPolygonVertex())
    }

    func testFirstClickModifierChoosesSubtract() throws {
        let (store, controller) = makeController()
        store.combineSelection(CGPath(rect: CGRect(x: 0, y: 0, width: 300, height: 300), transform: nil),
                               mode: .replace)
        click(controller, 350, 10, modifiers: [.option]) // outside, so not an outline grab
        click(controller, 350, 350)
        click(controller, 10, 350)
        controller.handleReturn()
        let path = try XCTUnwrap(store.selection.path)
        XCTAssertFalse(path.contains(CGPoint(x: 290, y: 290)), "the triangle was subtracted")
        XCTAssertTrue(path.contains(CGPoint(x: 10, y: 10)))
    }
}

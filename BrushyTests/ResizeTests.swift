import CoreGraphics
import Foundation
import XCTest

final class ResizeTests: XCTestCase {
    private func sampleDocument() -> Document {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        let p3 = BrushyColorSpace.displayP3
        document.layers = [
            Layer(name: "A",
                  source: GeneratedImages.solid(width: 100, height: 80, r: 200, g: 40, b: 40,
                                                colorSpace: p3),
                  transform: CGAffineTransform(translationX: 40, y: 30)),
            Layer(name: "B",
                  source: GeneratedImages.solid(width: 60, height: 60, r: 40, g: 200, b: 40,
                                                colorSpace: p3),
                  transform: CGAffineTransform(rotationAngle: 0.4)
                    .concatenating(CGAffineTransform(translationX: 220, y: 150))),
        ]
        return document
    }

    // MARK: Image Size

    /// Image Size scales transforms only — sources stay the identical objects,
    /// and geometry lands exactly where a document-wide scale should put it.
    func testImageSizeScalesTransformsNotSources() {
        let document = sampleDocument()
        let originalBounds = document.layers.map(\.canvasBounds)
        let resized = document.scaled(to: CGSize(width: 200, height: 150))

        XCTAssertEqual(resized.canvasSize, CGSize(width: 200, height: 150))
        for (resizedLayer, original) in zip(resized.layers, document.layers) {
            XCTAssertTrue(resizedLayer.source === original.source)
        }
        for (bounds, original) in zip(resized.layers.map(\.canvasBounds), originalBounds) {
            XCTAssertEqual(bounds.minX, original.minX * 0.5, accuracy: 1e-9)
            XCTAssertEqual(bounds.minY, original.minY * 0.5, accuracy: 1e-9)
            XCTAssertEqual(bounds.width, original.width * 0.5, accuracy: 1e-9)
            XCTAssertEqual(bounds.height, original.height * 0.5, accuracy: 1e-9)
        }
    }

    func testImageSizeNonUniform() {
        let resized = sampleDocument().scaled(to: CGSize(width: 400, height: 600))
        let (sx, sy) = resized.layers[0].transform.scaleComponents
        XCTAssertEqual(sx, 1, accuracy: 1e-9)
        XCTAssertEqual(sy, 2, accuracy: 1e-9)
    }

    /// Round-tripping a resize restores geometry — nothing was baked.
    func testImageSizeRoundTripIsLossless() {
        let document = sampleDocument()
        let roundTripped = document
            .scaled(to: CGSize(width: 123, height: 77))
            .scaled(to: document.canvasSize)
        for (a, b) in zip(roundTripped.layers, document.layers) {
            for (va, vb) in zip(a.transform.asArray, b.transform.asArray) {
                XCTAssertEqual(va, vb, accuracy: 1e-6)
            }
            XCTAssertTrue(a.source === b.source)
        }
    }

    // MARK: Canvas Size

    func testCanvasSizeAnchors() {
        let document = sampleDocument() // 400×300
        let grow = CGSize(width: 500, height: 400)

        // Centre anchor: content shifts by half the added space.
        let centered = document.resizingCanvas(to: grow, anchor: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(centered.layers[0].transform.tx, 40 + 50)
        XCTAssertEqual(centered.layers[0].transform.ty, 30 + 50)

        // Top-left anchor (y-up: x=0, y=1): content pinned to the top-left,
        // new space appears right and below.
        let topLeft = document.resizingCanvas(to: grow, anchor: CGPoint(x: 0, y: 1))
        XCTAssertEqual(topLeft.layers[0].transform.tx, 40)
        XCTAssertEqual(topLeft.layers[0].transform.ty, 30 + 100)

        // Bottom-right anchor (x=1, y=0): new space appears left and above.
        let bottomRight = document.resizingCanvas(to: grow, anchor: CGPoint(x: 1, y: 0))
        XCTAssertEqual(bottomRight.layers[0].transform.tx, 40 + 100)
        XCTAssertEqual(bottomRight.layers[0].transform.ty, 30)
    }

    /// Shrinking the canvas never destroys content: growing back restores it.
    func testCanvasSizeShrinkKeepsPixels() {
        let document = sampleDocument()
        let small = document.resizingCanvas(to: CGSize(width: 120, height: 90),
                                            anchor: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(small.canvasSize, CGSize(width: 120, height: 90))
        let restored = small.resizingCanvas(to: document.canvasSize,
                                            anchor: CGPoint(x: 0.5, y: 0.5))
        for (a, b) in zip(restored.layers, document.layers) {
            XCTAssertEqual(a.transform, b.transform)
            XCTAssertTrue(a.source === b.source)
        }
    }

    // MARK: Store integration

    func testStoreResizeOpsAreUndoableWithNames() {
        let store = DocumentStore(document: sampleDocument())
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        let original = store.document

        undoManager.beginUndoGrouping()
        store.resizeImage(to: CGSize(width: 800, height: 600))
        undoManager.endUndoGrouping()
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 800, height: 600))
        XCTAssertEqual(undoManager.undoActionName, "Image Size")

        undoManager.beginUndoGrouping()
        store.resizeCanvas(to: CGSize(width: 1000, height: 700), anchor: CGPoint(x: 0, y: 1))
        undoManager.endUndoGrouping()
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 1000, height: 700))
        XCTAssertEqual(undoManager.undoActionName, "Canvas Size")

        undoManager.undo()
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 800, height: 600))
        undoManager.undo()
        XCTAssertEqual(store.document.canvasSize, original.canvasSize)
        XCTAssertEqual(store.document.layers[0].transform, original.layers[0].transform)
    }

    func testStoreClampsDegenerateSizes() {
        let store = DocumentStore(document: sampleDocument())
        store.resizeImage(to: CGSize(width: 0, height: -5))
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 1, height: 1))
        store.resizeImage(to: CGSize(width: 99999, height: 50))
        XCTAssertEqual(store.document.canvasSize.width, 16384)
    }
}

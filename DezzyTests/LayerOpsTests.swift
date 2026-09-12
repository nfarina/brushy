import CoreGraphics
import Foundation
import XCTest

final class LayerOpsTests: XCTestCase {
    /// A layer whose left half is red and right half is blue, for orientation
    /// checks after flips/rotations.
    private func makeStore() -> DocumentStore {
        var document = Document(canvasSize: CGSize(width: 300, height: 200))
        let source = GeneratedImages.image(width: 100, height: 80,
                                           colorSpace: DezzyColorSpace.displayP3) { x, _ in
            x < 50 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }
        document.layers = [Layer(name: "halves", source: source,
                                 transform: CGAffineTransform(translationX: 100, y: 60))]
        return DocumentStore(document: document)
    }

    private func renderedPixel(_ store: DocumentStore, x: Int, yUp: Int) throws
        -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let image = RenderEngine.shared.renderFlattened(
            document: store.document, profile: DezzyColorSpace.displayP3,
            sixteenBit: false)!
        let pixels = try rawRGBA8(image)
        return pixels[x, Int(store.document.canvasSize.height) - 1 - yUp]
    }

    func testFlipHorizontalMirrorsContentInPlace() throws {
        let store = makeStore()
        let boundsBefore = store.document.layers[0].canvasBounds
        XCTAssertGreaterThan(try renderedPixel(store, x: 110, yUp: 100).r, 200,
                             "left half starts red")

        store.flipSelectedLayer(vertical: false)

        let layer = store.document.layers[0]
        XCTAssertEqual(layer.canvasBounds.midX, boundsBefore.midX, accuracy: 0.001)
        XCTAssertEqual(layer.canvasBounds.midY, boundsBefore.midY, accuracy: 0.001)
        XCTAssertEqual(layer.canvasBounds.width, boundsBefore.width, accuracy: 0.001)
        XCTAssertGreaterThan(try renderedPixel(store, x: 110, yUp: 100).b, 200,
                             "after horizontal flip the left half is blue")
        XCTAssertGreaterThan(try renderedPixel(store, x: 190, yUp: 100).r, 200)
    }

    func testRotate90KeepsCenterAndSwapsDimensions() throws {
        let store = makeStore()
        let before = store.document.layers[0].canvasBounds

        store.rotateSelectedLayer90(clockwise: false) // 90° left (CCW, y-up)

        let after = store.document.layers[0].canvasBounds
        XCTAssertEqual(after.midX, before.midX, accuracy: 0.001)
        XCTAssertEqual(after.midY, before.midY, accuracy: 0.001)
        XCTAssertEqual(after.width, before.height, accuracy: 0.001)
        XCTAssertEqual(after.height, before.width, accuracy: 0.001)
        // CCW: the red (originally left) half ends up at the BOTTOM.
        XCTAssertGreaterThan(try renderedPixel(store, x: 150, yUp: 60).r, 200)
        XCTAssertGreaterThan(try renderedPixel(store, x: 150, yUp: 140).b, 200)

        // Four rotations come back to the identity bounds.
        for _ in 0..<3 { store.rotateSelectedLayer90(clockwise: false) }
        let restored = store.document.layers[0].canvasBounds
        XCTAssertEqual(restored.minX, before.minX, accuracy: 0.01)
        XCTAssertEqual(restored.minY, before.minY, accuracy: 0.01)
        XCTAssertTrue(store.document.layers[0].source === makeStoreSourceCheck(store),
                      "flips/rotations never touch the source")
    }

    private func makeStoreSourceCheck(_ store: DocumentStore) -> CGImage {
        store.document.layers[0].source
    }

    func testFillSelectionOnMask() {
        let store = makeStore()
        var layer = store.document.layers[0]
        layer.mask = Mask(texture: MaskTexture(width: 100, height: 80, fill: 255),
                          isEnabled: true)
        store.replaceDocument(store.document.replacingLayer(layer))
        store.selectLayer(layer.id)
        store.maskTargeted = true
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

        // Selection over the layer's left part (canvas coords).
        store.combineSelection(CGPath(rect: CGRect(x: 100, y: 60, width: 40, height: 80),
                                      transform: nil), mode: .replace)
        store.fillSelection()

        let texture = store.document.layers[0].mask!.texture
        func sample(_ x: Int, _ yUpLocal: Int) -> UInt8 {
            texture.data[(texture.height - 1 - yUpLocal) * texture.width + x]
        }
        XCTAssertEqual(sample(20, 40), 0, "selected mask area filled with black (hide)")
        XCTAssertEqual(sample(60, 40), 255, "unselected mask area untouched")
    }

    func testFillSelectionOnPaintLayerAndNoSelectionFillsAll() throws {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 200, height: 150)))
        store.addPaintLayer()
        store.foregroundColor = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

        store.combineSelection(CGPath(rect: CGRect(x: 20, y: 20, width: 60, height: 50),
                                      transform: nil), mode: .replace)
        store.fillSelection()
        var pixels = try rawRGBA8(store.document.layers[0].source, in: DezzyColorSpace.sRGB)
        XCTAssertGreaterThan(pixels[50, 150 - 45].g, 240, "selected area filled green")
        XCTAssertEqual(pixels[150, 20].a, 0, "outside the selection stays transparent")

        // Deselect → fill covers the whole layer, with the background colour.
        store.deselect()
        store.fillSelection(withBackgroundColor: true) // default white
        pixels = try rawRGBA8(store.document.layers[0].source, in: DezzyColorSpace.sRGB)
        XCTAssertGreaterThan(pixels[150, 20].r, 250)
        XCTAssertGreaterThan(pixels[150, 20].a, 250)
    }

    func testFillOnImportedLayerRasterizesItThenFills() {
        let store = makeStore()
        store.selectLayer(store.document.layers[0].id)
        XCTAssertFalse(store.canFillSelection, "not until it has pixels of its own")
        store.fillSelection()
        XCTAssertTrue(store.document.layers[0].isPaintable, "the fill rasterized it and went through")
        XCTAssertNotNil(store.toast)
    }
}

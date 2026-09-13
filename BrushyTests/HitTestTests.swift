import CoreGraphics
import XCTest

/// move tool: pixel-accurate click-to-select hit-testing
/// (`Document.topmostLayer(at:)`) and the ⌥-drag duplicate gesture's
/// single-undo-step contract.
final class HitTestTests: XCTestCase {
    private let p3 = BrushyColorSpace.displayP3

    /// A 100×100 solid layer translated to (x, y) in canvas space.
    private func solidLayer(name: String, x: CGFloat, y: CGFloat,
                            r: UInt8 = 200, g: UInt8 = 10, b: UInt8 = 10) -> Layer {
        var layer = Layer(name: name,
                          source: GeneratedImages.solid(width: 100, height: 100,
                                                        r: r, g: g, b: b, colorSpace: p3))
        layer.transform = CGAffineTransform(translationX: x, y: y)
        return layer
    }

    private func document(with layers: [Layer]) -> Document {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        document.layers = layers
        return document
    }

    // MARK: - topmostLayer(at:)

    func testTopmostOfOverlappingOpaqueLayersWins() {
        let bottom = solidLayer(name: "bottom", x: 0, y: 0)
        let top = solidLayer(name: "top", x: 40, y: 40, r: 10, g: 200, b: 10)
        let doc = document(with: [bottom, top])

        // Both layers cover (60, 60); the later array entry renders on top
        // (: index 0 is the bottom of the stack) and must win.
        XCTAssertEqual(doc.topmostLayer(at: CGPoint(x: 60, y: 60))?.id, top.id)
        // Where only the bottom layer has pixels, it is hit.
        XCTAssertEqual(doc.topmostLayer(at: CGPoint(x: 20, y: 20))?.id, bottom.id)
        // Empty canvas: no hit.
        XCTAssertNil(doc.topmostLayer(at: CGPoint(x: 350, y: 250)))
    }

    func testTransparentRegionFallsThroughToLayerBeneath() {
        let bottom = solidLayer(name: "bottom", x: 0, y: 0)
        let top = Layer(name: "top",
                        source: GeneratedImages.image(width: 100, height: 100,
                                                      colorSpace: p3) { col, _ in
                            col < 50 ? (10, 200, 10, 255) : (0, 0, 0, 0)
                        })
        let doc = document(with: [bottom, top])

        XCTAssertEqual(doc.topmostLayer(at: CGPoint(x: 25, y: 50))?.id, top.id,
                       "opaque half of the top layer wins")
        XCTAssertEqual(doc.topmostLayer(at: CGPoint(x: 75, y: 50))?.id, bottom.id,
                       "fully transparent pixels fall through to the layer beneath")
    }

    func testPointInsideAABBButOutsideRotatedQuadMisses() {
        // A 100×100 square rotated 45° about its centre (50, 50): the AABB
        // spans centre ± ~70.7 per axis, but the quad itself only covers
        // |dx| + |dy| ≤ ~70.7.
        var layer = solidLayer(name: "rotated", x: 0, y: 0)
        layer.transform = CGAffineTransform(translationX: 50, y: 50)
            .rotated(by: .pi / 4)
            .translatedBy(x: -50, y: -50)
        let doc = document(with: [layer])

        let corner = CGPoint(x: 110, y: 110) // inside the AABB, outside the quad
        XCTAssertTrue(layer.canvasBounds.contains(corner),
                      "precondition: the point survives the AABB fast reject")
        XCTAssertNil(doc.topmostLayer(at: corner))
        XCTAssertEqual(doc.topmostLayer(at: CGPoint(x: 50, y: 50))?.id, layer.id,
                       "centre of the rotated quad still hits")
    }

    func testMaskedOutRegionMissesAndDisabledMaskDoesNot() {
        var layer = solidLayer(name: "masked", x: 0, y: 0)
        // Hide the layer's top half. Mask buffers store row 0 at the TOP,
        // flipped relative to y-up canvas/source space.
        var texture = MaskTexture(width: 100, height: 100, fill: 255)
        texture.mutate { data in
            for i in 0..<(50 * 100) { data[i] = 0 }
        }
        layer.mask = Mask(texture: texture, isEnabled: true)
        var doc = document(with: [layer])

        XCTAssertNil(doc.topmostLayer(at: CGPoint(x: 50, y: 75)),
                     "canvas-space top half is masked out (mask row 0 = top)")
        XCTAssertEqual(doc.topmostLayer(at: CGPoint(x: 50, y: 25))?.id, layer.id,
                       "bottom half is unmasked")

        // A disabled mask is ignored, matching the renderer.
        layer.mask?.isEnabled = false
        doc = document(with: [layer])
        XCTAssertEqual(doc.topmostLayer(at: CGPoint(x: 50, y: 75))?.id, layer.id)
    }

    func testInvisibleAndSubThresholdLayersAreSkipped() {
        let bottom = solidLayer(name: "bottom", x: 0, y: 0)
        var faint = solidLayer(name: "faint", x: 0, y: 0, r: 10, g: 10, b: 200)
        faint.opacity = 0.01 // below the 0.02 default threshold
        var hidden = solidLayer(name: "hidden", x: 0, y: 0, r: 10, g: 200, b: 10)
        hidden.isVisible = false
        let doc = document(with: [bottom, faint, hidden])

        XCTAssertEqual(doc.topmostLayer(at: CGPoint(x: 50, y: 50))?.id, bottom.id,
                       "hidden and sub-threshold layers never take the click")
    }

    func testSubPixelScaledLayerIsRejectedWithoutCrashing() {
        var layer = solidLayer(name: "degenerate", x: 0, y: 0)
        layer.transform = CGAffineTransform(scaleX: 1e-14, y: 1e-14)
        let doc = document(with: [layer])

        XCTAssertNil(doc.topmostLayer(at: .zero),
                     "a non-invertible transform is skipped, not inverted")
    }

    // MARK: - ⌥-drag duplicate (store flow)

    private func makeStore() -> (DocumentStore, UndoManager) {
        let store = DocumentStore(document: document(with: [
            solidLayer(name: "L0", x: 0, y: 0),
            solidLayer(name: "L1", x: 120, y: 40, r: 10, g: 200, b: 10),
        ]))
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        return (store, undoManager)
    }

    func testOptionDragDuplicateIsOneHistoryEntryNamedDuplicateLayer() {
        let (store, um) = makeStore()
        let original = store.document.layers[1]
        store.selectLayer(original.id)
        let before = store.document

        um.beginUndoGrouping()
        guard let copy = store.beginDuplicateDrag(of: original.id) else {
            um.endUndoGrouping()
            return XCTFail("duplicate drag did not begin")
        }
        // The live drag of the copy, then the gesture's single commit.
        store.setLiveLayerTransform(
            copy.id, copy.transform.concatenating(CGAffineTransform(translationX: 25, y: -10)))
        store.commitDuplicateDrag()
        um.endUndoGrouping()

        XCTAssertEqual(um.undoActionName, "Duplicate Layer")
        XCTAssertEqual(store.document.layers.count, 3)
        XCTAssertEqual(store.selectedLayerID, copy.id, "the copy ends up selected")
        XCTAssertEqual(store.document.layerIndex(of: copy.id),
                       store.document.layerIndex(of: original.id)! + 1,
                       "the copy sits directly above the original")
        XCTAssertEqual(store.document[layerID: copy.id]?.name, original.name + " copy")
        XCTAssertEqual(store.document[layerID: copy.id]?.sourceID, original.sourceID,
                       "duplicates share source storage")
        XCTAssertEqual(store.document[layerID: original.id]?.transform, original.transform,
                       "the original never moves during an ⌥-drag")

        // Exactly one history entry: a single undo restores the pre-gesture
        // state and leaves nothing further to undo.
        XCTAssertTrue(store.canUndo)
        um.undo()
        XCTAssertEqual(store.document, before)
        XCTAssertEqual(store.selectedLayerID, original.id)
        XCTAssertFalse(store.canUndo, "⌥-drag must be exactly one undo step")
    }
}

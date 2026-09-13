import XCTest
import AppKit
import CoreGraphics

/// "Layer → Duplicate Layer to": cross-document transfer through
/// `DocumentStore.receiveLayer(_:from:)` (model, undo) and the dynamic
/// submenu the frontmost document populates via `NSMenuDelegate`.
final class CrossDocumentTransferTests: XCTestCase {

    // MARK: Fixtures

    /// 100×80 imported (non-paintable) layer — left half red, right half
    /// blue — with a non-trivial transform and a patterned full-size mask.
    private static func makeTravellerLayer() -> Layer {
        let source = GeneratedImages.image(width: 100, height: 80,
                                           colorSpace: BrushyColorSpace.displayP3) { x, _ in
            x < 50 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }
        var maskData = Data(count: 100 * 80)
        for i in 0..<maskData.count { maskData[i] = UInt8((i * 7) % 251) }
        var layer = Layer(name: "Traveller", source: source,
                          transform: CGAffineTransform(a: 0.9, b: 0.1, c: -0.1, d: 0.9,
                                                       tx: 12.5, ty: -3),
                          opacity: 0.7)
        layer.mask = Mask(texture: MaskTexture(width: 100, height: 80, data: maskData),
                          isEnabled: true)
        return layer
    }

    /// 300×200 source document holding the traveller layer.
    private func makeSourceStore() -> DocumentStore {
        var document = Document(canvasSize: CGSize(width: 300, height: 200))
        document.layers = [Self.makeTravellerLayer()]
        return DocumentStore(document: document)
    }

    private func makeTargetStore(canvas: CGSize, withBaseLayer: Bool) -> DocumentStore {
        var document = Document(canvasSize: canvas)
        if withBaseLayer {
            let base = GeneratedImages.image(width: 10, height: 10,
                                             colorSpace: BrushyColorSpace.displayP3) { _, _ in
                (20, 220, 20, 255)
            }
            document.layers = [Layer(name: "Base", source: base, transform: .identity)]
        }
        return DocumentStore(document: document)
    }

    // MARK: Transfer semantics

    func testTransferMintsFreshIdentityAndPreservesContent() throws {
        let source = makeSourceStore()
        let original = source.document.layers[0]
        let target = makeTargetStore(canvas: CGSize(width: 300, height: 200),
                                     withBaseLayer: true)

        target.receiveLayer(original, from: source.document.canvasSize)

        XCTAssertEqual(target.document.layers.count, 2)
        let received = target.document.layers[1]
        // Fresh identity on both counts: two documents must not share a
        // layer id, and never a sourceID (serializer caches key on it).
        XCTAssertNotEqual(received.id, original.id)
        XCTAssertNotEqual(received.sourceID, original.sourceID)
        XCTAssertEqual(target.selectedLayerID, received.id,
                       "the transferred layer is selected in the target")

        // Identical pixels and mask bytes; kind/opacity/visibility survive.
        let originalRaw = try rawRGBA8(original.source, in: BrushyColorSpace.displayP3)
        let receivedRaw = try rawRGBA8(received.source, in: BrushyColorSpace.displayP3)
        XCTAssertEqual(receivedRaw.rgba, originalRaw.rgba, "source pixels must survive")
        XCTAssertEqual(received.mask?.texture.data, original.mask?.texture.data,
                       "mask bytes must survive")
        XCTAssertEqual(received.mask?.isEnabled, true)
        XCTAssertEqual(received.opacity, original.opacity)
        XCTAssertEqual(received.kind, original.kind)
        XCTAssertEqual(received.isVisible, original.isVisible)
        XCTAssertFalse(received.isPaintable,
                       "an imported photo stays non-paintable in the target")
        // Equal canvas sizes preserve the transform exactly.
        XCTAssertEqual(received.transform, original.transform)
    }

    func testSourceUntouchedAndTargetGainsExactlyOneUndoStep() {
        let source = makeSourceStore()
        let sourceBefore = source.document
        let target = makeTargetStore(canvas: CGSize(width: 300, height: 200),
                                     withBaseLayer: true)
        let targetBefore = target.document
        let um = UndoManager()
        um.groupsByEvent = false
        um.levelsOfUndo = 100
        target.undoManager = um

        um.beginUndoGrouping()
        target.receiveLayer(source.document.layers[0], from: source.document.canvasSize)
        um.endUndoGrouping()

        XCTAssertEqual(source.document, sourceBefore, "the source document is unmodified")
        XCTAssertFalse(source.canUndo, "the source gains no history entry")

        XCTAssertEqual(um.undoActionName, "Duplicate Layer")
        XCTAssertTrue(target.canUndo)
        um.undo()
        XCTAssertEqual(target.document, targetBefore)
        XCTAssertFalse(um.canUndo, "exactly one history entry on the target")
    }

    func testUnequalCanvasReplacesLikeNewlyPlacedImage() {
        let source = makeSourceStore()
        let original = source.document.layers[0]
        let targetCanvas = CGSize(width: 500, height: 400)
        let target = makeTargetStore(canvas: targetCanvas, withBaseLayer: true)

        target.receiveLayer(original, from: source.document.canvasSize)

        let received = target.document.layers[1]
        let expected = DocumentStore.placedLayer(original.source, named: original.name,
                                                 canvasSize: targetCanvas).transform
        XCTAssertEqual(received.transform, expected,
                       "a different canvas re-places the layer like a newly placed image")
        // 100×80 source fits 500×400 unscaled, so it is centred 1:1.
        XCTAssertEqual(received.canvasBounds.midX, 250, accuracy: 0.001)
        XCTAssertEqual(received.canvasBounds.midY, 200, accuracy: 0.001)
        // Content rules hold on this path too.
        XCTAssertEqual(received.mask?.texture.data, original.mask?.texture.data)
        XCTAssertNotEqual(received.sourceID, original.sourceID)
    }

    func testEmptyTargetAdoptsSourceCanvasAndKeepsTransform() {
        let source = makeSourceStore()
        let original = source.document.layers[0]
        let target = makeTargetStore(canvas: CGSize(width: 1920, height: 1080),
                                     withBaseLayer: false)

        target.receiveLayer(original, from: source.document.canvasSize)

        XCTAssertEqual(target.document.canvasSize, CGSize(width: 300, height: 200),
                       "an empty target adopts the source document's frame")
        XCTAssertEqual(target.document.layers.count, 1)
        XCTAssertEqual(target.document.layers[0].transform, original.transform,
                       "adoption preserves the transform, so the layer lands in place")
        XCTAssertEqual(target.selectedLayerID, target.document.layers[0].id)
    }

    func testMismatchedMaskIsDropped() {
        var layer = Self.makeTravellerLayer()
        layer.mask = Mask(texture: MaskTexture(width: 64, height: 48, fill: 255),
                          isEnabled: true)
        let target = makeTargetStore(canvas: CGSize(width: 300, height: 200),
                                     withBaseLayer: true)

        target.receiveLayer(layer, from: CGSize(width: 300, height: 200))

        XCTAssertNil(target.document.layers[1].mask,
                     "a mask whose dimensions differ from the source raster is dropped, "
                        + "the same rule updateVectorLayer applies")
    }

    func testTransferArmsFreeTransformExactlyWhenCanvasNotAdopted() {
        let source = makeSourceStore()
        let original = source.document.layers[0]

        // A non-empty target receives the copy with Free Transform armed —
        // the shared arrival rule (`armTransformForArrivedLayer`),
        // same as Place, drop and Paste.
        let populated = makeTargetStore(canvas: CGSize(width: 300, height: 200),
                                        withBaseLayer: true)
        populated.receiveLayer(original, from: source.document.canvasSize)
        XCTAssertEqual(populated.transformSession?.layerID,
                       populated.document.layers[1].id,
                       "transfer into a non-empty document arms Free Transform "
                          + "on the received copy")

        // An empty target adopted the source frame: Open semantics, no box.
        let empty = makeTargetStore(canvas: CGSize(width: 1920, height: 1080),
                                    withBaseLayer: false)
        empty.receiveLayer(original, from: source.document.canvasSize)
        XCTAssertNil(empty.transformSession,
                     "no transform box when the document adopted the source frame")
    }

    func testVectorKindSurvivesTransfer() {
        var layer = Self.makeTravellerLayer()
        layer.mask = nil
        layer.kind = .shape(ShapeSpec(kind: .rectangle))
        let target = makeTargetStore(canvas: CGSize(width: 300, height: 200),
                                     withBaseLayer: true)

        target.receiveLayer(layer, from: CGSize(width: 300, height: 200))

        XCTAssertEqual(target.document.layers[1].kind, layer.kind,
                       "shape/text kind survives so the layer stays editable in the target")
    }

    // MARK: Submenu population

    func testSubmenuListsOtherDocumentsAndNewDocument() {
        let docA = BrushyDocument()
        let docB = BrushyDocument()
        NSDocumentController.shared.addDocument(docA)
        NSDocumentController.shared.addDocument(docB)
        defer {
            NSDocumentController.shared.removeDocument(docA)
            NSDocumentController.shared.removeDocument(docB)
        }

        let menu = NSMenu(title: "Duplicate Layer to")
        docA.menuNeedsUpdate(menu)

        let targets = menu.items.compactMap { $0.representedObject as? BrushyDocument }
        XCTAssertTrue(targets.contains { $0 === docB }, "other documents are listed")
        XCTAssertFalse(targets.contains { $0 === docA }, "the document itself is excluded")
        XCTAssertEqual(menu.items.last?.title, "New Document")
        XCTAssertEqual(menu.items.last?.action,
                       #selector(BrushyDocument.duplicateLayerToNewDocument(_:)))

        // With no other document open, the submenu shows just "New Document".
        NSDocumentController.shared.removeDocument(docB)
        docA.menuNeedsUpdate(menu)
        let remaining = menu.items.compactMap { $0.representedObject as? BrushyDocument }
        XCTAssertFalse(remaining.contains { $0 === docB })
        XCTAssertEqual(menu.items.last?.title, "New Document")
        NSDocumentController.shared.addDocument(docB) // keep the deferred removal balanced
    }
}

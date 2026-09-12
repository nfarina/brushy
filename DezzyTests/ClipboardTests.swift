import AppKit
import CoreGraphics
import XCTest

// No `@testable import Dezzy`: the test target compiles the app sources
// directly (file-system-synchronized groups), so the app module isn't a
// dependency — importing it only resolves against stale DerivedData and
// breaks clean builds.

/// — clipboard Cut / Copy / Copy Merged / Paste / Paste Into.
final class ClipboardTests: XCTestCase {
    /// 300×200 canvas; 100×80 imported (non-paintable) layer at (100, 60):
    /// left half red, right half blue.
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

    private func uniquePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("clipboard-tests-\(UUID().uuidString)"))
    }

    // MARK: Round trip

    func testLayerRoundTripsThroughPasteboard() throws {
        let pb = uniquePasteboard()
        let source = GeneratedImages.gradientChecker(width: 64, height: 48, square: 8,
                                                     colorSpace: DezzyColorSpace.displayP3)
        var maskData = Data(count: 64 * 48)
        for i in 0..<maskData.count { maskData[i] = UInt8((i * 7) % 251) }
        var layer = Layer(name: "Round Trip", source: source,
                          transform: CGAffineTransform(a: 0.9, b: 0.1, c: -0.1, d: 0.9,
                                                       tx: 12.5, ty: -3),
                          opacity: 0.7)
        layer.mask = Mask(texture: MaskTexture(width: 64, height: 48, data: maskData),
                          isEnabled: true)
        layer.blendMode = .screen
        layer.isClippedToBelow = true

        XCTAssertTrue(LayerPasteboard.write(layer: layer,
                                            canvasSize: CGSize(width: 320, height: 240),
                                            renderedImage: nil, to: pb))
        guard case .layer(let envelope) = LayerPasteboard.read(from: pb),
              let decoded = LayerPasteboard.layer(from: envelope) else {
            return XCTFail("Expected a layer payload on the pasteboard")
        }
        XCTAssertEqual(decoded.transform, layer.transform)
        XCTAssertEqual(decoded.opacity, layer.opacity)
        XCTAssertEqual(decoded.name, "Round Trip")
        XCTAssertEqual(decoded.kind, .raster)
        XCTAssertEqual(decoded.blendMode, .screen, "blend mode must survive the envelope")
        XCTAssertFalse(decoded.isClippedToBelow,
                       "a pasted layer lands unclipped — clipping is a relationship with the stack it left")
        XCTAssertEqual(decoded.mask?.isEnabled, true)
        XCTAssertEqual(decoded.mask?.texture.data, maskData, "mask bytes must survive")
        XCTAssertEqual(envelope.canvasWidth, 320)
        XCTAssertEqual(envelope.canvasHeight, 240)
        let original = try rawRGBA8(source, in: DezzyColorSpace.displayP3)
        let roundTripped = try rawRGBA8(decoded.source, in: DezzyColorSpace.displayP3)
        XCTAssertEqual(roundTripped.rgba, original.rgba, "source pixels must survive")

        // A vector kind survives the envelope too.
        var textLayer = layer
        textLayer.mask = nil
        textLayer.kind = .text(TextSpec())
        XCTAssertTrue(LayerPasteboard.write(layer: textLayer,
                                            canvasSize: CGSize(width: 320, height: 240),
                                            renderedImage: nil, to: pb))
        guard case .layer(let envelope2) = LayerPasteboard.read(from: pb),
              let decoded2 = LayerPasteboard.layer(from: envelope2) else {
            return XCTFail("Expected a layer payload on the pasteboard")
        }
        XCTAssertEqual(decoded2.kind, textLayer.kind)
    }

    // MARK: Copy with a selection → paste into another document

    func testCopyWithSelectionPastesCroppedLayerInPlace() throws {
        let pb = uniquePasteboard()
        let store = makeStore()
        let selectionRect = CGRect(x: 120, y: 70, width: 40, height: 30)
        store.combineSelection(CGPath(rect: selectionRect, transform: nil), mode: .replace)
        store.copySelection(to: pb)

        let target = DocumentStore(document: Document(canvasSize: CGSize(width: 500, height: 400)))
        target.paste(from: pb)

        XCTAssertEqual(target.document.layers.count, 1)
        // The empty target adopted the source document's canvas, so the layer
        // pasted in place: its bounds are exactly the selection rectangle.
        XCTAssertEqual(target.document.canvasSize, CGSize(width: 300, height: 200))
        let pasted = target.document.layers[0]
        XCTAssertEqual(pasted.canvasBounds, selectionRect)
        XCTAssertTrue(pasted.isPaintable)

        let raw = try rawRGBA8(pasted.source, in: DezzyColorSpace.displayP3)
        XCTAssertEqual(raw.width, 40)
        XCTAssertEqual(raw.height, 30)
        // Canvas x 120…149 is layer-local x 20…49 (red); 150…159 is blue.
        let left = raw[5, 15]
        let right = raw[35, 15]
        XCTAssertGreaterThan(Int(left.r), 200)
        XCTAssertLessThan(Int(left.b), 55)
        XCTAssertGreaterThan(Int(right.b), 200)
        XCTAssertLessThan(Int(right.r), 55)
        XCTAssertEqual(left.a, 255)
    }

    // MARK: Copy Merged vs. independent reference

    func testCopyMergedMatchesReferenceComposite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let p3 = DezzyColorSpace.displayP3
        let bottom = GeneratedImages.horizontalGradient(width: 200, height: 150,
                                                        from: (255, 0, 0), to: (0, 0, 255),
                                                        colorSpace: p3)
        let top = GeneratedImages.gradientChecker(width: 80, height: 60, square: 10,
                                                  colorSpace: p3)
        try writePNG(bottom, to: dir.appendingPathComponent("bottom.png"))
        try writePNG(top, to: dir.appendingPathComponent("top.png"))

        let spec = FixtureSpec(name: "clipboard-merged", notes: nil,
                               canvas: .init(width: 200, height: 150),
                               outputProfile: "displayP3", referenceKind: "analytic",
                               colorTolerance: nil, alphaTolerance: nil,
                               layers: [
                                   .init(source: "bottom.png", transform: [1, 0, 0, 1, 0, 0],
                                         opacity: nil, visible: nil, mask: nil),
                                   .init(source: "top.png", transform: [1, 0, 0, 1, 40, 30],
                                         opacity: nil, visible: nil, mask: nil),
                               ],
                               reference: "unused.png")
        let reference = try ReferenceRenderer.render(spec: spec, fixturesDir: dir)

        let store = DocumentStore(document: try spec.buildDocument(fixturesDir: dir))
        let selectionRect = CGRect(x: 30, y: 20, width: 100, height: 90)
        store.combineSelection(CGPath(rect: selectionRect, transform: nil), mode: .replace)
        let pb = uniquePasteboard()
        store.copyMerged(to: pb)

        guard case .layer(let envelope) = LayerPasteboard.read(from: pb),
              let merged = LayerPasteboard.layer(from: envelope) else {
            return XCTFail("Copy Merged wrote no layer payload")
        }
        XCTAssertEqual(merged.canvasBounds, selectionRect)

        let actual = try rawRGBA8(merged.source, in: p3)
        let expected = try rawRGBA8(reference, in: p3)
        var maxDelta = 0
        for row in 0..<actual.height {
            for col in 0..<actual.width {
                let a = actual[col, row]
                let e = expected[Int(selectionRect.minX) + col,
                                 150 - Int(selectionRect.maxY) + row]
                maxDelta = max(maxDelta,
                               abs(Int(a.r) - Int(e.r)), abs(Int(a.g) - Int(e.g)),
                               abs(Int(a.b) - Int(e.b)), abs(Int(a.a) - Int(e.a)))
            }
        }
        XCTAssertLessThanOrEqual(maxDelta, 2, "Copy Merged deviates from the reference composite")
    }

    // MARK: Cut

    func testCutOnImportedLayerRasterizesItThenCuts() {
        let pb = uniquePasteboard()
        let store = makeStore()
        let undoManager = UndoManager()
        store.undoManager = undoManager
        let originalSource = store.document.layers[0].source
        XCTAssertFalse(store.document.layers[0].isPaintable)

        store.combineSelection(CGPath(rect: CGRect(x: 100, y: 60, width: 40, height: 80),
                                      transform: nil), mode: .replace)
        store.cutSelection(to: pb)

        let layer = store.document.layers[0]
        XCTAssertTrue(layer.isPaintable, "cutting from a photo rasterizes it")
        XCTAssertFalse(layer.source === originalSource, "so the pixels really are cut")
        XCTAssertNil(layer.mask, "no hide-mask invented in its place")
        XCTAssertNotNil(store.toast)
        if case .layer = LayerPasteboard.read(from: pb) {} else {
            XCTFail("Cut did not write the layer flavour")
        }
        // Undo walks back through the cut and the rasterize it needed.
        XCTAssertTrue(store.canUndo)
        undoManager.undo()
        XCTAssertTrue(store.document.layers[0].source === originalSource,
                      "the photo's own bytes come back")
        XCTAssertFalse(store.document.layers[0].isPaintable)
    }

    func testCopyAndCutOutsideLayerBoundsAreNoOps() {
        let pb = uniquePasteboard()
        let store = makeStore()
        store.combineSelection(CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 40),
                                      transform: nil), mode: .replace)
        store.copySelection(to: pb)
        XCTAssertNil(pb.types?.first { $0 == LayerPasteboard.layerType },
                     "A selection outside the layer must not write to the pasteboard")

        let before = store.document
        store.cutSelection(to: pb)
        XCTAssertEqual(store.document, before, "Cut outside the layer must not commit")
        XCTAssertNil(store.document.layers[0].mask)
    }

    // MARK: Paste Into

    func testPasteIntoMasksToSelectionAndConsumesIt() {
        let pb = uniquePasteboard()
        let store = makeStore()
        store.copySelection(to: pb) // whole layer — no selection yet
        let selectionRect = CGRect(x: 110, y: 70, width: 30, height: 20)
        store.combineSelection(CGPath(rect: selectionRect, transform: nil), mode: .replace)
        store.pasteInto(from: pb)

        XCTAssertEqual(store.document.layers.count, 2)
        let pasted = store.document.layers[1]
        XCTAssertEqual(pasted.mask?.isEnabled, true, "Paste Into must mask to the selection")
        XCTAssertTrue(store.selection.isEmpty, "Paste Into consumes the selection")
        XCTAssertNotNil(store.transformSession, "pasted content arrives with Free Transform armed")
    }

    // MARK: Transform on arrival

    func testPasteIntoNonEmptyDocumentArmsFreeTransformOnPastedLayer() {
        let pb = uniquePasteboard()
        let store = makeStore()
        store.copySelection(to: pb) // whole layer — no selection yet
        store.paste(from: pb)

        XCTAssertEqual(store.document.layers.count, 2)
        let pasted = store.document.layers[1]
        XCTAssertEqual(store.selectedLayerID, pasted.id)
        XCTAssertEqual(store.transformSession?.layerID, pasted.id,
                       "paste into a non-empty document arms Free Transform on "
                          + "the pasted layer — the same rule as Place and drop")
    }

    func testPasteIntoEmptyDocumentAdoptsImageSizeWithoutTransformBox() throws {
        let pb = uniquePasteboard()
        let image = GeneratedImages.solid(width: 240, height: 180, r: 30, g: 90, b: 200,
                                          colorSpace: DezzyColorSpace.sRGB)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]))
        pb.declareTypes([.png], owner: nil)
        pb.setData(png, forType: .png)

        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 1920,
                                                                        height: 1080)))
        store.paste(from: pb)

        XCTAssertEqual(store.document.layers.count, 1)
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 240, height: 180),
                       "an empty document adopts the pasted image's size — Open semantics")
        XCTAssertNil(store.transformSession,
                     "no transform box when the pasted image defined the canvas")
    }

    func testPasteCommitsExactlyOneHistoryEntryDespiteArming() {
        let pb = uniquePasteboard()
        let store = makeStore()
        store.copySelection(to: pb)
        let before = store.document
        let um = UndoManager()
        um.groupsByEvent = false
        um.levelsOfUndo = 100
        store.undoManager = um

        um.beginUndoGrouping()
        store.paste(from: pb)
        um.endUndoGrouping()

        XCTAssertNotNil(store.transformSession, "arming happens after the commit")
        XCTAssertEqual(um.undoActionName, "Paste")
        um.undo()
        XCTAssertEqual(store.document, before,
                       "a single undo removes the whole paste — arming added no second entry")
        XCTAssertNil(store.transformSession, "history stepping discards the armed session")
        XCTAssertFalse(um.canUndo, "exactly one history entry")
    }
}

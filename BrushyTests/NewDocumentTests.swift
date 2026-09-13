import AppKit
import CoreGraphics
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// File → New…: the sized-creation path behind the New Document dialog.
/// (The modal dialog itself is UI; the creation helper is what must hold.)
/// Deliberately windowless: `sizedUntitledDocument` is tested without
/// `makeWindowControllers()` — a Metal-backed canvas window created in the
/// test process measurably slows the performance test that runs later.
final class NewDocumentTests: XCTestCase {
    func testSizedUntitledDocumentUsesRequestedSize() {
        let doc = AppDelegate.sizedUntitledDocument(size: CGSize(width: 640, height: 480))
        defer { doc.close() }
        XCTAssertEqual(doc.store.document.canvasSize, CGSize(width: 640, height: 480))
        // Every new document starts with a canvas-sized blank "Layer 1".
        XCTAssertEqual(doc.store.document.layers.count, 1)
        let blank = doc.store.document.layers[0]
        XCTAssertEqual(blank.name, "Layer 1")
        XCTAssertTrue(blank.isPaintable)
        XCTAssertEqual(blank.source.width, 640)
        XCTAssertEqual(blank.source.height, 480)
        XCTAssertFalse(doc.store.canUndo, "a fresh document starts with clean history")
    }

    func testSizedUntitledDocumentClampsDegenerateSizes() {
        let doc = AppDelegate.sizedUntitledDocument(size: CGSize(width: 0, height: 99999))
        defer { doc.close() }
        XCTAssertEqual(doc.store.document.canvasSize, CGSize(width: 1, height: 16384),
                       "sizes clamp to the store's Metal-friendly limits")
    }

    // MARK: Auto blank layer

    /// A store shaped exactly like a fresh window's: one pristine blank.
    private func pristineStore(canvasSize: CGSize) -> DocumentStore {
        var document = Document(canvasSize: canvasSize)
        document.layers = [DocumentStore.blankPaintLayer(canvasSize: canvasSize,
                                                         name: "Layer 1")!]
        return DocumentStore(document: document)
    }

    /// A pasteboard carrying a whole-layer copy from a 300×200 document.
    private func pasteboardWithCopiedLayer() -> NSPasteboard {
        let pb = uniquePasteboard()
        var sourceDoc = Document(canvasSize: CGSize(width: 300, height: 200))
        sourceDoc.layers = [Layer(name: "photo",
                                  source: GeneratedImages.solid(
                                      width: 100, height: 80, r: 0, g: 200, b: 0,
                                      colorSpace: BrushyColorSpace.displayP3),
                                  transform: CGAffineTransform(translationX: 10, y: 20))]
        DocumentStore(document: sourceDoc).copySelection(to: pb)
        return pb
    }

    func testUntitledDocumentStartsWithPristineBlankLayer() {
        let doc = BrushyDocument()
        XCTAssertEqual(doc.store.document.layers.count, 1)
        XCTAssertTrue(doc.store.isPristineBlankDocument)
        XCTAssertEqual(doc.store.selectedLayerID, doc.store.document.layers[0].id,
                       "the blank layer is selected and ready to paint")
    }

    func testArrivalReplacesPristineBlank() {
        let target = pristineStore(canvasSize: CGSize(width: 1920, height: 1080))
        target.paste(from: pasteboardWithCopiedLayer())
        XCTAssertEqual(target.document.layers.count, 1,
                       "a pristine blank is replaced, not stacked above")
        XCTAssertEqual(target.document.layers[0].name, "photo")
        XCTAssertEqual(target.document.canvasSize, CGSize(width: 300, height: 200),
                       "adoption fires exactly as it did for empty documents")
    }

    func testEditedBlankIsNotReplaced() {
        let target = pristineStore(canvasSize: CGSize(width: 500, height: 400))
        target.undoManager = UndoManager()
        target.renameLayer(target.document.layers[0].id, to: "My painting")
        target.paste(from: pasteboardWithCopiedLayer())
        XCTAssertEqual(target.document.layers.count, 2,
                       "any committed edit makes the blank user content")
        XCTAssertEqual(target.document.canvasSize, CGSize(width: 500, height: 400),
                       "no adoption once the document has real content")
    }

    func testExplicitlySizedDocumentKeepsItsBlankLayer() {
        let target = pristineStore(canvasSize: CGSize(width: 800, height: 600))
        target.canvasSizeChosenExplicitly = true
        target.paste(from: pasteboardWithCopiedLayer())
        XCTAssertEqual(target.document.layers.count, 2,
                       "a ⌘N document keeps its Layer 1, like Photoshop")
        XCTAssertEqual(target.document.canvasSize, CGSize(width: 800, height: 600))
    }

    // MARK: Clipboard size offer

    private func uniquePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("new-doc-tests-\(UUID().uuidString)"))
    }

    func testContentPixelSizeReadsLayerEnvelopeCanvas() {
        let pb = uniquePasteboard()
        let source = GeneratedImages.solid(width: 40, height: 30, r: 10, g: 20, b: 30,
                                           colorSpace: BrushyColorSpace.displayP3)
        LayerPasteboard.write(layer: Layer(name: "L", source: source),
                              canvasSize: CGSize(width: 640, height: 360),
                              renderedImage: nil, to: pb)
        XCTAssertEqual(LayerPasteboard.contentPixelSize(on: pb),
                       CGSize(width: 640, height: 360),
                       "a copied layer offers its source canvas, so a paste lands in place")
    }

    func testContentPixelSizeReadsRawImageData() throws {
        let pb = uniquePasteboard()
        let image = GeneratedImages.solid(width: 123, height: 45, r: 1, g: 2, b: 3,
                                          colorSpace: BrushyColorSpace.sRGB)
        let png = try XCTUnwrap(DocumentSerializer.encodePNG(image))
        pb.clearContents()
        pb.setData(png, forType: .png)
        XCTAssertEqual(LayerPasteboard.contentPixelSize(on: pb),
                       CGSize(width: 123, height: 45))
    }

    func testContentPixelSizeNilOnEmptyPasteboard() {
        XCTAssertNil(LayerPasteboard.contentPixelSize(on: uniquePasteboard()))
    }

    // MARK: Explicit size beats empty-document adoption

    func testExplicitlySizedDocumentKeepsCanvasOnPaste() {
        let pb = uniquePasteboard()
        var sourceDoc = Document(canvasSize: CGSize(width: 300, height: 200))
        sourceDoc.layers = [Layer(name: "red",
                                  source: GeneratedImages.solid(
                                      width: 100, height: 80, r: 255, g: 0, b: 0,
                                      colorSpace: BrushyColorSpace.displayP3),
                                  transform: CGAffineTransform(translationX: 100, y: 60))]
        let source = DocumentStore(document: sourceDoc)
        source.copySelection(to: pb)

        // Paste into an EMPTY document whose size the user chose explicitly.
        let target = DocumentStore(document: Document(canvasSize: CGSize(width: 800, height: 600)))
        target.canvasSizeChosenExplicitly = true
        target.paste(from: pb)

        XCTAssertEqual(target.document.canvasSize, CGSize(width: 800, height: 600),
                       "an explicitly chosen size is never overridden by adoption")
        XCTAssertEqual(target.document.layers.count, 1)
        // Non-adopted paste: the layer recentres and arrives with the box armed.
        XCTAssertEqual(target.document.layers[0].canvasBounds.midX, 400, accuracy: 0.5)
        XCTAssertEqual(target.document.layers[0].canvasBounds.midY, 300, accuracy: 0.5)
        XCTAssertNotNil(target.transformSession)
    }
}

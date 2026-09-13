import CoreGraphics
import Foundation
import XCTest

// NOTE: no `@testable import Brushy` — the test target compiles the app
// sources directly (see ClipboardTests.swift).

/// guides as document state (pure ops, crop/scale behaviour,
/// persistence, undo) and the ruler tick metrics.
final class GuidesTests: XCTestCase {

    // MARK: - Document ops

    func testGuideOpsAddMoveReplaceRemoveClear() {
        let doc = Document(canvasSize: CGSize(width: 400, height: 300))
        let v = Guide(axis: .vertical, position: 100)
        let h = Guide(axis: .horizontal, position: 50)

        var d = doc.addingGuide(v).addingGuide(h)
        XCTAssertEqual(d.guides.map(\.id), [v.id, h.id])

        d = d.movingGuide(id: v.id, to: 140)
        XCTAssertEqual(d.guides.first?.position, 140)
        XCTAssertEqual(d.guides.map(\.id), [v.id, h.id], "moving preserves order")

        // replacingGuide carries the ⌥ axis flip; order must survive so an
        // unchanged drag produces a document equal to its base.
        d = d.replacingGuide(Guide(id: v.id, axis: .horizontal, position: 60))
        XCTAssertEqual(d.guides.first?.axis, .horizontal)
        XCTAssertEqual(d.guides.first?.position, 60)
        XCTAssertEqual(d.guides.map(\.id), [v.id, h.id])

        XCTAssertEqual(d.removingGuide(id: v.id).guides.map(\.id), [h.id])
        XCTAssertTrue(d.clearingGuides().guides.isEmpty)
    }

    func testCropShiftsGuidesAndKeepsOutOfFrameOnes() {
        var doc = Document(canvasSize: CGSize(width: 400, height: 300))
        doc.guides = [Guide(axis: .vertical, position: 100),
                      Guide(axis: .horizontal, position: 50),
                      Guide(axis: .vertical, position: 10)]
        let cropped = doc.cropped(to: CGRect(x: 40, y: 30, width: 200, height: 150))
        XCTAssertEqual(cropped.guides[0].position, 60, "vertical shifts by −origin.x")
        XCTAssertEqual(cropped.guides[1].position, 20, "horizontal shifts by −origin.y")
        // Pushed outside the frame but kept, like layer content.
        XCTAssertEqual(cropped.guides[2].position, -30)
        XCTAssertEqual(cropped.guides.count, 3)
        // Growing the canvas back over it recovers the original position.
        let restored = cropped.cropped(to: CGRect(x: -40, y: -30, width: 400, height: 300))
        XCTAssertEqual(restored.guides[2].position, 10)
    }

    func testImageSizeScalesGuides() {
        var doc = Document(canvasSize: CGSize(width: 400, height: 300))
        doc.guides = [Guide(axis: .vertical, position: 100),
                      Guide(axis: .horizontal, position: 50)]
        let scaled = doc.scaled(to: CGSize(width: 800, height: 450))
        XCTAssertEqual(scaled.guides[0].position, 200, "vertical scales by sx (×2)")
        XCTAssertEqual(scaled.guides[1].position, 75, "horizontal scales by sy (×1.5)")
    }

    func testCanvasSizeShiftsGuidesLikeCrop() {
        var doc = Document(canvasSize: CGSize(width: 400, height: 300))
        doc.guides = [Guide(axis: .vertical, position: 0)]
        let grown = doc.resizingCanvas(to: CGSize(width: 500, height: 400),
                                       anchor: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(grown.guides[0].position, 50)
    }

    // MARK: - Ruler metrics

    func testNiceStepIsMonotoneAcrossZoomRange() {
        var previous: CGFloat = 0
        // Sweep zoom from far in to far out: the label step must never
        // shrink, and must always keep the minimum screen spacing.
        var zoom = Viewport.maxZoom
        while zoom >= Viewport.minZoom {
            let step = RulerMetrics.niceStep(for: zoom)
            XCTAssertGreaterThanOrEqual(step * zoom, 50 - 1e-6,
                                        "screen spacing too small at zoom \(zoom)")
            XCTAssertGreaterThanOrEqual(step, previous,
                                        "step shrank while zooming out at zoom \(zoom)")
            previous = step
            zoom *= 0.97
        }
    }

    func testNiceStepValuesComeFromTheNiceSequence() {
        for zoom in stride(from: 0.03, through: 32.0, by: 0.13) {
            let step = RulerMetrics.niceStep(for: CGFloat(zoom))
            let decade = pow(10, (log10(step)).rounded(.down))
            let mantissa = step / decade
            XCTAssertTrue([1, 2, 2.5, 5].contains { abs($0 - mantissa) < 1e-6 },
                          "step \(step) is not from the 1/2/5 · decade sequence")
        }
    }

    func testNiceStepSpotValues() {
        XCTAssertEqual(RulerMetrics.niceStep(for: 1), 50)
        XCTAssertEqual(RulerMetrics.niceStep(for: 2), 25)
        XCTAssertEqual(RulerMetrics.niceStep(for: 0.5), 100)
        XCTAssertEqual(RulerMetrics.niceStep(for: 32), 2)
        XCTAssertEqual(RulerMetrics.niceStep(for: 0.03), 2500)
    }

    func testGridNearestRespectsOrigin() {
        let grid = SmartGuides.Grid(step: 25, origin: CGPoint(x: 0, y: 310))
        XCTAssertEqual(grid.nearestX(to: 52), 50)
        XCTAssertEqual(grid.nearestX(to: 63), 75)
        // The y lattice is offset to the canvas top: … 10, 35, 60 … 310.
        XCTAssertEqual(grid.nearestY(to: 33), 35)
        XCTAssertEqual(grid.nearestY(to: 300), 310)
    }

    // MARK: - Persistence

    func testGuidesRoundTripThroughCompdoc() throws {
        let p3 = BrushyColorSpace.displayP3
        var document = Document(canvasSize: CGSize(width: 320, height: 240))
        document.layers = [Layer(name: "Base",
                                 source: GeneratedImages.solid(width: 40, height: 30,
                                                               r: 200, g: 100, b: 50,
                                                               colorSpace: p3))]
        document.guides = [Guide(axis: .vertical, position: 123.5),
                           Guide(axis: .horizontal, position: -20)] // off-canvas: kept

        let wrapper = try DocumentSerializer().fileWrapper(for: document)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("guides-\(UUID().uuidString).brushy")
        try wrapper.write(to: temp, options: .atomic, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let restored = try DocumentSerializer().document(from: FileWrapper(url: temp))

        XCTAssertEqual(restored.guides, document.guides)
    }

    func testDocumentWithoutGuidesKeyDecodesToEmpty() throws {
        // Pre-Task-4 documents have no "guides" key → decode as []. Writing
        // an empty list omits the key, so old files round-trip unchanged.
        let p3 = BrushyColorSpace.displayP3
        var document = Document(canvasSize: CGSize(width: 64, height: 48))
        document.layers = [Layer(name: "L",
                                 source: GeneratedImages.solid(width: 8, height: 8,
                                                               r: 1, g: 2, b: 3,
                                                               colorSpace: p3))]
        let wrapper = try DocumentSerializer().fileWrapper(for: document)
        let json = wrapper.fileWrappers?["document.json"]?.regularFileContents ?? Data()
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("\"guides\""))
        let restored = try DocumentSerializer().document(from: wrapper)
        XCTAssertTrue(restored.guides.isEmpty)
    }

    // MARK: - Store commits & undo

    func testGuideDragCommitsAreUndoableWithNames() {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 400, height: 300)))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager

        let guide = Guide(axis: .vertical, position: 100)
        undoManager.beginUndoGrouping()
        store.commitGuideDrag(store.document.addingGuide(guide), actionName: "Add Guide")
        undoManager.endUndoGrouping()
        XCTAssertEqual(store.document.guides, [guide])
        XCTAssertEqual(undoManager.undoActionName, "Add Guide")

        undoManager.beginUndoGrouping()
        store.commitGuideDrag(store.document.movingGuide(id: guide.id, to: 160),
                              actionName: "Move Guide")
        undoManager.endUndoGrouping()
        XCTAssertEqual(store.document.guides.first?.position, 160)
        XCTAssertEqual(undoManager.undoActionName, "Move Guide")

        undoManager.beginUndoGrouping()
        store.clearGuides()
        undoManager.endUndoGrouping()
        XCTAssertTrue(store.document.guides.isEmpty)
        XCTAssertEqual(undoManager.undoActionName, "Clear Guides")

        undoManager.undo()
        XCTAssertEqual(store.document.guides.first?.position, 160)
        undoManager.undo()
        XCTAssertEqual(store.document.guides.first?.position, 100)
        undoManager.undo()
        XCTAssertTrue(store.document.guides.isEmpty)
    }

    func testCancelledGuideDragLeavesNoHistory() {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 400, height: 300)))
        let base = store.document
        // Mid-gesture live guide, then the drop cancels (dropped on a ruler):
        // the controller re-commits the base, which must dissolve entirely.
        store.setLiveDocument(base.addingGuide(Guide(axis: .vertical, position: 50)))
        store.commitGuideDrag(base, actionName: "Remove Guide")
        XCTAssertTrue(store.document.guides.isEmpty)
        XCTAssertFalse(store.canUndo, "a cancelled guide drag must not create history")
    }
}

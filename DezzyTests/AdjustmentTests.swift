import CoreGraphics
import CoreImage
import Foundation
import XCTest

/// Adjustment layers: the pure curve maths, what the renderer makes of it, and
/// the layer's life in the document.
final class AdjustmentTests: XCTestCase {
    // MARK: - Pure maths

    func testLevelsMapsTheInputRangeOntoTheOutputRange() {
        var levels = AdjustmentSpec.Levels()
        levels.inputBlack = 0.2
        levels.inputWhite = 0.8
        XCTAssertEqual(levels.apply(0.2), 0, accuracy: 0.001, "the black point bottoms out")
        XCTAssertEqual(levels.apply(0.8), 1, accuracy: 0.001, "the white point tops out")
        XCTAssertEqual(levels.apply(0.5), 0.5, accuracy: 0.001, "the midpoint stays put")
        XCTAssertEqual(levels.apply(0.1), 0, accuracy: 0.001, "below black clips")
        XCTAssertEqual(levels.apply(0.9), 1, accuracy: 0.001, "above white clips")
    }

    func testLevelsGammaAboveOneLightensLikePhotoshop() {
        var levels = AdjustmentSpec.Levels()
        levels.gamma = 2
        XCTAssertGreaterThan(levels.apply(0.5), 0.5)
        XCTAssertEqual(levels.apply(0), 0, accuracy: 0.001, "the ends are pinned")
        XCTAssertEqual(levels.apply(1), 1, accuracy: 0.001)
        levels.gamma = 0.5
        XCTAssertLessThan(levels.apply(0.5), 0.5, "below one darkens")
    }

    func testLevelsOutputRangeLiftsBlacks() {
        var levels = AdjustmentSpec.Levels()
        levels.outputBlack = 0.25
        levels.outputWhite = 0.75
        XCTAssertEqual(levels.apply(0), 0.25, accuracy: 0.001)
        XCTAssertEqual(levels.apply(1), 0.75, accuracy: 0.001)
    }

    func testUntouchedAdjustmentsAreInactiveAndIdentity() {
        XCTAssertFalse(AdjustmentSpec.levels(.init()).isActive)
        XCTAssertFalse(AdjustmentSpec.curves(.init()).isActive)
        XCTAssertFalse(AdjustmentSpec.hueSaturation(.init()).isActive)
        for value in [0.0, 0.3, 0.5, 0.9, 1.0] {
            XCTAssertEqual(AdjustmentSpec.Levels().apply(value), value, accuracy: 0.001)
            XCTAssertEqual(AdjustmentSpec.Curves().apply(value), value, accuracy: 0.02)
        }
    }

    func testCurvesPassThroughTheirControlPointsAndStayInRange() {
        var curves = AdjustmentSpec.Curves()
        curves.outputs = [0, 0.1, 0.7, 0.9, 1]
        XCTAssertEqual(curves.apply(0.25), 0.1, accuracy: 0.001)
        XCTAssertEqual(curves.apply(0.5), 0.7, accuracy: 0.001)
        XCTAssertEqual(curves.apply(0.75), 0.9, accuracy: 0.001)
        for step in 0...20 {
            let value = curves.apply(Double(step) / 20)
            XCTAssertTrue((0...1).contains(value), "\(value) escaped 0…1")
        }
    }

    // MARK: - Rendering

    /// A mid-grey canvas with one adjustment layer over it.
    private func makeStore(_ spec: AdjustmentSpec) -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: CGSize(width: 8, height: 8))
        document.layers = [Layer(name: "Grey",
                                 source: GeneratedImages.solid(width: 8, height: 8,
                                                               r: 128, g: 128, b: 128,
                                                               colorSpace: DezzyColorSpace.sRGB),
                                 isPaintable: true)]
        let store = DocumentStore(document: document)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        store.selectLayer(document.layers[0].id)
        undoManager.beginUndoGrouping()
        store.addAdjustmentLayer(spec)
        undoManager.endUndoGrouping()
        return (store, undoManager)
    }

    private func grey(_ store: DocumentStore) -> UInt8 {
        let engine = RenderEngine.shared
        guard let cg = engine.context.createCGImage(engine.compositeImage(for: store.document),
                                                    from: CGRect(x: 3, y: 3, width: 1, height: 1),
                                                    format: .RGBA8,
                                                    colorSpace: DezzyColorSpace.sRGB) else { return 0 }
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: DezzyColorSpace.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return ctx.data!.assumingMemoryBound(to: UInt8.self)[0]
    }

    func testALevelsLayerLightensWhatIsBelowIt() {
        var levels = AdjustmentSpec.Levels()
        levels.gamma = 2
        let (store, _) = makeStore(.levels(levels))
        XCTAssertGreaterThan(grey(store), 150, "mid grey lifts with gamma 2")

        // Hiding the adjustment puts the composite back.
        store.setLayerVisibility(store.document.layers[1].id, false)
        XCTAssertEqual(Int(grey(store)), 128, accuracy: 3, "hidden adjustments do nothing")
    }

    func testAdjustmentOpacityFadesTheCorrection() {
        var levels = AdjustmentSpec.Levels()
        levels.gamma = 2
        let (store, _) = makeStore(.levels(levels))
        let full = grey(store)
        store.setLiveOpacity(store.document.layers[1].id, 0.5)
        let half = grey(store)
        XCTAssertLessThan(half, full, "half opacity is half the correction")
        XCTAssertGreaterThan(half, 128)
    }

    func testHueSaturationDesaturatesAndCurvesDarken() {
        var desaturate = AdjustmentSpec.HueSaturation()
        desaturate.saturation = -100
        var document = Document(canvasSize: CGSize(width: 8, height: 8))
        document.layers = [Layer(name: "Red",
                                 source: GeneratedImages.solid(width: 8, height: 8, r: 220, g: 30, b: 30,
                                                               colorSpace: DezzyColorSpace.sRGB),
                                 isPaintable: true)]
        let store = DocumentStore(document: document)
        store.selectLayer(document.layers[0].id)
        store.addAdjustmentLayer(.hueSaturation(desaturate))
        let engine = RenderEngine.shared
        let cg = engine.context.createCGImage(engine.compositeImage(for: store.document),
                                              from: CGRect(x: 3, y: 3, width: 1, height: 1),
                                              format: .RGBA8, colorSpace: DezzyColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: DezzyColorSpace.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Int(data[0]), Int(data[1]), accuracy: 6, "fully desaturated is grey")
        XCTAssertEqual(Int(data[1]), Int(data[2]), accuracy: 6)
    }

    // MARK: - The layer's life

    func testAddingAnAdjustmentIsOneUndoStepAndOpensItsEditor() {
        let (store, um) = makeStore(.curves(.init()))
        XCTAssertEqual(store.document.layers.count, 2)
        XCTAssertEqual(store.document.layers[1].name, "Curves")
        XCTAssertEqual(um.undoActionName, "New Curves Layer")
        XCTAssertEqual(store.adjustmentRequest?.id, store.document.layers[1].id,
                       "the editor opens on the new layer")
        XCTAssertEqual(store.editableAdjustmentLayerID, store.document.layers[1].id)

        um.undo()
        XCTAssertEqual(store.document.layers.count, 1)
    }

    func testEditingCommitsOnceAndPreviewsLive() {
        let (store, um) = makeStore(.levels(.init()))
        let id = store.document.layers[1].id
        let entries = store.historyEntries.count

        var levels = AdjustmentSpec.Levels()
        levels.gamma = 1.5
        store.updateAdjustment(id, spec: .levels(levels), transient: true)
        XCTAssertEqual(store.historyEntries.count, entries, "dragging leaves no history")

        levels.gamma = 1.8
        um.beginUndoGrouping()
        store.updateAdjustment(id, spec: .levels(levels), transient: false)
        um.endUndoGrouping()
        XCTAssertEqual(store.historyEntries.count, entries + 1)
        XCTAssertEqual(um.undoActionName, "Levels")
        XCTAssertEqual(store.document.layers[1].kind.adjustmentSpec, .levels(levels))
    }

    func testPixelToolsLeaveAnAdjustmentLayerAlone() {
        let (store, _) = makeStore(.levels(.init()))
        XCTAssertFalse(store.canFillSelection, "nothing to fill")
        XCTAssertFalse(store.canRasterizeSelectedLayer, "and nothing to rasterise")
        store.activeTool = .brush
        store.beginBrushStroke(at: CGPoint(x: 4, y: 4), eraser: false)
        XCTAssertNil(store.strokePreview)
        XCTAssertNil(store.toast, "and it doesn't rasterize anything either")
        XCTAssertNotNil(store.brushHint)
        store.enterTransformMode()
        XCTAssertNil(store.transformSession, "⌘T has nothing to transform")
    }

    func testAdjustmentSurvivesASaveAndReload() throws {
        var levels = AdjustmentSpec.Levels()
        levels.inputBlack = 0.1
        levels.gamma = 1.4
        let (store, _) = makeStore(.levels(levels))
        let serializer = DocumentSerializer()
        let wrapper = try serializer.fileWrapper(for: store.document)
        let reloaded = try serializer.document(from: wrapper)

        XCTAssertEqual(reloaded.layers.count, 2)
        XCTAssertEqual(reloaded.layers[1].kind.adjustmentSpec, .levels(levels),
                       "the spec IS the layer — it has to round-trip")
    }
}

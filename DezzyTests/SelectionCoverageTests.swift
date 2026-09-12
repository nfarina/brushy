import AppKit
import CoreGraphics
import XCTest

/// The selection's optional alpha channel: where it comes from, what keeps it,
/// what drops it, and that the operations which read it actually blend by
/// coverage rather than clipping hard.
final class SelectionCoverageTests: XCTestCase {
    private let canvas = CGSize(width: 40, height: 30)

    private func makeStore() -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: canvas)
        document.layers = [Layer(name: "Paint",
                                 source: GeneratedImages.solid(width: 40, height: 30,
                                                               r: 255, g: 255, b: 255,
                                                               colorSpace: DezzyColorSpace.sRGB),
                                 isPaintable: true)]
        let store = DocumentStore(document: document)
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        store.selectLayer(document.layers[0].id)
        store.featherAmount = 0
        return (store, undoManager)
    }

    private func pixel(_ store: DocumentStore, at point: CGPoint) -> (r: UInt8, a: UInt8) {
        let engine = RenderEngine.shared
        guard let cg = engine.context.createCGImage(
            engine.compositeImage(for: store.document),
            from: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBA8, colorSpace: DezzyColorSpace.sRGB) else { return (0, 0) }
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: DezzyColorSpace.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (data[0], data[3])
    }

    private func group(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping(); body(); um.endUndoGrouping()
    }

    /// Installs a selection whose coverage is `value` everywhere on the canvas.
    private func selectSoftly(_ store: DocumentStore, _ um: UndoManager, value: UInt8) {
        group(um) {
            store.replaceSelection(.coverage(MaskTexture(width: 40, height: 30, fill: value),
                                             rect: CGRect(origin: .zero, size: canvas)),
                                   actionName: "Select")
        }
    }

    // MARK: - Building one

    func testCoverageTracesItsOwnOutlineAtFiftyPercent() throws {
        // A left half at 200, a right half at 40: the contour falls in between.
        var texture = MaskTexture(width: 40, height: 30, fill: 0)
        texture.mutate { data in
            for row in 0..<30 {
                for col in 0..<40 { data[row * 40 + col] = col < 20 ? 200 : 40 }
            }
        }
        let selection = SelectionState.coverage(texture, rect: CGRect(origin: .zero, size: canvas))
        XCTAssertEqual(try XCTUnwrap(selection.path?.boundingBoxOfPath),
                       CGRect(x: 0, y: 0, width: 20, height: 30),
                       "the ants follow the 50% contour")
        XCTAssertTrue(selection.hasAlpha, "partial values are the whole point of keeping it")
    }

    func testBinaryCoverageKeepsNoAlphaChannel() {
        var texture = MaskTexture(width: 40, height: 30, fill: 0)
        texture.mutate { data in
            for row in 5..<15 {
                for col in 5..<15 { data[row * 40 + col] = 255 }
            }
        }
        let selection = SelectionState.coverage(texture, rect: CGRect(origin: .zero, size: canvas))
        XCTAssertFalse(selection.hasAlpha,
                       "a hard-edged region is exactly a path — no channel to carry")
        XCTAssertEqual(selection.path?.boundingBoxOfPath,
                       CGRect(x: 5, y: 15, width: 10, height: 10))
    }

    func testLoadingALayersPixelsKeepsTheirSoftness() throws {
        var document = Document(canvasSize: canvas)
        document.layers = [Layer(name: "Soft", source: halfTransparentSquare(), isPaintable: true)]
        let store = DocumentStore(document: document)
        store.selectLayer(document.layers[0].id)
        store.featherAmount = 0

        store.selectPixels(of: document.layers[0].id)

        XCTAssertTrue(store.selection.hasAlpha,
                      "⌘-click loads the layer's alpha, it does not threshold it away")
        let alpha = try XCTUnwrap(store.selection.alpha)
        // The square spans canvas (10,10)–(30,20) at 50% alpha; buffer row 0 is
        // the canvas TOP, so canvas y 15 is row 30 − 15 − 1.
        let value = alpha.texture.data[(30 - 15 - 1) * 40 + 15]
        XCTAssertEqual(Double(value), 128, accuracy: 4)
    }

    /// A 20×10 square at half alpha, at canvas (10,10).
    private func halfTransparentSquare() -> CGImage {
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: DezzyColorSpace.displayP3,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 128.0 / 255))
        ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 10))
        return ctx.makeImage()!
    }

    // MARK: - Reading it

    func testFillThroughASoftSelectionBlendsByCoverage() {
        let (store, um) = makeStore()
        selectSoftly(store, um, value: 128)
        XCTAssertTrue(store.selection.hasAlpha)

        group(um) { store.fillSelection(using: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)) }

        // Black at 50% coverage over white: neither white (coverage ignored)
        // nor black (coverage inverted).
        let value = Int(pixel(store, at: CGPoint(x: 20, y: 15)).r)
        XCTAssertTrue((90...170).contains(value), "expected a half-strength fill, got \(value)")
    }

    func testClearingThroughASoftSelectionLeavesPartialAlpha() {
        let (store, um) = makeStore()
        selectSoftly(store, um, value: 128)

        group(um) { store.clearSelection() }

        let alpha = Int(pixel(store, at: CGPoint(x: 20, y: 15)).a)
        XCTAssertTrue((90...170).contains(alpha),
                      "a half-selected pixel should be half erased, got \(alpha)")
    }

    func testAddingALayerMaskTakesTheCoverage() throws {
        let (store, um) = makeStore()
        selectSoftly(store, um, value: 128)

        group(um) { store.addLayerMask() }

        let mask = try XCTUnwrap(store.document.layers[0].mask)
        XCTAssertEqual(Double(mask.texture.data[0]), 128, accuracy: 4,
                       "the selection's own channel becomes the mask")
    }

    // MARK: - Keeping and dropping it

    func testWholePixelMovesCarryTheCoverage() throws {
        let (store, um) = makeStore()
        selectSoftly(store, um, value: 128)

        group(um) { store.moveSelectionOutline(by: CGPoint(x: 5, y: -3)) }

        XCTAssertTrue(store.selection.hasAlpha, "a translation never has to resample")
        XCTAssertEqual(try XCTUnwrap(store.selection.alpha).rect,
                       CGRect(x: 5, y: -3, width: 40, height: 30))
    }

    func testModifyDropsTheCoverageAndSaysSo() {
        let (store, um) = makeStore()
        selectSoftly(store, um, value: 128)

        group(um) { store.growSelection(by: 3) }

        XCTAssertFalse(store.selection.hasAlpha, "path morphology cannot carry a channel")
        XCTAssertNotNil(store.toast, "and the user is told rather than left guessing")
    }

    func testInverseInvertsTheCoverageExactly() throws {
        let (store, um) = makeStore()
        var texture = MaskTexture(width: 40, height: 30, fill: 0)
        texture.mutate { data in
            for row in 0..<30 {
                for col in 0..<40 { data[row * 40 + col] = col < 20 ? 200 : 40 }
            }
        }
        group(um) {
            store.replaceSelection(.coverage(texture, rect: CGRect(origin: .zero, size: canvas)),
                                   actionName: "Select")
        }

        group(um) { store.invertSelection() }

        let alpha = try XCTUnwrap(store.selection.alpha)
        XCTAssertEqual(Int(alpha.texture.data[0]), 55, "255 − 200, exactly")
        XCTAssertEqual(Int(alpha.texture.data[39]), 215)
        XCTAssertEqual(store.selection.path?.boundingBoxOfPath,
                       CGRect(x: 20, y: 0, width: 20, height: 30),
                       "and the ants swap sides with it")
        XCTAssertNil(store.toast, "nothing was lost, so nothing to announce")
    }

    func testCropKeepsTheCoverageLinedUpWithThePixels() throws {
        let (store, um) = makeStore()
        var texture = MaskTexture(width: 40, height: 30, fill: 0)
        texture.mutate { data in
            // Rows 5..<15 from the top = canvas y 15..<25, columns 10..<30.
            for row in 5..<15 {
                for col in 10..<30 { data[row * 40 + col] = 128 }
            }
        }
        group(um) {
            store.replaceSelection(.coverage(texture, rect: CGRect(origin: .zero, size: canvas)),
                                   actionName: "Select")
        }

        group(um) { store.cropToSelection() }

        XCTAssertEqual(store.document.canvasSize, CGSize(width: 20, height: 10))
        let alpha = try XCTUnwrap(store.selection.alpha)
        XCTAssertEqual(alpha.rect, CGRect(x: -10, y: -15, width: 40, height: 30),
                       "the channel shifts with the content instead of being thrown away")
        XCTAssertTrue(store.selection.hasAlpha)
    }
}

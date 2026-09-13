import CoreGraphics
import Foundation
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// Blend modes and clipping masks.
///
/// Blend arithmetic is verified analytically against closed-form Photoshop
/// math on known pixel values, in the style of ColorManagementTests. The
/// pipeline composites in linear light, but Photoshop applies blend-mode
/// math to gamma-encoded document-space values by default — the render engine
/// reconciles the two with a gamma sandwich (see `RenderEngine.blended`), so
/// the expected values below are computed on ENCODED components (byte/255),
/// exactly as Photoshop computes them. Sources are P3-tagged and output is
/// P3, so bytes map 1:1 onto encoded components (same reasoning as
/// ColorManagementTests.testCompositesInLinearLightNotGamma).
final class BlendClippingTests: XCTestCase {
    private let p3 = BrushyColorSpace.displayP3

    private func solidLayer(_ name: String, r: UInt8, g: UInt8, b: UInt8,
                            width: Int = 32, height: Int = 32) -> Layer {
        Layer(name: name,
              source: GeneratedImages.solid(width: width, height: height,
                                            r: r, g: g, b: b, colorSpace: p3))
    }

    /// Renders a 32×32 two-layer stack (opaque base + `mode` top) and returns
    /// the centre pixel.
    private func blendedPixel(base: (UInt8, UInt8, UInt8), top: (UInt8, UInt8, UInt8),
                              mode: BlendMode,
                              topOpacity: Float = 1) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        var topLayer = solidLayer("top", r: top.0, g: top.1, b: top.2)
        topLayer.blendMode = mode
        topLayer.opacity = topOpacity
        document.layers = [solidLayer("base", r: base.0, g: base.1, b: base.2), topLayer]
        guard let output = RenderEngine.shared.renderFlattened(
            document: document, profile: p3, sixteenBit: false) else {
            throw TestImageError.contextFailed
        }
        return try rawRGBA8(output)[16, 16]
    }

    // MARK: - Blend math (analytic, encoded-space)

    /// Screen is the discriminating case between the two candidate spaces:
    /// screen(128,128) on encoded values (Photoshop) gives
    /// 1−(1−0.50196)² = 0.75196 → 192; the same blend performed on linear
    /// values would encode to ≈167. The assertion range excludes the linear
    /// result by a wide margin, pinning the gamma-sandwich behaviour.
    func testScreenMatchesPhotoshopEncodedMathNotLinear() throws {
        let pixel = try blendedPixel(base: (128, 128, 128), top: (128, 128, 128), mode: .screen)
        for channel in [pixel.r, pixel.g, pixel.b] {
            XCTAssert((189...194).contains(Int(channel)),
                      "expected encoded-space screen ≈192 (Photoshop), got \(channel) — linear-space blending would give ≈167")
        }
        XCTAssertEqual(pixel.a, 255)
    }

    /// difference(200,100) = |200−100|/255 on encoded values → exactly 100.
    /// Linear-space difference would encode to ≈179.
    func testDifferenceMatchesEncodedMath() throws {
        let pixel = try blendedPixel(base: (200, 200, 200), top: (100, 100, 100), mode: .difference)
        for channel in [pixel.r, pixel.g, pixel.b] {
            XCTAssert((98...102).contains(Int(channel)),
                      "expected encoded-space difference ≈100, got \(channel) — linear-space blending would give ≈179")
        }
    }

    /// multiply(200,100): 0.78431 × 0.39216 = 0.30757 → 78.
    /// (Multiply nearly commutes with a power-law transfer, so this checks
    /// the formula more than the space — screen/difference pin the space.)
    func testMultiplyMatchesEncodedMath() throws {
        let pixel = try blendedPixel(base: (200, 200, 200), top: (100, 100, 100), mode: .multiply)
        for channel in [pixel.r, pixel.g, pixel.b] {
            XCTAssert((76...80).contains(Int(channel)),
                      "expected encoded-space multiply ≈78, got \(channel)")
        }
    }

    /// Soft light, W3C/PDF (= Photoshop) formula, Cs > 0.5 → D(Cb) = √Cb
    /// branch: B = Cb + (2·Cs − 1)(√Cb − Cb) with Cb = 100/255 = 0.39216,
    /// Cs = 191/255 = 0.74902 → 0.39216 + 0.49804 × 0.23407 = 0.50874 → 130.
    func testSoftLightMatchesEncodedMath() throws {
        let pixel = try blendedPixel(base: (100, 100, 100), top: (191, 191, 191), mode: .softLight)
        for channel in [pixel.r, pixel.g, pixel.b] {
            XCTAssert((128...132).contains(Int(channel)),
                      "expected encoded-space soft light ≈130, got \(channel)")
        }
    }

    /// Luminosity keeps the base's colour and takes the top's luma; for two
    /// greys that is simply the top grey: SetLum(0.50196, Lum(0.25098)) →
    /// 0.25098 → 64.
    func testLuminosityMatchesEncodedMath() throws {
        let pixel = try blendedPixel(base: (128, 128, 128), top: (64, 64, 64), mode: .luminosity)
        for channel in [pixel.r, pixel.g, pixel.b] {
            XCTAssert((62...66).contains(Int(channel)),
                      "expected encoded-space luminosity ≈64, got \(channel)")
        }
    }

    /// Partial opacity exercises the unpremultiply → encode → premultiply
    /// order inside the gamma sandwich: Photoshop computes
    /// co = (1−α)·Cb + α·(Cb·Cs) on encoded straight-alpha values:
    /// 0.4×0.50196 + 0.6×(0.50196×0.2) = 0.26102 → 66.6. Encoding
    /// premultiplied components instead would land visibly off.
    func testMultiplyAtPartialOpacityMatchesStraightAlphaEncodedMath() throws {
        let pixel = try blendedPixel(base: (128, 128, 128), top: (51, 51, 51),
                                     mode: .multiply, topOpacity: 0.6)
        for channel in [pixel.r, pixel.g, pixel.b] {
            XCTAssert((65...69).contains(Int(channel)),
                      "expected encoded straight-alpha multiply ≈67, got \(channel)")
        }
        XCTAssertEqual(pixel.a, 255)
    }

    // MARK: - Clipping composite semantics

    /// bg (white, full canvas) + base (red 32×32 square at (32,16)) +
    /// clipped layer, on a 96×64 canvas.
    private func clippingDocument(clip: Layer) -> Document {
        var document = Document(canvasSize: CGSize(width: 96, height: 64))
        var base = solidLayer("base", r: 255, g: 0, b: 0)
        base.transform = CGAffineTransform(translationX: 32, y: 16)
        var clipped = clip
        clipped.isClippedToBelow = true
        document.layers = [solidLayer("bg", r: 255, g: 255, b: 255,
                                      width: 96, height: 64),
                           base, clipped]
        return document
    }

    private func flattenedPixels(_ document: Document) throws -> RawImage {
        guard let output = RenderEngine.shared.renderFlattened(
            document: document, profile: p3, sixteenBit: false) else {
            throw TestImageError.contextFailed
        }
        return try rawRGBA8(output)
    }

    /// Canvas y-up point → RawImage (row 0 at top) subscript.
    private func pixel(_ image: RawImage, _ x: Int, _ yUp: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        image[x, image.height - 1 - yUp]
    }

    func testClippedLayerConfinedToBaseAlpha() throws {
        let clip = solidLayer("clip", r: 0, g: 0, b: 255, width: 96, height: 64)
        let pixels = try flattenedPixels(clippingDocument(clip: clip))

        // Inside the base square the full-canvas clipped layer shows.
        let inside = pixel(pixels, 48, 32)
        XCTAssertLessThan(inside.r, 6)
        XCTAssertGreaterThan(inside.b, 249, "clipped content must render over the base")
        // Outside the base square it is clipped away entirely.
        let outside = pixel(pixels, 8, 32)
        XCTAssertGreaterThan(outside.r, 249)
        XCTAssertGreaterThan(outside.b, 249)
        XCTAssertEqual(outside.a, 255)
    }

    /// A Multiply clip darkens its BASE, never the layers beneath the group.
    func testClippedBlendModeAppliesAgainstBaseNotBackdrop() throws {
        var clip = solidLayer("clip", r: 128, g: 128, b: 128, width: 96, height: 64)
        clip.blendMode = .multiply
        var document = clippingDocument(clip: clip)
        // Green background makes any leakage of the multiply obvious.
        document.layers[0] = solidLayer("bg", r: 0, g: 255, b: 0, width: 96, height: 64)
        let pixels = try flattenedPixels(document)

        // Inside: grey × red on encoded values → (128, 0, 0).
        let inside = pixel(pixels, 48, 32)
        XCTAssert((126...130).contains(Int(inside.r)),
                  "expected encoded multiply of grey over red ≈128, got \(inside.r)")
        XCTAssertLessThan(inside.g, 4)
        // Outside: the green background is untouched by the clipped multiply.
        let outside = pixel(pixels, 8, 32)
        XCTAssertLessThan(outside.r, 4)
        XCTAssertGreaterThan(outside.g, 251)
    }

    /// The base's opacity scales the finished group exactly once
    /// (Photoshop's "blend clipped layers as group"): an opaque clip over a
    /// 50%-opacity base reads as the clip's colour at 50% — composited in
    /// linear light because the group lands with the base's normal mode
    /// (50% blue over white → r = g = encode(0.5) ≈ 187, b = 255;).
    func testBaseOpacityAppliesToGroupOnce() throws {
        let clip = solidLayer("clip", r: 0, g: 0, b: 255, width: 96, height: 64)
        var document = clippingDocument(clip: clip)
        document.layers[1].opacity = 0.5
        let pixels = try flattenedPixels(document)

        let inside = pixel(pixels, 48, 32)
        for channel in [inside.r, inside.g] {
            XCTAssert((184...191).contains(Int(channel)),
                      "expected 50% linear-light blend ≈187 — applying base opacity twice would give a different mix, got \(channel)")
        }
        XCTAssertGreaterThan(inside.b, 252)
        XCTAssertEqual(inside.a, 255)
    }

    /// Hiding the base hides its whole clipped group, Photoshop-style.
    func testHiddenBaseHidesClippedGroup() throws {
        let clip = solidLayer("clip", r: 0, g: 0, b: 255, width: 96, height: 64)
        var document = clippingDocument(clip: clip)
        document.layers[1].isVisible = false
        let pixels = try flattenedPixels(document)

        let inside = pixel(pixels, 48, 32)
        XCTAssertGreaterThan(inside.r, 249, "hidden base must hide the clipped layer too")
        XCTAssertGreaterThan(inside.g, 249)
        XCTAssertGreaterThan(inside.b, 249)
    }

    /// A hidden member does not break the clipped run: the layer above it
    /// still clips to the same base.
    func testHiddenClippedMemberSkippedWithoutBreakingRun() throws {
        var hiddenClip = solidLayer("hidden clip", r: 0, g: 255, b: 0, width: 96, height: 64)
        hiddenClip.isVisible = false
        var document = clippingDocument(clip: hiddenClip)
        var topClip = solidLayer("top clip", r: 0, g: 0, b: 255, width: 96, height: 64)
        topClip.isClippedToBelow = true
        document.layers.append(topClip)
        let pixels = try flattenedPixels(document)

        let inside = pixel(pixels, 48, 32)
        XCTAssertGreaterThan(inside.b, 249, "top clip must still clip to the base through a hidden member")
        XCTAssertLessThan(inside.g, 6)
        let outside = pixel(pixels, 8, 32)
        XCTAssertGreaterThan(outside.r, 249)
    }

    /// The base's own mask participates in the alpha the group is confined
    /// to (source alpha × opacity × mask).
    func testBaseMaskConfinesClippedGroup() throws {
        let clip = solidLayer("clip", r: 0, g: 0, b: 255, width: 96, height: 64)
        var document = clippingDocument(clip: clip)
        // Mask hides the left half of the base's 32×32 source.
        var maskData = Data(count: 32 * 32)
        for row in 0..<32 {
            for col in 0..<32 { maskData[row * 32 + col] = col < 16 ? 0 : 255 }
        }
        document.layers[1].mask = Mask(texture: MaskTexture(width: 32, height: 32, data: maskData),
                                       isEnabled: true)
        let pixels = try flattenedPixels(document)

        // Left half of the square: base masked out → clip confined out → bg.
        let maskedOut = pixel(pixels, 36, 32)
        XCTAssertGreaterThan(maskedOut.r, 249)
        XCTAssertGreaterThan(maskedOut.b, 249)
        // Right half: base present → clip shows.
        let shown = pixel(pixels, 56, 32)
        XCTAssertLessThan(shown.r, 6)
        XCTAssertGreaterThan(shown.b, 249)
    }

    /// An (invalid) clipped bottom layer renders unclipped — the renderer's
    /// counterpart of `normalizingClipping()` for hand-built documents.
    func testClippedBottomLayerRendersUnclipped() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        var bottom = solidLayer("bottom", r: 0, g: 0, b: 255)
        bottom.isClippedToBelow = true
        document.layers = [bottom]
        let pixels = try flattenedPixels(document)
        let center = pixel(pixels, 16, 16)
        XCTAssertGreaterThan(center.b, 249, "clipped bottom layer must render as unclipped, not vanish")
        XCTAssertEqual(center.a, 255)
    }

    // MARK: - Model: normalization, base resolution, hit-testing

    func testNormalizationAndPositionalBaseResolution() {
        var document = Document(canvasSize: CGSize(width: 96, height: 64))
        var base = solidLayer("base", r: 255, g: 0, b: 0)
        base.transform = CGAffineTransform(translationX: 32, y: 16)
        var clip = solidLayer("clip", r: 0, g: 0, b: 255, width: 96, height: 64)
        clip.isClippedToBelow = true
        document.layers = [solidLayer("bg", r: 255, g: 255, b: 255, width: 96, height: 64),
                           base, clip]

        // Deleting the base re-resolves the run positionally: the clip keeps
        // its flag and now clips to the background.
        let withoutBase = document.removingLayer(id: base.id)
        XCTAssertEqual(withoutBase.layers.count, 2)
        XCTAssertTrue(withoutBase.layers[1].isClippedToBelow,
                      "clip flag persists across base deletion (positional membership)")
        XCTAssertEqual(withoutBase.clippingBaseIndex(below: 1), 0)

        // Deleting the background too leaves the clip at the bottom —
        // normalized unclipped.
        let clipOnly = withoutBase.removingLayer(id: withoutBase.layers[0].id)
        XCTAssertFalse(clipOnly.layers[0].isClippedToBelow,
                       "a layer that lands at the bottom must be released")

        // Reordering the clipped layer to the bottom (display offsets are
        // topmost-first: move display row 0 below display row 2) releases it.
        let reordered = document.movingLayers(fromDisplayOffsets: IndexSet(integer: 0),
                                              toDisplayOffset: 3)
        XCTAssertEqual(reordered.layers.first?.name, "clip")
        XCTAssertFalse(reordered.layers[0].isClippedToBelow)

        // Direct normalization helper.
        var invalid = document
        invalid.layers[0].isClippedToBelow = true
        XCTAssertFalse(invalid.normalizingClipping().layers[0].isClippedToBelow)

        // Equality and duplication carry the new fields.
        var changed = clip
        changed.blendMode = .multiply
        XCTAssertNotEqual(changed, clip, "blendMode must participate in Layer equality")
        let duplicate = changed.duplicated(name: "copy")
        XCTAssertEqual(duplicate.blendMode, .multiply)
        XCTAssertTrue(duplicate.isClippedToBelow)
    }

    /// Auto-select hit-testing respects clipping: a clipped layer only hits
    /// where its base has content.
    func testTopmostLayerRespectsClipping() {
        let clip = solidLayer("clip", r: 0, g: 0, b: 255, width: 96, height: 64)
        let document = clippingDocument(clip: clip)
        let bgID = document.layers[0].id
        let clipID = document.layers[2].id

        XCTAssertEqual(document.topmostLayer(at: CGPoint(x: 48, y: 32))?.id, clipID,
                       "inside the base, the clipped layer is what the user sees")
        XCTAssertEqual(document.topmostLayer(at: CGPoint(x: 8, y: 32))?.id, bgID,
                       "outside the base, the click falls through the clipped layer")

        var hiddenBase = document
        hiddenBase.layers[1].isVisible = false
        XCTAssertEqual(hiddenBase.topmostLayer(at: CGPoint(x: 48, y: 32))?.id, bgID,
                       "a hidden base hides its clipped group from hit-testing")
    }

    // MARK: - Store: commits, undo names, guards

    private func makeStore(layers: [Layer],
                           canvas: CGSize = CGSize(width: 96, height: 64)) -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: canvas)
        document.layers = layers
        let store = DocumentStore(document: document)
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        return (store, undoManager)
    }

    private func commitGrouped(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    func testSetLayerBlendModeCommitsOnceWithUndoName() {
        let (store, um) = makeStore(layers: [solidLayer("a", r: 10, g: 20, b: 30),
                                             solidLayer("b", r: 40, g: 50, b: 60)])
        let id = store.document.layers[1].id

        commitGrouped(um) { store.setLayerBlendMode(id, .overlay) }
        XCTAssertEqual(store.document[layerID: id]?.blendMode, .overlay)
        XCTAssertEqual(um.undoActionName, "Change Blend Mode")

        // Same value again: no-op, no extra history entry. (Not wrapped in an
        // undo group — an empty group would itself become an undo step.)
        store.setLayerBlendMode(id, .overlay)
        um.undo()
        XCTAssertEqual(store.document[layerID: id]?.blendMode, .normal,
                       "one undo must restore normal — the repeat set may not add history")
    }

    func testToggleClippingMaskCommitsWithPhotoshopNames() {
        let (store, um) = makeStore(layers: [solidLayer("a", r: 10, g: 20, b: 30),
                                             solidLayer("b", r: 40, g: 50, b: 60)])
        let bottomID = store.document.layers[0].id
        let topID = store.document.layers[1].id

        commitGrouped(um) { store.toggleClippingMask(topID) }
        XCTAssertEqual(store.document[layerID: topID]?.isClippedToBelow, true)
        XCTAssertEqual(um.undoActionName, "Create Clipping Mask")

        commitGrouped(um) { store.toggleClippingMask(topID) }
        XCTAssertEqual(store.document[layerID: topID]?.isClippedToBelow, false)
        XCTAssertEqual(um.undoActionName, "Release Clipping Mask")

        um.undo()
        XCTAssertEqual(store.document[layerID: topID]?.isClippedToBelow, true)
        um.undo()
        XCTAssertEqual(store.document[layerID: topID]?.isClippedToBelow, false)
        XCTAssertFalse(um.canUndo, "history exhausted after undoing both toggles")

        // The bottom layer can never be clipped: refused, no history entry.
        store.toggleClippingMask(bottomID)
        XCTAssertEqual(store.document[layerID: bottomID]?.isClippedToBelow, false)
        XCTAssertFalse(um.canUndo, "refused toggle must not create an undo entry")
    }

    /// Merging a clipped layer into its base bakes the confinement and the
    /// merged layer takes the base's (unclipped) place.
    func testMergeDownBakesClippingConfinement() throws {
        var base = solidLayer("base", r: 255, g: 0, b: 0)
        base.transform = CGAffineTransform(translationX: 32, y: 16)
        var clip = solidLayer("clip", r: 0, g: 0, b: 255, width: 96, height: 64)
        clip.isClippedToBelow = true
        let bg = solidLayer("bg", r: 255, g: 255, b: 255, width: 96, height: 64)
        let (store, _) = makeStore(layers: [bg, base, clip])

        store.selectLayer(store.document.layers[2].id)
        store.mergeDownSelectedLayer()
        XCTAssertEqual(store.document.layers.count, 2)
        let merged = store.document.layers[1]
        XCTAssertFalse(merged.isClippedToBelow, "merged layer takes the unclipped base's place")

        let pixels = try flattenedPixels(store.document)
        let inside = pixel(pixels, 48, 32)
        XCTAssertGreaterThan(inside.b, 249, "baked pixels keep the clipped content over the base")
        let outside = pixel(pixels, 8, 32)
        XCTAssertGreaterThan(outside.r, 249, "outside the base the baked layer is transparent → bg shows")
        XCTAssertGreaterThan(outside.g, 249)
    }

    /// Cross-document transfer carries the blend mode but drops the clip
    /// flag (clipping is a relationship with the stack the layer left).
    func testReceiveLayerCarriesBlendModeDropsClipping() {
        var layer = solidLayer("moving", r: 40, g: 50, b: 60)
        layer.blendMode = .colorDodge
        layer.isClippedToBelow = true
        let (target, _) = makeStore(layers: [solidLayer("existing", r: 1, g: 2, b: 3)])

        target.receiveLayer(layer, from: CGSize(width: 96, height: 64))
        let received = target.document.layers.last
        XCTAssertEqual(received?.blendMode, .colorDodge)
        XCTAssertEqual(received?.isClippedToBelow, false)
    }

    // MARK: - Serialization details beyond the round-trip

    /// Default-valued layers must not write the new keys at all, so
    /// pre-blend-mode documents round-trip byte-identically; a hand-edited
    /// file with a clipped bottom layer is normalized on read.
    func testSerializerOmitsDefaultsAndNormalizesBottomClipOnRead() throws {
        var document = Document(canvasSize: CGSize(width: 48, height: 48))
        document.layers = [solidLayer("a", r: 10, g: 20, b: 30),
                           solidLayer("b", r: 40, g: 50, b: 60)]
        let wrapper = try DocumentSerializer().fileWrapper(for: document)
        guard let jsonData = wrapper.fileWrappers?["document.json"]?.regularFileContents,
              let json = String(data: jsonData, encoding: .utf8) else {
            return XCTFail("missing document.json")
        }
        XCTAssertFalse(json.contains("\"blendMode\""),
                       "normal blend mode must be omitted from the JSON")
        XCTAssertFalse(json.contains("\"isClipped\""),
                       "unclipped layers must omit the clipping key")

        // Inject an invalid clipped bottom layer straight into the JSON.
        var dto = try JSONDecoder().decode(DocumentDTO.self, from: jsonData)
        dto.layers[0].isClipped = true
        dto.layers[1].isClipped = true
        dto.layers[1].blendMode = BlendMode.screen.rawValue
        let encoder = JSONEncoder()
        let mutatedJSON = try encoder.encode(dto)
        var children: [String: FileWrapper] = [:]
        for (name, child) in wrapper.fileWrappers ?? [:] where name != "document.json" {
            children[name] = child
        }
        children["document.json"] = FileWrapper(regularFileWithContents: mutatedJSON)
        let restored = try DocumentSerializer()
            .document(from: FileWrapper(directoryWithFileWrappers: children))
        XCTAssertFalse(restored.layers[0].isClippedToBelow,
                       "clipped bottom layer must be normalized on read")
        XCTAssertTrue(restored.layers[1].isClippedToBelow)
        XCTAssertEqual(restored.layers[1].blendMode, .screen)

        // An unknown blend-mode token from a future build degrades to normal.
        dto.layers[1].blendMode = "linearBurnFromTheFuture"
        children["document.json"] = FileWrapper(regularFileWithContents: try encoder.encode(dto))
        let future = try DocumentSerializer()
            .document(from: FileWrapper(directoryWithFileWrappers: children))
        XCTAssertEqual(future.layers[1].blendMode, .normal)
    }
}

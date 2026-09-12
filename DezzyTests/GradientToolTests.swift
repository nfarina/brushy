import CoreGraphics
import Foundation
import XCTest

/// Gradient tool (G) bakes, routed like Edit → Fill. Deliberately windowless
/// (see the note in NewDocumentTests.swift). Mask expectations use the
/// pixel-centre convention: buffer row `r` covers y-up source coordinates
/// [height−r−1, height−r), centred at height−r−0.5 — row 0 is the TOP row
///, which is exactly what these tests pin down.
final class GradientToolTests: XCTestCase {

    private let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

    /// 200×200 imported photo covering a 200×200 canvas — mask bytes align
    /// 1:1 with canvas pixels, so expectations are exact.
    private func makeImportedStore(withMask: Bool = true,
                                   maskFill: UInt8 = 128) -> DocumentStore {
        var document = Document(canvasSize: CGSize(width: 200, height: 200))
        var layer = Layer(name: "photo",
                          source: GeneratedImages.solid(width: 200, height: 200,
                                                        r: 90, g: 140, b: 200,
                                                        colorSpace: DezzyColorSpace.displayP3))
        if withMask {
            layer.mask = Mask(texture: MaskTexture(width: 200, height: 200, fill: maskFill),
                              isEnabled: true)
        }
        document.layers = [layer]
        return DocumentStore(document: document)
    }

    private func makePaintStore() -> DocumentStore {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 200, height: 200)))
        store.addPaintLayer()
        return store
    }

    /// Mask byte at integer source coordinates given as y-UP indices; the
    /// buffer itself stores row 0 at the top, so the row index flips here.
    private func maskByte(_ store: DocumentStore, x: Int, yUp: Int) -> UInt8 {
        let texture = store.document.layers[0].mask!.texture
        return texture.data[(texture.height - 1 - yUp) * texture.width + x]
    }

    // MARK: Mask bakes — bytes at known coordinates, both vector orientations

    func testLinearMaskBakeUpwardDrag() {
        let store = makeImportedStore()
        store.foregroundColor = black
        store.backgroundColor = white
        store.applyGradient(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 100, y: 150))

        // Before the start point: clamped to the start colour's luminance.
        XCTAssertEqual(maskByte(store, x: 20, yUp: 10), 0)
        XCTAssertEqual(maskByte(store, x: 180, yUp: 49), 0)
        // Past the end point: clamped to the end colour.
        XCTAssertEqual(maskByte(store, x: 20, yUp: 190), 255)
        XCTAssertEqual(maskByte(store, x: 180, yUp: 151), 255)
        // Midpoint ramps. (Centre of the yUp=100 row sits at 100.5 → t=0.505.)
        XCTAssertEqual(Double(maskByte(store, x: 100, yUp: 100)), 128, accuracy: 3)
    }

    /// The reversed-orientation drag — with an upward drag this pair is the
    /// canonical catcher for a row-order (y-flip) bug in the mask bake.
    func testLinearMaskBakeDownwardDrag() {
        let store = makeImportedStore()
        store.foregroundColor = black
        store.backgroundColor = white
        store.applyGradient(from: CGPoint(x: 100, y: 150), to: CGPoint(x: 100, y: 50))

        XCTAssertEqual(maskByte(store, x: 100, yUp: 190), 0,
                       "above the start point the mask takes the start colour")
        XCTAssertEqual(maskByte(store, x: 100, yUp: 10), 255,
                       "below the end point the mask takes the end colour")
    }

    func testLinearMaskBakeHorizontalDrag() {
        let store = makeImportedStore()
        store.foregroundColor = black
        store.backgroundColor = white
        store.applyGradient(from: CGPoint(x: 50, y: 100), to: CGPoint(x: 150, y: 100))

        XCTAssertEqual(maskByte(store, x: 10, yUp: 100), 0)
        XCTAssertEqual(maskByte(store, x: 49, yUp: 20), 0)
        XCTAssertEqual(maskByte(store, x: 190, yUp: 100), 255)
        XCTAssertEqual(maskByte(store, x: 151, yUp: 180), 255)
        XCTAssertEqual(Double(maskByte(store, x: 100, yUp: 100)), 128, accuracy: 3)
    }

    func testMaskBakeUsesColourLuminance() {
        let store = makeImportedStore()
        store.foregroundColor = red // Rec. 709 luminance of pure red: 54/255
        store.backgroundColor = white
        store.applyGradient(from: CGPoint(x: 50, y: 100), to: CGPoint(x: 150, y: 100))

        XCTAssertEqual(maskByte(store, x: 10, yUp: 100), 54,
                       "mask gradients use the colours' luminance, not their RGB")
        XCTAssertEqual(maskByte(store, x: 190, yUp: 100), 255)
    }

    func testToTransparentMaskLeavesFarEndUntouched() {
        let store = makeImportedStore(maskFill: 200)
        store.foregroundColor = black
        store.gradientToTransparent = true
        store.applyGradient(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 180, y: 100))

        XCTAssertEqual(maskByte(store, x: 10, yUp: 100), 0,
                       "the opaque end paints the foreground luminance in full")
        XCTAssertEqual(maskByte(store, x: 190, yUp: 100), 200,
                       "the transparent end leaves the existing mask untouched")
        // Halfway, the foreground blends over the existing value by ramp coverage.
        XCTAssertEqual(Double(maskByte(store, x: 100, yUp: 100)), 100, accuracy: 3)
    }

    func testReverseSwapsTheEnds() {
        let store = makeImportedStore()
        store.foregroundColor = black
        store.backgroundColor = white
        store.gradientReversed = true
        store.applyGradient(from: CGPoint(x: 50, y: 100), to: CGPoint(x: 150, y: 100))

        XCTAssertEqual(maskByte(store, x: 10, yUp: 100), 255)
        XCTAssertEqual(maskByte(store, x: 190, yUp: 100), 0)
    }

    func testRadialMaskBake() {
        let store = makeImportedStore()
        store.foregroundColor = black
        store.backgroundColor = white
        store.gradientShape = .radial
        store.applyGradient(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 160, y: 100))

        XCTAssertLessThan(maskByte(store, x: 100, yUp: 100), 5,
                          "the drag start is the centre of the ramp")
        XCTAssertEqual(maskByte(store, x: 5, yUp: 5), 255,
                       "beyond the radius the mask clamps to the end colour")
        XCTAssertEqual(maskByte(store, x: 180, yUp: 100), 255)
        // Half the radius out (30 px of 60) the ramp is halfway.
        XCTAssertEqual(Double(maskByte(store, x: 130, yUp: 100)), 129, accuracy: 4)
        XCTAssertEqual(Double(maskByte(store, x: 100, yUp: 70)), 129, accuracy: 4)
    }

    func testSelectionClipsMaskBake() {
        let store = makeImportedStore(maskFill: 128)
        store.foregroundColor = black
        store.backgroundColor = white
        store.combineSelection(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 200),
                                      transform: nil), mode: .replace)
        store.applyGradient(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 180, y: 100))

        XCTAssertEqual(maskByte(store, x: 10, yUp: 100), 0,
                       "inside the selection the ramp lands")
        XCTAssertEqual(Double(maskByte(store, x: 60, yUp: 100)), 65, accuracy: 3)
        XCTAssertEqual(maskByte(store, x: 150, yUp: 100), 128,
                       "outside the selection the mask is untouched")
        XCTAssertEqual(maskByte(store, x: 190, yUp: 100), 128)
    }

    /// A translated layer: the drag is in canvas space, so the bake must map
    /// it through the layer transform into the mask's source grid.
    func testTransformedLayerMapsDragThroughLayerTransform() {
        var document = Document(canvasSize: CGSize(width: 300, height: 200))
        var layer = Layer(name: "photo",
                          source: GeneratedImages.solid(width: 100, height: 80,
                                                        r: 90, g: 140, b: 200,
                                                        colorSpace: DezzyColorSpace.displayP3),
                          transform: CGAffineTransform(translationX: 100, y: 60))
        layer.mask = Mask(texture: MaskTexture(width: 100, height: 80, fill: 128),
                          isEnabled: true)
        document.layers = [layer]
        let store = DocumentStore(document: document)
        store.foregroundColor = black
        store.backgroundColor = white
        store.applyGradient(from: CGPoint(x: 120, y: 100), to: CGPoint(x: 180, y: 100))

        // Source column c sits at canvas x = c + 100(.5).
        XCTAssertEqual(maskByte(store, x: 10, yUp: 40), 0)   // canvas 110.5 ≤ 120
        XCTAssertEqual(maskByte(store, x: 90, yUp: 40), 255) // canvas 190.5 ≥ 180
        XCTAssertEqual(Double(maskByte(store, x: 40, yUp: 40)), 87, accuracy: 3)
    }

    // MARK: History semantics

    func testGradientIsOneUndoStep() {
        let store = makeImportedStore()
        store.foregroundColor = black
        store.backgroundColor = white
        let before = store.document
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 100
        store.undoManager = undoManager

        undoManager.beginUndoGrouping()
        store.applyGradient(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 100, y: 150))
        undoManager.endUndoGrouping()

        XCTAssertEqual(undoManager.undoActionName, "Gradient")
        XCTAssertNotEqual(store.document, before)
        undoManager.undo()
        XCTAssertEqual(store.document, before,
                       "a single undo reverts the whole drag")
        XCTAssertFalse(undoManager.canUndo, "exactly one history entry per drag")
    }

    func testZeroLengthDragIsANoOpWithNoHistory() {
        let store = makeImportedStore()
        let before = store.document
        store.applyGradient(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(store.document, before)
        XCTAssertFalse(store.canUndo, "zero-length drags leave no history entry")
    }

    func testGradientOnImportedLayerWithoutMaskAsksToRasterize() throws {
        let store = makeImportedStore(withMask: false)
        let original = store.document.layers[0]
        store.applyGradient(from: CGPoint(x: 50, y: 100), to: CGPoint(x: 150, y: 100))

        XCTAssertNotNil(store.rasterizePrompt, "the gradient asks before touching a photo")
        XCTAssertFalse(store.canUndo, "and nothing lands until it is answered")
        let after = store.document.layers[0]
        XCTAssertTrue(after.source === original.source,
                      "imported pixels are never replaced")
        XCTAssertEqual(after.sourceID, original.sourceID)
        XCTAssertNil(after.mask, "the gradient never invents a mask to write into")
        XCTAssertEqual(try rawRGBA8(after.source).rgba, try rawRGBA8(original.source).rgba,
                       "the source stays byte-identical")
    }

    // MARK: Pixel bakes (paint layers)

    func testPixelsBakeGetsFreshSourceIDAndClampsToEndColours() throws {
        let store = makePaintStore()
        let originalID = store.document.layers[0].sourceID
        store.foregroundColor = red
        store.backgroundColor = blue
        store.applyGradient(from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))

        let layer = store.document.layers[0]
        XCTAssertNotEqual(layer.sourceID, originalID,
                          "new pixels get a fresh sourceID")
        let pixels = try rawRGBA8(layer.source, in: DezzyColorSpace.sRGB)
        // The clamped regions take the end colours across the whole layer.
        XCTAssertGreaterThan(pixels[10, 100].r, 245)
        XCTAssertLessThan(pixels[10, 100].b, 15)
        XCTAssertEqual(pixels[10, 100].a, 255)
        XCTAssertGreaterThan(pixels[190, 100].b, 245)
        XCTAssertLessThan(pixels[190, 100].r, 15)
        XCTAssertEqual(pixels[190, 100].a, 255)
    }

    func testPixelsToTransparentRampsAlpha() throws {
        let store = makePaintStore()
        store.foregroundColor = red
        store.gradientToTransparent = true
        store.applyGradient(from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))

        let pixels = try rawRGBA8(store.document.layers[0].source,
                                  in: DezzyColorSpace.sRGB)
        XCTAssertEqual(pixels[10, 100].a, 255)
        XCTAssertGreaterThan(pixels[10, 100].r, 245)
        XCTAssertLessThan(pixels[190, 100].a, 5,
                          "the far end fades out to fully transparent")
        let midAlpha = Int(pixels[100, 100].a)
        XCTAssertTrue((110...145).contains(midAlpha),
                      "halfway along the drag the alpha ramp is near 50% (got \(midAlpha))")
    }

    func testSelectionClipsPixelsBake() throws {
        let store = makePaintStore()
        store.foregroundColor = red
        store.backgroundColor = blue
        store.combineSelection(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 200),
                                      transform: nil), mode: .replace)
        store.applyGradient(from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))

        let pixels = try rawRGBA8(store.document.layers[0].source,
                                  in: DezzyColorSpace.sRGB)
        XCTAssertEqual(pixels[50, 100].a, 255, "inside the selection the gradient lands")
        XCTAssertGreaterThan(pixels[50, 100].r, 200)
        XCTAssertEqual(pixels[150, 100].a, 0,
                       "outside the selection the paint layer stays transparent")
    }

    func testRadialPixelsBake() throws {
        let store = makePaintStore()
        store.foregroundColor = red
        store.backgroundColor = blue
        store.gradientShape = .radial
        store.applyGradient(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 160))

        let pixels = try rawRGBA8(store.document.layers[0].source,
                                  in: DezzyColorSpace.sRGB)
        XCTAssertGreaterThan(pixels[100, 100].r, 240, "the centre takes the start colour")
        XCTAssertLessThan(pixels[100, 100].b, 20)
        XCTAssertGreaterThan(pixels[5, 5].b, 245, "beyond the radius clamps to the end colour")
        XCTAssertLessThan(pixels[5, 5].r, 15)
        XCTAssertEqual(pixels[5, 5].a, 255)
    }
}

import CoreGraphics
import Foundation
import XCTest

final class BrushTests: XCTestCase {
    private func makeStroke(radius: CGFloat, hardness: Double, opacity: Double = 1,
                            eraser: Bool = false, maskValue: UInt8 = 255,
                            size: Int = 200) -> BrushStroke {
        BrushStroke(target: .mask(layerID: UUID()),
                    isEraser: eraser,
                    color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                    maskValue: maskValue,
                    opacityCeiling: opacity,
                    radius: radius,
                    hardness: hardness,
                    targetWidth: size, targetHeight: size)
    }

    /// coverage sample in buffer coordinates (row 0 = top). Local y-up point
    /// (x, y) lands at row (height − y).
    private func sample(_ stroke: BrushStroke, x: Int, yUp: Int, size: Int = 200) -> UInt8 {
        stroke.coverage[(size - yUp) * size + x]
    }

    ///: stamps interpolate between mouse events — a fast stroke is a solid
    /// line, not dots. (The most common way a brush feels wrong.)
    func testFastStrokeIsContinuous() {
        var stroke = makeStroke(radius: 10, hardness: 0.8)
        stroke.extend(toLocal: CGPoint(x: 20, y: 100))
        stroke.extend(toLocal: CGPoint(x: 180, y: 100)) // one giant event gap
        for x in stride(from: 30, through: 170, by: 5) {
            XCTAssertGreaterThanOrEqual(sample(stroke, x: x, yUp: 100), 250,
                                        "gap at x=\(x) — stamps are not interpolated")
        }
        // Perpendicular falloff still exists (it's a line, not a smear).
        XCTAssertEqual(sample(stroke, x: 100, yUp: 130), 0)
        XCTAssertEqual(sample(stroke, x: 100, yUp: 70), 0)
    }

    /// Hardness 100% = 1px antialiased edge, not a soft blob.
    func testFullHardnessHasTightEdge() {
        var stroke = makeStroke(radius: 10, hardness: 1)
        stroke.extend(toLocal: CGPoint(x: 100, y: 100))
        XCTAssertGreaterThanOrEqual(sample(stroke, x: 100, yUp: 100), 254)
        XCTAssertGreaterThanOrEqual(sample(stroke, x: 108, yUp: 100), 250,
                                    "inside the core must be solid")
        XCTAssertEqual(sample(stroke, x: 111, yUp: 100), 0,
                       "outside the radius must be empty")
    }

    /// Hardness 0% = smooth, monotonically decaying (roughly Gaussian) falloff.
    func testZeroHardnessFallsOffSmoothly() {
        var stroke = makeStroke(radius: 20, hardness: 0)
        stroke.extend(toLocal: CGPoint(x: 100, y: 100))
        var previous = Int(sample(stroke, x: 100, yUp: 100))
        XCTAssertGreaterThanOrEqual(previous, 250)
        var midValue = 0
        for dx in 1...21 {
            let value = Int(sample(stroke, x: 100 + dx, yUp: 100))
            XCTAssertLessThanOrEqual(value, previous + 1, "falloff must be monotonic")
            if dx == 10 { midValue = value }
            previous = value
        }
        XCTAssertEqual(sample(stroke, x: 121, yUp: 100), 0)
        XCTAssert((100...200).contains(midValue),
                  "half-radius value \(midValue) should sit mid-falloff (Gaussian-ish)")
    }

    /// flow: a 50%-opacity stroke crossing itself clamps at 50%; a second
    /// stroke over the same area compounds.
    func testOpacityCeilingWithinStrokeAndCompoundingAcrossStrokes() {
        let base = MaskTexture(width: 200, height: 200, fill: 0)

        var crossing = makeStroke(radius: 12, hardness: 0.9, opacity: 0.5)
        crossing.extend(toLocal: CGPoint(x: 40, y: 100))
        crossing.extend(toLocal: CGPoint(x: 160, y: 100))
        crossing.extend(toLocal: CGPoint(x: 100, y: 40))
        crossing.extend(toLocal: CGPoint(x: 100, y: 160)) // crosses the first pass
        let once = RenderEngine.shared.bakeMaskStroke(into: base,
                                                      stroke: crossing.preview()!)
        let center = once.data[100 * 200 + 100]
        XCTAssert((120...132).contains(Int(center)),
                  "self-crossing 50% stroke must clamp at ~128, got \(center)")

        var second = makeStroke(radius: 12, hardness: 0.9, opacity: 0.5)
        second.extend(toLocal: CGPoint(x: 40, y: 100))
        second.extend(toLocal: CGPoint(x: 160, y: 100))
        let twice = RenderEngine.shared.bakeMaskStroke(into: once,
                                                       stroke: second.preview()!)
        let compounded = twice.data[100 * 200 + 100]
        XCTAssert((185...197).contains(Int(compounded)),
                  "a second 50% stroke should compound to ~191, got \(compounded)")
    }

    func testPaintAndEraseOnPaintLayer() throws {
        var store = makePaintStore()
        store.foregroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        store.brushSize = 40
        store.brushHardness = 100
        store.brushOpacity = 100

        store.activeTool = .brush
        store.beginBrushStroke(at: CGPoint(x: 100, y: 100), eraser: false)
        store.continueBrushStroke(to: CGPoint(x: 140, y: 100))
        store.endBrushStroke()

        // The paint layer stores Display P3; sample in sRGB to compare against
        // the sRGB brush colour.
        var pixels = try rawRGBA8(store.document.layers[0].source, in: BrushyColorSpace.sRGB)
        var center = pixels[120, 200 - 100]
        XCTAssertGreaterThan(center.a, 250, "brush must paint opaque colour")
        XCTAssertGreaterThan(center.r, 248)
        XCTAssertLessThan(center.g, 8)
        XCTAssertEqual(pixels[20, 20].a, 0, "far pixels stay transparent")

        store.activeTool = .eraser
        store.beginBrushStroke(at: CGPoint(x: 100, y: 100), eraser: true)
        store.continueBrushStroke(to: CGPoint(x: 140, y: 100))
        store.endBrushStroke()

        pixels = try rawRGBA8(store.document.layers[0].source, in: BrushyColorSpace.sRGB)
        center = pixels[120, 200 - 100]
        XCTAssertLessThan(center.a, 4, "eraser must clear paint-layer alpha")
    }

    func testEraserOnImportedLayerRasterizesItRatherThanMasking() throws {
        let store = makeImportedStore()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        XCTAssertNil(store.document.layers[0].mask)

        undoManager.beginUndoGrouping()
        store.activeTool = .eraser
        store.beginBrushStroke(at: CGPoint(x: 100, y: 100), eraser: true)
        store.continueBrushStroke(to: CGPoint(x: 130, y: 100))
        store.endBrushStroke()
        undoManager.endUndoGrouping()

        let layer = store.document.layers[0]
        XCTAssertTrue(layer.isPaintable, "the erase rasterized the photo")
        XCTAssertNil(layer.mask, "and invented no mask behind the user's back")
        XCTAssertNotNil(store.toast, "a toast says what happened")
        let pixels = try rawRGBA8(layer.source, in: BrushyColorSpace.sRGB)
        XCTAssertLessThan(pixels[115, 200 - 100].a, 10, "the pixels really went")

        // The rasterize and the stroke are separate entries; this gesture put
        // both in one group, so one undo takes the photo back.
        undoManager.undo()
        XCTAssertFalse(store.document.layers[0].isPaintable, "back to the untouched photo")
        XCTAssertNil(store.document.layers[0].mask)
    }

    func testBrushOnImportedLayerRasterizesItAndPaints() {
        let store = makeImportedStore()
        store.activeTool = .brush
        store.beginBrushStroke(at: CGPoint(x: 100, y: 100), eraser: false)
        XCTAssertNotNil(store.strokePreview, "the stroke lands on this very click")
        XCTAssertTrue(store.document.layers[0].isPaintable)
        XCTAssertNotNil(store.toast,
                        "painting a photo rasterizes it and says so, without a dialog")
        store.endBrushStroke()
        XCTAssertFalse((store.undoManager?.canUndo) ?? false)
    }

    func testMaskPaintingUsesForegroundLuminanceAndIsOneUndoStep() {
        let store = makeImportedStore(withMask: true)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        store.maskTargeted = true
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        store.brushOpacity = 100
        store.brushHardness = 100
        store.brushSize = 30

        undoManager.beginUndoGrouping()
        store.activeTool = .brush
        store.beginBrushStroke(at: CGPoint(x: 100, y: 100), eraser: false)
        store.continueBrushStroke(to: CGPoint(x: 120, y: 100))
        store.endBrushStroke()
        undoManager.endUndoGrouping()

        let texture = store.document.layers[0].mask!.texture
        XCTAssertLessThan(texture.data[(200 - 100) * 200 + 110], 6,
                          "black foreground paints the mask toward hidden")
        XCTAssertEqual(undoManager.undoActionName, "Brush Stroke")
        undoManager.undo()
        XCTAssertEqual(store.document.layers[0].mask!.texture.data[(200 - 100) * 200 + 110], 255)
    }

    /// A blank layer must be creatable in a completely empty document (the
    /// draw-from-scratch flow), canvas-sized and transparent.
    func testAddBlankLayerToEmptyDocument() throws {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 800, height: 600)))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager

        undoManager.beginUndoGrouping()
        store.addPaintLayer()
        undoManager.endUndoGrouping()

        XCTAssertEqual(store.document.layers.count, 1)
        let layer = store.document.layers[0]
        XCTAssertTrue(layer.isPaintable)
        XCTAssertEqual(layer.source.width, 800)
        XCTAssertEqual(layer.source.height, 600)
        XCTAssertEqual(store.selectedLayerID, layer.id)
        XCTAssertEqual(undoManager.undoActionName, "New Layer")
        let pixels = try rawRGBA8(layer.source)
        XCTAssertEqual(pixels[400, 300].a, 0, "blank layer must be transparent")

        // And a second one stacks above the first.
        undoManager.beginUndoGrouping()
        store.addPaintLayer()
        undoManager.endUndoGrouping()
        XCTAssertEqual(store.document.layers.count, 2)
        XCTAssertEqual(store.document.layers[1].name, "Layer 2")
    }

    // MARK: - Fixtures

    private func makePaintStore() -> DocumentStore {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 200, height: 200)))
        store.addPaintLayer()
        return store
    }

    private func makeImportedStore(withMask: Bool = false) -> DocumentStore {
        var document = Document(canvasSize: CGSize(width: 200, height: 200))
        var layer = Layer(name: "photo",
                          source: GeneratedImages.solid(width: 200, height: 200,
                                                        r: 90, g: 140, b: 200,
                                                        colorSpace: BrushyColorSpace.displayP3))
        if withMask {
            layer.mask = Mask(texture: MaskTexture(width: 200, height: 200, fill: 255),
                              isEnabled: true)
        }
        document.layers = [layer]
        return DocumentStore(document: document)
    }
}

import AppKit
import CoreGraphics
import XCTest

/// Photoshop's Quick Mask: the selection painted as a channel instead of drawn
/// as an outline. Entering stashes the selection in the channel, painting edits
/// it (and undoes like any other edit), and leaving traces it back into a
/// selection — keeping the soft edges a path could not describe.
final class QuickMaskTests: XCTestCase {
    private let canvas = CGSize(width: 40, height: 30)

    private func makeStore() -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: canvas)
        document.layers = [Layer(name: "Paint",
                                 source: GeneratedImages.solid(width: 40, height: 30,
                                                               r: 255, g: 255, b: 255,
                                                               colorSpace: BrushyColorSpace.sRGB),
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

    private func group(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping(); body(); um.endUndoGrouping()
    }

    /// Channel value under a canvas-space point (buffer row 0 is the top).
    private func maskValue(_ texture: MaskTexture, at point: CGPoint) -> Int {
        let col = Int(point.x)
        let row = texture.height - 1 - Int(point.y)
        return Int(texture.data[row * texture.width + col])
    }

    // MARK: - Entering and leaving

    func testEnteringWithNoSelectionStartsFullySelected() throws {
        let (store, um) = makeStore()
        group(um) { store.enterQuickMask() }

        let texture = try XCTUnwrap(store.quickMask)
        XCTAssertTrue(store.quickMaskActive)
        XCTAssertEqual(Set(texture.data), [255],
                       "no selection means everything is selected, so no red anywhere")
        XCTAssertTrue(store.selection.isEmpty, "the selection lives in the channel now")
    }

    func testEnteringWithASelectionMasksEverythingElse() throws {
        let (store, um) = makeStore()
        group(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 10, y: 10, width: 20, height: 10),
                                          transform: nil), mode: .replace)
        }
        group(um) { store.enterQuickMask() }

        let texture = try XCTUnwrap(store.quickMask)
        XCTAssertEqual(maskValue(texture, at: CGPoint(x: 15, y: 15)), 255, "inside stays selected")
        XCTAssertEqual(maskValue(texture, at: CGPoint(x: 35, y: 25)), 0, "outside is masked")
    }

    func testLeavingTracesTheChannelBackIntoASelection() throws {
        let (store, um) = makeStore()
        group(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 10, y: 10, width: 20, height: 10),
                                          transform: nil), mode: .replace)
        }
        group(um) { store.enterQuickMask() }
        group(um) { store.exitQuickMask() }

        XCTAssertFalse(store.quickMaskActive)
        XCTAssertEqual(try XCTUnwrap(store.selection.path?.boundingBoxOfPath),
                       CGRect(x: 10, y: 10, width: 20, height: 10),
                       "an untouched round trip gives the same rectangle back")
        XCTAssertFalse(store.selection.hasAlpha, "and no channel, because nothing is partial")
    }

    // MARK: - Painting it

    func testPaintingBlackDeselectsThatAreaAndUndoes() throws {
        let (store, um) = makeStore()
        group(um) { store.selectAll() }
        group(um) { store.enterQuickMask() }
        let sourceBefore = store.document.layers[0].sourceID

        store.brushSize = 8
        store.brushHardness = 100
        store.brushOpacity = 100
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        group(um) {
            store.beginBrushStroke(at: CGPoint(x: 20, y: 15), eraser: false)
            store.endBrushStroke()
        }

        let painted = try XCTUnwrap(store.quickMask)
        XCTAssertEqual(maskValue(painted, at: CGPoint(x: 20, y: 15)), 0, "black masks")
        XCTAssertEqual(maskValue(painted, at: CGPoint(x: 2, y: 2)), 255, "away from the brush")
        XCTAssertEqual(store.document.layers[0].sourceID, sourceBefore,
                       "painting the mask never touches the layer")

        um.undo()
        XCTAssertEqual(maskValue(try XCTUnwrap(store.quickMask), at: CGPoint(x: 20, y: 15)), 255,
                       "a Quick Mask stroke is an ordinary undo step")

        um.redo()
        group(um) { store.exitQuickMask() }
        // The hole the brush made is outside the resulting selection.
        let path = try XCTUnwrap(store.selection.path)
        XCTAssertFalse(path.contains(CGPoint(x: 20, y: 15), using: .winding),
                       "what was painted black is not selected")
        XCTAssertTrue(path.contains(CGPoint(x: 2, y: 2), using: .winding))
    }

    func testPaintingLeavesTheDocumentAlone() {
        let (store, um) = makeStore()
        let before = store.document
        group(um) { store.enterQuickMask() }
        store.brushSize = 8
        group(um) {
            store.beginBrushStroke(at: CGPoint(x: 20, y: 15), eraser: false)
            store.continueBrushStroke(to: CGPoint(x: 25, y: 15))
            store.endBrushStroke()
        }
        XCTAssertEqual(store.document, before, "the canvas is the channel, not the pixels")
    }

    func testAGradientAcrossTheChannelMakesASoftSelection() throws {
        let (store, um) = makeStore()
        group(um) { store.enterQuickMask() }
        store.foregroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        store.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

        group(um) { store.applyGradient(from: CGPoint(x: 0, y: 15), to: CGPoint(x: 40, y: 15)) }
        let ramped = try XCTUnwrap(store.quickMask)
        XCTAssertGreaterThan(maskValue(ramped, at: CGPoint(x: 2, y: 15)),
                             maskValue(ramped, at: CGPoint(x: 37, y: 15)),
                             "white at the start of the drag, black at the end")

        group(um) { store.exitQuickMask() }
        XCTAssertTrue(store.selection.hasAlpha,
                      "the fade survives as the selection's coverage — the reason for all this")
    }

    func testFillingTheChannelWithBlackEmptiesTheSelection() throws {
        let (store, um) = makeStore()
        group(um) { store.enterQuickMask() }
        group(um) { store.fillSelection(using: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)) }
        XCTAssertEqual(Set(try XCTUnwrap(store.quickMask).data), [0])

        group(um) { store.exitQuickMask() }
        XCTAssertTrue(store.selection.isEmpty, "nothing masked in means nothing selected")
    }

    // MARK: - Staying out of the way

    /// A selection made inside Quick Mask is a stencil for painting the
    /// channel, exactly as it is for painting a layer.
    func testASelectionInsideQuickMaskLimitsWhereTheBrushLands() throws {
        let (store, um) = makeStore()
        group(um) { store.enterQuickMask() }
        group(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 0, y: 0, width: 20, height: 30),
                                          transform: nil), mode: .replace)
        }
        XCTAssertFalse(store.selection.isEmpty, "selecting still works with the mask up")

        store.brushSize = 40
        store.brushHardness = 100
        store.brushOpacity = 100
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        group(um) {
            store.beginBrushStroke(at: CGPoint(x: 10, y: 15), eraser: false)
            store.continueBrushStroke(to: CGPoint(x: 34, y: 15))
            store.endBrushStroke()
        }

        let texture = try XCTUnwrap(store.quickMask)
        XCTAssertEqual(maskValue(texture, at: CGPoint(x: 8, y: 15)), 0, "masked inside the selection")
        XCTAssertEqual(maskValue(texture, at: CGPoint(x: 30, y: 15)), 255,
                       "and untouched outside it")
    }

    func testFillingInsideQuickMaskRespectsTheSelection() throws {
        let (store, um) = makeStore()
        group(um) { store.enterQuickMask() }
        group(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 0, y: 0, width: 20, height: 30),
                                          transform: nil), mode: .replace)
        }
        group(um) { store.fillSelection(using: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)) }

        let texture = try XCTUnwrap(store.quickMask)
        XCTAssertEqual(maskValue(texture, at: CGPoint(x: 5, y: 15)), 0)
        XCTAssertEqual(maskValue(texture, at: CGPoint(x: 35, y: 15)), 255)
    }

    /// The commands that would take pixels out of the document or resize the
    /// canvas under a canvas-sized channel stay out of the way, with a hint.
    func testPixelCommandsAreInertWhileTheMaskIsUp() {
        let (store, um) = makeStore()
        group(um) { store.enterQuickMask() }
        group(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 10, y: 10, width: 10, height: 10),
                                          transform: nil), mode: .replace)
        }
        let entries = store.historyEntries.count
        let layers = store.document.layers.count

        store.layerViaCopy()
        store.cropToSelection()
        XCTAssertNil(store.beginSelectionFloat(), "and Move lifts nothing out from under it")

        XCTAssertEqual(store.document.layers.count, layers)
        XCTAssertEqual(store.document.canvasSize, canvas)
        XCTAssertEqual(store.historyEntries.count, entries, "and no history churn either")
        XCTAssertNotNil(store.brushHint, "with a hint saying why")
    }

    func testInverseInvertsTheChannelWhenNothingIsSelected() throws {
        let (store, um) = makeStore()
        group(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 10, y: 10, width: 20, height: 10),
                                          transform: nil), mode: .replace)
        }
        group(um) { store.enterQuickMask() }
        group(um) { store.invertSelection() }

        let texture = try XCTUnwrap(store.quickMask)
        XCTAssertEqual(maskValue(texture, at: CGPoint(x: 15, y: 15)), 0)
        XCTAssertEqual(maskValue(texture, at: CGPoint(x: 35, y: 25)), 255)
    }


    // MARK: - The rubylith

    /// The red overlay is composited with the canvas (GPU), not painted over it
    /// by the overlay view — so it is checked where it lands: in the displayed
    /// image. Polarity is the thing to pin: red where the channel does NOT
    /// select, nothing where it does.
    func testTheChannelShowsAsRedWhereItDoesNotSelect() {
        var document = Document(canvasSize: CGSize(width: 4, height: 1))
        document.layers = [Layer(name: "White",
                                 source: GeneratedImages.solid(width: 4, height: 1,
                                                               r: 255, g: 255, b: 255,
                                                               colorSpace: BrushyColorSpace.sRGB),
                                 isPaintable: true)]
        var channel = MaskTexture(width: 4, height: 1, fill: 255)
        channel.mutate { data in data[3] = 0 } // the last pixel is masked

        let bounds = CGRect(x: 0, y: 0, width: 4, height: 1)
        let image = RenderEngine.shared.displayImage(for: document,
                                                     viewTransform: .identity,
                                                     viewPixelBounds: bounds,
                                                     contentScale: 1,
                                                     quickMask: channel)
        let selected = pixel(image, bounds: bounds, x: 0)
        let masked = pixel(image, bounds: bounds, x: 3)

        XCTAssertEqual(Int(selected.g), 255, "a selected pixel is left alone")
        XCTAssertEqual(Int(selected.b), 255)
        XCTAssertEqual(Int(masked.r), 255, "a masked one goes red")
        XCTAssertLessThan(Int(masked.g), 230, "and loses green and blue to it")
        XCTAssertLessThan(Int(masked.b), 230)
    }

    private func pixel(_ image: CIImage, bounds: CGRect, x: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let cg = RenderEngine.shared.context.createCGImage(image, from: bounds, format: .RGBA8,
                                                           colorSpace: BrushyColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                            bytesPerRow: cg.width * 4, space: BrushyColorSpace.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (data[x * 4], data[x * 4 + 1], data[x * 4 + 2])
    }
}

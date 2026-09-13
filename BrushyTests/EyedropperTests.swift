import XCTest
import AppKit
import CoreGraphics

/// — eyedropper sampling. The sampler reads the *composite* (opacity,
/// masks and blending included), converts to sRGB on the way out (: the
/// colour wells hold sRGB), and never touches undo history.
final class EyedropperTests: XCTestCase {

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> CGImage {
        try ImageImporter.importImage(at: TestPaths.inputsDir.appendingPathComponent(name))
    }

    /// A P3-byte colour converted the way the colour wells display it.
    private func srgbOfP3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> [CGFloat] {
        let p3 = CGColor(colorSpace: BrushyColorSpace.displayP3,
                         components: [r / 255, g / 255, b / 255, 1])!
        let srgb = p3.converted(to: BrushyColorSpace.sRGB,
                                intent: .defaultIntent, options: nil)!
        return srgb.components!.map { min(max($0, 0), 1) }
    }

    private func srgbComponents(_ color: CGColor) -> [CGFloat] {
        color.converted(to: BrushyColorSpace.sRGB,
                        intent: .defaultIntent, options: nil)!.components!
    }

    private func assertColor(_ color: CGColor?, matches expected: [CGFloat],
                             accuracy: CGFloat = 1.0 / 255, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let color else {
            return XCTFail("sample returned nil — \(message)", file: file, line: line)
        }
        let got = srgbComponents(color)
        for i in 0..<3 {
            XCTAssertEqual(got[i], expected[i], accuracy: accuracy,
                           "channel \(i) \(message)", file: file, line: line)
        }
        XCTAssertEqual(got[3], 1, "eyedropper colours are opaque \(message)",
                       file: file, line: line)
    }

    // MARK: - Pure geometry (pattern: separate from the controller/engine)

    func testSampleBoxGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)

        XCTAssertEqual(RenderEngine.sampleBox(around: CGPoint(x: 50.7, y: 40.2),
                                              size: 1, in: bounds),
                       CGRect(x: 50, y: 40, width: 1, height: 1),
                       "point sample = the pixel containing the point")
        XCTAssertEqual(RenderEngine.sampleBox(around: CGPoint(x: 50.7, y: 40.2),
                                              size: 5, in: bounds),
                       CGRect(x: 48, y: 38, width: 5, height: 5),
                       "5×5 box centred on the pixel containing the point")
        XCTAssertEqual(RenderEngine.sampleBox(around: CGPoint(x: 0.5, y: 0.5),
                                              size: 5, in: bounds),
                       CGRect(x: 0, y: 0, width: 3, height: 3),
                       "box straddling the canvas edge keeps only the in-canvas portion")
        XCTAssertNil(RenderEngine.sampleBox(around: CGPoint(x: -0.5, y: 40),
                                            size: 3, in: bounds),
                     "point outside the canvas samples nothing")
        XCTAssertNil(RenderEngine.sampleBox(around: CGPoint(x: 50, y: 80),
                                            size: 3, in: bounds),
                     "the top edge is outside (pixels span [0, height))")
    }

    // MARK: - Engine sampling

    /// Task test 1: sample a known-colour fixture; sRGB components within 1/255.
    func testSamplesRedFixtureInSRGB() throws {
        var document = Document(canvasSize: CGSize(width: 128, height: 96))
        document.layers = [Layer(name: "red", source: try fixture("red-128x96-p3.png"))]

        let sampled = RenderEngine.shared.sampleColor(document: document,
                                                      at: CGPoint(x: 64.5, y: 48.5), size: 1)
        assertColor(sampled, matches: srgbOfP3(255, 0, 0), "P3 red fixture")

        // The same through the store API the tool uses.
        let store = DocumentStore(document: document)
        store.eyedropperSampleSize = 1
        assertColor(store.sampleColor(at: CGPoint(x: 10, y: 10)),
                    matches: srgbOfP3(255, 0, 0), "store.sampleColor")
    }

    /// P3-wide colours round-trip to the same value the colour well shows —
    /// and the fixture is in-gamut-distinct, so this fails if the P3→sRGB
    /// conversion is skipped (P3 red alone would clip to a degenerate match).
    func testP3WideColourMatchesWellConversion() throws {
        var document = Document(canvasSize: CGSize(width: 200, height: 120))
        document.layers = [Layer(name: "blue", source: try fixture("blue-200x120-p3.png"))]

        let expected = srgbOfP3(40, 90, 235)
        let naive: [CGFloat] = [40.0 / 255, 90.0 / 255, 235.0 / 255]
        let maxShift = (0..<3).map { abs(expected[$0] - naive[$0]) }.max() ?? 0
        XCTAssertGreaterThan(maxShift, 2.0 / 255,
                             "fixture must convert non-trivially for this test to mean anything")

        let sampled = RenderEngine.shared.sampleColor(document: document,
                                                      at: CGPoint(x: 100, y: 60), size: 3)
        assertColor(sampled, matches: expected, "P3 (40, 90, 235) fixture")
    }

    /// Task test 2: a 5×5 box across the boundary of two fixtures averages them.
    func testFiveByFiveAverageAcrossFixtureBoundary() throws {
        // White 320×240 base; blue 200×120 on top with its left edge at x=100.
        var document = Document(canvasSize: CGSize(width: 320, height: 240))
        document.layers = [
            Layer(name: "white", source: try fixture("white-320x240-p3.png")),
            Layer(name: "blue", source: try fixture("blue-200x120-p3.png"),
                  transform: CGAffineTransform(translationX: 100, y: 60)),
        ]

        // Box columns 98–102: two white, three blue. Expected = the average of
        // the byte-quantised per-pixel sRGB values, which is what an 8-bit
        // readback averages.
        let quantise: ([CGFloat]) -> [CGFloat] = { $0.map { ($0 * 255).rounded() / 255 } }
        let white = quantise(srgbOfP3(255, 255, 255))
        let blue = quantise(srgbOfP3(40, 90, 235))
        let expected = (0..<4).map { (2 * white[$0] + 3 * blue[$0]) / 5 }

        let sampled = RenderEngine.shared.sampleColor(document: document,
                                                      at: CGPoint(x: 100.4, y: 120.4), size: 5)
        assertColor(sampled, matches: expected, "2:3 white/blue boundary average")
    }

    /// Edge cases: outside the canvas, an empty document, and a fully
    /// transparent region all sample nothing (and must not crash).
    func testOutsideEmptyAndTransparentReturnNil() throws {
        let empty = Document(canvasSize: CGSize(width: 100, height: 80))
        XCTAssertNil(RenderEngine.shared.sampleColor(document: empty,
                                                     at: CGPoint(x: 50, y: 40), size: 3),
                     "empty document")

        var document = Document(canvasSize: CGSize(width: 100, height: 80))
        document.layers = [Layer(name: "left-half",
                                 source: GeneratedImages.solid(width: 50, height: 80,
                                                               r: 0, g: 150, b: 150,
                                                               colorSpace: BrushyColorSpace.displayP3))]
        XCTAssertNil(RenderEngine.shared.sampleColor(document: document,
                                                     at: CGPoint(x: -1, y: 40), size: 1),
                     "outside the canvas")
        XCTAssertNil(RenderEngine.shared.sampleColor(document: document,
                                                     at: CGPoint(x: 90, y: 40), size: 3),
                     "inside the canvas but fully transparent")
        XCTAssertNotNil(RenderEngine.shared.sampleColor(document: document,
                                                        at: CGPoint(x: 25, y: 40), size: 3),
                        "covered region still samples")
    }

    /// A box clipped by the canvas edge averages only the in-canvas portion —
    /// content beyond the canvas frame (which the composite crops away) must
    /// not leak in, and partial boxes must not be diluted by uncovered pixels.
    func testEdgeClippedBoxAveragesOnlyInCanvasPortion() throws {
        var document = Document(canvasSize: CGSize(width: 100, height: 80))
        let teal = GeneratedImages.solid(width: 100, height: 80, r: 0, g: 150, b: 150,
                                         colorSpace: BrushyColorSpace.displayP3)
        let orange = GeneratedImages.solid(width: 80, height: 80, r: 255, g: 140, b: 0,
                                           colorSpace: BrushyColorSpace.displayP3)
        document.layers = [
            Layer(name: "teal", source: teal),
            // Entirely right of the canvas frame; adjacent to the sample box.
            Layer(name: "off-canvas orange", source: orange,
                  transform: CGAffineTransform(translationX: 100, y: 0)),
        ]

        let sampled = RenderEngine.shared.sampleColor(document: document,
                                                      at: CGPoint(x: 99.5, y: 40), size: 5)
        assertColor(sampled, matches: srgbOfP3(0, 150, 150),
                    "clipped corner box stays pure teal")
    }

    // MARK: - Undo / history

    /// Task test 3: sampling is UI state, not document state — no history
    /// entry and nothing registered with NSUndoManager. Intentional (see
    /// DocumentStore.sampleColor); do not "fix" it.
    func testSamplingCreatesNoUndoEntry() throws {
        var document = Document(canvasSize: CGSize(width: 100, height: 80))
        document.layers = [Layer(name: "teal",
                                 source: GeneratedImages.solid(width: 100, height: 80,
                                                               r: 0, g: 150, b: 150,
                                                               colorSpace: BrushyColorSpace.displayP3))]
        let store = DocumentStore(document: document)
        let um = UndoManager()
        um.levelsOfUndo = 100
        um.groupsByEvent = false
        store.undoManager = um

        XCTAssertFalse(store.canUndo)
        store.eyedropperSampleSize = 3
        let before = store.foregroundColor
        let sampled = try XCTUnwrap(store.sampleColor(at: CGPoint(x: 50, y: 40)))
        store.foregroundColor = sampled // what the tool does with the sample
        XCTAssertNotEqual(store.foregroundColor, before, "the sample landed")
        XCTAssertFalse(store.canUndo, "sampling must not push a history snapshot")
        XCTAssertFalse(store.canRedo)
        XCTAssertFalse(um.canUndo, "sampling must not register with NSUndoManager")
    }

    // MARK: - Controller wiring (click targets, drag, transient ⌥)

    func testControllerClickTargetsDragAndTransientSampling() throws {
        // Left half P3 red, right half P3 blue (blue shares sRGB's primary, so
        // it converts exactly; red clamps — both compared via the well path).
        var document = Document(canvasSize: CGSize(width: 100, height: 80))
        let halves = GeneratedImages.image(width: 100, height: 80,
                                           colorSpace: BrushyColorSpace.displayP3) { x, _ in
            x < 50 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }
        document.layers = [Layer(name: "halves", source: halves)]
        let store = DocumentStore(document: document)
        let controller = CanvasController(store: store)
        let red = srgbOfP3(255, 0, 0)
        let blue = srgbOfP3(0, 0, 255)
        // View coords via the viewport, so the test holds at any zoom/pan.
        let leftView = store.viewport.toView(CGPoint(x: 25, y: 40))
        let rightView = store.viewport.toView(CGPoint(x: 75, y: 40))

        // Plain click → foreground.
        store.activeTool = .eyedropper
        controller.mouseDown(at: rightView, modifiers: [], clickCount: 1)
        controller.mouseUp(at: rightView, modifiers: [], clickCount: 1)
        assertColor(store.foregroundColor, matches: blue, "click samples foreground")

        // ⌥-click → background.
        controller.mouseDown(at: leftView, modifiers: [.option], clickCount: 1)
        controller.mouseUp(at: leftView, modifiers: [.option], clickCount: 1)
        assertColor(store.backgroundColor, matches: red, "⌥-click samples background")

        // Drag = continuous sampling: down on blue, drag onto red.
        controller.mouseDown(at: rightView, modifiers: [], clickCount: 1)
        assertColor(store.foregroundColor, matches: blue, "sampled at mouse-down")
        controller.mouseDragged(to: leftView, modifiers: [])
        controller.mouseUp(at: leftView, modifiers: [], clickCount: 1)
        assertColor(store.foregroundColor, matches: red, "drag keeps sampling")

        // Transient: ⌥ while the brush is active samples the *foreground*,
        // starts no stroke, and still creates no history entry.
        store.activeTool = .brush
        XCTAssertFalse(store.canUndo)
        controller.mouseDown(at: rightView, modifiers: [.option], clickCount: 1)
        controller.mouseDragged(to: rightView, modifiers: [.option])
        controller.mouseUp(at: rightView, modifiers: [.option], clickCount: 1)
        assertColor(store.foregroundColor, matches: blue, "⌥+brush samples foreground")
        XCTAssertNil(store.strokePreview, "no brush stroke was started")
        XCTAssertFalse(store.canUndo, "transient sampling adds no history")
        XCTAssertEqual(store.activeTool, .brush, "the brush tool stays active")
    }
}

import CoreGraphics
import XCTest
@testable import Brushy

/// The `edit_image` tool without the network: the crop geometry, the
/// outlined reference the model sees, the placement script, and the whole
/// flow against a stubbed image model.
@MainActor
final class ImageEditTests: XCTestCase {
    func testFrameGrowsToAnAspectRatioAndStaysOnCanvas() {
        let canvas = CGSize(width: 400, height: 300)
        // A square region: padding 0.5 → 100 each side → 200×200, 1:1.
        let square = ImageEdit.frame(around: CGRect(x: 150, y: 100, width: 100, height: 100), padding: 0.5, canvas: canvas)
        XCTAssertEqual(square.ratio, "1:1")
        XCTAssertEqual(square.frame, CGRect(x: 100, y: 50, width: 200, height: 200))
        // Padding never drops below 32 px.
        let tiny = ImageEdit.frame(around: CGRect(x: 200, y: 150, width: 4, height: 4), padding: 0.5, canvas: canvas)
        XCTAssertEqual(tiny.frame.width, 68)
        // At a corner the frame slides inside the canvas rather than overhanging.
        let corner = ImageEdit.frame(around: CGRect(x: 0, y: 0, width: 100, height: 100), padding: 0.5, canvas: canvas)
        XCTAssertEqual(corner.frame.origin, .zero)
        XCTAssertEqual(corner.frame.size, CGSize(width: 200, height: 200))
        // A wide strip: padded 500×240 exceeds the canvas width, so it overhangs
        // symmetrically instead; the ratio only ever grows the frame.
        let wide = ImageEdit.frame(around: CGRect(x: 50, y: 100, width: 300, height: 40), padding: 0.5, canvas: canvas)
        XCTAssertGreaterThanOrEqual(wide.frame.width, 500)
        let value = ChatTools.aspectRatios.first { $0.name == wide.ratio }!.value
        XCTAssertEqual(Double(wide.frame.width / wide.frame.height), value, accuracy: 0.02)
        XCTAssertLessThan(wide.frame.minX, 0)
        XCTAssertGreaterThan(wide.frame.maxX, 400)
    }

    func testReferenceShowsCropWithRedOutlineAndWhiteOverhang() throws {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        document.layers.append(Layer(name: "Photo", source: GeneratedImages.solid(width: 400, height: 300, r: 20, g: 60, b: 200,
                                                                                    colorSpace: BrushyColorSpace.displayP3)))
        let canvas = document.canvasSize
        // A strip nearly as wide as the canvas: padded by 180 on every side
        // (720×460) and grown to 3:2 (720×480) it overhangs all round.
        let region = CGRect(x: 20, y: 100, width: 360, height: 100)
        let (frame, ratio) = ImageEdit.frame(around: region, padding: 0.5, canvas: canvas)
        XCTAssertEqual(ratio, "3:2")
        XCTAssertEqual(frame, CGRect(x: -160, y: -90, width: 720, height: 480))
        XCTAssertLessThan(frame.minX, 0)
        XCTAssertGreaterThan(frame.maxX, 400)
        let composite = try XCTUnwrap(ChatRenderer.composite(document, maxSide: 400))
        let outline = CGPath(rect: ScriptGeometry.canvas(region, canvasHeight: canvas.height), transform: nil)
        let reference = try XCTUnwrap(ImageEdit.reference(composite: composite, scale: 1, frame: frame, canvas: canvas, outline: outline))
        if let dump = ProcessInfo.processInfo.environment["BRUSHY_TEST_DUMP"], let png = ChatRenderer.png(reference) {
            try png.write(to: URL(fileURLWithPath: dump))
        }
        XCTAssertEqual(reference.width, Int(frame.width))
        let px = try rawRGBA8(reference, in: BrushyColorSpace.sRGB)
        // Inside the canvas but outside the region: the photo's blue.
        let inside = px[Int(region.minX - frame.minX) - 20, Int(region.midY - frame.minY)]
        XCTAssertTrue(inside.b > 150 && inside.r < 80, "\(inside)")
        // On the region's left edge: the red outline.
        let edge = px[Int(region.minX - frame.minX), Int(region.midY - frame.minY)]
        XCTAssertTrue(edge.r > 200 && edge.g < 80 && edge.b < 80, "\(edge)")
        // Past the canvas: white, on the right and above.
        let overhang = px[Int(frame.width) - 3, Int(region.midY - frame.minY)]
        XCTAssertTrue(overhang.r > 245 && overhang.g > 245 && overhang.b > 245, "\(overhang)")
        let above = px[Int(region.midX - frame.minX), 5]
        XCTAssertTrue(above.r > 245 && above.g > 245 && above.b > 245, "\(above)")
    }

    func testPlacementScript() {
        let frame = CGRect(x: 100, y: 50, width: 200, height: 200)
        let withSelection = ImageEdit.placementScript(document: "doc1", frame: frame, region: nil, name: "Edit")
        XCTAssertTrue(withSelection.contains("brushy.doc(\"doc1\")"))
        XCTAssertTrue(withSelection.contains("\"stretch\":true"))
        XCTAssertTrue(withSelection.contains("addMask(\"selection\")"))
        XCTAssertFalse(withSelection.contains("select("))
        let withRegion = ImageEdit.placementScript(document: "doc1", frame: frame,
                                                   region: CGRect(x: 150, y: 100, width: 100, height: 100), name: "Edit")
        XCTAssertTrue(withRegion.contains("target.select({"))
        XCTAssertTrue(withRegion.hasSuffix("target.deselect();"))
        XCTAssertTrue(ImageEdit.prompt(for: "make it red", outlined: true).contains("outlined in red"))
    }

    func testEditImageToolPlacesMaskedLayerOverTheSelection() async throws {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        document.layers.append(Layer(name: "Photo", source: GeneratedImages.solid(width: 400, height: 300, r: 20, g: 60, b: 200,
                                                                                    colorSpace: BrushyColorSpace.displayP3)))
        let store = DocumentStore(document: document)
        // Selection: a 100×100 square in the middle (canvas y-up path).
        let region = CGRect(x: 150, y: 100, width: 100, height: 100)
        store.combineSelection(CGPath(rect: ScriptGeometry.canvas(region, canvasHeight: 300), transform: nil), mode: .replace)
        let registry = DocumentRegistry()
        registry.enumerate = { [(store, "Untitled")] }
        registry.active = { store }
        let tools = ChatTools(registry: registry, runner: ScriptRunner(registry: registry))

        var received: (prompt: String, references: Int, ratio: String, size: String)?
        tools.generateImageData = { prompt, references, ratio, size in
            received = (prompt, references.count, ratio, size)
            // The "edit": a solid red image at the requested ratio.
            let ctx = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                                space: BrushyColorSpace.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            return ChatRenderer.jpeg(ctx.makeImage()!, quality: 0.9)!
        }

        let outcome = await tools.run(FunctionCall(id: "c1", name: ChatTools.editImageName,
                                                   arguments: ["prompt": .string("make it red")]))
        XCTAssertEqual(outcome.status, .succeeded, outcome.text)
        XCTAssertNotNil(outcome.image, "the edited crop goes back to the model")
        let call = try XCTUnwrap(received)
        XCTAssertTrue(call.prompt.hasPrefix("Edit this image: make it red."), call.prompt)
        XCTAssertEqual(call.references, 1)
        XCTAssertEqual(call.ratio, "1:1")
        XCTAssertEqual(call.size, "512")

        // One new layer on top, masked, covering the crop frame (200×200 around the region).
        XCTAssertEqual(store.document.layers.count, 2)
        let placed = try XCTUnwrap(store.document.layers.last)
        XCTAssertNotNil(placed.mask)
        XCTAssertEqual(ScriptGeometry.topLeft(placed.canvasBounds, canvasHeight: 300),
                       CGRect(x: 100, y: 50, width: 200, height: 200))
        XCTAssertEqual(store.historyEntries.last?.actionName, "AI: Edit image: make it red")
        // The composite: red inside the selection, the photo's blue just outside it.
        let composite = try XCTUnwrap(ChatRenderer.composite(store.document, maxSide: 400))
        let px = try rawRGBA8(composite, in: BrushyColorSpace.sRGB)
        XCTAssertTrue(px[200, 150].r > 200 && px[200, 150].b < 80, "\(px[200, 150])")
        XCTAssertTrue(px[130, 150].b > 150 && px[130, 150].r < 80, "\(px[130, 150])")
        XCTAssertTrue(px[200, 80].b > 150 && px[200, 80].r < 80, "\(px[200, 80])")
    }

    func testEditImageWithoutSelectionNeedsARegion() async {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 400, height: 300)))
        let registry = DocumentRegistry()
        registry.enumerate = { [(store, "Untitled")] }
        registry.active = { store }
        let tools = ChatTools(registry: registry, runner: ScriptRunner(registry: registry))
        tools.generateImageData = { _, _, _, _ in Data() }
        let outcome = await tools.run(FunctionCall(id: "c1", name: ChatTools.editImageName,
                                                   arguments: ["prompt": .string("make it red")]))
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.text.contains("Nothing is selected"), outcome.text)
    }
}

import CoreGraphics
import Foundation
import XCTest

final class SerializationTests: XCTestCase {
    /// round-trip: canvas, layer metadata, transforms, pixels, masks and
    /// shared sources all survive write → read.
    func testCompdocRoundTrip() throws {
        let p3 = DezzyColorSpace.displayP3
        var document = Document(canvasSize: CGSize(width: 320, height: 240))

        var layerA = Layer(name: "Base",
                           source: GeneratedImages.gradientChecker(width: 200, height: 150,
                                                                   square: 16, colorSpace: p3))
        layerA.transform = CGAffineTransform(translationX: 12.5, y: -3)
        layerA.opacity = 0.8

        // Duplicate shares the source: must be stored once.
        var layerB = layerA.duplicated(name: "Base copy")
        layerB.transform = CGAffineTransform(rotationAngle: 0.31)
            .concatenating(CGAffineTransform(translationX: 60, y: 40))
        layerB.isVisible = false
        layerB.blendMode = .multiply
        layerB.isClippedToBelow = true

        var layerC = Layer(name: "Masked",
                           source: GeneratedImages.solid(width: 120, height: 90,
                                                         r: 20, g: 220, b: 120, colorSpace: p3),
                           transform: CGAffineTransform(translationX: 100, y: 80))
        let maskPath = CGPath(rect: CGRect(x: 120, y: 100, width: 60, height: 40), transform: nil)
        layerC.mask = Mask(texture: MaskFactory.maskTexture(for: layerC,
                                                            selection: SelectionState(path: maskPath),
                                                            featherCanvasPx: 8),
                           isEnabled: false)

        document.layers = [layerA, layerB, layerC]

        let writer = DocumentSerializer()
        let wrapper = try writer.fileWrapper(for: document)

        XCTAssertNotNil(wrapper.fileWrappers?["document.json"])
        XCTAssertEqual(wrapper.fileWrappers?["sources"]?.fileWrappers?.count, 2,
                       "shared source must be stored once (2 sources for 3 layers)")
        XCTAssertEqual(wrapper.fileWrappers?["masks"]?.fileWrappers?.count, 1)

        // Serialize through actual bytes (as on disk) and read with a fresh instance.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-\(UUID().uuidString).dezzy")
        try wrapper.write(to: temp, options: .atomic, originalContentsURL: nil)
        let readWrapper = try FileWrapper(url: temp)
        let restored = try DocumentSerializer().document(from: readWrapper)

        XCTAssertEqual(restored.canvasSize, document.canvasSize)
        XCTAssertEqual(restored.workingSpace, .displayP3)
        XCTAssertEqual(restored.layers.count, 3)

        for (original, loaded) in zip(document.layers, restored.layers) {
            XCTAssertEqual(loaded.id, original.id)
            XCTAssertEqual(loaded.sourceID, original.sourceID)
            XCTAssertEqual(loaded.name, original.name)
            XCTAssertEqual(loaded.opacity, original.opacity)
            XCTAssertEqual(loaded.isVisible, original.isVisible)
            XCTAssertEqual(loaded.blendMode, original.blendMode)
            XCTAssertEqual(loaded.isClippedToBelow, original.isClippedToBelow)
            XCTAssertEqual(loaded.transform.asArray, original.transform.asArray)
            XCTAssertEqual(loaded.mask?.isEnabled, original.mask?.isEnabled)
            XCTAssertEqual(loaded.mask?.texture.data, original.mask?.texture.data,
                           "mask pixels must round-trip exactly")

            // Source pixels must survive byte-for-byte (lossless, unmodified).
            let a = try rawRGBA8(original.source)
            let b = try rawRGBA8(loaded.source)
            XCTAssertEqual(a.rgba, b.rgba, "source pixels changed in round-trip for \(original.name)")
            XCTAssertEqual(loaded.source.colorSpace?.name, original.source.colorSpace?.name)
        }

        // Shared source stays shared after loading.
        XCTAssertTrue(restored.layers[0].source === restored.layers[1].source)
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - Hostile documents

    /// `document.json` is plain text inside a package the user can open, so
    /// every number in it is untrusted input. Builds a valid document, then
    /// rewrites its JSON through `patch` and reads the result back.
    private func documentPatchingJSON(
        _ patch: (inout [String: Any]) -> Void) throws -> Document {
        var original = Document(canvasSize: CGSize(width: 64, height: 48))
        original.layers = [Layer(name: "Layer",
                                 source: GeneratedImages.solid(width: 32, height: 24,
                                                               r: 200, g: 100, b: 50,
                                                               colorSpace: DezzyColorSpace.sRGB))]
        let wrapper = try DocumentSerializer().fileWrapper(for: original)
        let json = try XCTUnwrap(wrapper.fileWrappers?["document.json"]?.regularFileContents)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [String: Any])
        patch(&object)
        let patched = try JSONSerialization.data(withJSONObject: object)

        var children = wrapper.fileWrappers ?? [:]
        children["document.json"] = FileWrapper(regularFileWithContents: patched)
        return try DocumentSerializer().document(
            from: FileWrapper(directoryWithFileWrappers: children))
    }

    /// A canvas of 1e300 used to reach `Int(canvasSize.width)` in the status
    /// bar, which traps — the window died as soon as it drew.
    func testAstronomicalCanvasSizeIsClamped() throws {
        let document = try documentPatchingJSON { $0["canvasWidth"] = 1e300 }
        XCTAssertEqual(document.canvasSize.width, Document.canvasSizeLimits.upperBound)
        XCTAssertTrue(document.canvasSize.width.isFinite)
    }

    func testNegativeCanvasSizeIsClamped() throws {
        let document = try documentPatchingJSON { $0["canvasHeight"] = -5 }
        XCTAssertEqual(document.canvasSize.height, Document.canvasSizeLimits.lowerBound)
    }

    /// Opacity multiplies alpha in a CIColorMatrix and drives
    /// `Int(opacity * 100)` in the layers panel.
    func testOutOfRangeLayerOpacityIsClamped() throws {
        let document = try documentPatchingJSON { object in
            guard var layers = object["layers"] as? [[String: Any]] else { return }
            layers[0]["opacity"] = 42
            object["layers"] = layers
        }
        XCTAssertEqual(document.layers.first?.opacity, 1)
    }

    /// `isInvertible` only inspects a/b/c/d, so a transform with a huge `tx`
    /// passed it and then produced non-finite source coordinates in
    /// hit-testing and mask sampling.
    func testNonFiniteLayerTransformFallsBackToIdentity() throws {
        let document = try documentPatchingJSON { object in
            guard var layers = object["layers"] as? [[String: Any]] else { return }
            layers[0]["transform"] = [1.0, 0.0, 0.0, 1.0, 1e300, 0.0]
            object["layers"] = layers
        }
        let transform = try XCTUnwrap(document.layers.first?.transform)
        XCTAssertTrue(transform.isFinite)
        XCTAssertEqual(transform, .identity)
    }

    /// Effect sizes are blur radii in canvas points; an unbounded one is a
    /// Gaussian the renderer will not finish.
    func testAstronomicalEffectSizeIsClamped() throws {
        // Encoded from the real type rather than hand-written, so the test
        // can't drift out of the effects schema.
        var effects = LayerEffects()
        var shadow = DropShadowEffect()
        shadow.isEnabled = true
        shadow.size = 1e9
        effects.dropShadow = shadow
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(effects))

        let document = try documentPatchingJSON { object in
            guard var layers = object["layers"] as? [[String: Any]] else { return }
            layers[0]["effects"] = encoded
            object["layers"] = layers
        }
        let size = try XCTUnwrap(document.layers.first?.effects.dropShadow?.size)
        XCTAssertEqual(size, LayerEffects.Bounds.point.upperBound)
    }
}

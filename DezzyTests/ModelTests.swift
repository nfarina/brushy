import CoreGraphics
import CoreImage
import Foundation
import XCTest

final class ModelTests: XCTestCase {
    private func sampleDocument() -> Document {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        let p3 = DezzyColorSpace.displayP3
        document.layers = [
            Layer(name: "A", source: GeneratedImages.solid(width: 100, height: 100,
                                                           r: 200, g: 10, b: 10, colorSpace: p3)),
            Layer(name: "B", source: GeneratedImages.solid(width: 80, height: 60,
                                                           r: 10, g: 200, b: 10, colorSpace: p3),
                  transform: CGAffineTransform(translationX: 120, y: 90)),
        ]
        return document
    }

    /// The single most important rule: geometry edits change `transform`
    /// only. `source` stays the identical object.
    func testTransformOpsNeverTouchSource() {
        var document = sampleDocument()
        let originalSources = document.layers.map { $0.source }
        for index in document.layers.indices {
            document.layers[index].transform = document.layers[index].transform
                .concatenating(CGAffineTransform(scaleX: 0.25, y: 0.25))
                .concatenating(CGAffineTransform(rotationAngle: 0.7))
                .concatenating(CGAffineTransform(translationX: 33, y: -12))
        }
        document = document.cropped(to: CGRect(x: 40, y: 20, width: 200, height: 150))
        for (layer, original) in zip(document.layers, originalSources) {
            XCTAssertTrue(layer.source === original)
        }
    }

    func testCropIsNonDestructiveAndReversible() {
        let document = sampleDocument()
        let cropRect = CGRect(x: 50, y: 30, width: 220, height: 180)
        let cropped = document.cropped(to: cropRect)
        XCTAssertEqual(cropped.canvasSize, cropRect.size)
        // Layer B sat at canvas (120, 90); relative to the new origin it is at (70, 60).
        XCTAssertEqual(cropped.layers[1].transform.tx, 70)
        XCTAssertEqual(cropped.layers[1].transform.ty, 60)

        let restored = cropped.cropped(to: CGRect(x: -cropRect.origin.x, y: -cropRect.origin.y,
                                                  width: document.canvasSize.width,
                                                  height: document.canvasSize.height))
        XCTAssertEqual(restored.canvasSize, document.canvasSize)
        for (a, b) in zip(restored.layers, document.layers) {
            XCTAssertEqual(a.transform, b.transform)
            XCTAssertTrue(a.source === b.source)
        }
    }

    func testMaskTextureCopyOnWrite() {
        let original = MaskTexture(width: 8, height: 8, fill: 255)
        var copy = original
        XCTAssertEqual(original.storageIdentity, copy.storageIdentity,
                       "unmutated copies share storage")
        copy.mutate { data in data[0] = 0 }
        XCTAssertNotEqual(original.storageIdentity, copy.storageIdentity)
        XCTAssertEqual(original.data[0], 255)
        XCTAssertEqual(copy.data[0], 0)
    }

    /// The case address-identity could not express: a texture nobody else
    /// references mutates IN PLACE, so the storage object — and therefore its
    /// address — is unchanged, while the bytes are not.
    ///
    /// `storageIdentity` is a cache key in three places (the render cache, the
    /// serializer's PNG cache, the thumbnail cache), so an unchanged key over
    /// changed bytes meant a stale mask on the canvas, a stale thumbnail in
    /// the panel, and a stale PNG written into the saved file.
    func testUniquelyReferencedMaskStillChangesItsIdentityWhenMutated() {
        var texture = MaskTexture(width: 8, height: 8, fill: 255)
        let before = texture.storageIdentity
        texture.mutate { data in data[0] = 7 }
        XCTAssertNotEqual(texture.storageIdentity, before,
                          "an in-place mutation must still invalidate cache keys")
        XCTAssertEqual(texture.data[0], 7)
    }

    /// A mask's cached CGImage has to follow its bytes too — it is built from
    /// the buffer and handed to the renderer.
    func testMaskCachedImageIsRebuiltAfterAnInPlaceMutation() throws {
        var texture = MaskTexture(width: 4, height: 4, fill: 0)
        let first = try XCTUnwrap(texture.cgImage)
        texture.mutate { data in for index in data.indices { data[index] = 255 } }
        let second = try XCTUnwrap(texture.cgImage)
        XCTAssertFalse(first === second, "the cached image must be invalidated")
    }

    func testSelectionCombineAndInvert() {
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
        let a = CGPath(rect: CGRect(x: 10, y: 10, width: 30, height: 30), transform: nil)
        let b = CGPath(rect: CGRect(x: 50, y: 50, width: 20, height: 20), transform: nil)

        var selection = SelectionState.empty.combining(a, mode: .replace)
        selection = selection.combining(b, mode: .add)
        XCTAssertFalse(selection.isEmpty)
        let combined = selection.path!
        XCTAssertTrue(combined.contains(CGPoint(x: 20, y: 20)))
        XCTAssertTrue(combined.contains(CGPoint(x: 55, y: 55)))
        XCTAssertFalse(combined.contains(CGPoint(x: 45, y: 45)))

        let subtracted = selection.combining(a, mode: .subtract).path!
        XCTAssertFalse(subtracted.contains(CGPoint(x: 20, y: 20)))
        XCTAssertTrue(subtracted.contains(CGPoint(x: 55, y: 55)))

        let inverted = selection.inverted(in: canvas)
        XCTAssertTrue(inverted.path!.contains(CGPoint(x: 45, y: 45)))
        XCTAssertFalse(inverted.path!.contains(CGPoint(x: 20, y: 20)))

        // Inverting a full-canvas selection deselects.
        let full = SelectionState.empty.combining(CGPath(rect: canvas, transform: nil), mode: .replace)
        XCTAssertTrue(full.inverted(in: canvas).isEmpty)
    }

    /// The Lanczos decomposition must land the image exactly where the plain
    /// affine would.
    func testResampledExtentMatchesTransform() {
        let source = CIImage(cgImage: GeneratedImages.solid(
            width: 100, height: 80, r: 128, g: 128, b: 128,
            colorSpace: DezzyColorSpace.displayP3))
        let transform = CGAffineTransform(rotationAngle: 0.3)
            .scaledBy(x: 0.4, y: 0.4)
            .concatenating(CGAffineTransform(translationX: 25, y: 13))
        let expected = CGRect(x: 0, y: 0, width: 100, height: 80).applying(transform)
        let actual = RenderEngine.resampled(source, by: transform).extent
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1.5)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1.5)
        XCTAssertEqual(actual.width, expected.width, accuracy: 3)
        XCTAssertEqual(actual.height, expected.height, accuracy: 3)
    }

    func testLayerReorderUsesPanelConvention() {
        var document = sampleDocument()
        let bottomID = document.layers[0].id
        let topID = document.layers[1].id
        // Panel shows [top, bottom]; dragging the top row below the bottom row
        // moves it to display offset 2.
        document = document.movingLayers(fromDisplayOffsets: IndexSet(integer: 0), toDisplayOffset: 2)
        XCTAssertEqual(document.layers[0].id, topID)
        XCTAssertEqual(document.layers[1].id, bottomID)
    }

    // MARK: - Feather bounds

    /// Sigma beyond the buffer's own size buys nothing: once the kernel is
    /// wider than the image every extra tap is an edge-extended duplicate.
    /// This pins the equivalence the clamp in `blurred` relies on — if it ever
    /// stops holding, the clamp is changing output and not just cost.
    func testSigmaBeyondTheBufferSizeDoesNotChangeTheResult() {
        var data = Data(repeating: 0, count: 64 * 64)
        for row in 0..<64 { for col in 0..<32 { data[row * 64 + col] = 255 } }
        let texture = MaskTexture(width: 64, height: 64, data: data)

        let atClamp = MaskFactory.blurred(texture, sigma: 64)
        let farPast = MaskFactory.blurred(texture, sigma: 512)
        XCTAssertEqual(atClamp.data, farPast.data,
                       "clamping sigma must be a cost optimisation, not a visual change")
    }

    /// `MaskFactory.maskTexture` divides the feather by the layer's scale, and
    /// `isInvertible` admits a determinant down to 1e-10, so a heavily
    /// downscaled layer at the maximum feather (250 px) asked for sigma 1.25e6
    /// — a 7.5-million-tap kernel. vImage runs it; it just costs ~3 s and
    /// ~150 MB per call, on the interactive path that turns a selection into a
    /// mask, for a result identical to the clamped one.
    ///
    /// Asserted as a kernel-width bound rather than a wall-clock bound, so the
    /// test isn't a flaky timing measurement.
    func testFeatherOnAHeavilyDownscaledLayerUsesABoundedKernel() {
        var layer = Layer(name: "Tiny",
                          source: GeneratedImages.solid(width: 64, height: 64,
                                                        r: 255, g: 255, b: 255,
                                                        colorSpace: DezzyColorSpace.sRGB))
        layer.transform = CGAffineTransform(scaleX: 1e-4, y: 1e-4)
        XCTAssertTrue(layer.transform.isInvertible, "the degenerate case has to reach the blur")

        let selection = CGPath(rect: CGRect(x: 0, y: 0, width: 32 * 1e-4, height: 64 * 1e-4),
                               transform: nil)
        let texture = MaskFactory.maskTexture(for: layer,
                                              selection: SelectionState(path: selection),
                                              featherCanvasPx: 250)
        XCTAssertEqual(texture.width, 64)
        XCTAssertEqual(texture.height, 64)
        // The feather still has to actually apply.
        XCTAssertFalse(Set(texture.data).subtracting([0, 255]).isEmpty,
                       "feather produced no intermediate values")
    }

    /// The unbounded term was `ceil(3 * sigma)`; a non-finite sigma also has
    /// to not trap the Int conversion inside.
    func testGaussianKernelHandlesExtremeSigma() {
        XCTAssertEqual(MaskFactory.gaussianKernel(sigma: 2).count, 2 * 6 + 1)
        XCTAssertFalse(MaskFactory.gaussianKernel(sigma: .nan).isEmpty)
    }
}

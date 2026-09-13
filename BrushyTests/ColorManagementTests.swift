import CoreGraphics
import Foundation
import XCTest

final class ColorManagementTests: XCTestCase {
    ///: a known P3 image through import → composite → export must land
    /// within 1/255 of the input.
    func testP3RoundTripWithinOneStep() throws {
        let source = GeneratedImages.image(width: 256, height: 32,
                                           colorSpace: BrushyColorSpace.displayP3) { x, _ in
            (UInt8(x), UInt8(255 - x), UInt8((x * 3) % 256), 255)
        }
        let imported = ImageImporter.normalize(source)
        var document = Document(canvasSize: CGSize(width: 256, height: 32))
        document.layers = [Layer(name: "P3", source: imported)]

        guard let output = RenderEngine.shared.renderFlattened(
            document: document, profile: BrushyColorSpace.displayP3, sixteenBit: false) else {
            XCTFail("render failed"); return
        }
        let actual = try rawRGBA8(output)
        let expected = try rawRGBA8(source)
        var maxDelta = 0
        for y in 0..<32 {
            for x in 0..<256 {
                let a = actual[x, y], e = expected[x, y]
                maxDelta = max(maxDelta,
                               abs(Int(a.r) - Int(e.r)), abs(Int(a.g) - Int(e.g)),
                               abs(Int(a.b) - Int(e.b)), abs(Int(a.a) - Int(e.a)))
            }
        }
        XCTAssertLessThanOrEqual(maxDelta, 1, "P3 round-trip deviates by \(maxDelta)/255")
    }

    ///: compositing happens in linear light. 50% white over black blends to
    /// linear 0.5, which encodes to ~187–188 — not the 128 that gamma-space
    /// blending would produce.
    func testCompositesInLinearLightNotGamma() throws {
        let p3 = BrushyColorSpace.displayP3
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        var white = Layer(name: "white",
                          source: GeneratedImages.solid(width: 64, height: 64,
                                                        r: 255, g: 255, b: 255, colorSpace: p3))
        white.opacity = 0.5
        document.layers = [
            Layer(name: "black",
                  source: GeneratedImages.solid(width: 64, height: 64,
                                                r: 0, g: 0, b: 0, colorSpace: p3)),
            white,
        ]
        guard let output = RenderEngine.shared.renderFlattened(
            document: document, profile: p3, sixteenBit: false) else {
            XCTFail("render failed"); return
        }
        let pixel = try rawRGBA8(output)[32, 32]
        for channel in [pixel.r, pixel.g, pixel.b] {
            XCTAssert((186...189).contains(Int(channel)),
                      "expected linear-light blend (~187), got \(channel) — gamma-space blending would give ~128")
        }
        XCTAssertEqual(pixel.a, 255)
    }
}

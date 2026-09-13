import CoreGraphics
import XCTest

/// The colour picker's HSB maths (`ColorPickerSheet`), which the view itself
/// only drives.
final class HSBColorTests: XCTestCase {
    private func assertRGB(_ color: HSBColor, _ expected: (Double, Double, Double),
                           line: UInt = #line) {
        let rgb = color.rgb
        XCTAssertEqual(rgb.r, expected.0, accuracy: 0.001, line: line)
        XCTAssertEqual(rgb.g, expected.1, accuracy: 0.001, line: line)
        XCTAssertEqual(rgb.b, expected.2, accuracy: 0.001, line: line)
    }

    func testHueSectorsConvertToRGB() {
        assertRGB(HSBColor(hue: 0, saturation: 1, brightness: 1), (1, 0, 0))
        assertRGB(HSBColor(hue: 1.0 / 3, saturation: 1, brightness: 1), (0, 1, 0))
        assertRGB(HSBColor(hue: 2.0 / 3, saturation: 1, brightness: 1), (0, 0, 1))
        assertRGB(HSBColor(hue: 0.5, saturation: 1, brightness: 0.5), (0, 0.5, 0.5))
        assertRGB(HSBColor(hue: 0.8, saturation: 0, brightness: 0.25), (0.25, 0.25, 0.25))
        assertRGB(HSBColor(hue: 1, saturation: 1, brightness: 1), (1, 0, 0), line: #line)
    }

    func testRGBRoundTripsThroughHSB() {
        for (r, g, b) in [(0.2, 0.7, 0.4), (1.0, 0.5, 0.0), (0.13, 0.13, 0.6), (0.0, 0.0, 0.0)] {
            assertRGB(HSBColor(r: r, g: g, b: b), (r, g, b))
        }
    }

    func testCGColorRoundTripKeepsAlpha() {
        let original = CGColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.4)
        let round = HSBColor(cgColor: original).cgColor
        XCTAssertEqual(round.components?[0] ?? 0, 0.25, accuracy: 0.002)
        XCTAssertEqual(round.components?[1] ?? 0, 0.5, accuracy: 0.002)
        XCTAssertEqual(round.components?[2] ?? 0, 0.75, accuracy: 0.002)
        XCTAssertEqual(round.alpha, 0.4, accuracy: 0.002)
    }

    func testHexParsingAndFormatting() {
        XCTAssertEqual(HSBColor(hex: "#FF8000")?.hex, "FF8000")
        XCTAssertEqual(HSBColor(hex: "f80")?.hex, "FF8800", "three digits expand")
        XCTAssertEqual(HSBColor(hex: "  00ff00 ")?.hex, "00FF00")
        XCTAssertNil(HSBColor(hex: "12345"))
        XCTAssertNil(HSBColor(hex: "GGGGGG"))
        XCTAssertEqual(HSBColor(hue: 0, saturation: 0, brightness: 1).hex, "FFFFFF")
    }
}

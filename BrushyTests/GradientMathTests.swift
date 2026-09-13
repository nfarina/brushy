import CoreGraphics
import XCTest

/// Pure gradient-parameter geometry (Gradient tool, G) — tested directly,
/// per the TransformMath convention.
final class GradientMathTests: XCTestCase {
    func testLinearParameterProjectsOntoVector() {
        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 110, y: 10)
        // Perpendicular offset never changes the parameter — hence the wild y values.
        XCTAssertEqual(GradientMath.linearParameter(of: CGPoint(x: 10, y: 40),
                                                    start: start, end: end), 0, accuracy: 1e-12)
        XCTAssertEqual(GradientMath.linearParameter(of: CGPoint(x: 110, y: -25),
                                                    start: start, end: end), 1, accuracy: 1e-12)
        XCTAssertEqual(GradientMath.linearParameter(of: CGPoint(x: 60, y: 500),
                                                    start: start, end: end), 0.5, accuracy: 1e-12)
    }

    func testLinearParameterClampsBeyondTheDraggedSpan() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 0, y: 100)
        XCTAssertEqual(GradientMath.linearParameter(of: CGPoint(x: 3, y: -400),
                                                    start: start, end: end), 0)
        XCTAssertEqual(GradientMath.linearParameter(of: CGPoint(x: -7, y: 999),
                                                    start: start, end: end), 1)
    }

    func testLinearParameterOnDiagonalVector() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 100)
        XCTAssertEqual(GradientMath.linearParameter(of: CGPoint(x: 100, y: 0),
                                                    start: start, end: end), 0.5, accuracy: 1e-12)
        XCTAssertEqual(GradientMath.linearParameter(of: CGPoint(x: 25, y: 25),
                                                    start: start, end: end), 0.25, accuracy: 1e-12)
    }

    func testRadialParameterIsDistanceOverRadiusInAnyDirection() {
        let start = CGPoint(x: 50, y: 50)
        let end = CGPoint(x: 50, y: 110) // radius 60
        XCTAssertEqual(GradientMath.radialParameter(of: start, start: start, end: end), 0)
        XCTAssertEqual(GradientMath.radialParameter(of: CGPoint(x: 50, y: 80),
                                                    start: start, end: end), 0.5, accuracy: 1e-12)
        XCTAssertEqual(GradientMath.radialParameter(of: CGPoint(x: 20, y: 50),
                                                    start: start, end: end), 0.5, accuracy: 1e-12)
        XCTAssertEqual(GradientMath.radialParameter(of: CGPoint(x: 50, y: 110),
                                                    start: start, end: end), 1, accuracy: 1e-12)
        XCTAssertEqual(GradientMath.radialParameter(of: CGPoint(x: 500, y: 500),
                                                    start: start, end: end), 1)
    }

    func testReverseFlipsTheRamp() {
        let start = CGPoint.zero
        let end = CGPoint(x: 100, y: 0)
        let point = CGPoint(x: 25, y: 0)
        XCTAssertEqual(GradientMath.parameter(of: point, start: start, end: end,
                                              shape: .linear, reversed: false),
                       0.25, accuracy: 1e-12)
        XCTAssertEqual(GradientMath.parameter(of: point, start: start, end: end,
                                              shape: .linear, reversed: true),
                       0.75, accuracy: 1e-12)
        XCTAssertEqual(GradientMath.parameter(of: point, start: start,
                                              end: CGPoint(x: 50, y: 0),
                                              shape: .radial, reversed: true),
                       0.5, accuracy: 1e-12)
    }

    func testDegenerateVectorReturnsStartOfRamp() {
        let point = CGPoint(x: 5, y: 5)
        XCTAssertEqual(GradientMath.linearParameter(of: point, start: point, end: point), 0)
        XCTAssertEqual(GradientMath.radialParameter(of: point, start: point, end: point), 0)
    }
}

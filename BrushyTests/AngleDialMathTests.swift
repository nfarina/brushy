import CoreGraphics
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// `AngleDialMath`: Photoshop angles (0 = right, 90 = up) from SwiftUI's
/// y-down view coordinates.
final class AngleDialMathTests: XCTestCase {
    private let center = CGPoint(x: 22, y: 22)

    func testCardinalDirectionsInYDownViewSpace() {
        XCTAssertEqual(AngleDialMath.angle(of: CGPoint(x: 40, y: 22), around: center), 0, accuracy: 1e-9)
        XCTAssertEqual(AngleDialMath.angle(of: CGPoint(x: 22, y: 2), around: center), 90, accuracy: 1e-9)
        XCTAssertEqual(AngleDialMath.angle(of: CGPoint(x: 2, y: 22), around: center), 180, accuracy: 1e-9)
        XCTAssertEqual(AngleDialMath.angle(of: CGPoint(x: 22, y: 40), around: center), -90, accuracy: 1e-9)
    }

    /// Up and to the left is Photoshop's default 120°.
    func testDefaultLightAngle() {
        let point = CGPoint(x: center.x - 10, y: center.y - 10 * tan(60 * .pi / 180))
        XCTAssertEqual(AngleDialMath.angle(of: point, around: center), 120, accuracy: 1e-9)
    }

    func testShiftSnapsTo15Degrees() {
        let point = CGPoint(x: center.x + cos(97 * .pi / 180) * 10,
                            y: center.y - sin(97 * .pi / 180) * 10)
        XCTAssertEqual(AngleDialMath.angle(of: point, around: center, snapping: true), 90, accuracy: 1e-9)
    }

    func testNormalizedFoldsIntoTheStoredRange() {
        XCTAssertEqual(AngleDialMath.normalized(190), -170, accuracy: 1e-9)
        XCTAssertEqual(AngleDialMath.normalized(-180), 180, accuracy: 1e-9)
        XCTAssertEqual(AngleDialMath.normalized(725), 5, accuracy: 1e-9)
        XCTAssertEqual(AngleDialMath.normalized(.nan), 0)
    }

    /// The dial draws in y-down space, so "up" must come out negative y.
    func testDirectionIsYDown() {
        let up = AngleDialMath.direction(90)
        XCTAssertEqual(up.dx, 0, accuracy: 1e-9)
        XCTAssertEqual(up.dy, -1, accuracy: 1e-9)
    }
}

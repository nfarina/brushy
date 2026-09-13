import CoreGraphics
import XCTest

final class TransformMathTests: XCTestCase {
    private let sourceRect = CGRect(x: 0, y: 0, width: 100, height: 80)

    /// Corner drag is proportional by default: dragging the top-right corner
    /// outward along one axis still scales both axes uniformly.
    func testCornerDragProportionalByDefault() {
        let initial = CGAffineTransform.identity
        // Drag the top-right corner from (100,80) to (150,80): projection onto
        // the diagonal gives a uniform factor.
        let t = TransformMath.scaled(handle: .topRight, initial: initial,
                                     sourceRect: sourceRect,
                                     currentCanvasPoint: CGPoint(x: 150, y: 80),
                                     proportional: true, fromCenter: false)
        let (sx, sy) = t.scaleComponents
        XCTAssertEqual(sx, sy, accuracy: 1e-9, "proportional scale must be uniform")
        XCTAssertGreaterThan(sx, 1)
        // Anchor (bottom-left) must not move.
        let anchor = CGPoint(x: 0, y: 0).applying(t)
        XCTAssertEqual(anchor.x, 0, accuracy: 1e-9)
        XCTAssertEqual(anchor.y, 0, accuracy: 1e-9)
    }

    /// Shift + corner = unconstrained (modern Photoshop — not inverted).
    func testShiftCornerDragUnconstrained() {
        let t = TransformMath.scaled(handle: .topRight, initial: .identity,
                                     sourceRect: sourceRect,
                                     currentCanvasPoint: CGPoint(x: 200, y: 40),
                                     proportional: false, fromCenter: false)
        let (sx, sy) = t.scaleComponents
        XCTAssertEqual(sx, 2, accuracy: 1e-9)
        XCTAssertEqual(sy, 0.5, accuracy: 1e-9)
    }

    /// Option scales from the centre: the centre point stays put.
    func testOptionScalesFromCenter() {
        let t = TransformMath.scaled(handle: .topRight, initial: .identity,
                                     sourceRect: sourceRect,
                                     currentCanvasPoint: CGPoint(x: 125, y: 100),
                                     proportional: true, fromCenter: true)
        let center = sourceRect.center.applying(t)
        XCTAssertEqual(center.x, 50, accuracy: 1e-6)
        XCTAssertEqual(center.y, 40, accuracy: 1e-6)
        let (sx, sy) = t.scaleComponents
        XCTAssertEqual(sx, sy, accuracy: 1e-9)
        XCTAssertGreaterThan(sx, 1)
    }

    /// Edge handles scale exactly one axis.
    func testEdgeDragScalesOneAxis() {
        let t = TransformMath.scaled(handle: .middleRight, initial: .identity,
                                     sourceRect: sourceRect,
                                     currentCanvasPoint: CGPoint(x: 130, y: 999),
                                     proportional: false, fromCenter: false)
        let (sx, sy) = t.scaleComponents
        XCTAssertEqual(sx, 1.3, accuracy: 1e-9)
        XCTAssertEqual(sy, 1.0, accuracy: 1e-9)
    }

    /// Scale factors compose against the *current* transform, so repeated
    /// drags on a rotated layer behave in its local axes.
    func testScaleOnRotatedLayerUsesLocalAxes() {
        let rotated = CGAffineTransform(rotationAngle: .pi / 5)
        let cornerCanvas = CGPoint(x: 100, y: 80).applying(rotated)
        // Drag the corner 1.5× further from the anchor along its own diagonal.
        let anchorCanvas = CGPoint.zero.applying(rotated)
        let dragged = CGPoint(x: anchorCanvas.x + (cornerCanvas.x - anchorCanvas.x) * 1.5,
                              y: anchorCanvas.y + (cornerCanvas.y - anchorCanvas.y) * 1.5)
        let t = TransformMath.scaled(handle: .topRight, initial: rotated,
                                     sourceRect: sourceRect,
                                     currentCanvasPoint: dragged,
                                     proportional: true, fromCenter: false)
        let (sx, sy) = t.scaleComponents
        XCTAssertEqual(sx, 1.5, accuracy: 1e-6)
        XCTAssertEqual(sy, 1.5, accuracy: 1e-6)
        XCTAssertEqual(t.rotationAngle, .pi / 5, accuracy: 1e-6, "rotation is preserved")
    }

    func testRotationSnapTo15Degrees() {
        let start = CGPoint(x: 120, y: 40) // to the right of centre (50, 40)
        // 22° of rotation → snaps to 15°.
        let angle: CGFloat = 22 * .pi / 180
        let current = CGPoint(x: 50 + 70 * cos(angle), y: 40 + 70 * sin(angle))
        let t = TransformMath.rotated(initial: .identity, sourceRect: sourceRect,
                                      startCanvasPoint: start, currentCanvasPoint: current,
                                      snapTo15Degrees: true)
        XCTAssertEqual(t.rotationAngle, 15 * .pi / 180, accuracy: 1e-6)

        let free = TransformMath.rotated(initial: .identity, sourceRect: sourceRect,
                                         startCanvasPoint: start, currentCanvasPoint: current,
                                         snapTo15Degrees: false)
        XCTAssertEqual(free.rotationAngle, angle, accuracy: 1e-6)
        // Rotation happens about the box centre.
        let center = sourceRect.center.applying(free)
        XCTAssertEqual(center.x, 50, accuracy: 1e-6)
        XCTAssertEqual(center.y, 40, accuracy: 1e-6)
    }

    func testConstrainedTo45() {
        let horizontal = TransformMath.constrainedTo45(CGPoint(x: 100, y: 8))
        XCTAssertEqual(horizontal.y, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(horizontal.x, 99)

        let diagonal = TransformMath.constrainedTo45(CGPoint(x: 70, y: 75))
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 1e-9)
    }
}

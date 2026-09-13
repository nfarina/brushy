import CoreGraphics
import Foundation
import XCTest

final class TextEditingGeometryTests: XCTestCase {
    private func viewport(zoom: CGFloat, origin: CGPoint = .zero) -> Viewport {
        var vp = Viewport()
        vp.zoom = zoom
        vp.origin = origin
        return vp
    }

    /// The rotated frame's top-left corner, recovered from the placement (the
    /// wrapper rotates about its centre).
    private func placedTopLeftCanvas(_ placement: TextEditingGeometry.Placement,
                                     viewport: Viewport) -> CGPoint {
        let center = CGPoint(x: placement.frame.midX, y: placement.frame.midY)
        let rotation = placement.rotationDegrees * .pi / 180
        let halfW = placement.frame.width / 2
        let halfH = placement.frame.height / 2
        // Top-left in the wrapper's unrotated frame is (-halfW, +halfH) from
        // the centre; rotate that offset about the centre.
        let dx = -halfW * cos(rotation) - halfH * sin(rotation)
        let dy = -halfW * sin(rotation) + halfH * cos(rotation)
        return viewport.fromView(CGPoint(x: center.x + dx, y: center.y + dy))
    }

    func testAnchorPinnedThroughZoomAndGrowth() {
        let anchor = CGPoint(x: 120, y: 340)
        for zoom in [0.5, 1.0, 2.37] {
            for size in [CGSize(width: 80, height: 30), CGSize(width: 300, height: 140)] {
                let vp = viewport(zoom: zoom, origin: CGPoint(x: 33, y: -12))
                let placement = TextEditingGeometry.placement(
                    anchorTopLeft: anchor, rotation: 0, scaleX: 1, scaleY: 1,
                    contentSize: size, viewport: vp)
                let recovered = placedTopLeftCanvas(placement, viewport: vp)
                XCTAssertEqual(recovered.x, anchor.x, accuracy: 1e-6)
                XCTAssertEqual(recovered.y, anchor.y, accuracy: 1e-6)
                XCTAssertEqual(placement.frame.width, size.width * zoom, accuracy: 1e-6)
                XCTAssertEqual(placement.boundsSize, size)
            }
        }
    }

    func testAnchorPinnedUnderRotationAndNonUniformScale() {
        let anchor = CGPoint(x: 200, y: 150)
        let vp = viewport(zoom: 1.5, origin: CGPoint(x: 10, y: 20))
        let placement = TextEditingGeometry.placement(
            anchorTopLeft: anchor, rotation: .pi / 5, scaleX: 2, scaleY: 0.75,
            contentSize: CGSize(width: 120, height: 48), viewport: vp)
        XCTAssertEqual(placement.rotationDegrees, 36, accuracy: 1e-9)
        XCTAssertEqual(placement.frame.width, 120 * 2 * 1.5, accuracy: 1e-6)
        XCTAssertEqual(placement.frame.height, 48 * 0.75 * 1.5, accuracy: 1e-6)
        let recovered = placedTopLeftCanvas(placement, viewport: vp)
        XCTAssertEqual(recovered.x, anchor.x, accuracy: 1e-5)
        XCTAssertEqual(recovered.y, anchor.y, accuracy: 1e-5)
    }

    /// The editor wrapper (placement) and the overlay hairline (corners) must
    /// describe the same box: the placement's frame centre equals the corner
    /// centroid mapped through the viewport.
    func testPlacementAndCornersDescribeTheSameBox() {
        let anchor = CGPoint(x: 140, y: 260)
        let vp = viewport(zoom: 1.23, origin: CGPoint(x: 40, y: 15))
        let contentSize = CGSize(width: 210, height: 84)
        for rotation in [0.0, 0.19, -.pi / 3] {
            let placement = TextEditingGeometry.placement(
                anchorTopLeft: anchor, rotation: rotation, scaleX: 1.4, scaleY: 0.9,
                contentSize: contentSize, viewport: vp)
            let corners = TextEditingGeometry.canvasCorners(
                anchorTopLeft: anchor, rotation: rotation, scaleX: 1.4, scaleY: 0.9,
                contentSize: contentSize)
            let centroidCanvas = CGPoint(
                x: corners.map(\.x).reduce(0, +) / 4,
                y: corners.map(\.y).reduce(0, +) / 4)
            let centroidView = vp.toView(centroidCanvas)
            XCTAssertEqual(placement.frame.midX, centroidView.x, accuracy: 1e-6,
                           "rotation \(rotation)")
            XCTAssertEqual(placement.frame.midY, centroidView.y, accuracy: 1e-6,
                           "rotation \(rotation)")
        }
    }

    func testCanvasCornersMatchPlacement() {
        let anchor = CGPoint(x: 50, y: 90)
        let corners = TextEditingGeometry.canvasCorners(
            anchorTopLeft: anchor, rotation: .pi / 2, scaleX: 1, scaleY: 1,
            contentSize: CGSize(width: 100, height: 40))
        XCTAssertEqual(corners[0], anchor)
        // 90° CCW: "rightward" is straight up, "downward" is +x.
        XCTAssertEqual(corners[1].x, 50, accuracy: 1e-9)
        XCTAssertEqual(corners[1].y, 190, accuracy: 1e-9)
        XCTAssertEqual(corners[3].x, 90, accuracy: 1e-9)
        XCTAssertEqual(corners[3].y, 90, accuracy: 1e-9)
    }

    func testTaskBarCenteredBelowFlipsAndClamps() {
        let host = CGRect(x: 0, y: 0, width: 800, height: 600)
        let bar = CGSize(width: 360, height: 36)

        // Roomy middle: centred under the box (y-up ⇒ below is smaller y).
        let box = CGRect(x: 220, y: 300, width: 200, height: 80)
        var frame = TextEditingGeometry.taskBarFrame(editingBox: box,
                                                     barSize: bar, hostBounds: host)
        XCTAssertEqual(frame.midX, box.midX, accuracy: 1e-9)
        XCTAssertEqual(frame.maxY, box.minY - 10, accuracy: 1e-9)
        XCTAssertEqual(frame.size, bar)

        // Box hugging the bottom edge → the bar flips above it.
        let low = CGRect(x: 220, y: 8, width: 200, height: 40)
        frame = TextEditingGeometry.taskBarFrame(editingBox: low,
                                                 barSize: bar, hostBounds: host)
        XCTAssertEqual(frame.minY, low.maxY + 10, accuracy: 1e-9)

        // Box at the right edge → clamped inside with the margin.
        let right = CGRect(x: 700, y: 300, width: 90, height: 40)
        frame = TextEditingGeometry.taskBarFrame(editingBox: right,
                                                 barSize: bar, hostBounds: host)
        XCTAssertEqual(frame.maxX, host.maxX - 8, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(frame.minX, host.minX)

        // Host too short for the flipped bar → it clamps fully inside.
        let short = CGRect(x: 0, y: 0, width: 800, height: 95)
        frame = TextEditingGeometry.taskBarFrame(editingBox: low,
                                                 barSize: bar, hostBounds: short)
        XCTAssertEqual(frame.maxY, short.maxY - 8, accuracy: 1e-9)
    }
}

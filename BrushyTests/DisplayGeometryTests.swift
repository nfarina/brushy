import CoreGraphics
import XCTest

final class DisplayGeometryTests: XCTestCase {
    private let canvas = CGSize(width: 20, height: 10)

    func testPixelAlignedPutsEveryCanvasEdgeOnAWholeDevicePixel() {
        let transform = CGAffineTransform(a: 0.63, b: 0, c: 0, d: 0.63, tx: 10.37, ty: 4.5)
        let aligned = DisplayGeometry.pixelAligned(transform, canvasSize: canvas)
        let edges = CGRect(origin: .zero, size: canvas).applying(aligned)
        for edge in [edges.minX, edges.maxX, edges.minY, edges.maxY] {
            XCTAssertEqual(edge, edge.rounded(), accuracy: 1e-9)
        }
        let exact = CGRect(origin: .zero, size: canvas).applying(transform)
        XCTAssertLessThanOrEqual(abs(edges.maxX - exact.maxX), 0.5)
        XCTAssertLessThanOrEqual(abs(edges.minY - exact.minY), 0.5)
    }

    func testPixelAlignedKeepsATinyCanvasAtLeastOnePixelAndLeavesRotationAlone() {
        let tiny = DisplayGeometry.pixelAligned(CGAffineTransform(scaleX: 0.01, y: 0.01),
                                                canvasSize: canvas)
        XCTAssertEqual(CGRect(origin: .zero, size: canvas).applying(tiny).width, 1)
        let rotated = CGAffineTransform(rotationAngle: 0.3)
        XCTAssertEqual(DisplayGeometry.pixelAligned(rotated, canvasSize: canvas), rotated)
    }

    func testPixelGridLinesStartEachInteriorPixelWithinTheVisibleRect() {
        let aligned = CGAffineTransform(a: 7.3, b: 0, c: 0, d: 10, tx: 0, ty: 0)
        let all = DisplayGeometry.pixelGridLines(aligned: aligned, canvasSize: CGSize(width: 4, height: 3),
                                                 visible: CGRect(x: 0, y: 0, width: 100, height: 100))
        // ceil(7.3k − 0.5) for k = 1, 2, 3; no line on the canvas's own edges.
        XCTAssertEqual(all.columns, [7, 15, 22])
        XCTAssertEqual(all.rows, [10, 20])
        let clipped = DisplayGeometry.pixelGridLines(aligned: aligned, canvasSize: CGSize(width: 4, height: 3),
                                                     visible: CGRect(x: 10, y: 0, width: 10, height: 15))
        XCTAssertEqual(clipped.columns, [15])
        XCTAssertEqual(clipped.rows, [10])
    }

    func testReadoutSitsBelowRightOfThePointerAndFlipsAtTheViewEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let size = CGSize(width: 80, height: 34)
        XCTAssertEqual(DisplayGeometry.readoutFrame(size: size, beside: CGPoint(x: 100, y: 200), in: bounds),
                       CGRect(x: 116, y: 150, width: 80, height: 34))
        // Near the right edge it moves left of the pointer; near the bottom
        // (y-up) it moves above.
        XCTAssertEqual(DisplayGeometry.readoutFrame(size: size, beside: CGPoint(x: 380, y: 20), in: bounds),
                       CGRect(x: 284, y: 36, width: 80, height: 34))
        // A pointer outside the view (dragging past the edge) still leaves
        // the readout fully inside it.
        let outside = DisplayGeometry.readoutFrame(size: size, beside: CGPoint(x: 500, y: -50), in: bounds)
        XCTAssertTrue(bounds.contains(outside))
    }
}

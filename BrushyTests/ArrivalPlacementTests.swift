import CoreGraphics
import XCTest

/// §4 arrival placement: pasted/placed content centres on the visible part
/// of the canvas, not the canvas centre.
final class ArrivalPlacementTests: XCTestCase {

    private let canvas = CGSize(width: 4000, height: 3000)

    private func viewport(zoom: CGFloat, origin: CGPoint) -> Viewport {
        var v = Viewport()
        v.viewSize = CGSize(width: 800, height: 600)
        v.zoom = zoom
        v.origin = origin
        v.isInitialized = true
        return v
    }

    func testFallsBackToCanvasCenterBeforeLayout() {
        XCTAssertEqual(Viewport().visibleCanvasCenter(canvasSize: canvas),
                       CGPoint(x: 2000, y: 1500))
    }

    func testZoomedInCentresOnVisibleRegion() {
        // 100%, canvas point (1000, 500) at the view's bottom-left.
        let v = viewport(zoom: 1, origin: CGPoint(x: -1000, y: -500))
        XCTAssertEqual(v.visibleCanvasCenter(canvasSize: canvas), CGPoint(x: 1400, y: 800))
    }

    func testPartlyVisibleCanvasUsesOnlyTheOnScreenPart() {
        // Canvas pushed right: only x 0…400 of it is on screen.
        let v = viewport(zoom: 1, origin: CGPoint(x: 400, y: -1000))
        XCTAssertEqual(v.visibleCanvasCenter(canvasSize: canvas), CGPoint(x: 200, y: 1300))
    }

    func testCanvasOffScreenFallsBackToCanvasCenter() {
        let v = viewport(zoom: 1, origin: CGPoint(x: 5000, y: 0))
        XCTAssertEqual(v.visibleCanvasCenter(canvasSize: canvas), CGPoint(x: 2000, y: 1500))
    }

    func testPlacedLayerCentresOnGivenPointOnWholePixels() {
        let image = CGContext(data: nil, width: 101, height: 51, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let layer = DocumentStore.placedLayer(image, named: "x", canvasSize: canvas,
                                              center: CGPoint(x: 300.3, y: 200))
        XCTAssertEqual(layer.transform.tx, 250)
        XCTAssertEqual(layer.transform.ty, 175) // 174.5 rounds up
        XCTAssertEqual(layer.transform.a, 1)
    }
}

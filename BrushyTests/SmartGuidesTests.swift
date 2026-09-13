import CoreGraphics
import XCTest

final class SmartGuidesTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 400, height: 300)

    func testSnapsToCanvasCenter() {
        let targets = SmartGuides.targets(canvasRect: canvas, otherLayerBounds: [])
        let moving = CGRect(x: 0, y: 0, width: 100, height: 60)
        // Raw drag puts the layer centre at (196, 152) — within 6px of (200, 150).
        let result = SmartGuides.snappedMoveDelta(movingBounds: moving,
                                                  rawDelta: CGPoint(x: 146, y: 122),
                                                  targets: targets, threshold: 6)
        XCTAssertEqual(moving.offsetBy(dx: result.delta.x, dy: result.delta.y).midX, 200)
        XCTAssertEqual(moving.offsetBy(dx: result.delta.x, dy: result.delta.y).midY, 150)
        XCTAssertTrue(result.guides.contains { $0.axis == .vertical && $0.position == 200 })
        XCTAssertTrue(result.guides.contains { $0.axis == .horizontal && $0.position == 150 })
    }

    func testSnapsToOtherLayerEdgeAndPicksNearest() {
        let other = CGRect(x: 200, y: 50, width: 80, height: 80)
        let targets = SmartGuides.targets(canvasRect: canvas, otherLayerBounds: [other])
        let moving = CGRect(x: 0, y: 100, width: 50, height: 40)
        // Moving right edge lands at 197 — 3px from the other layer's left edge
        // (200); canvas edges are far away.
        let result = SmartGuides.snappedMoveDelta(movingBounds: moving,
                                                  rawDelta: CGPoint(x: 147, y: 0),
                                                  targets: targets, threshold: 6)
        XCTAssertEqual(moving.offsetBy(dx: result.delta.x, dy: 0).maxX, 200)
        XCTAssertTrue(result.guides.contains { $0.axis == .vertical && $0.position == 200 })
        // The guide spans both rects.
        let guide = result.guides.first { $0.axis == .vertical && $0.position == 200 }!
        XCTAssertLessThanOrEqual(guide.start, 50)
        XCTAssertGreaterThanOrEqual(guide.end, 130)
    }

    func testNoSnapBeyondThreshold() {
        let targets = SmartGuides.targets(canvasRect: canvas, otherLayerBounds: [])
        let moving = CGRect(x: 0, y: 0, width: 100, height: 60)
        let raw = CGPoint(x: 30, y: 25) // nothing within 6px
        let result = SmartGuides.snappedMoveDelta(movingBounds: moving, rawDelta: raw,
                                                  targets: targets, threshold: 6)
        XCTAssertEqual(result.delta.x, raw.x)
        XCTAssertEqual(result.delta.y, raw.y)
        XCTAssertTrue(result.guides.isEmpty)
    }

    func testUniformScaleSnapLandsEdgeOnTarget() {
        let targets = SmartGuides.targets(canvasRect: canvas, otherLayerBounds: [])
        // Layer from (0,0) to (100,60), anchor at origin. A factor of 3.95
        // puts the right edge at 395 — snap should adjust f to land it on 400.
        let f = SmartGuides.snappedUniformScale(3.95, anchorCanvas: .zero,
                                                unscaledBounds: CGRect(x: 0, y: 0, width: 100, height: 60),
                                                targets: targets, threshold: 6)
        XCTAssertEqual(f, 4, accuracy: 1e-9)
    }

    // MARK: - User guides & grid

    func testSnapsToUserGuideAndFeedbackSpansCanvas() {
        let guide = Guide(axis: .vertical, position: 120)
        let targets = SmartGuides.targets(canvasRect: canvas, otherLayerBounds: [],
                                          guides: [guide])
        let moving = CGRect(x: 0, y: 100, width: 50, height: 40)
        // Right edge lands at 117 — 3px from the guide at 120.
        let result = SmartGuides.snappedMoveDelta(movingBounds: moving,
                                                  rawDelta: CGPoint(x: 67, y: 0),
                                                  targets: targets, threshold: 6)
        XCTAssertEqual(moving.offsetBy(dx: result.delta.x, dy: 0).maxX, 120)
        let line = result.guides.first { $0.axis == .vertical && $0.position == 120 }
        XCTAssertNotNil(line, "aligning with a user guide draws a feedback line")
        // Guide targets carry the full canvas rect, so the line spans it.
        XCTAssertLessThanOrEqual(line?.start ?? .infinity, 0)
        XCTAssertGreaterThanOrEqual(line?.end ?? -.infinity, 300)
    }

    func testGuideAndLayerTargetsCompeteNearestWins() {
        // Kept clear of x=200 — the canvas centre is itself a target.
        let other = CGRect(x: 304, y: 0, width: 80, height: 80)
        let guide = Guide(axis: .vertical, position: 297)
        let targets = SmartGuides.targets(canvasRect: canvas, otherLayerBounds: [other],
                                          guides: [guide])
        let moving = CGRect(x: 0, y: 100, width: 50, height: 40)
        // Right edge at 302: layer edge (304) is 2 away, guide (297) 5 away.
        var result = SmartGuides.snappedMoveDelta(movingBounds: moving,
                                                  rawDelta: CGPoint(x: 252, y: 0),
                                                  targets: targets, threshold: 6)
        XCTAssertEqual(moving.offsetBy(dx: result.delta.x, dy: 0).maxX, 304,
                       "the nearer layer edge must beat the guide")
        // Right edge at 298: guide 1 away, layer edge 6 away — guide wins.
        result = SmartGuides.snappedMoveDelta(movingBounds: moving,
                                              rawDelta: CGPoint(x: 248, y: 0),
                                              targets: targets, threshold: 6)
        XCTAssertEqual(moving.offsetBy(dx: result.delta.x, dy: 0).maxX, 297,
                       "the nearer guide must beat the layer edge")
    }

    func testGridSnapsMoveAndEmitsNoFeedback() {
        // 400×310 canvas: the y lattice anchors at the TOP (origin.y = 310),
        // so with step 25 its lines sit at 310, 285, …, 10 — deliberately not
        // multiples of 25. The x lattice anchors at 0.
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 310)
        let grid = SmartGuides.Grid(step: 25, origin: CGPoint(x: 0, y: 310))
        let targets = SmartGuides.targets(canvasRect: canvas, otherLayerBounds: [],
                                          grid: grid)
        let moving = CGRect(x: 0, y: 0, width: 50, height: 40)
        // minX lands at 52 → lattice 50; minY at 33 → lattice 35 (310 − 11·25).
        let result = SmartGuides.snappedMoveDelta(movingBounds: moving,
                                                  rawDelta: CGPoint(x: 52, y: 33),
                                                  targets: targets, threshold: 6)
        let snapped = moving.offsetBy(dx: result.delta.x, dy: result.delta.y)
        XCTAssertEqual(snapped.minX, 50)
        XCTAssertEqual(snapped.minY, 35)
        XCTAssertTrue(result.guides.isEmpty,
                      "grid snapping deliberately draws no magenta feedback")
    }

    func testUniformScaleSnapsToGuide() {
        let guide = Guide(axis: .vertical, position: 350)
        let targets = SmartGuides.targets(canvasRect: canvas, otherLayerBounds: [],
                                          guides: [guide])
        // Anchor at origin; right edge 100 × 3.45 = 345 → f adjusts to 3.5.
        let f = SmartGuides.snappedUniformScale(3.45, anchorCanvas: .zero,
                                                unscaledBounds: CGRect(x: 0, y: 0, width: 100, height: 60),
                                                targets: targets, threshold: 6)
        XCTAssertEqual(f, 3.5, accuracy: 1e-9)
    }

    func testAxisScaleSnapsToGridLine() {
        let grid = SmartGuides.Grid(step: 25)
        let targets = SmartGuides.targets(canvasRect: canvas, otherLayerBounds: [],
                                          grid: grid)
        // Left edge anchored at 0; right edge 100 × 1.22 = 122 → lattice 125.
        let f = SmartGuides.snappedAxisScale(1.22, anchor: 0, unscaledEdges: [0, 100],
                                             axisTargets: [], gridLine: targets.gridLineX,
                                             threshold: 6)
        XCTAssertEqual(f, 1.25, accuracy: 1e-9)
    }
}

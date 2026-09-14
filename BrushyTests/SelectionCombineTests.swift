import CoreGraphics
import XCTest

/// Selection combine modes: the ⇧/⌥ mapping, intersect for path selections,
/// and the per-pixel arithmetic that keeps soft edges when either side has
/// coverage (⌘⇧ / ⌘⌥ / ⌘⇧⌥-clicking a layer thumbnail).
final class SelectionCombineTests: XCTestCase {
    private let canvasRect = CGRect(x: 0, y: 0, width: 40, height: 30)

    private func hard(_ rect: CGRect) -> SelectionState {
        SelectionState(path: CGPath(rect: rect, transform: nil))
    }

    /// Coverage `value` over `rect` (canvas space, y-up), zero elsewhere.
    private func soft(_ rect: CGRect, value: UInt8) -> SelectionState {
        var texture = MaskTexture(width: 40, height: 30, fill: 0)
        texture.mutate { data in
            for y in Int(rect.minY)..<Int(rect.maxY) {
                let row = 29 - y // row 0 is the top (§4)
                for x in Int(rect.minX)..<Int(rect.maxX) { data[row * 40 + x] = value }
            }
        }
        return .coverage(texture, rect: canvasRect)
    }

    private func coverage(_ selection: SelectionState, at point: CGPoint) -> UInt8 {
        selection.coverageTexture(over: canvasRect).data[(29 - Int(point.y)) * 40 + Int(point.x)]
    }

    func testModifiersMapToPhotoshopModes() {
        XCTAssertEqual(SelectionState.CombineMode(shift: false, option: false), .replace)
        XCTAssertEqual(SelectionState.CombineMode(shift: true, option: false), .add)
        XCTAssertEqual(SelectionState.CombineMode(shift: false, option: true), .subtract)
        XCTAssertEqual(SelectionState.CombineMode(shift: true, option: true), .intersect)
    }

    // MARK: - Paths

    func testIntersectKeepsOnlyTheOverlapOfTwoPaths() throws {
        let result = hard(CGRect(x: 0, y: 0, width: 20, height: 20))
            .combining(CGPath(rect: CGRect(x: 10, y: 10, width: 20, height: 20), transform: nil),
                       mode: .intersect)
        XCTAssertEqual(try XCTUnwrap(result.path?.boundingBoxOfPath),
                       CGRect(x: 10, y: 10, width: 10, height: 10))
    }

    func testIntersectWithNothingSelectedIsEmpty() {
        XCTAssertTrue(SelectionState.empty
            .combining(CGPath(rect: canvasRect, transform: nil), mode: .intersect).isEmpty)
    }

    func testTwoHardSelectionsCombineAsExactGeometry() throws {
        let result = hard(CGRect(x: 0, y: 0, width: 10, height: 10))
            .combining(hard(CGRect(x: 20, y: 0, width: 10, height: 10)), mode: .add)
        XCTAssertFalse(result.hasAlpha, "nothing soft on either side, so no channel is invented")
        XCTAssertEqual(try XCTUnwrap(result.path?.boundingBoxOfPath),
                       CGRect(x: 0, y: 0, width: 30, height: 10))
    }

    // MARK: - Coverage

    func testAddingSoftCoverageTakesTheStrongerValue() {
        let result = hard(CGRect(x: 0, y: 0, width: 10, height: 30))
            .combining(soft(CGRect(x: 20, y: 0, width: 20, height: 30), value: 200), mode: .add)
        XCTAssertTrue(result.hasAlpha, "the soft side's partial values survive")
        XCTAssertEqual(coverage(result, at: CGPoint(x: 5, y: 5)), 255)
        XCTAssertEqual(coverage(result, at: CGPoint(x: 15, y: 5)), 0)
        XCTAssertEqual(coverage(result, at: CGPoint(x: 30, y: 5)), 200)
    }

    func testSubtractingSoftCoverageLeavesTheRemainder() {
        let result = hard(canvasRect)
            .combining(soft(CGRect(x: 0, y: 0, width: 20, height: 30), value: 200), mode: .subtract)
        XCTAssertTrue(result.hasAlpha)
        XCTAssertEqual(coverage(result, at: CGPoint(x: 5, y: 5)), 55, "255 × (1 − 200/255)")
        XCTAssertEqual(coverage(result, at: CGPoint(x: 30, y: 5)), 255)
    }

    func testIntersectingSoftCoverageMultiplies() {
        let result = soft(canvasRect, value: 200)
            .combining(soft(CGRect(x: 0, y: 0, width: 20, height: 30), value: 200), mode: .intersect)
        XCTAssertTrue(result.hasAlpha)
        XCTAssertEqual(coverage(result, at: CGPoint(x: 5, y: 5)), 157, "200 × 200/255, rounded")
        XCTAssertEqual(coverage(result, at: CGPoint(x: 30, y: 5)), 0)
    }

    func testCombiningWithAnEmptySelection() {
        let some = soft(CGRect(x: 0, y: 0, width: 20, height: 30), value: 200)
        XCTAssertEqual(SelectionState.empty.combining(some, mode: .add), some)
        XCTAssertTrue(SelectionState.empty.combining(some, mode: .subtract).isEmpty)
        XCTAssertEqual(some.combining(.empty, mode: .subtract), some)
        XCTAssertTrue(some.combining(.empty, mode: .intersect).isEmpty)
    }
}

import CoreGraphics
import Foundation
import XCTest

/// Select > Modify (Grow/Contract/Border) morphology and Select > Transform
/// Selection (task 5): pure `SelectionState` geometry plus the store commands'
/// one-history-entry contract.
final class SelectionModifyTests: XCTestCase {
    private let square = CGRect(x: 0, y: 0, width: 100, height: 100)

    // MARK: - Marquee pixel alignment

    func testMarqueeRectSnapsCornersToThePixelGrid() {
        XCTAssertEqual(SelectionState.marqueeRect(from: CGPoint(x: 10.4, y: 20.6),
                                                  to: CGPoint(x: 60.5, y: 5.2)),
                       CGRect(x: 10, y: 5, width: 51, height: 16),
                       "each corner rounds to the nearest grid line, in either drag direction")
        XCTAssertEqual(SelectionState.marqueeRect(from: CGPoint(x: 3.2, y: 3.2),
                                                  to: CGPoint(x: 3.4, y: 9)).width, 0,
                       "a sub-pixel-wide drag collapses rather than selecting a sliver")
    }

    func testMarqueeRectSquareAndFromCentreConstraints() {
        XCTAssertEqual(SelectionState.marqueeRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40.3, y: 22),
                                                  square: true),
                       CGRect(x: 10, y: 10, width: 30, height: 30), "the longer drag axis sets the side")
        XCTAssertEqual(SelectionState.marqueeRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: -5, y: 30),
                                                  square: true),
                       CGRect(x: -10, y: 10, width: 20, height: 20), "the square grows toward the pointer")
        XCTAssertEqual(SelectionState.marqueeRect(from: CGPoint(x: 50.2, y: 49.8), to: CGPoint(x: 60.4, y: 45),
                                                  fromCenter: true),
                       CGRect(x: 40, y: 45, width: 20, height: 10), "the anchor is the centre")
        XCTAssertEqual(SelectionState.marqueeRect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 53, y: 58),
                                                  square: true, fromCenter: true),
                       CGRect(x: 42, y: 42, width: 16, height: 16))
        let snappedSquare = SelectionState.marqueeRect(from: CGPoint(x: 3.4, y: 7.6),
                                                       to: CGPoint(x: 20.5, y: 11.1), square: true)
        XCTAssertEqual(snappedSquare.width, snappedSquare.height, "snapping never breaks the square")
    }

    // MARK: - Image > Crop frame

    func testCropRectRoundsOutwardAndClipsToCanvas() {
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertNil(SelectionState.empty.cropRect(in: canvas))
        XCTAssertEqual(rectSelection(CGRect(x: 10.3, y: 20.7, width: 50.2, height: 40.1)).cropRect(in: canvas),
                       CGRect(x: 10, y: 20, width: 51, height: 41))
        XCTAssertEqual(rectSelection(CGRect(x: -30, y: 250, width: 100, height: 100)).cropRect(in: canvas),
                       CGRect(x: 0, y: 250, width: 70, height: 50))
        XCTAssertNil(rectSelection(CGRect(x: 500, y: 0, width: 50, height: 50)).cropRect(in: canvas),
                     "a selection entirely off the canvas has nothing to crop to")
    }

    // MARK: - Helpers

    private func rectSelection(_ rect: CGRect) -> SelectionState {
        SelectionState.empty.combining(CGPath(rect: rect, transform: nil), mode: .replace)
    }

    /// Area via flattening + shoelace. Holes in a normalized path carry the
    /// opposite orientation, so their signed areas subtract from the total.
    private func area(of path: CGPath) -> CGFloat {
        var total: CGFloat = 0
        var start = CGPoint.zero
        var prev = CGPoint.zero
        path.flattened(threshold: 0.05).applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                start = e.points[0]
                prev = start
            case .addLineToPoint:
                let p = e.points[0]
                total += (prev.x * p.y - p.x * prev.y) / 2
                prev = p
            case .closeSubpath:
                total += (prev.x * start.y - start.x * prev.y) / 2
                prev = start
            default:
                break // a flattened path contains no curves
            }
        }
        return abs(total)
    }

    private func assertBounds(_ path: CGPath?, _ expected: CGRect, accuracy: CGFloat = 0.5,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let path else {
            XCTFail("expected a selection path", file: file, line: line)
            return
        }
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(box.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(box.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(box.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    private func makeStore() -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        var layer = Layer(name: "L0",
                          source: GeneratedImages.solid(width: 100, height: 100,
                                                        r: 40, g: 80, b: 120,
                                                        colorSpace: DezzyColorSpace.displayP3))
        layer.transform = CGAffineTransform(translationX: 0, y: 40)
        document.layers.append(layer)
        let store = DocumentStore(document: document)
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        return (store, undoManager)
    }

    private func commitGrouped(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    /// Scale about the rect's centre (the anchor Photoshop's "scale from
    /// centre" uses).
    private func scale(_ factor: CGFloat, aboutCenterOf rect: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: factor, y: factor)
            .translatedBy(x: -rect.midX, y: -rect.midY)
    }

    // MARK: - Pure morphology (SelectionState)

    /// Grow(10) on 100×100 → 120×120 box; round joins round the corners, so
    /// the area gains perimeter·r + πr² (not the square-cornered 4r²).
    func testGrowExpandsRectWithRoundedCorners() {
        let grown = rectSelection(square).grown(by: 10)
        assertBounds(grown.path, CGRect(x: -10, y: -10, width: 120, height: 120))
        XCTAssertEqual(area(of: grown.path!), 10000 + 4000 + .pi * 100, accuracy: 30)
    }

    /// Contract(10) → 80×80 with square corners (the annulus's inner boundary
    /// is the r-inset rect).
    func testContractShrinksRect() {
        let contracted = rectSelection(square).contracted(by: 10)
        assertBounds(contracted.path, CGRect(x: 10, y: 10, width: 80, height: 80))
        XCTAssertEqual(area(of: contracted.path!), 6400, accuracy: 30)
    }

    /// A radius past the shape's half-width consumes the whole selection —
    /// collapsing to `.empty` is the correct answer, not an error.
    func testContractPastHalfWidthCollapsesToEmpty() {
        XCTAssertTrue(rectSelection(square).contracted(by: 60).isEmpty)
    }

    /// Border(4) is the band of width 4 centred on the boundary (Photoshop's
    /// Border): area ≈ perimeter × width, with a hole in the middle.
    func testBorderIsBandCentredOnEdge() {
        let border = rectSelection(square).bordered(width: 4)
        assertBounds(border.path, CGRect(x: -2, y: -2, width: 104, height: 104))
        XCTAssertEqual(area(of: border.path!), 400 * 4, accuracy: 30)
        XCTAssertFalse(border.path!.contains(CGPoint(x: 50, y: 50)),
                       "the band must not include the selection interior")
        XCTAssertTrue(border.path!.contains(CGPoint(x: 0, y: 50)),
                      "the old boundary line sits mid-band")
    }

    /// Radii clamp to the feather field's 1...250 range: 0 behaves as 1.
    func testModifyAmountsClampToFeatherRange() {
        let grown = rectSelection(square).grown(by: 0)
        assertBounds(grown.path, CGRect(x: -1, y: -1, width: 102, height: 102))
    }

    func testMorphologyOnEmptySelectionStaysEmpty() {
        XCTAssertTrue(SelectionState.empty.grown(by: 10).isEmpty)
        XCTAssertTrue(SelectionState.empty.contracted(by: 10).isEmpty)
        XCTAssertTrue(SelectionState.empty.bordered(width: 4).isEmpty)
        XCTAssertTrue(SelectionState.empty.transformed(by: .identity).isEmpty)
    }

    /// Transform Selection's commit math: scale ×2 about the centre doubles
    /// the bounds around a fixed centre.
    func testTransformedScaleAboutCentreDoublesBounds() {
        let transformed = rectSelection(square).transformed(by: scale(2, aboutCenterOf: square))
        assertBounds(transformed.path, CGRect(x: -50, y: -50, width: 200, height: 200),
                     accuracy: 1e-6)
    }

    // MARK: - Store commands: exactly one history entry each

    func testGrowCommandIsOneUndoStep() {
        let (store, um) = makeStore()
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        commitGrouped(um) { store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace) }
        commitGrouped(um) { store.growSelection(by: 10) }

        XCTAssertEqual(um.undoActionName, "Grow Selection")
        assertBounds(store.selection.path, CGRect(x: 90, y: 90, width: 120, height: 120))

        um.undo() // exactly one step back to the marquee selection
        assertBounds(store.selection.path, rect)
        XCTAssertTrue(um.canUndo)
        um.undo()
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertFalse(um.canUndo)
    }

    func testBorderCommandIsOneUndoStep() {
        let (store, um) = makeStore()
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        commitGrouped(um) { store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace) }
        commitGrouped(um) { store.borderSelection(width: 4) }

        XCTAssertEqual(um.undoActionName, "Border Selection")
        assertBounds(store.selection.path, CGRect(x: 98, y: 98, width: 104, height: 104))

        um.undo()
        assertBounds(store.selection.path, rect)
    }

    /// The user asked for the contraction, so a result of `.empty` still
    /// commits — and undoes — as a real history entry.
    func testContractToEmptySelectionIsAHistoryEntry() {
        let (store, um) = makeStore()
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        commitGrouped(um) { store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace) }
        commitGrouped(um) { store.contractSelection(by: 60) }

        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertEqual(um.undoActionName, "Contract Selection")
        um.undo()
        assertBounds(store.selection.path, rect)
    }

    func testModifyCommandsOnEmptySelectionPushNothing() {
        // Deliberately no undo groups: with groupsByEvent = false a wrongful
        // registerUndo outside a group raises, so a regression fails loudly.
        let (store, um) = makeStore()
        store.growSelection(by: 10)
        store.contractSelection(by: 10)
        store.borderSelection(width: 4)

        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertFalse(store.canUndo, "no-ops must create no history entries")
        XCTAssertFalse(um.canUndo)
    }

    // MARK: - Transform Selection session

    func testTransformSelectionScaleCommitsOnce() {
        let (store, um) = makeStore()
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        commitGrouped(um) { store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace) }

        store.enterSelectionTransformMode()
        XCTAssertNotNil(store.selectionTransformSession)
        store.updateSelectionTransformSession(scale(2, aboutCenterOf: rect))
        assertBounds(store.selection.path, rect) // live preview never touches the committed selection

        commitGrouped(um) { store.commitSelectionTransformSession() }
        XCTAssertNil(store.selectionTransformSession)
        XCTAssertEqual(um.undoActionName, "Transform Selection")
        assertBounds(store.selection.path, CGRect(x: 50, y: 50, width: 200, height: 200))

        um.undo() // one step restores the pre-transform selection
        assertBounds(store.selection.path, rect)
        XCTAssertTrue(um.canUndo)
        um.undo()
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertFalse(um.canUndo)
    }

    /// Esc: the committed selection was never changed mid-session, so cancel
    /// leaves it untouched and pushes nothing.
    func testTransformSelectionCancelRestores() {
        let (store, um) = makeStore()
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        commitGrouped(um) { store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace) }

        store.enterSelectionTransformMode()
        store.updateSelectionTransformSession(CGAffineTransform(translationX: 40, y: 0))
        store.cancelSelectionTransformSession()

        XCTAssertNil(store.selectionTransformSession)
        assertBounds(store.selection.path, rect)
        um.undo() // only the original Select entry exists
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertFalse(um.canUndo)
    }

    func testTransformSelectionUntouchedCommitPushesNothing() {
        let (store, um) = makeStore()
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        commitGrouped(um) { store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace) }

        store.enterSelectionTransformMode()
        // No undo group on purpose: an identity commit must register nothing
        // (a wrongful registerUndo outside a group would raise here).
        store.commitSelectionTransformSession()

        XCTAssertNil(store.selectionTransformSession)
        XCTAssertEqual(um.undoActionName, "Select", "an untouched box must not add history")
        assertBounds(store.selection.path, rect)
    }

    func testEnterTransformSelectionOnEmptySelectionIsNoOp() {
        let (store, um) = makeStore()
        store.enterSelectionTransformMode()
        XCTAssertNil(store.selectionTransformSession)
        XCTAssertFalse(um.canUndo)
    }

    /// `commitPendingSessions()` — the invariant every mutating store op leans
    /// on — must land a live selection transform.
    func testCommitPendingSessionsLandsSelectionTransform() {
        let (store, um) = makeStore()
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        commitGrouped(um) { store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace) }

        store.enterSelectionTransformMode()
        store.updateSelectionTransformSession(CGAffineTransform(translationX: 40, y: 0))
        commitGrouped(um) { store.commitPendingSessions() }

        XCTAssertNil(store.selectionTransformSession)
        XCTAssertEqual(um.undoActionName, "Transform Selection")
        assertBounds(store.selection.path, rect.offsetBy(dx: 40, dy: 0))
    }

    /// Selection-changing commands land a live transform first, like tool
    /// switches land Cmd+T. (Both commits share this test's one undo group,
    /// so a single undo unwinds to the original selection.)
    func testModifyLandsPendingSelectionTransformFirst() {
        let (store, um) = makeStore()
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        commitGrouped(um) { store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace) }

        store.enterSelectionTransformMode()
        store.updateSelectionTransformSession(CGAffineTransform(translationX: 40, y: 0))
        commitGrouped(um) { store.growSelection(by: 10) }

        XCTAssertNil(store.selectionTransformSession)
        XCTAssertEqual(um.undoActionName, "Grow Selection")
        assertBounds(store.selection.path, CGRect(x: 130, y: 90, width: 120, height: 120))

        um.undo() // the shared group unwinds both the grow and the landed transform
        assertBounds(store.selection.path, rect)
    }
}

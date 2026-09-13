import CoreGraphics
import Foundation
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// Select → Select Subject (owner-requested): the pure marching-squares
/// vectorizer, the Vision wrapper on a generated fixture, and the store-level
/// commit and staleness guards. Deliberately windowless, like
/// NewDocumentTests — no window controllers, no canvas view.
///
/// Vision assertions are coarse on purpose (the model's mask is not
/// pixel-stable across OS builds), and tests skip rather than fail when the
/// request itself is unavailable in the environment.
final class SubjectMaskTests: XCTestCase {

    // MARK: - Marching squares (pure geometry)

    func testContourPathTracesSquareToSubpixelAccuracy() {
        var grid = [Float](repeating: 0, count: 64)
        for row in 2...5 { for col in 2...5 { grid[row * 8 + col] = 1 } }
        guard let path = SubjectMask.contourPath(values: grid, width: 8, height: 8,
                                                 threshold: 0.5) else {
            return XCTFail("No contour for a solid square")
        }
        // 1.0-pixels at cols/rows 2...5 against a 0.0 background cross the
        // 0.5 iso-level exactly on the pixel boundary: bbox (2, 2, 4, 4).
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minX, 2, accuracy: 1e-6)
        XCTAssertEqual(box.minY, 2, accuracy: 1e-6)
        XCTAssertEqual(box.width, 4, accuracy: 1e-6)
        XCTAssertEqual(box.height, 4, accuracy: 1e-6)
        XCTAssertTrue(path.contains(CGPoint(x: 4, y: 4), using: .winding))
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1), using: .winding))
        // Collinear runs merge losslessly: 4 sides + 4 half-pixel chamfers.
        var points = 0
        path.applyWithBlock { if $0.pointee.type != .closeSubpath { points += 1 } }
        XCTAssertEqual(points, 8)
    }

    func testContourPathKeepsAnnulusHoleUnderBothFillRules() {
        var grid = [Float](repeating: 0, count: 32 * 32)
        for row in 0..<32 {
            for col in 0..<32 {
                let d = hypot(Double(col) + 0.5 - 16, Double(row) + 0.5 - 16)
                if d >= 5 && d <= 12 { grid[row * 32 + col] = 1 }
            }
        }
        guard let path = SubjectMask.contourPath(values: grid, width: 32, height: 32,
                                                 threshold: 0.5) else {
            return XCTFail("No contour for the annulus")
        }
        var subpaths = 0
        path.applyWithBlock { if $0.pointee.type == .moveToPoint { subpaths += 1 } }
        XCTAssertEqual(subpaths, 2, "annulus needs an outer boundary and a hole")
        // Outer boundaries and holes wind oppositely, so the winding rule
        // (used by MaskFactory and SelectionState) agrees with even-odd.
        for rule in [CGPathFillRule.winding, .evenOdd] {
            XCTAssertFalse(path.contains(CGPoint(x: 16, y: 16), using: rule),
                           "hole should stay empty under \(rule)")
            XCTAssertTrue(path.contains(CGPoint(x: 24, y: 16), using: rule),
                          "ring should be filled under \(rule)")
            XCTAssertFalse(path.contains(CGPoint(x: 2, y: 2), using: rule),
                           "outside should stay empty under \(rule)")
        }
    }

    func testContourPathDegenerateInputs() {
        XCTAssertNil(SubjectMask.contourPath(values: [Float](repeating: 0, count: 16),
                                             width: 4, height: 4, threshold: 0.5),
                     "all-below-threshold grid has no contour")
        XCTAssertNil(SubjectMask.contourPath(values: [], width: 0, height: 0,
                                             threshold: 0.5))
        XCTAssertNil(SubjectMask.contourPath(values: [1, 1], width: 4, height: 4,
                                             threshold: 0.5),
                     "mismatched buffer size must not crash")
        // A fully-on grid closes around the padded border: the whole frame.
        guard let full = SubjectMask.contourPath(values: [Float](repeating: 1, count: 16),
                                                 width: 4, height: 4, threshold: 0.5) else {
            return XCTFail("No contour for a fully-on grid")
        }
        let box = full.boundingBoxOfPath
        XCTAssertEqual(box.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(box.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(box.width, 4, accuracy: 1e-6)
        XCTAssertEqual(box.height, 4, accuracy: 1e-6)
    }

    // MARK: - Vision on a generated fixture

    /// Red disc on white — Vision lifts clean synthetic subjects reliably.
    /// The centre is (128, 96) in row space (96 rows from the TOP), radius
    /// 60 — i.e. (128, 160) in y-up source space — deliberately off-centre so
    /// a missing y-flip fails loudly, not by luck.
    private func discImage() -> CGImage {
        GeneratedImages.image(width: 256, height: 256,
                              colorSpace: BrushyColorSpace.displayP3) { col, row in
            let d = hypot(Double(col) + 0.5 - 128, Double(row) + 0.5 - 96)
            return d <= 60 ? (204, 31, 31, 255) : (255, 255, 255, 255)
        }
    }

    func testVisionSubjectPathMatchesGeneratedDisc() throws {
        let path: CGPath
        do {
            path = try SubjectMask.subjectPath(in: discImage())
        } catch SubjectMask.Failure.noSubject {
            return XCTFail("Vision found no subject in the disc fixture")
        } catch {
            // Headless/CI machines can lack the segmentation model.
            throw XCTSkip("Vision subject lift unavailable: \(error)")
        }

        // Source space is y-up: the disc drawn 96 rows from the top must land
        // centred on y = 160, not y = 96.
        let center = CGPoint(x: 128, y: 160)
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.midX, center.x, accuracy: 15)
        XCTAssertEqual(box.midY, center.y, accuracy: 15)
        XCTAssertEqual(box.width, 120, accuracy: 30)
        XCTAssertEqual(box.height, 120, accuracy: 30)

        // Coarse coverage: nearly all of the disc, nearly none of the white.
        var insideHits = 0
        var outsideHits = 0
        for k in 0..<16 {
            let angle = Double(k) / 16 * 2 * .pi
            let inner = CGPoint(x: center.x + 40 * cos(angle),
                                y: center.y + 40 * sin(angle))
            let outer = CGPoint(x: center.x + 90 * cos(angle),
                                y: center.y + 90 * sin(angle))
            if path.contains(inner, using: .winding) { insideHits += 1 }
            if path.contains(outer, using: .winding) { outsideHits += 1 }
        }
        XCTAssertGreaterThanOrEqual(insideHits, 14, "subject coverage too thin")
        XCTAssertLessThanOrEqual(outsideHits, 1, "selection bleeds into the background")

        // Agreement with the ideal disc. The prototype measured IoU 0.994 on
        // this fixture; 0.85 leaves room for model drift across OS builds.
        var intersection = 0
        var union = 0
        for gy in 0..<64 {
            for gx in 0..<64 {
                let p = CGPoint(x: (Double(gx) + 0.5) * 4, y: (Double(gy) + 0.5) * 4)
                let inPath = path.contains(p, using: .winding)
                let inDisc = hypot(p.x - center.x, p.y - center.y) <= 60
                if inPath && inDisc { intersection += 1 }
                if inPath || inDisc { union += 1 }
            }
        }
        XCTAssertGreaterThan(Double(intersection) / Double(max(union, 1)), 0.85)
    }

    // MARK: - Store integration

    /// A disc layer translated by (40, 20) on a 400×300 canvas: the committed
    /// selection must land in canvas space through the layer transform.
    private func makeDiscStore() -> DocumentStore {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        var layer = Layer(name: "Disc", source: discImage())
        layer.transform = CGAffineTransform(translationX: 40, y: 20)
        document.layers.append(layer)
        let store = DocumentStore(document: document)
        store.selectedLayerID = layer.id
        return store
    }

    /// Spins the main run loop until the in-progress hint clears — the
    /// completion clears it on every outcome, success or failure.
    private func waitForSubjectRequest(on store: DocumentStore,
                                       timeout: TimeInterval = 120) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while store.brushHint != nil && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return store.brushHint == nil
    }

    func testSelectSubjectCommitsCanvasSpaceSelection() throws {
        let store = makeDiscStore()
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        store.undoManager = undoManager

        XCTAssertTrue(store.selection.isEmpty)
        store.selectSubject()
        XCTAssertNotNil(store.brushHint, "kick-off should show the in-progress hint")
        XCTAssertTrue(waitForSubjectRequest(on: store), "request never completed")

        if let message = store.lastErrorMessage {
            if message.hasPrefix("Select Subject failed") {
                throw XCTSkip("Vision subject lift unavailable: \(message)")
            }
            return XCTFail(message)
        }
        XCTAssertFalse(store.selection.isEmpty)
        // Disc centre (128, 160) in source space + the (40, 20) layer
        // translation = (168, 180) in canvas space.
        let box = store.selection.path?.boundingBoxOfPath ?? .null
        XCTAssertEqual(box.midX, 168, accuracy: 20)
        XCTAssertEqual(box.midY, 180, accuracy: 20)
        XCTAssertTrue(store.canUndo)
        XCTAssertEqual(undoManager.undoActionName, "Select Subject")

        // One clean history entry: undo restores the empty selection. (The
        // extra spin lets the event-grouped undo registration close.)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        undoManager.undo()
        XCTAssertTrue(store.selection.isEmpty)
    }

    func testSelectSubjectDropsResultWhenSelectionMovesOn() {
        let store = makeDiscStore()
        store.selectSubject()
        XCTAssertNotNil(store.brushHint)
        // The user moves on before Vision answers: deselect the layer.
        store.selectedLayerID = nil
        XCTAssertTrue(waitForSubjectRequest(on: store), "request never completed")
        // The stale result is dropped silently — no selection, no history
        // entry, no error — whether Vision succeeded, found nothing, or is
        // unavailable, which keeps this test deterministic everywhere.
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertFalse(store.canUndo)
        XCTAssertNil(store.lastErrorMessage)
    }
}

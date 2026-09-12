import CoreGraphics
import Foundation
import XCTest

/// The wand's pure half: which pixels match, and the trace that turns them
/// into a selection path.
final class MagicWandTests: XCTestCase {
    /// Builds a buffer from rows of characters, one colour per character.
    /// Row 0 is the TOP row, as in the real pixel buffer.
    private func pixels(_ rows: [String],
                        colors: [Character: (UInt8, UInt8, UInt8, UInt8)]) -> MagicWand.Pixels {
        let width = rows[0].count, height = rows.count
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for (row, line) in rows.enumerated() {
            for (column, character) in line.enumerated() {
                let color = colors[character]!
                let offset = (row * width + column) * 4
                data[offset] = color.0
                data[offset + 1] = color.1
                data[offset + 2] = color.2
                data[offset + 3] = color.3
            }
        }
        return MagicWand.Pixels(data: data, width: width, height: height)
    }

    private let redWhite: [Character: (UInt8, UInt8, UInt8, UInt8)] = [
        "r": (255, 0, 0, 255), "w": (255, 255, 255, 255), "p": (250, 8, 8, 255),
    ]

    func testContiguousFloodStopsAtTheEdgeOfTheRun() {
        // Two red patches separated by white: only the clicked one matches.
        let buffer = pixels(["rrwwrr",
                             "rrwwrr",
                             "wwwwww"], colors: redWhite)
        let region = MagicWand.region(in: buffer, seedX: 0, seedY: 0,
                                      tolerance: 0, contiguous: true)
        XCTAssertEqual(region.filter { $0 }.count, 4)
        XCTAssertTrue(region[1])
        XCTAssertFalse(region[4], "the far patch is a separate run")
    }

    func testNonContiguousTakesEveryMatchingPixel() {
        let buffer = pixels(["rrwwrr",
                             "rrwwrr",
                             "wwwwww"], colors: redWhite)
        let region = MagicWand.region(in: buffer, seedX: 0, seedY: 0,
                                      tolerance: 0, contiguous: false)
        XCTAssertEqual(region.filter { $0 }.count, 8)
    }

    func testToleranceIsTheLargestPerChannelDifference() {
        // 'p' differs from 'r' by 8 on the strongest channel.
        let buffer = pixels(["rp"], colors: redWhite)
        XCTAssertEqual(MagicWand.region(in: buffer, seedX: 0, seedY: 0,
                                        tolerance: 7, contiguous: true).filter { $0 }.count, 1)
        XCTAssertEqual(MagicWand.region(in: buffer, seedX: 0, seedY: 0,
                                        tolerance: 8, contiguous: true).filter { $0 }.count, 2,
                       "a difference equal to the tolerance still matches")
    }

    func testAlphaCountsSoTransparencySelectsAsItsOwnRegion() {
        let colors: [Character: (UInt8, UInt8, UInt8, UInt8)] = [
            "o": (255, 255, 255, 255), "t": (255, 255, 255, 0),
        ]
        let buffer = pixels(["ot"], colors: colors)
        let region = MagicWand.region(in: buffer, seedX: 1, seedY: 0,
                                      tolerance: 10, contiguous: true)
        XCTAssertEqual(region, [false, true], "same RGB, different alpha")
    }

    // MARK: - Tracing

    private func pointCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { element in
            if element.pointee.type == .addLineToPoint || element.pointee.type == .moveToPoint {
                count += 1
            }
        }
        return count
    }

    func testASolidRectangleTracesToFourCorners() {
        // 4×2 block inside a 6×4 buffer, rows top-down.
        var mask = [Bool](repeating: false, count: 24)
        for row in 1...2 { for x in 1...4 { mask[row * 6 + x] = true } }
        let path = MagicWand.path(from: mask, width: 6, height: 4)

        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 1, y: 1, width: 4, height: 2),
                       "canvas space is y-up, so the buffer rows flip")
        XCTAssertEqual(pointCount(path), 4, "straight runs collapse to corners")
    }

    func testASinglePixelTracesToItsOwnSquare() {
        var mask = [Bool](repeating: false, count: 9)
        mask[4] = true // centre of a 3×3
        let path = MagicWand.path(from: mask, width: 3, height: 3)
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 1, y: 1, width: 1, height: 1))
    }

    func testAHoleIsPunchedOutRatherThanFilled() {
        // A 5×5 ring with a one-pixel hole in the middle.
        var mask = [Bool](repeating: true, count: 25)
        mask[12] = false
        let path = MagicWand.path(from: mask, width: 5, height: 5)

        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 5, height: 5))
        XCTAssertFalse(path.contains(CGPoint(x: 2.5, y: 2.5), using: .winding),
                       "the hole is outside the selection")
        XCTAssertTrue(path.contains(CGPoint(x: 0.5, y: 0.5), using: .winding))
    }

    func testAnEmptyRegionTracesToAnEmptyPath() {
        XCTAssertTrue(MagicWand.path(from: [Bool](repeating: false, count: 9),
                                     width: 3, height: 3).isEmpty)
    }
}

/// The wand through the store, on real layer pixels — which is also what pins
/// the buffer's top-down rows against the canvas's y-up space.
final class WandSelectionTests: XCTestCase {
    /// 40×30 canvas, white, with a red patch in the TOP-left quadrant.
    private func makeStore() -> DocumentStore {
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: DezzyColorSpace.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 15, width: 20, height: 15)) // y-up: the top-left
        var document = Document(canvasSize: CGSize(width: 40, height: 30))
        document.layers = [Layer(name: "Flag", source: ctx.makeImage()!, isPaintable: true)]
        let store = DocumentStore(document: document)
        store.selectLayer(document.layers[0].id)
        store.wandTolerance = 10
        store.wandContiguous = true
        return store
    }

    func testClickingThePatchSelectsExactlyIt() throws {
        let store = makeStore()
        store.selectByWand(at: CGPoint(x: 5, y: 25), mode: .replace)
        let bounds = try XCTUnwrap(store.selection.path?.boundingBoxOfPath)
        XCTAssertEqual(bounds, CGRect(x: 0, y: 15, width: 20, height: 15),
                       "the red patch is at the TOP — a flipped buffer would select the bottom")
    }

    func testClickingTheSurroundSelectsEverythingElse() throws {
        let store = makeStore()
        store.selectByWand(at: CGPoint(x: 35, y: 5), mode: .replace)
        let path = try XCTUnwrap(store.selection.path)
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 40, height: 30))
        XCTAssertFalse(path.contains(CGPoint(x: 5, y: 25), using: .winding),
                       "the red patch is the hole in this selection")
    }

    func testShiftAddsTheSecondRegionAndTheClickIsOneHistoryEntry() throws {
        let store = makeStore()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        let entries = store.historyEntries.count

        undoManager.beginUndoGrouping()
        store.selectByWand(at: CGPoint(x: 5, y: 25), mode: .replace)
        undoManager.endUndoGrouping()
        XCTAssertEqual(store.historyEntries.count, entries + 1)

        undoManager.beginUndoGrouping()
        store.selectByWand(at: CGPoint(x: 35, y: 5), mode: .add)
        undoManager.endUndoGrouping()
        XCTAssertEqual(undoManager.undoActionName, "Add to Selection")
        XCTAssertEqual(try XCTUnwrap(store.selection.path).boundingBoxOfPath,
                       CGRect(x: 0, y: 0, width: 40, height: 30), "the two make the whole canvas")
    }

    func testNonContiguousIgnoresTheGap() throws {
        let store = makeStore()
        store.wandContiguous = false
        // Both white areas — the right half and the bottom-left — match.
        store.selectByWand(at: CGPoint(x: 35, y: 5), mode: .replace)
        let path = try XCTUnwrap(store.selection.path)
        XCTAssertTrue(path.contains(CGPoint(x: 5, y: 5), using: .winding),
                      "the bottom-left white is part of it, though not connected around")
        XCTAssertFalse(path.contains(CGPoint(x: 5, y: 25), using: .winding))
    }
}

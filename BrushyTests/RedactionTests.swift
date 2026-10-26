import CoreGraphics
import XCTest

/// §5 Redact tool: grid geometry, block averaging/shuffling, and the store
/// operation (one history entry, imported pixels untouched).
final class RedactionTests: XCTestCase {

    /// Deterministic RNG so shuffle tests are repeatable.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Geometry

    func testGridIsAnchoredTopLeftWithPartialEdgeBlocks() {
        let canvas = CGSize(width: 25, height: 25)
        // Top-left block: canvas y 15…25 (y-up).
        XCTAssertEqual(Redaction.canvasRect(of: .init(x: 0, y: 0), blockSize: 10, canvasSize: canvas),
                       CGRect(x: 0, y: 15, width: 10, height: 10))
        // Bottom-right block is the 5×5 remainder.
        XCTAssertEqual(Redaction.canvasRect(of: .init(x: 2, y: 2), blockSize: 10, canvasSize: canvas),
                       CGRect(x: 20, y: 0, width: 5, height: 5))
    }

    func testCellsInRectTakeEveryTouchedBlockClippedToCanvas() {
        let canvas = CGSize(width: 100, height: 100)
        let cells = Redaction.cells(in: CGRect(x: 15, y: 75, width: 10, height: 10),
                                    blockSize: 10, canvasSize: canvas)
        // x 15…25 → columns 1, 2; y 75…85 → rows from top 1, 2.
        XCTAssertEqual(cells, [.init(x: 1, y: 1), .init(x: 2, y: 1),
                               .init(x: 1, y: 2), .init(x: 2, y: 2)])
        XCTAssertEqual(Redaction.cells(in: CGRect(x: 95, y: -50, width: 100, height: 55),
                                       blockSize: 10, canvasSize: canvas),
                       [.init(x: 9, y: 9)])
        XCTAssertTrue(Redaction.cells(in: CGRect(x: 200, y: 0, width: 5, height: 5),
                                      blockSize: 10, canvasSize: canvas).isEmpty)
    }

    func testBrushSegmentCoversItsWidthAndAlwaysItsEnds() {
        let canvas = CGSize(width: 100, height: 100)
        // A horizontal stroke along block-row centres (canvas y 95 = row 0).
        let one = Redaction.cells(alongSegment: CGPoint(x: 5, y: 95), CGPoint(x: 35, y: 95),
                                  widthInBlocks: 1, blockSize: 10, canvasSize: canvas)
        XCTAssertEqual(one, Set((0...3).map { Redaction.Cell(x: $0, y: 0) }))
        let three = Redaction.cells(alongSegment: CGPoint(x: 55, y: 55), CGPoint(x: 55, y: 55),
                                    widthInBlocks: 3, blockSize: 10, canvasSize: canvas)
        XCTAssertTrue(three.isSuperset(of: [.init(x: 5, y: 4), .init(x: 4, y: 4), .init(x: 6, y: 4),
                                            .init(x: 5, y: 3), .init(x: 5, y: 5)]))
        // A click between centres still lands the block under it.
        let click = Redaction.cells(alongSegment: CGPoint(x: 1, y: 99), CGPoint(x: 1, y: 99),
                                    widthInBlocks: 1, blockSize: 10, canvasSize: canvas)
        XCTAssertTrue(click.contains(.init(x: 0, y: 0)))
    }

    func testBoxBlocksFitTheRectExactlyWithNoSlivers() {
        let canvas = CGSize(width: 500, height: 500)
        // 107×43 at block 20 → 5 columns × 2 rows of 21–22 × 21–22.
        let blocks = Redaction.blocks(fitting: CGRect(x: 10.4, y: 30.6, width: 107, height: 43),
                                      blockSize: 20, canvasSize: canvas)
        XCTAssertEqual(blocks.count, 10)
        XCTAssertEqual(Redaction.bounds(of: blocks), CGRect(x: 10, y: 31, width: 107, height: 43))
        for block in blocks {
            XCTAssertTrue((21...22).contains(Int(block.width)), "\(block)")
            XCTAssertTrue((21...22).contains(Int(block.height)), "\(block)")
        }
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.width * $1.height }, 107 * 43, "tiles without overlap")
        // Top row first.
        XCTAssertEqual(blocks[0].maxY, 74)
        // Smaller than a block: still one block, the whole rect.
        XCTAssertEqual(Redaction.blocks(fitting: CGRect(x: 0, y: 0, width: 6, height: 4),
                                        blockSize: 20, canvasSize: canvas),
                       [CGRect(x: 0, y: 0, width: 6, height: 4)])
        // Clipped to the canvas.
        XCTAssertEqual(Redaction.bounds(of: Redaction.blocks(
            fitting: CGRect(x: 480, y: -10, width: 60, height: 30), blockSize: 20, canvasSize: canvas)),
            CGRect(x: 480, y: 0, width: 20, height: 20))
    }

    // MARK: - Pixels

    /// 4×2 canvas, block 2 → two blocks: left all red, right all blue.
    private func withBuffers(_ body: (Redaction.Buffer, Redaction.Buffer) -> Void) -> [UInt8] {
        let canvas = CGRect(x: 0, y: 0, width: 4, height: 2)
        var composite: [UInt8] = []
        for _ in 0..<2 {
            composite += [200, 0, 0, 255, 100, 0, 0, 255, 0, 0, 200, 255, 0, 0, 100, 255]
        }
        var target = [UInt8](repeating: 0, count: 32)
        composite.withUnsafeMutableBytes { c in
            target.withUnsafeMutableBytes { t in
                body(Redaction.Buffer(bytes: c.baseAddress!, bytesPerRow: 16, canvasRect: canvas),
                     Redaction.Buffer(bytes: t.baseAddress!, bytesPerRow: 16, canvasRect: canvas))
            }
        }
        return target
    }

    func testPixelateAveragesEachBlock() {
        let cells: Set<Redaction.Cell> = [.init(x: 0, y: 0), .init(x: 1, y: 0)]
        var rng = SplitMix(state: 1)
        let out = withBuffers { composite, target in
            Redaction.apply(blocks: Redaction.blocks(of: cells, blockSize: 2,
                                                     canvasSize: CGSize(width: 4, height: 2)),
                            mode: .pixelate, shuffle: false, solid: [0, 0, 0, 255],
                            composite: composite, into: target, using: &rng)
        }
        XCTAssertEqual(Array(out[0..<8]), [150, 0, 0, 255, 150, 0, 0, 255])
        XCTAssertEqual(Array(out[8..<16]), [0, 0, 150, 255, 0, 0, 150, 255])
        XCTAssertEqual(out[0..<16], out[16..<32], "both rows of each block")
    }

    func testShuffleKeepsThePaletteButCanReorder() {
        let cells: Set<Redaction.Cell> = [.init(x: 0, y: 0), .init(x: 1, y: 0)]
        var sawSwap = false
        for seed in 0..<20 {
            var rng = SplitMix(state: UInt64(seed))
            let out = withBuffers { composite, target in
                Redaction.apply(blocks: Redaction.blocks(of: cells, blockSize: 2,
                                                         canvasSize: CGSize(width: 4, height: 2)),
                                mode: .pixelate, shuffle: true, solid: [],
                                composite: composite, into: target, using: &rng)
            }
            let left = Array(out[0..<4]), right = Array(out[8..<12])
            XCTAssertEqual(Set([left, right]), Set([[150, 0, 0, 255], [0, 0, 150, 255]]))
            if left == [0, 0, 150, 255] { sawSwap = true }
        }
        XCTAssertTrue(sawSwap)
    }

    func testSolidFillsBlocksOnly() {
        var rng = SplitMix(state: 1)
        let out = withBuffers { _, target in
            Redaction.apply(blocks: [CGRect(x: 2, y: 0, width: 2, height: 2)],
                            mode: .solid, shuffle: true, solid: [1, 2, 3, 255],
                            composite: nil, into: target, using: &rng)
        }
        XCTAssertEqual(Array(out[0..<8]), [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(Array(out[8..<12]), [1, 2, 3, 255])
    }

    // MARK: - Store

    private func makeStore() -> (DocumentStore, UndoManager) {
        let photo = Layer(name: "Screenshot",
                          source: GeneratedImages.solid(width: 100, height: 100, r: 200, g: 40, b: 40,
                                                        colorSpace: BrushyColorSpace.displayP3))
        var document = Document(canvasSize: CGSize(width: 100, height: 100))
        document.layers = [photo]
        let store = DocumentStore(document: document)
        let um = UndoManager()
        um.groupsByEvent = false
        store.undoManager = um
        return (store, um)
    }

    private func pixel(_ image: CGImage, x: Int, yFromTop: Int) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: BrushyColorSpace.displayP3,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self) + yFromTop * image.width * 4 + x * 4
        return (0..<4).map { p[$0] }
    }

    func testRedactLandsOnARedactionsLayerAsOneStepAndNeverPaintsTheImport() {
        let (store, um) = makeStore()
        let photo = store.document.layers[0]
        XCTAssertFalse(photo.isPaintable)
        store.redactShuffle = false
        let blocks = Redaction.blocks(fitting: CGRect(x: 0, y: 80, width: 40, height: 20),
                                      blockSize: 20, canvasSize: store.document.canvasSize)
        um.beginUndoGrouping(); store.redact(blocks: blocks); um.endUndoGrouping()

        XCTAssertEqual(um.undoActionName, "Redact")
        XCTAssertEqual(store.document.layers.count, 2)
        let redactions = store.document.layers[1]
        XCTAssertEqual(redactions.name, DocumentStore.redactionsLayerName)
        XCTAssertEqual(store.selectedLayerID, redactions.id)
        XCTAssertTrue(store.document.layers[0].source === photo.source, "the screenshot is untouched")
        XCTAssertEqual(store.document.layers[0].sourceID, photo.sourceID)
        // A solid-colour photo pixelates to (about) itself; outside the blocks stays clear.
        let inside = pixel(redactions.source, x: 5, yFromTop: 5)
        XCTAssertEqual(inside[3], 255)
        XCTAssertEqual(Int(inside[0]), Int(pixel(photo.source, x: 5, yFromTop: 5)[0]), accuracy: 1)
        XCTAssertEqual(pixel(redactions.source, x: 50, yFromTop: 50)[3], 0)

        // A second redaction reuses the layer with fresh pixels (invariant 4).
        store.redactMode = .solid
        store.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        um.beginUndoGrouping()
        store.redact(blocks: [CGRect(x: 80, y: 0, width: 20, height: 20)])
        um.endUndoGrouping()
        XCTAssertEqual(store.document.layers.count, 2)
        XCTAssertNotEqual(store.document.layers[1].sourceID, redactions.sourceID)
        XCTAssertEqual(pixel(store.document.layers[1].source, x: 90, yFromTop: 90), [0, 0, 0, 255])

        um.undo()
        um.undo()
        XCTAssertEqual(store.document.layers.count, 1)
    }

    func testRedactStartsANewLayerWhenTheTopOneIsntReusable() {
        let (store, _) = makeStore()
        store.redact(blocks: [CGRect(x: 0, y: 80, width: 20, height: 20)])
        var moved = store.document.layers[1]
        moved.transform = CGAffineTransform(translationX: 5, y: 0)
        let store2 = DocumentStore(document: store.document.replacingLayer(moved))
        store2.redact(blocks: [CGRect(x: 0, y: 80, width: 20, height: 20)])
        XCTAssertEqual(store2.document.layers.count, 3)
    }
}

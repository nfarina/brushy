import Compression
import CoreGraphics
import Foundation
import ImageIO
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// Decode budgets (read path).
///
/// A compressed image says nothing about the size of its decode: the PNG built
/// below is ~380 KB on disk and 1.6 GB once decoded. Both routes into the app
/// carry untrusted data — a `.brushy` package is a folder of PNGs the user can
/// swap, and the clipboard takes whatever any process put there — and both
/// decode with `kCGImageSourceShouldCacheImmediately`, so the allocation is
/// immediate rather than lazy.
final class DecodeBudgetTests: XCTestCase {
    /// A fully-valid 8-bit grayscale PNG. All-zero pixels, so it deflates to
    /// roughly nothing on disk while costing width x height x 4 bytes decoded
    /// — the bomb shape.
    ///
    /// Every scanline is really encoded, which is what makes these tests slow
    /// at large sizes. Two shortcuts were tried and both produced tests that
    /// passed for the wrong reason: with an EMPTY IDAT, and with only the
    /// first few scanlines encoded, ImageIO reports no properties at all — so
    /// `decodeBounded` returned nil because it could not read the size, not
    /// because it refused it. Sizes below are therefore kept just past the
    /// limit rather than comfortably past it.
    private func png(width: Int, height: Int) -> Data {
        func chunk(_ tag: String, _ payload: Data) -> Data {
            var out = Data()
            out.appendU32(UInt32(payload.count))
            let tagged = Data(tag.utf8) + payload
            out.append(tagged)
            out.appendU32(CRC32.checksum(tagged))
            return out
        }
        var ihdr = Data()
        ihdr.appendU32(UInt32(width))
        ihdr.appendU32(UInt32(height))
        ihdr.append(contentsOf: [8, 0, 0, 0, 0])   // 8-bit grayscale, no interlace

        var raw = Data()
        raw.reserveCapacity((width + 1) * height)
        let row = Data(repeating: 0, count: width + 1)
        for _ in 0..<height { raw.append(row) }

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        out.append(chunk("IHDR", ihdr))
        out.append(chunk("IDAT", Zlib.compressed(raw)))
        out.append(chunk("IEND", Data()))
        return out
    }

    private func source(_ data: Data) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    }

    // MARK: The premise

    /// A small file really does describe a much larger raster.
    func testASmallPNGDescribesAMuchLargerRaster() throws {
        let data = png(width: 4_000, height: 4_000)
        XCTAssertLessThan(data.count, 200_000)
        let size = try XCTUnwrap(ImageImporter.pixelDimensions(of: try source(data)))
        XCTAssertEqual(size.width * size.height, 16_000_000)
        XCTAssertGreaterThan(size.width * size.height * 4, 300 * data.count,
                             "decoded footprint dwarfs the file")
    }

    // MARK: The policy, tested directly

    /// The accumulator, without paying for images. A package is as easily
    /// bombed with many modest sources as with one huge one.
    func testDocumentBudgetAccumulatesAndEventuallyRefuses() {
        var budget = ImageImporter.DecodeBudget()
        let quarterGig = 1 << 28
        var accepted = 0
        for _ in 0..<64 where budget.charge(quarterGig) { accepted += 1 }
        XCTAssertEqual(accepted, ImageImporter.Limits.maxDocumentDecodedBytes / quarterGig,
                       "the budget must admit exactly what it can afford, then refuse")
    }

    func testBudgetRefusesAnOverflowingCharge() {
        var budget = ImageImporter.DecodeBudget()
        XCTAssertFalse(budget.charge(Int.max), "an overflowing charge must not wrap")
        XCTAssertTrue(budget.charge(1), "and must not have consumed the budget either")
    }

    // MARK: ImageIO integration

    /// 16400² is 269 megapixels — 1.076 GB as RGBA8, just past the 1 GiB
    /// per-image budget.
    func testOversizedImageIsRefused() throws {
        let data = png(width: 16_400, height: 16_400)
        let probed = try XCTUnwrap(ImageImporter.pixelDimensions(of: try source(data)),
                                   "the file must be readable, or the refusal proves nothing")
        XCTAssertGreaterThan(probed.width * probed.height * 4,
                             ImageImporter.Limits.maxImageDecodedBytes)
        let bombSource = try source(data)
        XCTAssertNil(ImageImporter.decodeBounded(bombSource),
                     "past the per-image decode budget must be refused")
    }

    /// A stitched panorama past 16384 px on its long edge is an ordinary
    /// photograph, not an attack. Capping per-side at the canvas limit would
    /// have stopped documents that already exist from reopening.
    func testWidePanoramaIsStillAccepted() throws {
        let data = png(width: 20_000, height: 2_000)   // 40 Mpx, 160 MB decoded
        XCTAssertGreaterThan(20_000, Int(Document.canvasSizeLimits.upperBound),
                             "wider than any canvas, deliberately")
        let panoramaSource = try source(data)
        XCTAssertNotNil(ImageImporter.decodeBounded(panoramaSource),
                        "a wide panorama must still import")
    }

    /// End to end: a `.brushy` package whose source PNG is oversized fails to
    /// open with a readable error instead of trying to allocate it.
    func testBrushyPackageWithAnOversizedSourceIsRefused() throws {
        var document = Document(canvasSize: CGSize(width: 64, height: 48))
        document.layers = [Layer(name: "Layer",
                                 source: GeneratedImages.solid(width: 32, height: 24,
                                                               r: 10, g: 20, b: 30,
                                                               colorSpace: BrushyColorSpace.sRGB))]
        let wrapper = try DocumentSerializer().fileWrapper(for: document)
        var children = try XCTUnwrap(wrapper.fileWrappers)
        let sourceName = "\(document.layers[0].sourceID.uuidString).png"
        children["sources"] = FileWrapper(directoryWithFileWrappers: [
            sourceName: FileWrapper(regularFileWithContents: png(width: 16_400, height: 16_400)),
        ])
        XCTAssertThrowsError(
            try DocumentSerializer().document(
                from: FileWrapper(directoryWithFileWrappers: children)))
    }

    /// The layer-count cap, which needs no images at all.
    func testAbsurdLayerCountIsRefused() throws {
        var document = Document(canvasSize: CGSize(width: 8, height: 8))
        document.layers = [Layer(name: "Layer",
                                 source: GeneratedImages.solid(width: 4, height: 4,
                                                               r: 1, g: 2, b: 3,
                                                               colorSpace: BrushyColorSpace.sRGB))]
        let wrapper = try DocumentSerializer().fileWrapper(for: document)
        let json = try XCTUnwrap(wrapper.fileWrappers?["document.json"]?.regularFileContents)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let template = try XCTUnwrap((object["layers"] as? [[String: Any]])?.first)
        object["layers"] = Array(repeating: template,
                                 count: ImageImporter.Limits.maxLayers + 1)
        var children = try XCTUnwrap(wrapper.fileWrappers)
        children["document.json"] = FileWrapper(
            regularFileWithContents: try JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(
            try DocumentSerializer().document(
                from: FileWrapper(directoryWithFileWrappers: children)))
    }
}

/// Minimal PNG plumbing for the test above — deliberately independent of the
/// app's own encoders, which cannot produce a file of this shape.
private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private enum Zlib {
    /// A zlib stream: the 2-byte header, raw DEFLATE from the Compression
    /// framework (COMPRESSION_ZLIB is headerless), then Adler-32 — the same
    /// layout PSDDecoder.inflate takes apart in the other direction.
    static func compressed(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        let bound = data.count + 1024
        var buffer = [UInt8](repeating: 0, count: bound)
        let written = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return buffer.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(destination.baseAddress!, bound,
                                          base, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        out.append(contentsOf: buffer.prefix(written))
        out.appendU32(adler32(data))
        return out
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }
}

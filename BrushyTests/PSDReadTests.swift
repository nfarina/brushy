import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// PSD reading(; the "no reading `.psd`" lifted by the
/// owner, with layer styles).
///
/// Two independent sources of truth are used deliberately:
///
/// 1. **ImageIO**, which writes real Photoshop-format files — a producer this
///    project didn't write, using RLE compression and the negative layer
///    count Photoshop itself emits. Round-tripping only against `PSDWriter`
///    would let a shared misreading of the spec pass twice.
/// 2. **`PSDWriter`**, for the structure ImageIO can't express: groups,
///    masks, blend modes, clipping and layer effects.
final class PSDReadTests: XCTestCase {
    private let p3 = BrushyColorSpace.displayP3

    // MARK: - Against a writer we didn't write

    /// ImageIO's PSD: RLE channels, one layer, layer count −1. Everything the
    /// reader believes about the format is on the line here.
    func testReadsAPSDWrittenByImageIO() throws {
        let width = 16, height = 8
        let source = GeneratedImages.image(width: width, height: height,
                                           colorSpace: BrushyColorSpace.sRGB) { column, row in
            (UInt8(column * 16), UInt8(row * 32), 200, 255)
        }
        let data = try imageIOPSD(source)
        let document = try PSDReader.document(from: data)

        XCTAssertEqual(document.canvasSize, CGSize(width: width, height: height))
        XCTAssertEqual(document.layers.count, 1)
        let layer = try XCTUnwrap(document.layers.first)
        XCTAssertEqual(layer.source.width, width)
        XCTAssertEqual(layer.source.height, height)

        // Pixels: compare through a flattened render, which is what the user
        // actually sees. ImageIO round-trips through its own colour handling,
        // so a couple of levels of slack is right; the gradient across the
        // image would fail this by a mile if rows or channels were confused.
        let rendered = try flatten(document, profile: BrushyColorSpace.sRGB)
        let expected = try rawRGBA8(source, in: BrushyColorSpace.sRGB)
        let (stats, _) = comparePixels(actual: rendered, reference: expected,
                                       colorTolerance: 3, alphaTolerance: 1)
        XCTAssertEqual(stats.deviatingPixels, 0, "PSD pixels differ — \(stats.summary)")
    }

    /// The file ImageIO writes is RLE-compressed; this pins that the reader is
    /// actually exercising that path rather than accidentally taking `raw`.
    func testImageIOPSDIsRLECompressedSoThePathIsCovered() throws {
        let image = GeneratedImages.solid(width: 8, height: 4, r: 10, g: 20, b: 30,
                                          colorSpace: BrushyColorSpace.sRGB)
        let data = try imageIOPSD(image)
        XCTAssertEqual(compositeCompression(of: data), 1, "expected RLE composite data")
    }

    func testUnpackBitsHandlesLiteralRepeatAndNoOpRuns() throws {
        // 0x02 → 3 literals; 0xFD (−3) → 4 repeats; 0x80 → no-op.
        let payload = Data([0x02, 1, 2, 3, 0xFD, 9, 0x80, 0x00, 7])
        let decoded = try PSDDecoder.unpackBits(payload, rowByteCounts: [payload.count],
                                                bytesPerRow: 9)
        XCTAssertEqual(decoded, [1, 2, 3, 9, 9, 9, 9, 7, 0])
    }

    // MARK: - Round trip through our own writer

    /// Everything the model carries that PSD can express, out and back.
    func testRoundTripsLayersGroupsMasksAndBlendModes() throws {
        var document = Document(canvasSize: CGSize(width: 64, height: 48))
        var bottom = Layer(name: "Bottom",
                           source: GeneratedImages.solid(width: 64, height: 48,
                                                         r: 220, g: 40, b: 40, colorSpace: p3))
        bottom.opacity = 0.5
        var middle = Layer(name: "Múltiply ✻",   // non-ASCII → the luni block
                           source: GeneratedImages.solid(width: 32, height: 24,
                                                         r: 40, g: 90, b: 220, colorSpace: p3),
                           transform: CGAffineTransform(translationX: 8, y: 12))
        middle.blendMode = .multiply
        middle.isVisible = false
        var top = Layer(name: "Clipped",
                        source: GeneratedImages.solid(width: 32, height: 24,
                                                      r: 250, g: 250, b: 120, colorSpace: p3),
                        transform: CGAffineTransform(translationX: 8, y: 12))
        top.isClippedToBelow = true
        var mask = MaskTexture(width: 32, height: 24, fill: 255)
        mask.mutate { data in
            for index in 0..<(32 * 12) { data[index] = 0 }   // top half hidden
        }
        top.mask = Mask(texture: mask, isEnabled: true)

        let group = LayerGroup(name: "Folder", opacity: 0.8, blendMode: .screen)
        middle.groupID = group.id
        top.groupID = group.id
        document.layers = [bottom, middle, top]
        document.groups = [group]
        document = document.normalizingGroups().normalizingClipping()

        let data = try PSDWriter.data(for: document, profile: p3)
        let read = try PSDReader.document(from: data)

        XCTAssertEqual(read.canvasSize, document.canvasSize)
        XCTAssertEqual(read.layers.map(\.name), ["Bottom", "Múltiply ✻", "Clipped"])
        XCTAssertEqual(read.layers.map(\.blendMode), [.normal, .multiply, .normal])
        XCTAssertEqual(read.layers.map(\.isVisible), [true, false, true])
        XCTAssertEqual(read.layers.map(\.isClippedToBelow), [false, false, true])
        XCTAssertEqual(Double(read.layers[0].opacity), 0.5, accuracy: 0.01)

        // Group: one folder holding the upper two layers, Screen at 80%.
        XCTAssertEqual(read.groups.count, 1)
        let readGroup = try XCTUnwrap(read.groups.first)
        XCTAssertEqual(readGroup.name, "Folder")
        XCTAssertEqual(readGroup.blendMode, .screen)
        XCTAssertEqual(Double(readGroup.opacity), 0.8, accuracy: 0.01)
        XCTAssertEqual(read.layers.map { $0.groupID == readGroup.id }, [false, true, true])

        // Position survives: the middle layer sits 8 right, 12 up from the
        // canvas origin (y-up), as it did going in.
        XCTAssertEqual(read.layers[1].canvasBounds.origin.x, 8, accuracy: 0.5)
        XCTAssertEqual(read.layers[1].canvasBounds.origin.y, 12, accuracy: 0.5)

        // Mask: same grid as the layer's pixels, top half hidden.
        let readMask = try XCTUnwrap(read.layers[2].mask)
        XCTAssertEqual(readMask.texture.width, 32)
        XCTAssertEqual(readMask.texture.height, 24)
        XCTAssertTrue(readMask.isEnabled)
        XCTAssertEqual(readMask.texture.data.first, 0, "mask row 0 is the TOP row")
        XCTAssertEqual(readMask.texture.data.last, 255)
    }

    /// A group whose blend mode is Pass Through (the default) must come back
    /// as Pass Through, not as Normal — they are different renders.
    func testPassThroughGroupsSurviveTheRoundTrip() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        let group = LayerGroup(name: "Plain")
        var layer = Layer(name: "Inside",
                          source: GeneratedImages.solid(width: 32, height: 32,
                                                        r: 10, g: 200, b: 90, colorSpace: p3))
        layer.groupID = group.id
        document.layers = [layer]
        document.groups = [group]

        let read = try PSDReader.document(from: try PSDWriter.data(for: document, profile: p3))
        XCTAssertEqual(read.groups.count, 1)
        XCTAssertNil(read.groups.first?.blendMode, "Pass Through must not degrade to Normal")
    }

    func testNestedGroupsKeepTheirParenting() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        let outer = LayerGroup(name: "Outer")
        let inner = LayerGroup(name: "Inner", parentID: outer.id)
        var deep = Layer(name: "Deep",
                         source: GeneratedImages.solid(width: 16, height: 16,
                                                       r: 5, g: 5, b: 5, colorSpace: p3))
        deep.groupID = inner.id
        var shallow = Layer(name: "Shallow",
                            source: GeneratedImages.solid(width: 16, height: 16,
                                                          r: 250, g: 5, b: 5, colorSpace: p3))
        shallow.groupID = outer.id
        document.layers = [deep, shallow]
        document.groups = [outer, inner]
        document = document.normalizingGroups()

        let read = try PSDReader.document(from: try PSDWriter.data(for: document, profile: p3))
        XCTAssertEqual(read.groups.count, 2)
        let readOuter = try XCTUnwrap(read.groups.first { $0.name == "Outer" })
        let readInner = try XCTUnwrap(read.groups.first { $0.name == "Inner" })
        XCTAssertNil(readOuter.parentID)
        XCTAssertEqual(readInner.parentID, readOuter.id)
        XCTAssertEqual(read.layers.first { $0.name == "Deep" }?.groupID, readInner.id)
    }

    /// A document with no layer records at all still opens — through the
    /// composite, which every PSD carries.
    func testFallsBackToTheCompositeWhenThereAreNoLayers() throws {
        let document = Document(canvasSize: CGSize(width: 24, height: 16))
        let data = try PSDWriter.data(for: document, profile: p3)
        let read = try PSDReader.document(from: data, fallbackName: "Flat")
        XCTAssertEqual(read.canvasSize, CGSize(width: 24, height: 16))
        XCTAssertEqual(read.layers.count, 1)
        XCTAssertEqual(read.layers.first?.name, "Flat")
    }

    func testRejectsNonPSDData() {
        let notAPSD = Data("this is not a Photoshop file, it is a sentence".utf8)
        XCTAssertThrowsError(try PSDReader.document(from: notAPSD)) { error in
            XCTAssertEqual((error as? PSDReadError)?.errorDescription,
                           PSDReadError.notAPSD.errorDescription)
        }
        // A PSB (version 2) header should say so rather than "damaged".
        var psb = Data()
        psb.appendFourCC("8BPS")
        psb.appendU16(2)
        psb.append(Data(count: 20))
        XCTAssertThrowsError(try PSDReader.document(from: psb)) { error in
            XCTAssertTrue((error as? PSDReadError)?.errorDescription?.contains(".psb") ?? false)
        }
    }

    // MARK: - 16-bit

    /// 16-bit documents keep their layers in an `Lr16` additional block with
    /// the ordinary layer info left empty — a layout our own writer never
    /// produces, so it gets a hand-built file.
    func testReadsSixteenBitLayersFromTheLr16Block() throws {
        let data = sixteenBitPSD(width: 4, height: 2,
                                 red: 0xFFFF, green: 0x8000, blue: 0x0000)
        let document = try PSDReader.document(from: data)
        XCTAssertEqual(document.layers.count, 1)
        let layer = try XCTUnwrap(document.layers.first)
        XCTAssertEqual(layer.source.bitsPerComponent, 16, "deep pixels must stay deep")

        let rendered = try flatten(document, profile: BrushyColorSpace.sRGB)
        let pixel = rendered[1, 1]
        XCTAssertEqual(Int(pixel.r), 255, accuracy: 2)
        XCTAssertEqual(Int(pixel.g), 128, accuracy: 3)
        XCTAssertEqual(Int(pixel.b), 0, accuracy: 2)
        XCTAssertEqual(Int(pixel.a), 255)
    }

    // MARK: - Helpers

    private func flatten(_ document: Document, profile: CGColorSpace) throws -> RawImage {
        guard let image = RenderEngine.shared.renderFlattened(document: document, profile: profile,
                                                              sixteenBit: false) else {
            throw TestImageError.contextFailed
        }
        return try rawRGBA8(image, in: profile)
    }

    private func imageIOPSD(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, "com.adobe.photoshop-image" as CFString, 1, nil) else {
            throw TestImageError.contextFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestImageError.contextFailed }
        return data as Data
    }

    /// The compression word of the composite image data, found by walking the
    /// four length-prefixed sections after the header.
    private func compositeCompression(of data: Data) -> Int? {
        func u16(_ offset: Int) -> Int { Int(data[offset]) << 8 | Int(data[offset + 1]) }
        func u32(_ offset: Int) -> Int { (u16(offset) << 16) | u16(offset + 2) }
        var offset = 26
        for _ in 0..<3 {
            guard offset + 4 <= data.count else { return nil }
            offset += 4 + u32(offset)
        }
        guard offset + 2 <= data.count else { return nil }
        return u16(offset)
    }

    /// A minimal but valid 16-bit RGB PSD: one opaque layer covering the
    /// canvas, raw channels, layers carried in `Lr16`.
    private func sixteenBitPSD(width: Int, height: Int,
                               red: UInt16, green: UInt16, blue: UInt16) -> Data {
        func plane(_ value: UInt16) -> Data {
            var data = Data()
            for _ in 0..<(width * height) { data.appendU16(value) }
            return data
        }
        let channels: [(id: Int16, data: Data)] = [
            (0, plane(red)), (1, plane(green)), (2, plane(blue)), (-1, plane(0xFFFF)),
        ]

        var record = Data()
        record.appendI32(0)                       // top
        record.appendI32(0)                       // left
        record.appendI32(Int32(height))           // bottom
        record.appendI32(Int32(width))            // right
        record.appendU16(UInt16(channels.count))
        for channel in channels {
            record.appendI16(channel.id)
            record.appendU32(UInt32(2 + channel.data.count))
        }
        record.appendFourCC("8BIM")
        record.appendFourCC("norm")
        record.appendU8(255)                      // opacity
        record.appendU8(0)                        // clipping
        record.appendU8(0)                        // flags
        record.appendU8(0)                        // filler
        var extra = Data()
        extra.appendU32(0)                        // no mask
        extra.appendU32(0)                        // no blending ranges
        extra.appendPascalString("Deep", paddedToMultipleOf: 4)
        record.appendU32(UInt32(extra.count))
        record.append(extra)

        var layerInfo = Data()
        layerInfo.appendI16(1)
        layerInfo.append(record)
        for channel in channels {
            layerInfo.appendU16(0)                // raw
            layerInfo.append(channel.data)
        }
        if layerInfo.count % 2 != 0 { layerInfo.appendU8(0) }

        var layerAndMask = Data()
        layerAndMask.appendU32(0)                 // 8-bit layer info: empty
        layerAndMask.appendU32(0)                 // global layer mask info
        layerAndMask.appendFourCC("8BIM")
        layerAndMask.appendFourCC("Lr16")
        layerAndMask.appendU32(UInt32(layerInfo.count))
        layerAndMask.append(layerInfo)

        var out = Data()
        out.appendFourCC("8BPS")
        out.appendU16(1)
        out.append(Data(count: 6))
        out.appendU16(3)                          // composite channels
        out.appendU32(UInt32(height))
        out.appendU32(UInt32(width))
        out.appendU16(16)                         // depth
        out.appendU16(3)                          // RGB
        out.appendU32(0)                          // colour mode data
        out.appendU32(0)                          // image resources
        out.appendU32(UInt32(layerAndMask.count))
        out.append(layerAndMask)
        out.appendU16(0)                          // composite: raw
        out.append(plane(red)); out.append(plane(green)); out.append(plane(blue))
        return out
    }

    // MARK: - Malformed input

    /// An 8-bit single-layer PSD with every field a malicious file would lie
    /// about left open. `layerRect` and `compression` are deliberately not
    /// derived from the payload, so a test can declare a rect the data cannot
    /// possibly back.
    private func syntheticPSD(canvasWidth: Int, canvasHeight: Int,
                              layerRect: (top: Int32, left: Int32, bottom: Int32, right: Int32),
                              compression: UInt16 = 0,
                              channelPayload: Data = Data([0, 0, 0, 0])) -> Data {
        let channelIDs: [Int16] = [0, 1, 2, -1]

        var record = Data()
        record.appendI32(layerRect.top)
        record.appendI32(layerRect.left)
        record.appendI32(layerRect.bottom)
        record.appendI32(layerRect.right)
        record.appendU16(UInt16(channelIDs.count))
        for id in channelIDs {
            record.appendI16(id)
            record.appendU32(UInt32(2 + channelPayload.count))
        }
        record.appendFourCC("8BIM")
        record.appendFourCC("norm")
        record.appendU8(255)
        record.appendU8(0)
        record.appendU8(0)
        record.appendU8(0)
        var extra = Data()
        extra.appendU32(0)                        // no mask
        extra.appendU32(0)                        // no blending ranges
        extra.appendPascalString("Hostile", paddedToMultipleOf: 4)
        record.appendU32(UInt32(extra.count))
        record.append(extra)

        var layerInfo = Data()
        layerInfo.appendI16(1)
        layerInfo.append(record)
        for _ in channelIDs {
            layerInfo.appendU16(compression)
            layerInfo.append(channelPayload)
        }
        if layerInfo.count % 2 != 0 { layerInfo.appendU8(0) }

        var layerAndMask = Data()
        layerAndMask.appendU32(UInt32(layerInfo.count))
        layerAndMask.append(layerInfo)

        var out = Data()
        out.appendFourCC("8BPS")
        out.appendU16(1)
        out.append(Data(count: 6))
        out.appendU16(3)
        out.appendU32(UInt32(canvasHeight))
        out.appendU32(UInt32(canvasWidth))
        out.appendU16(8)
        out.appendU16(3)                          // RGB
        out.appendU32(0)                          // colour mode data
        out.appendU32(0)                          // image resources
        out.appendU32(UInt32(layerAndMask.count))
        out.append(layerAndMask)
        // A valid raw composite, so a file whose LAYER section is rejected
        // still has something for the fallback to open.
        out.appendU16(0)
        out.append(Data(repeating: 128, count: canvasWidth * canvasHeight * 3))
        return out
    }

    /// A layer rect far past what the app can represent used to size the
    /// interleave buffer directly: `width * height * 4 * sampleBytes` both
    /// overflows Int (a trap) and asks for tens of GB. The file must still
    /// open — via the composite — rather than taking the process down.
    func testOversizedLayerRectFallsBackToTheComposite() throws {
        let data = syntheticPSD(canvasWidth: 8, canvasHeight: 4,
                                layerRect: (top: 0, left: 0,
                                            bottom: 2_000_000, right: 2_000_000))
        let document = try PSDReader.document(from: data)
        XCTAssertEqual(document.canvasSize, CGSize(width: 8, height: 4))
        XCTAssertEqual(document.layers.count, 1, "composite fallback, not the bogus layer")
        XCTAssertEqual(document.layers.first?.source.width, 8)
    }

    /// `right < left` yields a negative width, which reaches allocations as a
    /// wrapped count. It has to fail the layer section rather than be skipped:
    /// channel data is positional, so dropping one record desyncs the rest.
    func testInvertedLayerRectFallsBackToTheComposite() throws {
        let data = syntheticPSD(canvasWidth: 8, canvasHeight: 4,
                                layerRect: (top: 4, left: 8, bottom: 0, right: 0))
        let document = try PSDReader.document(from: data)
        XCTAssertEqual(document.layers.count, 1)
        XCTAssertEqual(document.layers.first?.source.width, 8)
    }

    /// An unrecognised compression word used to fall through to `raw`, which
    /// then zero-padded whatever it found — wrong pixels, silently. It must
    /// route to the composite instead.
    func testUnknownCompressionFallsBackToTheComposite() throws {
        let data = syntheticPSD(canvasWidth: 8, canvasHeight: 4,
                                layerRect: (top: 0, left: 0, bottom: 4, right: 8),
                                compression: 99)
        let document = try PSDReader.document(from: data)
        XCTAssertEqual(document.layers.count, 1)
        XCTAssertEqual(document.layers.first?.source.width, 8)
    }

    /// A raw channel shorter than its rect claims is truncation; zero-padding
    /// it produced a plausible-looking layer from a damaged file.
    func testShortRawChannelFallsBackToTheComposite() throws {
        let data = syntheticPSD(canvasWidth: 8, canvasHeight: 4,
                                layerRect: (top: 0, left: 0, bottom: 4, right: 8),
                                channelPayload: Data([1, 2, 3]))  // needs 32
        let document = try PSDReader.document(from: data)
        XCTAssertEqual(document.layers.count, 1)
        XCTAssertEqual(document.layers.first?.source.width, 8)
    }

    /// Past the app's own canvas ceiling the hand-rolled path must not be
    /// sizing buffers at all — ImageIO decodes the composite instead, with its
    /// own memory management.
    func testCanvasPastTheAppLimitTakesTheCompositePath() throws {
        let width = DocumentStore.sizeLimits.upperBound + 1
        let data = syntheticPSD(canvasWidth: Int(width), canvasHeight: 2,
                                layerRect: (top: 0, left: 0, bottom: 2, right: Int32(width)))
        // ImageIO may or may not decode a composite this shape; what matters
        // is that the layer path declined it rather than trapping.
        _ = try? PSDReader.document(from: data)
    }

    // MARK: - Grayscale colour handling

    /// A grayscale PSD with an embedded gray profile, one 1x1 layer at
    /// `gray`, and that profile in image resource 1039.
    private func grayscalePSD(gray: UInt8, profile: CGColorSpace) throws -> Data {
        let iccData = try XCTUnwrap(profile.copyICCData() as Data?,
                                    "the test profile must be embeddable")
        var resources = Data()
        resources.appendFourCC("8BIM")
        resources.appendU16(1039)                 // ICC profile
        resources.appendU8(0)                     // empty Pascal name…
        resources.appendU8(0)                     // …padded to even
        resources.appendU32(UInt32(iccData.count))
        resources.append(iccData)
        if iccData.count % 2 != 0 { resources.appendU8(0) }

        let channels: [(id: Int16, data: Data)] = [(0, Data([gray])), (-1, Data([255]))]
        var record = Data()
        record.appendI32(0); record.appendI32(0)   // top, left
        record.appendI32(1); record.appendI32(1)   // bottom, right
        record.appendU16(UInt16(channels.count))
        for channel in channels {
            record.appendI16(channel.id)
            record.appendU32(UInt32(2 + channel.data.count))
        }
        record.appendFourCC("8BIM")
        record.appendFourCC("norm")
        record.appendU8(255); record.appendU8(0); record.appendU8(0); record.appendU8(0)
        var extra = Data()
        extra.appendU32(0)
        extra.appendU32(0)
        extra.appendPascalString("Gray", paddedToMultipleOf: 4)
        record.appendU32(UInt32(extra.count))
        record.append(extra)

        var layerInfo = Data()
        layerInfo.appendI16(1)
        layerInfo.append(record)
        for channel in channels {
            layerInfo.appendU16(0)                // raw
            layerInfo.append(channel.data)
        }
        if layerInfo.count % 2 != 0 { layerInfo.appendU8(0) }

        var layerAndMask = Data()
        layerAndMask.appendU32(UInt32(layerInfo.count))
        layerAndMask.append(layerInfo)

        var out = Data()
        out.appendFourCC("8BPS")
        out.appendU16(1)
        out.append(Data(count: 6))
        out.appendU16(1)                          // one composite channel
        out.appendU32(1)                          // height
        out.appendU32(1)                          // width
        out.appendU16(8)                          // depth
        out.appendU16(1)                          // Grayscale
        out.appendU32(0)                          // colour mode data
        out.appendU32(UInt32(resources.count))
        out.append(resources)
        out.appendU32(UInt32(layerAndMask.count))
        out.append(layerAndMask)
        out.appendU16(0)                          // composite: raw
        out.append(Data([gray]))
        return out
    }

    /// A grayscale sample is a tone value in the file's own transfer curve,
    /// not an RGB triple. Replicating it into R=G=B and tagging the result
    /// Display P3 asserts that the file's curve is P3's.
    ///
    /// Uses a LINEAR gray profile so the difference is unmistakable rather
    /// than a rounding artefact: mid-gray 128 is ~50% linear light, which in
    /// P3's (sRGB-like) encoding is ~188, not 128.
    func testGrayscalePSDIsConvertedThroughItsEmbeddedProfile() throws {
        let linearGray = try XCTUnwrap(CGColorSpace(calibratedGrayWhitePoint: [0.9505, 1.0, 1.089],
                                                    blackPoint: [0, 0, 0], gamma: 1.0))
        let document = try PSDReader.document(from: try grayscalePSD(gray: 128,
                                                                     profile: linearGray))
        let layer = try XCTUnwrap(document.layers.first)
        let pixels = try rawRGBA8(layer.source, in: BrushyColorSpace.displayP3)
        let value = Int(pixels[0, 0].r)

        XCTAssertEqual(Int(pixels[0, 0].g), value, "grayscale stays neutral")
        XCTAssertEqual(Int(pixels[0, 0].b), value, "grayscale stays neutral")
        XCTAssertGreaterThan(value, 165,
                             "linear 50% must encode well above 128 in P3 — got \(value), "
                             + "which is the raw sample passed through untouched")
    }

    /// The neutral axis has to survive: black stays black, white stays white,
    /// whatever the curve.
    func testGrayscaleEndpointsSurviveTheConversion() throws {
        let linearGray = try XCTUnwrap(CGColorSpace(calibratedGrayWhitePoint: [0.9505, 1.0, 1.089],
                                                    blackPoint: [0, 0, 0], gamma: 1.0))
        for (sample, expected) in [(UInt8(0), 0), (UInt8(255), 255)] {
            let document = try PSDReader.document(from: try grayscalePSD(gray: sample,
                                                                         profile: linearGray))
            let layer = try XCTUnwrap(document.layers.first)
            let pixels = try rawRGBA8(layer.source, in: BrushyColorSpace.displayP3)
            XCTAssertEqual(Int(pixels[0, 0].r), expected, accuracy: 2)
            XCTAssertEqual(Int(pixels[0, 0].a), 255, "alpha stays straight and opaque")
        }
    }

    /// A header past the PSD format's own maximum is not a document.
    func testAbsurdCanvasDimensionsAreRejected() {
        var out = Data()
        out.appendFourCC("8BPS")
        out.appendU16(1)
        out.append(Data(count: 6))
        out.appendU16(3)
        out.appendU32(1_000_000)                  // height
        out.appendU32(1_000_000)                  // width
        out.appendU16(8)
        out.appendU16(3)
        out.appendU32(0)
        out.appendU32(0)
        out.appendU32(0)
        XCTAssertThrowsError(try PSDReader.document(from: out))
    }
}

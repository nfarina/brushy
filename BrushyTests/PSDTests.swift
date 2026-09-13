import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// Minimal PSD reader for validating our writer — big-endian walk of the
/// header, layer records, and raw channel planes. Independent of the writer.
private struct MiniPSD {
    struct Layer {
        var top = 0, left = 0, bottom = 0, right = 0
        var channels: [(id: Int, length: Int)] = []
        var opacity = 0
        var blendKey = ""
        var clipping = 0
        var flags = 0
        var name = ""
        var hasMask = false
        var maskDisabled = false
        /// Channel id → raw plane bytes.
        var planes: [Int: [UInt8]] = [:]
        /// Adobe `lsct` section type when present: 1 open folder, 2 closed
        /// folder, 3 bounding divider; nil for ordinary layers.
        var sectionType: Int?
        /// The blend key inside the `lsct` block (12-byte form), e.g. "pass".
        var sectionBlendKey: String?

        var width: Int { right - left }
        var height: Int { bottom - top }
    }

    var width = 0
    var height = 0
    var compositeChannels = 0
    var layers: [Layer] = []

    init(data: Data) throws {
        var offset = 0
        func u8() -> Int { defer { offset += 1 }; return Int(data[offset]) }
        func u16() -> Int { (u8() << 8) | u8() }
        func u32() -> Int { (u16() << 16) | u16() }
        func i16() -> Int { let v = u16(); return v >= 0x8000 ? v - 0x10000 : v }
        func i32() -> Int { let v = u32(); return v >= 0x8000_0000 ? v - 0x1_0000_0000 : v }
        func fourCC() -> String {
            let bytes = data[offset..<offset + 4]; offset += 4
            return String(bytes: bytes, encoding: .ascii) ?? "????"
        }
        func bytes(_ count: Int) -> [UInt8] {
            defer { offset += count }
            return [UInt8](data[offset..<offset + count])
        }

        guard fourCC() == "8BPS", u16() == 1 else {
            throw NSError(domain: "MiniPSD", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad signature"])
        }
        offset += 6
        compositeChannels = u16()
        height = u32()
        width = u32()
        _ = u16() // depth
        _ = u16() // mode
        offset += u32() // colour mode data
        offset += u32() // image resources
        _ = u32() // layer-and-mask total length
        _ = u32() // layer info length
        let count = abs(i16())

        for _ in 0..<count {
            var layer = Layer()
            layer.top = i32(); layer.left = i32()
            layer.bottom = i32(); layer.right = i32()
            let channelCount = u16()
            for _ in 0..<channelCount {
                let id = i16()
                let length = u32()
                layer.channels.append((id, length))
            }
            _ = fourCC() // 8BIM
            layer.blendKey = fourCC()
            layer.opacity = u8()
            layer.clipping = u8()
            layer.flags = u8()
            _ = u8() // filler
            let extraLength = u32()
            let extraEnd = offset + extraLength
            let maskLength = u32()
            if maskLength > 0 {
                _ = i32(); _ = i32(); _ = i32(); _ = i32()
                _ = u8() // default colour
                let maskFlags = u8()
                layer.hasMask = true
                layer.maskDisabled = maskFlags & 2 != 0
                offset += maskLength - 18
            }
            offset += u32() // blending ranges
            let nameLength = u8()
            layer.name = String(bytes: bytes(nameLength), encoding: .utf8) ?? ""
            var consumed = 1 + nameLength
            while consumed % 4 != 0 { _ = u8(); consumed += 1 }
            // Additional info blocks: {8BIM, key, length, payload} with the
            // payload padded to even length. Capture `lsct` (group section
            // dividers); skip everything else (luni etc.).
            while offset + 12 <= extraEnd {
                guard fourCC() == "8BIM" else { break }
                let key = fourCC()
                let length = u32()
                let payloadEnd = offset + length + (length % 2)
                if key == "lsct", length >= 4 {
                    layer.sectionType = u32()
                    if length >= 12 {
                        _ = fourCC() // 8BIM
                        layer.sectionBlendKey = fourCC()
                    }
                }
                offset = payloadEnd
            }
            offset = extraEnd
            layers.append(layer)
        }

        // Channel image data, in record order.
        for index in layers.indices {
            for (id, length) in layers[index].channels {
                let compression = u16()
                guard compression == 0 else {
                    throw NSError(domain: "MiniPSD", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "expected raw channels"])
                }
                layers[index].planes[id] = bytes(length - 2)
            }
        }
    }
}

final class PSDTests: XCTestCase {
    private func makeDocument() -> Document {
        var document = Document(canvasSize: CGSize(width: 320, height: 240))
        let p3 = BrushyColorSpace.displayP3
        var background = Layer(name: "Background",
                               source: GeneratedImages.solid(width: 320, height: 240,
                                                             r: 255, g: 255, b: 255,
                                                             colorSpace: p3))
        _ = background
        var red = Layer(name: "Red Box",
                        source: GeneratedImages.solid(width: 100, height: 80,
                                                      r: 255, g: 0, b: 0, colorSpace: p3),
                        transform: CGAffineTransform(translationX: 40, y: 30))
        red.opacity = 0.6
        // Multiply by white is identity, so the composite spot-checks below
        // hold with either blend implementation — this exercises the key
        // write, not the arithmetic (BlendClippingTests covers that).
        red.blendMode = .multiply
        var masked = Layer(name: "Masked Ünïcode",
                           source: GeneratedImages.solid(width: 80, height: 60,
                                                         r: 0, g: 0, b: 255, colorSpace: p3),
                           transform: CGAffineTransform(translationX: 180, y: 120))
        masked.isClippedToBelow = true
        var maskTexture = MaskTexture(width: 80, height: 60, fill: 255)
        maskTexture.mutate { data in
            for row in 0..<60 where row < 30 {
                for col in 0..<80 { data[row * 80 + col] = 0 } // hide the top half
            }
        }
        masked.mask = Mask(texture: maskTexture, isEnabled: true)
        var hidden = Layer(name: "Hidden",
                           source: GeneratedImages.solid(width: 50, height: 50,
                                                         r: 0, g: 255, b: 0, colorSpace: p3))
        hidden.isVisible = false
        document.layers = [background, red, masked, hidden]
        return document
    }

    func testPSDStructureAndPixels() throws {
        let document = makeDocument()
        let data = try PSDWriter.data(for: document, profile: BrushyColorSpace.sRGB)
        let psd = try MiniPSD(data: data)

        XCTAssertEqual(psd.width, 320)
        XCTAssertEqual(psd.height, 240)
        XCTAssertEqual(psd.compositeChannels, 3)
        XCTAssertEqual(psd.layers.count, 4)

        let background = psd.layers[0]
        XCTAssertEqual(background.name, "Background")
        XCTAssertEqual((background.top, background.left, background.bottom, background.right).0, 0)
        XCTAssertEqual(background.width, 320)
        XCTAssertEqual(background.height, 240)

        // Layer rects are y-flipped into PSD's top-down space:
        // red box canvas y-up (40,30,100,80) → top = 240−110 = 130.
        let red = psd.layers[1]
        XCTAssertEqual(red.name, "Red Box")
        XCTAssertEqual(red.left, 40)
        XCTAssertEqual(red.top, 130)
        XCTAssertEqual(red.width, 100)
        XCTAssertEqual(red.height, 80)
        XCTAssertEqual(red.opacity, 153, "60% opacity → 153/255")
        XCTAssertEqual(red.channels.count, 4)
        // sRGB-exported red stays pure; alpha is opaque; centre spot checks.
        let redCenter = (red.height / 2) * red.width + red.width / 2
        XCTAssertGreaterThan(red.planes[0]![redCenter], 250)
        XCTAssertLessThan(red.planes[1]![redCenter], 8)
        XCTAssertEqual(red.planes[-1]![redCenter], 255)

        XCTAssertEqual(background.blendKey, "norm")
        XCTAssertEqual(background.clipping, 0)
        XCTAssertEqual(red.blendKey, "mul ", "multiply → Adobe key 'mul '")
        XCTAssertEqual(red.clipping, 0)

        let masked = psd.layers[2]
        XCTAssertTrue(masked.hasMask)
        XCTAssertFalse(masked.maskDisabled)
        XCTAssertEqual(masked.channels.count, 5)
        XCTAssertEqual(masked.blendKey, "norm")
        XCTAssertEqual(masked.clipping, 1, "clipped layer must carry the non-base clipping byte")
        let maskPlane = masked.planes[-2]!
        // Mask top half hidden: PSD rows are top-down, so row 0 is black.
        XCTAssertEqual(maskPlane[masked.width / 2], 0)
        XCTAssertEqual(maskPlane[(masked.height - 1) * masked.width + masked.width / 2], 255)

        let hiddenLayer = psd.layers[3]
        XCTAssertEqual(hiddenLayer.flags & 2, 2, "hidden layer must carry the hidden flag")
        XCTAssertEqual(psd.layers[1].flags & 2, 0)
    }

    /// Spot-checks Adobe's documented 4CC blend keys across the mode groups
    /// (including the space-padded ones).
    func testPSDBlendModeKeys() throws {
        let p3 = BrushyColorSpace.displayP3
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        let modes: [BlendMode] = [.screen, .softLight, .luminosity, .colorDodge]
        document.layers = modes.enumerated().map { index, mode in
            var layer = Layer(name: "M\(index)",
                              source: GeneratedImages.solid(width: 32, height: 32,
                                                            r: 200, g: 100, b: 50, colorSpace: p3))
            layer.blendMode = mode
            return layer
        }
        let data = try PSDWriter.data(for: document, profile: BrushyColorSpace.sRGB)
        let psd = try MiniPSD(data: data)
        XCTAssertEqual(psd.layers.map(\.blendKey), ["scrn", "sLit", "lum ", "div "])
    }

    /// The unicode name survives via the `luni` block; the Pascal name is the
    /// ASCII-lossy fallback. We validate by scanning for the block bytes.
    func testPSDUnicodeNameBlockPresent() throws {
        let document = makeDocument()
        let data = try PSDWriter.data(for: document, profile: BrushyColorSpace.sRGB)
        let marker = Data("luni".utf8)
        XCTAssertNotNil(data.range(of: marker), "luni unicode-name blocks must be present")
        let utf16Name = Data(Array("Masked Ünïcode".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        XCTAssertNotNil(data.range(of: utf16Name), "unicode layer name must round-trip in UTF-16BE")
    }

    // MARK: - Layer groups (lsct section dividers)

    /// Groups export as Adobe's folder structure: records run bottom-to-top,
    /// so each group is a hidden "</Layer group>" bounding divider (type 3)
    /// below its members and a folder record (type 1 open / 2 closed) above
    /// them, nesting recursively. The folder record carries the group's
    /// name, opacity, visibility and blend key — `pass` for Pass Through.
    func testPSDGroupsEmitSectionDividerPairs() throws {
        let p3 = BrushyColorSpace.displayP3
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        func solid(_ name: String) -> Layer {
            Layer(name: name, source: GeneratedImages.solid(width: 16, height: 16,
                                                            r: 90, g: 90, b: 90, colorSpace: p3))
        }
        var outer = LayerGroup(name: "Outer")
        outer.isExpanded = false      // → closed folder (type 2)
        outer.isVisible = false       // → hidden flag on the folder record
        var inner = LayerGroup(name: "Inner", parentID: outer.id)
        inner.blendMode = .multiply   // isolated → 'mul ' on the folder record
        inner.opacity = 0.8
        document.groups = [outer, inner]
        var a = solid("a"); a.groupID = outer.id
        var b = solid("b"); b.groupID = inner.id
        document.layers = [solid("bg"), a, b, solid("top")]

        let data = try PSDWriter.data(for: document, profile: BrushyColorSpace.sRGB)
        let psd = try MiniPSD(data: data)

        XCTAssertEqual(psd.layers.map(\.name),
                       ["bg",
                        "</Layer group>", "a",
                        "</Layer group>", "b", "Inner",
                        "Outer",
                        "top"],
                       "bottom-to-top: divider below members, folder above, nested pairs inside")
        XCTAssertEqual(psd.layers.map(\.sectionType),
                       [nil, 3, nil, 3, nil, 1, 2, nil])

        let innerFolder = psd.layers[5]
        XCTAssertEqual(innerFolder.blendKey, "mul ", "isolated group blend key on the record")
        XCTAssertEqual(innerFolder.sectionBlendKey, "mul ")
        XCTAssertEqual(innerFolder.opacity, 204, "80% group opacity → 204/255")
        XCTAssertEqual(innerFolder.flags & 2, 0)

        let outerFolder = psd.layers[6]
        XCTAssertEqual(outerFolder.blendKey, "pass", "Pass Through folders write Adobe's 'pass'")
        XCTAssertEqual(outerFolder.sectionBlendKey, "pass")
        XCTAssertEqual(outerFolder.flags & 2, 2, "a hidden group's folder carries the hidden flag")

        // Divider/folder records are zero-pixel: 4 channels, each raw+empty.
        for record in [psd.layers[1], psd.layers[3], psd.layers[5], psd.layers[6]] {
            XCTAssertEqual(record.width, 0)
            XCTAssertEqual(record.height, 0)
            XCTAssertEqual(record.channels.count, 4)
            XCTAssertTrue(record.channels.allSatisfy { $0.length == 2 })
        }
    }

    /// A document without groups emits no dividers — the existing positional
    /// expectations elsewhere in this suite depend on it.
    func testPSDGroupFreeDocumentHasNoSectionBlocks() throws {
        let data = try PSDWriter.data(for: makeDocument(), profile: BrushyColorSpace.sRGB)
        let psd = try MiniPSD(data: data)
        XCTAssertEqual(psd.layers.count, 4)
        XCTAssertTrue(psd.layers.allSatisfy { $0.sectionType == nil })
        XCTAssertNil(data.range(of: Data("lsct".utf8)))
    }

    /// ImageIO must still decode the flattened composite with divider
    /// records present.
    func testPSDWithGroupsOpensViaImageIO() throws {
        let p3 = BrushyColorSpace.displayP3
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        let group = LayerGroup(name: "G")
        document.groups = [group]
        var member = Layer(name: "m", source: GeneratedImages.solid(width: 64, height: 64,
                                                                    r: 255, g: 0, b: 0,
                                                                    colorSpace: p3))
        member.groupID = group.id
        document.layers = [member]
        let data = try PSDWriter.data(for: document, profile: BrushyColorSpace.sRGB)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("ImageIO could not decode the grouped PSD")
            return
        }
        XCTAssertEqual(image.width, 64)
        let pixels = try rawRGBA8(image, in: BrushyColorSpace.sRGB)
        XCTAssertGreaterThan(pixels[32, 32].r, 200, "the grouped member renders in the composite")
    }

    /// macOS's own ImageIO must decode the composite (what Preview/Quick Look
    /// show) at the right size.
    func testPSDCompositeOpensViaImageIO() throws {
        let document = makeDocument()
        let data = try PSDWriter.data(for: document, profile: BrushyColorSpace.sRGB)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("ImageIO could not decode the exported PSD")
            return
        }
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 240)
        // The composite must be the SAME PICTURE the app shows, flattened over
        // white — that is what "Preview opens it and it looks right" means, and
        // it is the only claim about the pixels this test can safely make.
        //
        // An absolute value cannot be: the exact grey of a 60%-opacity multiply
        // over white depends on whether Core Image evaluates the blend through
        // its gamma sandwich or takes the source-over fallback, and which one a
        // given process gets has been observed to differ between a full-suite
        // run and this suite alone (~165 vs ~87). Pinning a number here made
        // the test fail in whichever environment it was not written in;
        // comparing against the app's own render is stable in both and is the
        // stronger statement anyway.
        let pixels = try rawRGBA8(image, in: BrushyColorSpace.sRGB)
        let center = pixels[90, 240 - 70] // canvas (90, 70) y-up → row 170
        let expected = try flattenedOverWhite(document, at: CGPoint(x: 90, y: 70))
        XCTAssertGreaterThan(center.r, 240, "the red box is in the composite")
        XCTAssertLessThan(Int(center.g), 230, "and it tints what is under it")
        XCTAssertEqual(Double(center.g), Double(expected.g), accuracy: 6,
                       "the exported composite must match what the app renders")
        XCTAssertEqual(Double(center.b), Double(expected.b), accuracy: 6)
    }

    /// The app's own composite of `document` flattened over white, read at a
    /// canvas-space point — the reference the exported composite is held to.
    private func flattenedOverWhite(_ document: Document,
                                    at point: CGPoint) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let engine = RenderEngine.shared
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1,
                                           colorSpace: BrushyColorSpace.sRGB)!)
            .cropped(to: document.canvasRect)
        let flattened = engine.compositeImage(for: document).composited(over: white)
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        let cg = try XCTUnwrap(engine.context.createCGImage(flattened, from: rect,
                                                            format: .RGBA8,
                                                            colorSpace: BrushyColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: BrushyColorSpace.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        return (bytes[0], bytes[1], bytes[2])
    }
}

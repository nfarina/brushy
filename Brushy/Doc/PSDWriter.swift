import Accelerate
import CoreGraphics
import CoreImage
import Foundation

/// Write-only layered PSD export (big-endian PSD v1, RGB 8-bit).
///
/// Scope matches the document model: each layer exports as a raster with its
/// transform baked into pixels (PSD layers carry no affine transforms),
/// straight-alpha RGBA channels, layer mask, name (Pascal + Unicode), opacity,
/// visibility, blend mode (Adobe's 4CC keys via `BlendMode.psdKey`) and the
/// clipping byte (1 for clipped layers). Channel data is uncompressed
/// (compression 0): bigger files, far smaller bug surface. A flattened
/// composite over white is written for viewers, and the export ICC profile is
/// embedded. Layer effects travel as Adobe `lfx2` descriptors (`PSDEffects`),
/// so Photoshop opens them as live, editable layer styles — the baked channel
/// data deliberately excludes them, the same separation Photoshop's own files
/// keep. Reading is `PSDReader`.
///
/// Layer groups export as Adobe's `lsct` section dividers so Photoshop opens
/// real folders: records run bottom-to-top, so each group emits a hidden
/// "</Layer group>" bounding divider (type 3) BELOW its members and a folder
/// record (type 1 open / 2 closed, carrying the group's name, opacity,
/// visibility and blend key — `pass` for Pass Through) ABOVE them; nesting
/// recurses through `Document.stackNodes()`, the same tree the renderer
/// composites.
enum PSDWriteError: LocalizedError {
    case canvasTooLarge
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .canvasTooLarge:
            return "PSD (version 1) supports up to 30,000×30,000 pixels."
        case .renderFailed(let name):
            return "Could not render “\(name)” for PSD export."
        }
    }
}

enum PSDWriter {
    static func data(for document: Document, profile: CGColorSpace) throws -> Data {
        let width = max(1, Int(document.canvasSize.width))
        let height = max(1, Int(document.canvasSize.height))
        guard width <= 30000, height <= 30000 else { throw PSDWriteError.canvasTooLarge }

        var out = Data()
        // ---- Header
        out.appendFourCC("8BPS")
        out.appendU16(1)                       // version
        out.append(Data(count: 6))             // reserved
        out.appendU16(3)                       // composite channel count (RGB)
        out.appendU32(UInt32(height))
        out.appendU32(UInt32(width))
        out.appendU16(8)                       // bits per channel
        out.appendU16(3)                       // colour mode: RGB

        // ---- Colour mode data (empty for RGB)
        out.appendU32(0)

        // ---- Image resources: embedded ICC profile (1039)
        var resources = Data()
        if let icc = profile.copyICCData() as Data? {
            resources.appendFourCC("8BIM")
            resources.appendU16(1039)
            resources.append(contentsOf: [0, 0]) // empty Pascal name, padded
            resources.appendU32(UInt32(icc.count))
            resources.append(icc)
            if icc.count % 2 != 0 { resources.appendU8(0) }
        }
        out.appendU32(UInt32(resources.count))
        out.append(resources)

        // ---- Layer and mask information
        // Records run bottom-to-top; groups wrap their members in a bounding
        // divider (below) and a folder record (above), recursively.
        var baked: [BakedLayer] = []
        func emit(_ nodes: [StackNode]) throws {
            for node in nodes {
                switch node {
                case .layer(let layer):
                    baked.append(try bake(layer, profile: profile, canvasHeight: height))
                case .group(let group, let children):
                    baked.append(sectionDivider())
                    try emit(children)
                    baked.append(folderRecord(for: group))
                }
            }
        }
        try emit(document.stackNodes())
        var layerInfo = Data()
        layerInfo.appendI16(Int16(baked.count))
        for layer in baked { layerInfo.append(layerRecord(for: layer)) }
        for layer in baked { layerInfo.append(channelData(for: layer)) }
        if layerInfo.count % 2 != 0 { layerInfo.appendU8(0) }

        var layerAndMask = Data()
        layerAndMask.appendU32(UInt32(layerInfo.count))
        layerAndMask.append(layerInfo)
        layerAndMask.appendU32(0)              // global layer mask info: none
        out.appendU32(UInt32(layerAndMask.count))
        out.append(layerAndMask)

        // ---- Composite image data (flattened over white, planar, raw)
        guard let composite = RenderEngine.shared.renderFlattened(
            document: document, profile: profile, sixteenBit: false, matteWhite: true),
              let planes = rgbaPlanes(of: composite, unpremultiply: false) else {
            throw PSDWriteError.renderFailed("composite")
        }
        out.appendU16(0)                       // compression: raw
        out.append(contentsOf: planes[0])
        out.append(contentsOf: planes[1])
        out.append(contentsOf: planes[2])
        return out
    }

    // MARK: - Layer baking

    private struct BakedLayer {
        var top: Int, left: Int, bottom: Int, right: Int
        /// R, G, B, A — straight alpha, rows top-down.
        var planes: [[UInt8]]
        var mask: (bytes: [UInt8], disabled: Bool)? // same rect as the layer
        var name: String
        var opacity: UInt8
        var hidden: Bool
        var blendKey: String
        var clipped: Bool
        /// The layer's style as Adobe's `lfx2` payload, so Photoshop opens it
        /// as live, editable effects rather than baked pixels (`PSDEffects`).
        var effects: Data?
        /// `lsct` section type for group records: 1 open folder, 2 closed
        /// folder, 3 bounding divider; nil for ordinary layers.
        var section: UInt32?
    }

    /// Pass Through — a group-only blend key; layers have no such mode.
    private static let passThroughKey = "pass"

    /// The hidden "</Layer group>" record marking a group's bottom boundary
    /// (records run bottom-to-top). Zero-pixel: four raw channels of length 0.
    private static func sectionDivider() -> BakedLayer {
        BakedLayer(top: 0, left: 0, bottom: 0, right: 0,
                   planes: [[], [], [], []], mask: nil,
                   name: "</Layer group>", opacity: 255, hidden: false,
                   blendKey: BlendMode.normal.psdKey, clipped: false,
                   section: 3)
    }

    /// The folder record above a group's members, carrying the group's
    /// user-facing state. Disclosure maps to open/closed folder types.
    private static func folderRecord(for group: LayerGroup) -> BakedLayer {
        BakedLayer(top: 0, left: 0, bottom: 0, right: 0,
                   planes: [[], [], [], []], mask: nil,
                   name: group.name,
                   opacity: UInt8((CGFloat(group.opacity) * 255).rounded()),
                   hidden: !group.isVisible,
                   blendKey: group.blendMode?.psdKey ?? passThroughKey,
                   clipped: false,
                   section: group.isExpanded ? 1 : 2)
    }

    private static func bake(_ layer: Layer, profile: CGColorSpace,
                             canvasHeight: Int) throws -> BakedLayer {
        let engine = RenderEngine.shared
        var bounds = layer.canvasBounds.integral
        if bounds.width < 1 || bounds.height < 1 || bounds.isNull {
            bounds = CGRect(x: bounds.isNull ? 0 : bounds.minX,
                            y: bounds.isNull ? 0 : bounds.minY, width: 1, height: 1)
        }
        // `bounds` is the layer's transform applied to its source rect, so a
        // document that reached us with a wild transform lands here as a
        // non-finite or astronomically large rect — and every conversion
        // below traps rather than throwing. Readers sanitise on the way in;
        // this is the backstop for a layer built some other way.
        guard bounds.isFinite,
              bounds.width <= Document.canvasSizeLimits.upperBound * 4,
              bounds.height <= Document.canvasSizeLimits.upperBound * 4 else {
            throw PSDWriteError.renderFailed(layer.name)
        }
        let transformed = RenderEngine.resampled(engine.ciImage(forSource: layer.source),
                                                 by: layer.transform)
        guard let cgImage = engine.context.createCGImage(transformed, from: bounds,
                                                         format: .RGBA8, colorSpace: profile),
              let planes = rgbaPlanes(of: cgImage, unpremultiply: true) else {
            throw PSDWriteError.renderFailed(layer.name)
        }

        var maskBytes: (bytes: [UInt8], disabled: Bool)?
        if let mask = layer.mask {
            let maskCI = RenderEngine.resampled(engine.ciImage(forMask: mask.texture),
                                                by: layer.transform)
            var bytes = [UInt8](repeating: 0, count: Int(bounds.width * bounds.height))
            bytes.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                engine.context.render(maskCI, toBitmap: base,
                                      rowBytes: Int(bounds.width), bounds: bounds,
                                      format: .L8, colorSpace: nil)
            }
            maskBytes = (bytes, !mask.isEnabled)
        }

        // Canvas is y-up; PSD rects are top-down from the canvas top.
        return BakedLayer(top: canvasHeight - Int(bounds.maxY),
                          left: Int(bounds.minX),
                          bottom: canvasHeight - Int(bounds.minY),
                          right: Int(bounds.maxX),
                          planes: planes,
                          mask: maskBytes,
                          name: layer.name,
                          opacity: UInt8((CGFloat(layer.opacity) * 255).rounded()),
                          hidden: !layer.isVisible,
                          blendKey: layer.blendMode.psdKey,
                          clipped: layer.isClippedToBelow,
                          effects: PSDEffects.lfx2Payload(for: layer.effects))
    }

    /// Splits RGBA8 into straight-alpha planes (rows top-down).
    private static func rgbaPlanes(of image: CGImage, unpremultiply: Bool) -> [[UInt8]]? {
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: image.colorSpace ?? BrushyColorSpace.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var red = [UInt8](repeating: 0, count: width * height)
        var green = red, blue = red, alpha = red
        let error: vImage_Error = rgba.withUnsafeMutableBytes { src in
            red.withUnsafeMutableBytes { p0 in
                green.withUnsafeMutableBytes { p1 in
                    blue.withUnsafeMutableBytes { p2 in
                        alpha.withUnsafeMutableBytes { p3 in
                            var srcBuf = vImage_Buffer(data: src.baseAddress,
                                                       height: vImagePixelCount(height),
                                                       width: vImagePixelCount(width),
                                                       rowBytes: width * 4)
                            if unpremultiply {
                                let err = vImageUnpremultiplyData_RGBA8888(
                                    &srcBuf, &srcBuf, vImage_Flags(kvImageNoFlags))
                                guard err == kvImageNoError else { return err }
                            }
                            func plane(_ raw: UnsafeMutableRawBufferPointer) -> vImage_Buffer {
                                vImage_Buffer(data: raw.baseAddress,
                                              height: vImagePixelCount(height),
                                              width: vImagePixelCount(width),
                                              rowBytes: width)
                            }
                            var d0 = plane(p0); var d1 = plane(p1)
                            var d2 = plane(p2); var d3 = plane(p3)
                            return vImageConvert_ARGB8888toPlanar8(
                                &srcBuf, &d0, &d1, &d2, &d3, vImage_Flags(kvImageNoFlags))
                        }
                    }
                }
            }
        }
        guard error == kvImageNoError else { return nil }
        return [red, green, blue, alpha]
    }

    // MARK: - Record & channel encoding

    private static func layerRecord(for layer: BakedLayer) -> Data {
        var record = Data()
        record.appendI32(Int32(layer.top))
        record.appendI32(Int32(layer.left))
        record.appendI32(Int32(layer.bottom))
        record.appendI32(Int32(layer.right))

        let channelIDs: [Int16] = layer.mask == nil ? [0, 1, 2, -1] : [0, 1, 2, -1, -2]
        record.appendU16(UInt16(channelIDs.count))
        let pixelCount = layer.planes.first?.count ?? 0 // 0 for group records
        for id in channelIDs {
            record.appendI16(id)
            let length = id == -2 ? (layer.mask?.bytes.count ?? 0) : pixelCount
            record.appendU32(UInt32(2 + length)) // includes the compression marker
        }

        record.appendFourCC("8BIM")
        record.appendFourCC(layer.blendKey)            // Adobe 4CC blend key
        record.appendU8(layer.opacity)
        record.appendU8(layer.clipped ? 1 : 0)         // clipping: 0 base, 1 non-base
        record.appendU8(layer.hidden ? 2 : 0)          // flags: bit 1 = hidden
        record.appendU8(0)                             // filler

        var extra = Data()
        if let mask = layer.mask {
            extra.appendU32(20)
            extra.appendI32(Int32(layer.top))
            extra.appendI32(Int32(layer.left))
            extra.appendI32(Int32(layer.bottom))
            extra.appendI32(Int32(layer.right))
            extra.appendU8(255)                        // default colour outside rect
            extra.appendU8(mask.disabled ? 2 : 0)      // flags: bit 1 = disabled
            extra.appendU16(0)                         // padding
        } else {
            extra.appendU32(0)
        }
        extra.appendU32(0)                             // blending ranges: none
        extra.appendPascalString(layer.name, paddedToMultipleOf: 4)
        extra.append(unicodeNameBlock(layer.name))
        if let effects = layer.effects {
            extra.append(infoBlock(key: "lfx2", content: effects))
        }
        if let section = layer.section {
            extra.append(sectionBlock(type: section, blendKey: layer.blendKey))
        }

        record.appendU32(UInt32(extra.count))
        record.append(extra)
        return record
    }

    /// An "additional layer information" block: 8BIM signature, 4CC key,
    /// length, payload, padded to even length.
    private static func infoBlock(key: String, content: Data) -> Data {
        var block = Data()
        block.appendFourCC("8BIM")
        block.appendFourCC(key)
        block.appendU32(UInt32(content.count))
        block.append(content)
        if content.count % 2 != 0 { block.appendU8(0) }
        return block
    }

    private static func unicodeNameBlock(_ name: String) -> Data {
        var content = Data()
        let units = Array(name.utf16)
        content.appendU32(UInt32(units.count))
        for unit in units { content.appendU16(unit) }
        return infoBlock(key: "luni", content: content)
    }

    /// Adobe's section-divider block ("lsct"): the 12-byte form — type plus
    /// a signed blend key — which Photoshop writes for folders.
    private static func sectionBlock(type: UInt32, blendKey: String) -> Data {
        var content = Data()
        content.appendU32(type)
        content.appendFourCC("8BIM")
        content.appendFourCC(blendKey)
        return infoBlock(key: "lsct", content: content)
    }

    private static func channelData(for layer: BakedLayer) -> Data {
        var data = Data()
        for plane in layer.planes {
            data.appendU16(0) // raw
            data.append(contentsOf: plane)
        }
        if let mask = layer.mask {
            data.appendU16(0)
            data.append(contentsOf: mask.bytes)
        }
        return data
    }
}

// MARK: - Big-endian writing helpers

extension Data {
    mutating func appendU8(_ value: UInt8) { append(value) }

    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value & 0xFF))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8(value >> 24)); append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF)); append(UInt8(value & 0xFF))
    }

    mutating func appendI16(_ value: Int16) { appendU16(UInt16(bitPattern: value)) }
    mutating func appendI32(_ value: Int32) { appendU32(UInt32(bitPattern: value)) }

    mutating func appendFourCC(_ code: String) {
        append(contentsOf: Array(code.utf8).prefix(4))
    }

    /// Pascal string (length byte + bytes), zero-padded so the total length is
    /// a multiple of `multiple`. Non-ASCII goes to the `luni` block instead.
    mutating func appendPascalString(_ string: String, paddedToMultipleOf multiple: Int) {
        let bytes = Array(string.prefix(255).utf8).prefix(255)
        appendU8(UInt8(bytes.count))
        append(contentsOf: bytes)
        var total = 1 + bytes.count
        while total % multiple != 0 {
            appendU8(0)
            total += 1
        }
    }
}

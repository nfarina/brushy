import CoreGraphics
import Foundation
import ImageIO

/// Layered PSD reading(; listed reading `.psd` as out of
/// scope and).
///
/// What comes across: every raster layer's pixels, position, name (Unicode
/// where present), opacity, visibility, blend mode, clipping flag, user layer
/// mask, folder structure (Adobe's `lsct` section dividers, nested), the
/// document's embedded ICC profile, and layer effects (`lfx2` — see
/// `PSDEffects`). 8- and 16-bit RGB and grayscale documents, RAW / RLE / ZIP
/// channel data.
///
/// What doesn't, and why: a PSD carries pixels for raster layers only, so
/// adjustment layers (which have none) are skipped; smart objects, text and
/// shape layers arrive as the rasterized pixels Photoshop stored for them,
/// losing their editability. Anything this reader can't take apart — CMYK,
/// Lab, indexed or 32-bit documents, `.psb` — falls back to the flattened
/// composite as a single layer rather than failing the open, which is the
/// same picture the Finder preview shows.
///
/// The inverse direction lives in `PSDWriter`; `PSDTests` round-trips the two
/// against each other and cross-checks the composite against ImageIO.
enum PSDReader {
    /// Bounds on what this reader will take apart by hand.
    ///
    /// Every dimension below comes from the file as a raw `u32`/`Int32`, so
    /// without these the products that size buffers both overflow `Int` (a
    /// trap, not an error) and request tens of GB from a payload of a few
    /// hundred bytes. The app is a registered Finder handler for `.psd`, so
    /// that is reachable by double-clicking a file.
    enum Limits {
        /// The largest canvas the hand-rolled layer path will touch. Matches
        /// `DocumentStore.sizeLimits`' upper bound — a document past it can't
        /// be represented anyway. Bigger files still OPEN: `canReadLayers`
        /// sends them to the composite fallback, where ImageIO does the
        /// decoding and its own memory management.
        static let maxDimension = 16_384

        /// PSD's own format ceiling (`.psb` goes further and is rejected as an
        /// unsupported version). Past this the header is not plausible.
        static let maxCanvasDimension = 30_000

        /// The layer count is an `Int16`, so this only rules out the absurd.
        static let maxLayerCount = 4_096

        /// Total decoded channel bytes for one document. The bomb shape is
        /// many modest layers as readily as one huge one, so the budget is
        /// per-document rather than per-layer. Generous enough that no real
        /// file trips it: a full 16384² 16-bit RGBA layer is ~2 GB.
        static let maxTotalPlaneBytes = 4 << 30
    }

    /// Running total of decoded channel bytes, threaded through the channel
    /// decoder so the budget above is enforced across the whole document.
    private struct DecodeBudget {
        private var spent = 0

        mutating func charge(_ bytes: Int) throws {
            let (total, overflow) = spent.addingReportingOverflow(bytes)
            guard !overflow, total <= Limits.maxTotalPlaneBytes else {
                throw PSDReadError.unsupportedLayout(
                    "layer data exceeds the \(Limits.maxTotalPlaneBytes >> 20) MB decode budget")
            }
            spent = total
        }
    }

    /// Product of `values`, or nil if it overflows. Layer rects are
    /// attacker-controlled `Int32`s, so `width * height * channels * depth`
    /// genuinely wraps at the top of the range — and a wrapped `Int` reaching
    /// an allocation traps rather than throwing.
    private static func product(_ values: Int...) -> Int? {
        var result = 1
        for value in values {
            guard value >= 0 else { return nil }
            let (next, overflow) = result.multipliedReportingOverflow(by: value)
            guard !overflow else { return nil }
            result = next
        }
        return result
    }

    static func document(at url: URL) throws -> Document {
        try document(from: try Data(contentsOf: url, options: .mappedIfSafe),
                     fallbackName: url.deletingPathExtension().lastPathComponent)
    }

    static func document(from data: Data, fallbackName: String = "Background") throws -> Document {
        let header = try Header(reading: data)
        var reader = PSDByteReader(data, offset: Header.byteLength)

        // Colour mode data (indexed palettes, duotone curves) — skipped.
        let colorModeLength = Int(try reader.u32())
        try reader.skip(colorModeLength)

        // Image resources: the embedded ICC profile (id 1039) is the one thing
        // worth having, since it tags every layer's pixels.
        let resourcesLength = Int(try reader.u32())
        let resources = try reader.bytes(resourcesLength)
        let profile = iccProfile(inResources: resources)

        guard header.canReadLayers else {
            return try compositeDocument(from: data, name: fallbackName, header: header)
        }

        let layerAndMaskLength = Int(try reader.u32())
        let layerAndMask = try reader.bytes(layerAndMaskLength)
        let records = (try? layerRecords(in: layerAndMask, header: header)) ?? []
        let document = try assemble(records: records, header: header, profile: profile)
        // A PSD saved without a layer section (flattened, or "maximize
        // compatibility" only) still has its composite.
        guard !document.layers.isEmpty else {
            return try compositeDocument(from: data, name: fallbackName, header: header)
        }
        return document
    }

    // MARK: - Header

    private struct Header {
        static let byteLength = 26

        var channels: Int
        var width: Int
        var height: Int
        var depth: Int
        var colorMode: Int

        init(reading data: Data) throws {
            var reader = PSDByteReader(data)
            guard (try? reader.fourCC()) == "8BPS" else { throw PSDReadError.notAPSD }
            let version = Int(try reader.u16())
            guard version == 1 else { throw PSDReadError.unsupportedVersion(version) }
            try reader.skip(6)
            channels = Int(try reader.u16())
            height = Int(try reader.u32())
            width = Int(try reader.u32())
            depth = Int(try reader.u16())
            colorMode = Int(try reader.u16())
            guard width > 0, height > 0 else {
                throw PSDReadError.unsupportedLayout("zero-sized canvas")
            }
            guard width <= Limits.maxCanvasDimension, height <= Limits.maxCanvasDimension else {
                throw PSDReadError.unsupportedLayout(
                    "canvas \(width)×\(height) exceeds the PSD format maximum")
            }
        }

        /// RGB (3) and Grayscale (1) at 8 or 16 bits are the shapes this
        /// reader takes apart channel by channel; everything else routes to
        /// the composite fallback — including anything past `maxDimension`,
        /// which the app could not represent as a canvas anyway and which the
        /// hand-rolled decoder should not be sizing buffers from.
        var canReadLayers: Bool {
            (colorMode == 3 || colorMode == 1) && (depth == 8 || depth == 16)
                && width <= Limits.maxDimension && height <= Limits.maxDimension
        }

        var isGrayscale: Bool { colorMode == 1 }
        var bytesPerSample: Int { depth / 8 }
    }

    private static func iccProfile(inResources resources: Data) -> CGColorSpace? {
        var reader = PSDByteReader(resources)
        while reader.remaining > 12 {
            guard let signature = try? reader.fourCC(), signature == "8BIM",
                  let id = try? reader.u16() else { return nil }
            // Pascal name padded to even length.
            guard let nameLength = try? reader.u8() else { return nil }
            let namePadding = Int(nameLength) + 1
            try? reader.skip(namePadding % 2 == 0 ? Int(nameLength) : Int(nameLength) + 1)
            guard let size = try? reader.u32() else { return nil }
            let padded = Int(size) + (size % 2 == 0 ? 0 : 1)
            guard let payload = try? reader.bytes(Int(size)) else { return nil }
            try? reader.skip(padded - Int(size))
            if id == 1039 {
                return CGColorSpace(iccData: payload as CFData)
            }
        }
        return nil
    }

    // MARK: - Layer records

    private struct ChannelInfo {
        var id: Int
        var byteLength: Int
    }

    private struct MaskInfo {
        var top = 0, left = 0, bottom = 0, right = 0
        var defaultColor: UInt8 = 0
        var disabled = false
        var width: Int { right - left }
        var height: Int { bottom - top }
    }

    private struct LayerRecord {
        var top = 0, left = 0, bottom = 0, right = 0
        var channels: [ChannelInfo] = []
        var blendKey = "norm"
        var opacity: UInt8 = 255
        var clipping = false
        var hidden = false
        var name = ""
        var mask: MaskInfo?
        /// `lsct` section type: 1 open folder, 2 closed folder, 3 bounding
        /// divider. Nil for ordinary layers.
        var sectionType: Int?
        var sectionBlendKey: String?
        var effects: LayerEffects?
        /// Channel id → decoded samples, rows top-down.
        var planes: [Int: [UInt8]] = [:]

        var width: Int { right - left }
        var height: Int { bottom - top }
        var isDivider: Bool { sectionType != nil }
    }

    /// Walks the layer-and-mask section. For 16-bit documents Photoshop puts
    /// the whole layer section inside an `Lr16` additional block and leaves
    /// the normal layer info empty, so both places are tried.
    private static func layerRecords(in section: Data, header: Header) throws -> [LayerRecord] {
        var reader = PSDByteReader(section)
        let layerInfoLength = Int(try reader.u32())
        if layerInfoLength > 0 {
            let info = try reader.bytes(layerInfoLength)
            return try parseLayerInfo(info, header: header)
        }
        // Global layer mask info, then additional blocks.
        let globalMaskLength = Int(try reader.u32())
        try reader.skip(globalMaskLength)
        while reader.remaining > 12 {
            let signature = try reader.fourCC()
            guard signature == "8BIM" || signature == "8B64" else { break }
            let key = try reader.fourCC()
            let length = Int(try reader.u32())
            let payload = try reader.bytes(length)
            if length % 2 != 0 { try? reader.skip(1) }
            if key == "Lr16" || key == "Lr32" {
                return try parseLayerInfo(payload, header: header)
            }
        }
        return []
    }

    private static func parseLayerInfo(_ info: Data, header: Header) throws -> [LayerRecord] {
        var reader = PSDByteReader(info)
        let rawCount = Int(try reader.i16())
        // A negative count means the composite's first alpha channel is the
        // document's transparency; the magnitude is still the layer count.
        let count = abs(rawCount)
        guard count > 0 else { return [] }
        guard count <= Limits.maxLayerCount else {
            throw PSDReadError.unsupportedLayout("\(count) layers")
        }

        var records: [LayerRecord] = []
        records.reserveCapacity(count)
        for _ in 0..<count {
            records.append(try parseLayerRecord(&reader))
        }
        // Channel data follows, in record order then channel order. The
        // budget spans the whole document, so many modest layers are bounded
        // the same way one huge layer is.
        var budget = DecodeBudget()
        for index in records.indices {
            for channel in records[index].channels {
                let plane = try decodeChannel(&reader, channel: channel,
                                              record: records[index], header: header,
                                              budget: &budget)
                records[index].planes[channel.id] = plane
            }
        }
        return records
    }

    private static func parseLayerRecord(_ reader: inout PSDByteReader) throws -> LayerRecord {
        var record = LayerRecord()
        record.top = Int(try reader.i32())
        record.left = Int(try reader.i32())
        record.bottom = Int(try reader.i32())
        record.right = Int(try reader.i32())
        // An empty rect is normal — adjustment layers and section dividers
        // have no pixels, and `assemble` skips them. An INVERTED or oversized
        // one is corruption, and it has to fail the layer section rather than
        // be skipped: the channel data that follows is positional, so
        // dropping a record here would desync every record after it. Failing
        // routes the whole file to the composite fallback, which is the
        // documented behaviour for anything this reader can't take apart.
        guard record.right >= record.left, record.bottom >= record.top else {
            throw PSDReadError.unsupportedLayout("inverted layer rectangle")
        }
        guard record.width <= Limits.maxDimension, record.height <= Limits.maxDimension else {
            throw PSDReadError.unsupportedLayout(
                "layer \(record.width)×\(record.height) exceeds \(Limits.maxDimension) px")
        }

        let channelCount = Int(try reader.u16())
        guard channelCount >= 0, channelCount < 64 else {
            throw PSDReadError.unsupportedLayout("\(channelCount) channels on one layer")
        }
        for _ in 0..<channelCount {
            let id = Int(try reader.i16())
            let length = Int(try reader.u32())
            record.channels.append(ChannelInfo(id: id, byteLength: length))
        }
        guard try reader.fourCC() == "8BIM" else {
            throw PSDReadError.truncated("layer blend signature")
        }
        record.blendKey = try reader.fourCC()
        record.opacity = try reader.u8()
        record.clipping = try reader.u8() != 0
        let flags = try reader.u8()
        record.hidden = flags & 0x02 != 0
        _ = try reader.u8()                       // filler

        let extraLength = Int(try reader.u32())
        let extra = try reader.bytes(extraLength)
        try parseExtra(extra, into: &record)
        return record
    }

    private static func parseExtra(_ extra: Data, into record: inout LayerRecord) throws {
        var reader = PSDByteReader(extra)
        let maskLength = Int(try reader.u32())
        if maskLength >= 18 {
            var mask = MaskInfo()
            mask.top = Int(try reader.i32())
            mask.left = Int(try reader.i32())
            mask.bottom = Int(try reader.i32())
            mask.right = Int(try reader.i32())
            mask.defaultColor = try reader.u8()
            let flags = try reader.u8()
            mask.disabled = flags & 0x02 != 0
            record.mask = mask
            try reader.skip(maskLength - 18)
        } else {
            try reader.skip(maskLength)
        }
        let blendingRangesLength = Int(try reader.u32())
        try reader.skip(blendingRangesLength)
        record.name = try reader.pascalString(padTo: 4)

        // Additional layer information: the Unicode name, the section
        // divider, the effect descriptor.
        while reader.remaining > 12 {
            let signature = try reader.fourCC()
            guard signature == "8BIM" || signature == "8B64" else { break }
            let key = try reader.fourCC()
            let length = Int(try reader.u32())
            let payload = try reader.bytes(length)
            if length % 2 != 0 { try? reader.skip(1) }
            switch key {
            case "luni":
                var block = PSDByteReader(payload)
                if let unicode = try? block.unicodeString(), !unicode.isEmpty {
                    record.name = unicode
                }
            case "lsct":
                var block = PSDByteReader(payload)
                record.sectionType = Int(try block.u32())
                if (try? block.fourCC()) == "8BIM" {
                    record.sectionBlendKey = try? block.fourCC()
                }
            case "lfx2":
                record.effects = try? PSDEffects.effects(fromLFX2: payload)
            default:
                break
            }
        }
    }

    // MARK: - Channel data

    /// One channel's samples, rows top-down, `width * bytesPerSample` per row.
    /// Mask channels (-2, -3) use the MASK rect's dimensions, not the layer's.
    private static func decodeChannel(_ reader: inout PSDByteReader, channel: ChannelInfo,
                                      record: LayerRecord, header: Header,
                                      budget: inout DecodeBudget) throws -> [UInt8] {
        let isMask = channel.id <= -2
        let width = isMask ? (record.mask?.width ?? 0) : record.width
        let height = isMask ? (record.mask?.height ?? 0) : record.height
        let payloadLength = max(0, channel.byteLength - 2)
        guard channel.byteLength >= 2 else { return [] }
        // An unrecognised scheme used to fall through to `.raw`, which then
        // zero-padded whatever it found — producing plausible-looking but
        // wrong pixels from a corrupt file, silently. Rejecting sends the
        // file to the composite fallback instead, where it is at least the
        // picture Photoshop stored.
        let rawCompression = try reader.u16()
        guard let compression = PSDCompression(rawValue: rawCompression) else {
            throw PSDReadError.unsupportedLayout("channel compression \(rawCompression)")
        }
        let payload = try reader.bytes(payloadLength)
        guard width > 0, height > 0 else { return [] }

        guard let bytesPerRow = product(width, header.bytesPerSample),
              let expected = product(bytesPerRow, height) else {
            throw PSDReadError.unsupportedLayout("channel dimensions overflow")
        }
        try budget.charge(expected)
        switch compression {
        case .raw:
            // Short means truncated, and used to be zero-padded into silence.
            // Trailing slack is tolerated — only the leading `expected` bytes
            // are the channel.
            guard payload.count >= expected else {
                throw PSDReadError.truncated(
                    "raw channel: \(payload.count) bytes, expected \(expected)")
            }
            return Array(payload.prefix(expected))
        case .rle:
            var table = PSDByteReader(payload)
            var rowByteCounts: [Int] = []
            rowByteCounts.reserveCapacity(height)
            for _ in 0..<height { rowByteCounts.append(Int(try table.u16())) }
            let body = payload.dropFirst(height * 2)
            return try PSDDecoder.unpackBits(Data(body), rowByteCounts: rowByteCounts,
                                             bytesPerRow: bytesPerRow)
        case .zip, .zipWithPrediction:
            // `inflate` allocates `expectedSize` up front, so this is where a
            // few hundred compressed bytes used to be able to ask for tens of
            // GB. `expected` is now bounded by the dimension caps and charged
            // against the document budget above.
            guard var bytes = PSDDecoder.inflate(payload, expectedSize: expected) else {
                throw PSDReadError.truncated("ZIP channel")
            }
            if compression == .zipWithPrediction && header.depth == 16 {
                PSDDecoder.undoPrediction16(&bytes, width: width, height: height)
            }
            return bytes
        }
    }

    // MARK: - Assembly

    /// Records arrive bottom-to-top, which is exactly `Document.layers`'
    /// order, so layers append as they come and the group runs stay
    /// contiguous by construction (the group invariant).
    private static func assemble(records: [LayerRecord], header: Header,
                                 profile: CGColorSpace?) throws -> Document {
        var document = Document(canvasSize: CGSize(width: header.width, height: header.height))
        let space = profile ?? BrushyColorSpace.sRGB

        /// One open group scope: the layers and child groups collected since
        /// its bounding divider.
        struct Frame {
            var layerIDs: [UUID] = []
            var childGroupIDs: [UUID] = []
        }
        var stack: [Frame] = []
        var groups: [LayerGroup] = []

        func attach(layerID: UUID) {
            if !stack.isEmpty { stack[stack.count - 1].layerIDs.append(layerID) }
        }

        for record in records {
            if let sectionType = record.sectionType {
                switch sectionType {
                case 3:
                    // "</Layer group>": the bottom boundary, so a new scope
                    // opens here and closes at its folder record above.
                    stack.append(Frame())
                case 1, 2:
                    let frame = stack.popLast() ?? Frame()
                    let key = record.sectionBlendKey ?? record.blendKey
                    let group = LayerGroup(
                        name: record.name.isEmpty ? "Group" : record.name,
                        isVisible: !record.hidden,
                        opacity: Float(record.opacity) / 255,
                        blendMode: key == BlendMode.psdPassThroughKey ? nil : BlendMode(psdKey: key),
                        isExpanded: sectionType == 1)
                    for id in frame.layerIDs {
                        if let index = document.layerIndex(of: id) {
                            document.layers[index].groupID = group.id
                        }
                    }
                    for childID in frame.childGroupIDs {
                        if let index = groups.firstIndex(where: { $0.id == childID }) {
                            groups[index].parentID = group.id
                        }
                    }
                    groups.append(group)
                    if !stack.isEmpty {
                        stack[stack.count - 1].childGroupIDs.append(group.id)
                    }
                default:
                    break
                }
                continue
            }
            // Adjustment layers and other pixel-free records have an empty
            // rect; there is nothing to import.
            guard record.width > 0, record.height > 0,
                  let layer = layer(from: record, header: header, space: space) else { continue }
            document.layers.append(layer)
            attach(layerID: layer.id)
        }
        document.groups = groups
        return document.normalizingGroups().normalizingClipping()
    }

    private static func layer(from record: LayerRecord, header: Header,
                              space: CGColorSpace) -> Layer? {
        guard let image = image(from: record, header: header, space: space) else { return nil }
        var layer = Layer(name: record.name.isEmpty ? "Layer" : record.name,
                          source: image,
                          // PSD rects are top-down from the canvas top; canvas
                          // space is y-up.
                          transform: CGAffineTransform(translationX: CGFloat(record.left),
                                                       y: CGFloat(header.height - record.bottom)),
                          opacity: Float(record.opacity) / 255,
                          isVisible: !record.hidden,
                          blendMode: BlendMode(psdKey: record.blendKey),
                          isClippedToBelow: record.clipping)
        if let mask = maskTexture(from: record) {
            layer.mask = Mask(texture: mask, isEnabled: !(record.mask?.disabled ?? false))
        }
        if let effects = record.effects {
            layer.effects = effects
        }
        return layer
    }

    /// Interleaves the channel planes into a straight-alpha CGImage. PSD
    /// stores unpremultiplied channels, and so does the image built here —
    /// the file's bytes survive the import untouched (the policy for
    /// imported sources), with Core Image premultiplying at render time.
    /// One grayscale plane, tone-mapped into Display P3 through the document's
    /// embedded gray profile, returned as three planes.
    ///
    /// ColorSync does the work: a single-channel image tagged with the file's
    /// own profile is drawn into an opaque P3 context, which applies the
    /// transfer curve the file actually specifies. Falls back to the generic
    /// gray space when the document carries no monochrome profile (an RGB
    /// profile on a grayscale document tells us nothing about its tone curve).
    private static func grayConvertedToRGB(_ samples: [UInt8], width: Int, height: Int,
                                           header: Header, space: CGColorSpace)
        -> (red: [UInt8], green: [UInt8], blue: [UInt8])? {
        let sampleBytes = header.bytesPerSample
        let graySpace = space.model == .monochrome ? space : BrushyColorSpace.gray
        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        if sampleBytes == 2 {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                                        | CGBitmapInfo.byteOrder16Big.rawValue)
        }
        guard let bytesPerRow = product(width, sampleBytes),
              let provider = CGDataProvider(data: Data(samples) as CFData),
              let grayImage = CGImage(width: width, height: height,
                                      bitsPerComponent: header.depth,
                                      bitsPerPixel: header.depth,
                                      bytesPerRow: bytesPerRow,
                                      space: graySpace, bitmapInfo: bitmapInfo,
                                      provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        // Opaque RGB destination: no alpha here, so nothing premultiplies and
        // the PSD's own alpha plane stays straight when it is reattached.
        let destinationInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            | (sampleBytes == 2 ? CGBitmapInfo.byteOrder16Big.rawValue : 0)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: header.depth,
                                      bytesPerRow: 0,
                                      space: BrushyColorSpace.displayP3,
                                      bitmapInfo: destinationInfo),
              let base = context.data else { return nil }
        context.interpolationQuality = .none
        context.draw(grayImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let rowBytes = context.bytesPerRow
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        guard let planeBytes = product(width, height, sampleBytes) else { return nil }
        var red = [UInt8](repeating: 0, count: planeBytes)
        var green = red, blue = red
        for row in 0..<height {
            let sourceRow = row * rowBytes
            let destinationRow = row * width * sampleBytes
            for column in 0..<width {
                let source = sourceRow + column * 4 * sampleBytes
                let destination = destinationRow + column * sampleBytes
                for byte in 0..<sampleBytes {
                    red[destination + byte] = bytes[source + byte]
                    green[destination + byte] = bytes[source + sampleBytes + byte]
                    blue[destination + byte] = bytes[source + 2 * sampleBytes + byte]
                }
            }
        }
        return (red, green, blue)
    }

    private static func image(from record: LayerRecord, header: Header,
                              space: CGColorSpace) -> CGImage? {
        let width = record.width, height = record.height
        let sampleBytes = header.bytesPerSample
        // `parseLayerRecord` bounds the rect, so these cannot overflow in
        // practice — checked anyway because the failure mode if that guard is
        // ever loosened is a trap on the allocation below, not a bad image.
        guard let pixelCount = product(width, height),
              let planeBytes = product(pixelCount, sampleBytes),
              let interleavedBytes = product(pixelCount, 4, sampleBytes),
              let bytesPerRow = product(width, 4, sampleBytes) else { return nil }
        guard pixelCount > 0 else { return nil }

        func plane(_ id: Int, fallback: UInt8) -> [UInt8] {
            let bytes = record.planes[id] ?? []
            if bytes.count >= planeBytes { return bytes }
            return bytes + [UInt8](repeating: fallback, count: planeBytes - bytes.count)
        }
        let alpha = record.planes[-1] != nil ? plane(-1, fallback: 255)
                                             : [UInt8](repeating: 255, count: planeBytes)

        // Grayscale documents: the single channel is NOT an RGB triple, it is
        // a tone value in the embedded gray profile's transfer curve.
        // Replicating it into R=G=B and tagging the result Display P3 asserts
        // that the file's curve is P3's, which it is not — "Gray Gamma 2.2" is
        // close enough to hide the bug, "Dot Gain 20%" is visibly wrong.
        //
        // Converting through ColorSync instead: build the real single-channel
        // image, let a P3 context do the tone mapping, then reunite it with
        // the alpha plane. Alpha stays STRAIGHT (the context is opaque RGB, so
        // nothing premultiplies), which is the policy for imported sources.
        let red: [UInt8], green: [UInt8], blue: [UInt8]
        if header.isGrayscale {
            guard let converted = grayConvertedToRGB(plane(0, fallback: 0),
                                                     width: width, height: height,
                                                     header: header, space: space) else {
                return nil
            }
            (red, green, blue) = converted
        } else {
            red = plane(0, fallback: 0)
            green = plane(1, fallback: 0)
            blue = plane(2, fallback: 0)
        }

        var interleaved = [UInt8](repeating: 0, count: interleavedBytes)
        for pixel in 0..<pixelCount {
            let source = pixel * sampleBytes
            let destination = pixel * 4 * sampleBytes
            for byte in 0..<sampleBytes {
                interleaved[destination + byte] = red[source + byte]
                interleaved[destination + sampleBytes + byte] = green[source + byte]
                interleaved[destination + 2 * sampleBytes + byte] = blue[source + byte]
                interleaved[destination + 3 * sampleBytes + byte] = alpha[source + byte]
            }
        }

        // Grayscale samples were converted into the working space above, so
        // they are genuinely P3 by this point rather than merely labelled it.
        let colorSpace = header.isGrayscale
            ? BrushyColorSpace.displayP3 : (space.model == .rgb ? space : BrushyColorSpace.sRGB)
        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        if sampleBytes == 2 {
            // PSD samples are big-endian; tagging them beats swapping them.
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue
                                        | CGBitmapInfo.byteOrder16Big.rawValue)
        }
        guard let provider = CGDataProvider(data: Data(interleaved) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: header.depth,
                       bitsPerPixel: header.depth * 4,
                       bytesPerRow: bytesPerRow,
                       space: colorSpace,
                       bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The user layer mask (channel −2), re-framed onto the layer's own grid:
    /// keeps masks at source resolution, while PSD gives the mask its own
    /// rect. Everything outside that rect takes the mask's default colour.
    /// Both buffers are row-0-at-top, so no flip.
    private static func maskTexture(from record: LayerRecord) -> MaskTexture? {
        guard let mask = record.mask, let samples = record.planes[-2], !samples.isEmpty,
              mask.width > 0, mask.height > 0 else { return nil }
        let width = record.width, height = record.height
        guard width > 0, height > 0 else { return nil }

        // 16-bit masks: take the high byte, which is what an 8-bit mask
        // texture can hold.
        let stride = samples.count >= mask.width * mask.height * 2 ? 2 : 1
        var buffer = Data(repeating: mask.defaultColor, count: width * height)
        buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for maskRow in 0..<mask.height {
                let layerRow = mask.top + maskRow - record.top
                guard layerRow >= 0, layerRow < height else { continue }
                for maskColumn in 0..<mask.width {
                    let layerColumn = mask.left + maskColumn - record.left
                    guard layerColumn >= 0, layerColumn < width else { continue }
                    let index = (maskRow * mask.width + maskColumn) * stride
                    guard index < samples.count else { continue }
                    base[layerRow * width + layerColumn] = samples[index]
                }
            }
        }
        return MaskTexture(width: width, height: height, data: buffer)
    }

    // MARK: - Composite fallback

    /// CMYK/Lab/indexed/32-bit documents and layer-free files: ImageIO decodes
    /// the flattened composite every PSD carries, and that becomes one layer.
    private static func compositeDocument(from data: Data, name: String,
                                          header: Header) throws -> Document {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw PSDReadError.unsupportedLayout("no readable composite")
        }
        let image = ImageImporter.normalize(decoded)
        var document = Document(canvasSize: CGSize(width: header.width, height: header.height))
        document.layers = [Layer(name: name, source: image)]
        return document
    }
}

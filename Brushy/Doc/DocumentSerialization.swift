import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// package format:
///   MyDoc.brushy/
///     document.json   — canvas size, colour space, layer metadata, transforms
///     sources/<sourceID>.png — original layer pixels, lossless, profile embedded
///     masks/<layerID>.png    — 8-bit grayscale
struct DocumentDTO: Codable {
    var version: Int = 1
    var canvasWidth: Double
    var canvasHeight: Double
    var colorSpace: String
    var layers: [LayerDTO]
    /// Optional for pre-guide documents (defaults to none on read); omitted
    /// when empty so older files round-trip byte-identically.
    var guides: [GuideDTO]?
    /// Optional for pre-group documents (defaults to none on read); omitted
    /// when empty so a document without groups is byte-identical to what an
    /// older build writes (and older builds simply ignore the key).
    var groups: [GroupDTO]?
}

/// A layer group. Field defaults are omitted on write,
/// following the blendMode/isClipped pattern; membership sits on LayerDTO
/// (`groupID`), parenting here (`parentID`). Dangling ids and any
/// contiguity damage from hand-edited files are repaired on read by
/// `normalizingGroups()`.
struct GroupDTO: Codable {
    var id: UUID
    var name: String
    /// Omitted when visible (the default).
    var isVisible: Bool?
    /// Omitted when 1.
    var opacity: Float?
    /// Omitted for Pass Through (the group default). An unrecognised token
    /// (from some future build) falls back to Pass Through.
    var blendMode: String?
    /// Omitted when expanded (the default).
    var isExpanded: Bool?
    /// Omitted at top level.
    var parentID: UUID?
}

struct GuideDTO: Codable {
    var id: UUID
    var axis: String
    var position: Double
}

struct LayerDTO: Codable {
    var id: UUID
    var sourceID: UUID
    var name: String
    var transform: [Double]
    var opacity: Float
    var isVisible: Bool
    var mask: MaskDTO?
    /// Optional for pre-brush documents (defaults to false on read).
    var isPaintable: Bool?
    /// Optional for pre-vector documents (raster when absent).
    var kind: LayerKind?
    /// Optional for pre-blend-mode documents (normal when absent); omitted
    /// when normal so older files round-trip byte-identically. An
    /// unrecognised token (from some future build) falls back to normal.
    var blendMode: String?
    /// Optional for pre-clipping documents (false when absent); omitted when
    /// false.
    var isClipped: Bool?
    /// Direct group membership; omitted for top-level
    /// layers, so group-free documents round-trip byte-identically.
    var groupID: UUID?
    /// Layer Style. Omitted when no effect is configured,
    /// so pre-effects documents round-trip byte-identically and older builds
    /// simply ignore the key. Effect parameters are canvas-space, like the
    /// model's.
    var effects: LayerEffects?
}

struct MaskDTO: Codable {
    var isEnabled: Bool
}

enum DocumentSerializationError: LocalizedError {
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .corrupt(let detail): return "The document could not be read: \(detail)"
        }
    }
}

/// One instance per NSDocument. PNG payloads are cached keyed on the immutable
/// source/mask identity, so autosaves only re-encode what actually changed.
final class DocumentSerializer {
    private var sourcePNGCache: [UUID: Data] = [:]
    private var maskPNGCache: [UUID: Data] = [:]

    // MARK: Write

    func fileWrapper(for document: Document) throws -> FileWrapper {
        let dto = DocumentDTO(
            canvasWidth: document.canvasSize.width,
            canvasHeight: document.canvasSize.height,
            colorSpace: document.workingSpace.rawValue,
            layers: document.layers.map { layer in
                LayerDTO(id: layer.id, sourceID: layer.sourceID, name: layer.name,
                         transform: layer.transform.asArray,
                         opacity: layer.opacity, isVisible: layer.isVisible,
                         mask: layer.mask.map { MaskDTO(isEnabled: $0.isEnabled) },
                         isPaintable: layer.isPaintable,
                         // Adjustments persist too, though they aren't vector:
                         // their spec IS the layer.
                         kind: layer.kind == .raster ? nil : layer.kind,
                         blendMode: layer.blendMode == .normal ? nil : layer.blendMode.rawValue,
                         isClipped: layer.isClippedToBelow ? true : nil,
                         groupID: layer.groupID,
                         effects: layer.effects.isEmpty ? nil : layer.effects)
            },
            guides: document.guides.isEmpty ? nil : document.guides.map {
                GuideDTO(id: $0.id, axis: $0.axis.rawValue, position: $0.position)
            },
            groups: document.groups.isEmpty ? nil : document.groups.map { group in
                GroupDTO(id: group.id, name: group.name,
                         isVisible: group.isVisible ? nil : false,
                         opacity: group.opacity == 1 ? nil : group.opacity,
                         blendMode: group.blendMode?.rawValue,
                         isExpanded: group.isExpanded ? nil : false,
                         parentID: group.parentID)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(dto)

        var sourceFiles: [String: FileWrapper] = [:]
        var maskFiles: [String: FileWrapper] = [:]
        var liveSourceIDs = Set<UUID>()
        var liveMaskIDs = Set<UUID>()

        for layer in document.layers {
            let sourceName = "\(layer.sourceID.uuidString).png"
            if sourceFiles[sourceName] == nil {
                guard let data = try sourcePNG(for: layer) else {
                    throw DocumentSerializationError.corrupt("could not encode layer “\(layer.name)”")
                }
                sourceFiles[sourceName] = FileWrapper(regularFileWithContents: data)
            }
            liveSourceIDs.insert(layer.sourceID)
            if let mask = layer.mask {
                guard let data = maskPNG(for: mask.texture) else {
                    throw DocumentSerializationError.corrupt("could not encode mask of “\(layer.name)”")
                }
                maskFiles["\(layer.id.uuidString).png"] = FileWrapper(regularFileWithContents: data)
                liveMaskIDs.insert(mask.texture.storageIdentity)
            }
        }
        sourcePNGCache = sourcePNGCache.filter { liveSourceIDs.contains($0.key) }
        maskPNGCache = maskPNGCache.filter { liveMaskIDs.contains($0.key) }

        var package: [String: FileWrapper] = [
            "document.json": FileWrapper(regularFileWithContents: json),
            "sources": FileWrapper(directoryWithFileWrappers: sourceFiles),
            "masks": FileWrapper(directoryWithFileWrappers: maskFiles),
        ]
        if let quickLook = Self.quickLookFiles(for: document) {
            package["QuickLook"] = FileWrapper(directoryWithFileWrappers: quickLook)
        }
        return FileWrapper(directoryWithFileWrappers: package)
    }

    // MARK: Quick Look

    /// Finder icons and space-bar previews with no extension at all: for a
    /// package type, Quick Look shows `QuickLook/Thumbnail.png` and
    /// `QuickLook/Preview.png` from inside the package (verified with
    /// qlmanage on macOS 27, 2026-09-13). Reading ignores the folder.
    /// Rendered fresh on every save from a downscaled composite, which costs
    /// a fraction of a full-size render.
    static let thumbnailMaxEdge: CGFloat = 512
    static let previewMaxEdge: CGFloat = 1600

    static func quickLookFiles(for document: Document) -> [String: FileWrapper]? {
        guard let thumbnail = quickLookImage(document, maxEdge: thumbnailMaxEdge).flatMap(encodePNG),
              let preview = quickLookImage(document, maxEdge: previewMaxEdge).flatMap(encodePNG) else {
            return nil
        }
        return ["Thumbnail.png": FileWrapper(regularFileWithContents: thumbnail),
                "Preview.png": FileWrapper(regularFileWithContents: preview)]
    }

    /// The flattened canvas, scaled to fit `maxEdge` (never enlarged).
    static func quickLookImage(_ document: Document, maxEdge: CGFloat) -> CGImage? {
        let size = document.canvasSize
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = min(1, maxEdge / max(size.width, size.height))
        let rect = CGRect(x: 0, y: 0,
                          width: max(1, (size.width * scale).rounded()),
                          height: max(1, (size.height * scale).rounded()))
        let engine = RenderEngine.shared
        let image = engine.compositeImage(for: document,
                                          outputTransform: CGAffineTransform(scaleX: scale, y: scale))
        return engine.context.createCGImage(image, from: rect, format: .RGBA8,
                                            colorSpace: BrushyColorSpace.displayP3)
    }

    private func sourcePNG(for layer: Layer) throws -> Data? {
        if let cached = sourcePNGCache[layer.sourceID] { return cached }
        guard let data = Self.encodePNG(layer.source) else { return nil }
        sourcePNGCache[layer.sourceID] = data
        return data
    }

    private func maskPNG(for texture: MaskTexture) -> Data? {
        let key = texture.storageIdentity
        if let cached = maskPNGCache[key] { return cached }
        guard let image = texture.cgImage, let data = Self.encodePNG(image) else { return nil }
        maskPNGCache[key] = data
        return data
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: Read

    func document(from wrapper: FileWrapper) throws -> Document {
        guard let json = wrapper.fileWrappers?["document.json"]?.regularFileContents else {
            throw DocumentSerializationError.corrupt("document.json is missing")
        }
        let dto: DocumentDTO
        do {
            dto = try JSONDecoder().decode(DocumentDTO.self, from: json)
        } catch {
            throw DocumentSerializationError.corrupt("document.json is invalid — \(error.localizedDescription)")
        }
        let sources = wrapper.fileWrappers?["sources"]?.fileWrappers ?? [:]
        let masks = wrapper.fileWrappers?["masks"]?.fileWrappers ?? [:]

        // Everything below this line came out of a JSON file, so none of it is
        // trustworthy: `document.json` is plain text inside a package a user
        // can edit, and a size of 1e300 or NaN reaches `Int(canvasSize.width)`
        // in the status bar and traps. Clamp at the boundary rather than
        // hardening every consumer.
        var document = Document(canvasSize: Document.clampedCanvasSize(
            CGSize(width: dto.canvasWidth, height: dto.canvasHeight)))
        document.workingSpace = WorkingColorSpace(rawValue: dto.colorSpace) ?? .displayP3
        // A document saved by an older build has no guides key → []. An
        // unrecognised axis (from some future build) drops that guide rather
        // than failing the whole document.
        document.guides = (dto.guides ?? []).compactMap { guideDTO in
            // A non-finite position would be drawn, snapped to, and written
            // back out; dropping the guide matches how an unrecognised axis
            // is already handled.
            guard guideDTO.position.isFinite else { return nil }
            return Guide.Axis(rawValue: guideDTO.axis).map {
                Guide(id: guideDTO.id, axis: $0, position: guideDTO.position)
            }
        }

        guard dto.layers.count <= ImageImporter.Limits.maxLayers else {
            throw DocumentSerializationError.corrupt("\(dto.layers.count) layers")
        }
        // One budget for the whole package: a document is as easily bombed
        // with a thousand modest PNGs as with one enormous one. Sources are
        // charged once each — `loadedSources` dedupes shared sources, and a
        // duplicated layer costs the pixels only once.
        var budget: ImageImporter.DecodeBudget? = ImageImporter.DecodeBudget()
        var loadedSources: [UUID: CGImage] = [:]
        for layerDTO in dto.layers {
            let image: CGImage
            if let cached = loadedSources[layerDTO.sourceID] {
                image = cached
            } else {
                let name = "\(layerDTO.sourceID.uuidString).png"
                guard let data = sources[name]?.regularFileContents,
                      let decoded = Self.decodePNG(data, budget: &budget) else {
                    throw DocumentSerializationError.corrupt(
                        "source image \(name) is missing, unreadable, or too large to decode")
                }
                image = ImageImporter.normalize(decoded)
                loadedSources[layerDTO.sourceID] = image
                sourcePNGCache[layerDTO.sourceID] = data
            }
            var layer = Layer(id: layerDTO.id, sourceID: layerDTO.sourceID,
                              name: layerDTO.name, source: image,
                              transform: CGAffineTransform(array: layerDTO.transform) ?? .identity)
            // Opacity multiplies alpha in a CIColorMatrix and drives the
            // layers panel's percentage; out of range it either blows out the
            // composite or traps on `Int(opacity * 100)`.
            layer.opacity = layerDTO.opacity.isFinite ? min(max(layerDTO.opacity, 0), 1) : 1
            layer.isVisible = layerDTO.isVisible
            layer.isPaintable = layerDTO.isPaintable ?? false
            layer.kind = layerDTO.kind ?? .raster
            layer.blendMode = layerDTO.blendMode.flatMap(BlendMode.init(rawValue:)) ?? .normal
            layer.isClippedToBelow = layerDTO.isClipped ?? false
            layer.groupID = layerDTO.groupID
            layer.effects = (layerDTO.effects ?? .none).sanitized()
            if let maskDTO = layerDTO.mask,
               let data = masks["\(layerDTO.id.uuidString).png"]?.regularFileContents,
               let texture = Self.decodeMask(data, budget: &budget),
               texture.width == image.width, texture.height == image.height {
                layer.mask = Mask(texture: texture, isEnabled: maskDTO.isEnabled)
                maskPNGCache[texture.storageIdentity] = data
            }
            document.layers.append(layer)
        }
        // A document saved by an older build has no groups key → []. An
        // unrecognised blend token degrades to Pass Through (the group
        // default), mirroring the layer blendMode rule.
        document.groups = (dto.groups ?? []).map { groupDTO in
            let opacity = groupDTO.opacity ?? 1
            return LayerGroup(id: groupDTO.id, name: groupDTO.name,
                       isVisible: groupDTO.isVisible ?? true,
                       opacity: opacity.isFinite ? min(max(opacity, 0), 1) : 1,
                       blendMode: groupDTO.blendMode.flatMap(BlendMode.init(rawValue:)),
                       isExpanded: groupDTO.isExpanded ?? true,
                       parentID: groupDTO.parentID)
        }
        // Group invariants first (dangling ids, contiguity, empty groups),
        // then clipping: a hand-edited or corrupt file must not smuggle
        // invalid state past the model invariants, and the clipping rule
        // depends on settled group membership.
        return document.normalizingGroups().normalizingClipping()
    }

    /// A `.brushy` package is a folder of PNGs the user can replace, so the
    /// bytes on disk say nothing about the size of the decode. `budget`, when
    /// supplied, is the enclosing document's running total.
    static func decodePNG(_ data: Data, budget: inout ImageImporter.DecodeBudget?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return ImageImporter.decodeBounded(source, budget: &budget)
    }

    static func decodePNG(_ data: Data) -> CGImage? {
        var none: ImageImporter.DecodeBudget?
        return decodePNG(data, budget: &none)
    }

    static func decodeMask(_ data: Data, budget: inout ImageImporter.DecodeBudget?) -> MaskTexture? {
        guard let image = decodePNG(data, budget: &budget) else { return nil }
        let width = image.width, height = image.height
        var buffer = Data(count: width * height)
        let ok = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: BrushyColorSpace.gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return MaskTexture(width: width, height: height, data: buffer)
    }

    static func decodeMask(_ data: Data) -> MaskTexture? {
        var none: ImageImporter.DecodeBudget?
        return decodeMask(data, budget: &none)
    }
}

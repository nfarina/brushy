import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Clipboard read/write for layers.
///
/// Every Copy writes two flavours of the same pasteboard item:
///  1. `com.nfarina.brushy.layer` — a JSON envelope reusing the `LayerDTO` shape
///     from DocumentSerialization plus PNG payloads, so a layer round-trips
///     between Brushy documents with transform, opacity, blend mode,
///     mask, vector kind and the source canvas size intact.
///  2. `public.png` + `public.tiff` — the rendered pixels, so a copy lands in
///     Preview, Slack, Figma, etc.
enum LayerPasteboard {
    static let layerType = NSPasteboard.PasteboardType("com.nfarina.brushy.layer")

    /// The private flavour. PNGs ride along base64-encoded inside the JSON —
    /// clipboard payloads are transient, so the encoding overhead is fine and
    /// the envelope stays one inspectable blob.
    struct ClipboardLayer: Codable {
        var version: Int = 1
        var layer: LayerDTO
        var canvasWidth: Double
        var canvasHeight: Double
        var sourcePNG: Data
        var maskPNG: Data?
    }

    enum PastePayload {
        case layer(ClipboardLayer)
        case image(CGImage)
        case urls([URL])
        case none
    }

    private static let urlOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// Anything pasteable on the board? Cheap — called from menu validation.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.types?.contains(layerType) == true { return true }
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: urlOptions) {
            return true
        }
        return pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    // MARK: Write

    /// Writes `layer` (already reduced to what Copy means — see
    /// `DocumentStore.copySelection`) with `renderedImage` as the public
    /// flavours. Returns false when nothing could be encoded.
    @discardableResult
    static func write(layer: Layer, canvasSize: CGSize, renderedImage: CGImage?,
                      to pasteboard: NSPasteboard) -> Bool {
        guard let sourcePNG = DocumentSerializer.encodePNG(layer.source) else { return false }
        let maskPNG = layer.mask.flatMap { $0.texture.cgImage }
            .flatMap(DocumentSerializer.encodePNG)
        if layer.mask != nil, maskPNG == nil { return false }
        // Blend mode and layer style travel with the layer — they are
        // properties OF it. The clipping flag and group membership
        // deliberately do not (isClipped: nil, groupID: nil): both are
        // relationships with the stack the layer is leaving, and a pasted
        // layer lands unclipped and ungrouped-from-source, like Photoshop's
        // paste (the landing spot decides any new membership).
        //
        // `effects` was previously omitted rather than excluded on purpose,
        // so Copy silently dropped the style. `LayerDTO.effects` was already
        // in the wire format, so filling it in is additive — an older build
        // reading this envelope just ignores the key.
        let dto = LayerDTO(id: layer.id, sourceID: layer.sourceID, name: layer.name,
                           transform: layer.transform.asArray,
                           opacity: layer.opacity, isVisible: layer.isVisible,
                           mask: layer.mask.map { MaskDTO(isEnabled: $0.isEnabled) },
                           isPaintable: layer.isPaintable,
                           kind: layer.kind.isVector ? layer.kind : nil,
                           blendMode: layer.blendMode == .normal ? nil : layer.blendMode.rawValue,
                           isClipped: nil,
                           groupID: nil,
                           effects: layer.effects.isEmpty ? nil : layer.effects)
        let envelope = ClipboardLayer(layer: dto,
                                      canvasWidth: canvasSize.width,
                                      canvasHeight: canvasSize.height,
                                      sourcePNG: sourcePNG, maskPNG: maskPNG)
        guard let json = try? JSONEncoder().encode(envelope) else { return false }

        let item = NSPasteboardItem()
        item.setData(json, forType: layerType)
        if let renderedImage {
            if let png = DocumentSerializer.encodePNG(renderedImage) {
                item.setData(png, forType: .png)
            }
            if let tiff = NSBitmapImageRep(cgImage: renderedImage).tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    // MARK: Read

    /// Paste priority: the private flavour, then image *files* (a Finder copy
    /// carries both a file URL and an icon bitmap — the file contents are what
    /// the user means), then raw image data (screenshots, browser copies).
    static func read(from pasteboard: NSPasteboard) -> PastePayload {
        if let data = pasteboard.data(forType: layerType),
           let envelope = try? JSONDecoder().decode(ClipboardLayer.self, from: data) {
            return .layer(envelope)
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: urlOptions) as? [URL],
           !urls.isEmpty {
            return .urls(urls)
        }
        if let image = imageFromData(on: pasteboard) {
            return .image(image)
        }
        return .none
    }

    /// Reconstructs a Layer from the envelope. The layer gets a fresh `id`;
    /// it keeps the envelope's `sourceID` — the pixels are the envelope's own
    /// PNG, so the id↔pixels pairing holds and repeated pastes
    /// dedupe their stored sources.
    static func layer(from envelope: ClipboardLayer) -> Layer? {
        guard let decoded = DocumentSerializer.decodePNG(envelope.sourcePNG) else { return nil }
        let image = ImageImporter.normalize(decoded)
        let dto = envelope.layer
        // The envelope is JSON on the general pasteboard, so any process on
        // the machine can put one there — it gets the same validation the
        // `.brushy` reader applies, for the same reasons.
        var layer = Layer(id: UUID(), sourceID: dto.sourceID, name: dto.name,
                          source: image,
                          transform: CGAffineTransform(array: dto.transform) ?? .identity,
                          opacity: dto.opacity.isFinite ? min(max(dto.opacity, 0), 1) : 1,
                          isVisible: true, mask: nil,
                          isPaintable: dto.isPaintable ?? false,
                          kind: dto.kind ?? .raster,
                          blendMode: dto.blendMode.flatMap(BlendMode.init(rawValue:)) ?? .normal,
                          isClippedToBelow: false,
                          groupID: nil,
                          effects: (dto.effects ?? .none).sanitized())
        if let maskDTO = dto.mask, let maskData = envelope.maskPNG,
           let texture = DocumentSerializer.decodeMask(maskData),
           texture.width == image.width, texture.height == image.height {
            layer.mask = Mask(texture: texture, isEnabled: maskDTO.isEnabled)
        }
        return layer
    }

    /// Decodes raw image data via ImageIO, baking in an embedded EXIF
    /// orientation; untagged data is assumed sRGB (via `normalize`).
    private static func imageFromData(on pasteboard: NSPasteboard) -> CGImage? {
        var candidates: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in pasteboard.types ?? []
        where !candidates.contains(type) && UTType(type.rawValue)?.conforms(to: .image) == true {
            candidates.append(type)
        }
        for type in candidates {
            // Bounded: the clipboard carries whatever any process on the
            // machine put there, and a compressed image says nothing about
            // the size of its decode.
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = ImageImporter.decodeBounded(source)
            else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
                .flatMap(CGImagePropertyOrientation.init) ?? .up
            return ImageImporter.normalize(image, orientation: orientation)
        }
        return nil
    }

    // MARK: Clipboard dimensions

    /// The pixel dimensions of whatever a paste would bring in — a copied
    /// layer's source canvas (so a paste lands in place), an image's pixel
    /// size (EXIF-rotation applied), or the first image file's size. Cheap:
    /// image data is probed through ImageIO properties without decoding
    /// pixels, and the layer envelope through a header-only Codable shape.
    /// Used by the New Document dialog to offer the clipboard's size,
    /// Photoshop-style.
    static func contentPixelSize(on pasteboard: NSPasteboard) -> CGSize? {
        if let data = pasteboard.data(forType: layerType),
           let header = try? JSONDecoder().decode(EnvelopeHeader.self, from: data),
           header.canvasWidth >= 1, header.canvasHeight >= 1 {
            return CGSize(width: header.canvasWidth, height: header.canvasHeight)
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: urlOptions) as? [URL],
           let url = urls.first,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            return pixelSize(of: source)
        }
        var candidates: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in pasteboard.types ?? []
        where !candidates.contains(type) && UTType(type.rawValue)?.conforms(to: .image) == true {
            candidates.append(type)
        }
        for type in candidates {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let size = pixelSize(of: source) else { continue }
            return size
        }
        return nil
    }

    /// Decodes only the envelope fields `contentPixelSize` needs — skipping
    /// the base64 PNG payloads entirely.
    private struct EnvelopeHeader: Codable {
        var canvasWidth: Double
        var canvasHeight: Double
    }

    /// Width/height from ImageIO properties (no pixel decode), swapped for
    /// the 90°-rotating EXIF orientations (5–8) so the offered size matches
    /// what `normalize` will actually produce.
    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 1, height >= 1 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let rotated = (5...8).contains(orientation)
        return rotated ? CGSize(width: height, height: width)
                       : CGSize(width: width, height: height)
    }
}

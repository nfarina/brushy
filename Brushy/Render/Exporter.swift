import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFileFormat: String, CaseIterable, Identifiable, Codable {
    case png
    case jpeg
    case tiff
    case psd

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .psd: return "PSD (layered)"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .psd: return "psd"
        }
    }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .psd:
            return UTType("com.adobe.photoshop-image")
                ?? UTType(filenameExtension: "psd")
                ?? .data
        }
    }

    var supportsSixteenBit: Bool { self == .png || self == .tiff }
    var isLayered: Bool { self == .psd }
}

struct ExportSettings {
    var format: ExportFileFormat = .png
    var sixteenBit = false
    /// 0…1, JPEG only.
    var jpegQuality: Double = 0.9
    var profile: ExportProfile = .sRGB
    /// Embed the ICC profile in the written file (Color pane default).
    /// Off strips it — a smaller file that any sane consumer will *assume* is
    /// sRGB, so it is only ever right when the profile is sRGB anyway. The
    /// pixels are converted to `profile` either way; this changes the tag, not
    /// the numbers.
    var embedProfile = true
}

enum ExportError: LocalizedError {
    case renderFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "Rendering the flattened image failed."
        case .encodeFailed: return "Encoding the exported file failed."
        }
    }
}

enum Exporter {
    static func export(document: Document, settings: ExportSettings, to url: URL) throws {
        if settings.format == .psd {
            let data = try PSDWriter.data(for: document,
                                          profile: settings.profile.cgColorSpace)
            try data.write(to: url, options: .atomic)
            return
        }
        var cgImage = try flattenedImage(document: document, settings: settings)
        // Not embedding = retag the (already converted) pixels as a device
        // space, which ImageIO writes without an ICC profile. If the retag
        // fails — 16-bit float layouts don't always accept it — embed rather
        // than silently exporting something else.
        if !settings.embedProfile,
           let untagged = cgImage.copy(colorSpace: CGColorSpaceCreateDeviceRGB()) {
            cgImage = untagged
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, settings.format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.encodeFailed
        }
        var properties: [CFString: Any] = [:]
        if settings.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.jpegQuality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodeFailed
        }
    }

    static func flattenedImage(document: Document, settings: ExportSettings) throws -> CGImage {
        let sixteenBit = settings.sixteenBit && settings.format.supportsSixteenBit
        guard let image = RenderEngine.shared.renderFlattened(
            document: document,
            profile: settings.profile.cgColorSpace,
            sixteenBit: sixteenBit,
            matteWhite: settings.format == .jpeg) else {
            throw ExportError.renderFailed
        }
        return image
    }
}

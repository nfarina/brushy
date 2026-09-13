import CoreGraphics

/// Colour management policy:
/// - working space: Display P3
/// - compositing: linear light (the render context's working space is
///   extended linear Display P3)
/// - untagged imports are assumed sRGB
/// - export converts to the chosen output profile and embeds it
enum BrushyColorSpace {
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let linearWorking = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let gray = CGColorSpaceCreateDeviceGray()
}

enum ExportProfile: String, CaseIterable, Identifiable, Codable {
    case sRGB
    case displayP3

    var id: String { rawValue }

    var cgColorSpace: CGColorSpace {
        switch self {
        case .sRGB: return BrushyColorSpace.sRGB
        case .displayP3: return BrushyColorSpace.displayP3
        }
    }

    var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        }
    }
}

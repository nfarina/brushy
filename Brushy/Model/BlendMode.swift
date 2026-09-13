import Foundation

/// Photoshop-style layer blend modes. Added on request — lists blend modes
/// as out of scope, and the owner explicitly lifted that exclusion.
///
/// The raw string is the `.brushy` JSON token; `.normal` is omitted on
/// write so pre-blend-mode documents round-trip byte-identically. The set is
/// the standard Photoshop modes that have exact Core Image equivalents,
/// grouped the way Photoshop's popup groups them (`uiGroups`).
///
/// Colour-space note (parity vs linear compositing): Photoshop applies
/// blend-mode arithmetic to gamma-encoded document-space values by default,
/// while this pipeline composites in linear light. `RenderEngine.blended`
/// reconciles the two — see the comment there.
enum BlendMode: String, Codable, CaseIterable, Equatable {
    case normal
    // Darken group
    case darken, multiply, colorBurn
    // Lighten group
    case lighten, screen, colorDodge
    // Contrast group
    case overlay, softLight, hardLight
    // Comparative group
    case difference, exclusion
    // Component group
    case hue, saturation, color, luminosity

    /// Photoshop's popup ordering and separator grouping.
    static let uiGroups: [[BlendMode]] = [
        [.normal],
        [.darken, .multiply, .colorBurn],
        [.lighten, .screen, .colorDodge],
        [.overlay, .softLight, .hardLight],
        [.difference, .exclusion],
        [.hue, .saturation, .color, .luminosity],
    ]

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .darken: return "Darken"
        case .multiply: return "Multiply"
        case .colorBurn: return "Color Burn"
        case .lighten: return "Lighten"
        case .screen: return "Screen"
        case .colorDodge: return "Color Dodge"
        case .overlay: return "Overlay"
        case .softLight: return "Soft Light"
        case .hardLight: return "Hard Light"
        case .difference: return "Difference"
        case .exclusion: return "Exclusion"
        case .hue: return "Hue"
        case .saturation: return "Saturation"
        case .color: return "Color"
        case .luminosity: return "Luminosity"
        }
    }

    /// The Core Image filter implementing this mode's blend function B(Cb, Cs)
    /// (the PDF/W3C compositing equations, which are also Photoshop's).
    /// `nil` for `.normal`, which stays on the source-over fast path.
    var ciFilterName: String? {
        switch self {
        case .normal: return nil
        case .darken: return "CIDarkenBlendMode"
        case .multiply: return "CIMultiplyBlendMode"
        case .colorBurn: return "CIColorBurnBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .colorDodge: return "CIColorDodgeBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .hardLight: return "CIHardLightBlendMode"
        case .difference: return "CIDifferenceBlendMode"
        case .exclusion: return "CIExclusionBlendMode"
        case .hue: return "CIHueBlendMode"
        case .saturation: return "CISaturationBlendMode"
        case .color: return "CIColorBlendMode"
        case .luminosity: return "CILuminosityBlendMode"
        }
    }

    /// Adobe's documented 4-character blend-mode key for the PSD layer record
    /// ("Layer records", Photoshop File Format spec). Keys shorter than four
    /// characters are space-padded in the spec and here.
    var psdKey: String {
        switch self {
        case .normal: return "norm"
        case .darken: return "dark"
        case .multiply: return "mul "
        case .colorBurn: return "idiv"
        case .lighten: return "lite"
        case .screen: return "scrn"
        case .colorDodge: return "div "
        case .overlay: return "over"
        case .softLight: return "sLit"
        case .hardLight: return "hLit"
        case .difference: return "diff"
        case .exclusion: return "smud"
        case .hue: return "hue "
        case .saturation: return "sat "
        case .color: return "colr"
        case .luminosity: return "lum "
        }
    }
}

import CoreGraphics
import Foundation

/// Colour as plain numbers so specs are Codable/Equatable (sRGB, straight).
struct ColorSpec: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(cgColor: CGColor) {
        let converted = cgColor.converted(to: DezzyColorSpace.sRGB,
                                          intent: .defaultIntent, options: nil) ?? cgColor
        let c = converted.components ?? [0, 0, 0, 1]
        if c.count >= 4 {
            self.init(r: c[0], g: c[1], b: c[2], a: c[3])
        } else if c.count >= 2 {
            self.init(r: c[0], g: c[0], b: c[0], a: c[1])
        } else {
            self.init(r: 0, g: 0, b: 0)
        }
    }

    static let black = ColorSpec(r: 0, g: 0, b: 0)
    static let white = ColorSpec(r: 1, g: 1, b: 1)
}

/// A live-editable text layer's parameters. The layer's `source` is a cached
/// rasterization; editing the spec re-renders it.
struct TextSpec: Codable, Equatable {
    var text: String = "Text"
    /// PostScript/family name; falls back to the system font if missing.
    var fontName: String = "Helvetica Neue"
    var fontSize: Double = 64
    var color: ColorSpec = .black
}

/// A live-editable shape layer's parameters, in the layer's own content space
/// (y-up, includes `padding` margins so strokes and arrowheads never clip).
struct ShapeSpec: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case rectangle
        case ellipse
        case line

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .rectangle: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .line: return "Line"
            }
        }
        var systemImage: String {
            switch self {
            case .rectangle: return "square"
            case .ellipse: return "circle"
            case .line: return "line.diagonal"
            }
        }
    }

    enum StrokeStyle: String, Codable, CaseIterable, Identifiable {
        case solid
        case dashed
        case dotted

        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    var kind: Kind = .rectangle
    /// Content-space size, padding included.
    var size: CGSize = CGSize(width: 100, height: 100)
    /// Line endpoints in content space (line kind only).
    var lineStart: CGPoint = .zero
    var lineEnd: CGPoint = .zero
    var fill: ColorSpec? = ColorSpec.white
    var stroke: ColorSpec? = ColorSpec.black
    var strokeWidth: Double = 4
    var strokeStyle: StrokeStyle = .solid
    var arrowStart = false
    var arrowEnd = false

    var arrowLength: Double {
        max(9, strokeWidth * 4.5)
    }

    /// Margin needed around the drawn geometry so strokes/arrowheads fit.
    var padding: Double {
        let strokePad = (stroke != nil) ? strokeWidth / 2 + 1 : 1
        let arrowPad = (kind == .line && (arrowStart || arrowEnd))
            ? arrowLength * 0.6 : 0
        return (strokePad + arrowPad).rounded(.up)
    }
}

/// What a layer *is*. Raster layers (imported photos, paint layers, merged
/// results) have no parametric payload; text/shape layers re-render their
/// source whenever the spec changes.
enum LayerKind: Codable, Equatable {
    case raster
    case text(TextSpec)
    case shape(ShapeSpec)
    /// A layer with no pixels that re-renders what is below it.
    case adjustment(AdjustmentSpec)

    /// Text and shapes re-rasterise from their spec. An adjustment has no
    /// rasterisation at all, so it is deliberately NOT vector by this test —
    /// which is what keeps `VectorRasterizer` and the shape/text tools away
    /// from it.
    var isVector: Bool {
        switch self {
        case .raster, .adjustment: return false
        case .text, .shape: return true
        }
    }

    var adjustmentSpec: AdjustmentSpec? {
        if case .adjustment(let spec) = self { return spec }
        return nil
    }

    var textSpec: TextSpec? {
        if case .text(let spec) = self { return spec }
        return nil
    }

    var shapeSpec: ShapeSpec? {
        if case .shape(let spec) = self { return spec }
        return nil
    }
}

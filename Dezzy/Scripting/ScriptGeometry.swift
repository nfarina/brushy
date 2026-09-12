import CoreGraphics
import Foundation

/// The scripting API speaks TOP-LEFT coordinates (y down, like CSS and every
/// screenshot a model has ever seen) while the model (§2) is y-up. This is
/// the one place that flips, so a script never sees canvas space.
///
/// Also home to the small parsers the API needs at its edge: colours as CSS
/// strings, blend modes as kebab-case names, canvas anchors as compass names.
enum ScriptGeometry {
    // MARK: - Coordinates

    /// Canvas (y-up) rect → top-left (y-down) rect.
    static func topLeft(_ rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: canvasHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// Top-left (y-down) rect → canvas (y-up) rect.
    static func canvas(_ rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: canvasHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// Top-left point → canvas point.
    static func canvas(_ point: CGPoint, canvasHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: canvasHeight - point.y)
    }

    /// Clockwise degrees in (-180, 180], the CSS `rotate()` convention: a
    /// y-up CCW rotation of θ reads as −θ clockwise. Flips make the
    /// decomposition ambiguous; this reports the angle of the transformed
    /// x axis, which is what a user eyeballing the layer would call it.
    static func rotationDegreesClockwise(of transform: CGAffineTransform) -> Double {
        let radians = atan2(Double(transform.b), Double(transform.a))
        var degrees = -radians * 180 / .pi
        if degrees <= -180 { degrees += 360 }
        if degrees > 180 { degrees -= 360 }
        // Squash float noise so an unrotated layer reports exactly 0.
        return (degrees * 1000).rounded() / 1000
    }

    /// A transform that maps a layer's source rect onto `frame` (canvas
    /// space) with no rotation: what "set the frame" means for a layer whose
    /// size is changing. Flips are dropped too — the frame is the truth.
    static func transform(fitting sourceSize: CGSize, to frame: CGRect) -> CGAffineTransform {
        let sx = sourceSize.width > 0 ? frame.width / sourceSize.width : 1
        let sy = sourceSize.height > 0 ? frame.height / sourceSize.height : 1
        return CGAffineTransform(scaleX: sx, y: sy)
            .concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))
    }

    /// Composes `about` (a linear map) around the layer's canvas-space centre.
    static func transform(_ transform: CGAffineTransform, sourceRect: CGRect,
                          aboutCenter about: CGAffineTransform) -> CGAffineTransform {
        let center = CGPoint(x: sourceRect.midX, y: sourceRect.midY).applying(transform)
        let around = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(about)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return transform.concatenating(around)
    }

    // MARK: - Anchors

    /// Canvas Size anchors by compass name → the unit y-up anchor
    /// `Document.resizingCanvas(to:anchor:)` takes.
    static func anchor(named name: String) throws -> CGPoint {
        switch name.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "center", "centre", "middle": return CGPoint(x: 0.5, y: 0.5)
        case "top": return CGPoint(x: 0.5, y: 1)
        case "bottom": return CGPoint(x: 0.5, y: 0)
        case "left": return CGPoint(x: 0, y: 0.5)
        case "right": return CGPoint(x: 1, y: 0.5)
        case "top-left", "topleft": return CGPoint(x: 0, y: 1)
        case "top-right", "topright": return CGPoint(x: 1, y: 1)
        case "bottom-left", "bottomleft": return CGPoint(x: 0, y: 0)
        case "bottom-right", "bottomright": return CGPoint(x: 1, y: 0)
        default:
            throw ScriptError("Unknown anchor \"\(name)\"; use center, top, bottom, left, right, top-left, top-right, bottom-left or bottom-right")
        }
    }

    // MARK: - Blend modes

    /// `colorBurn` ↔ `color-burn`.
    static func blendModeName(_ mode: BlendMode) -> String {
        var out = ""
        for ch in mode.rawValue {
            if ch.isUppercase { out += "-" + ch.lowercased() } else { out.append(ch) }
        }
        return out
    }

    static func blendMode(named name: String) throws -> BlendMode {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        if let mode = BlendMode.allCases.first(where: { blendModeName($0) == key }) {
            return mode
        }
        let names = BlendMode.allCases.map(blendModeName).joined(separator: ", ")
        throw ScriptError("Unknown blend mode \"\(name)\"; use one of \(names)")
    }

    // MARK: - Colours

    private static let namedColors: [String: ColorSpec] = [
        "black": ColorSpec(r: 0, g: 0, b: 0), "white": ColorSpec(r: 1, g: 1, b: 1),
        "red": ColorSpec(r: 1, g: 0, b: 0), "green": ColorSpec(r: 0, g: 0.5, b: 0),
        "lime": ColorSpec(r: 0, g: 1, b: 0), "blue": ColorSpec(r: 0, g: 0, b: 1),
        "yellow": ColorSpec(r: 1, g: 1, b: 0), "cyan": ColorSpec(r: 0, g: 1, b: 1),
        "aqua": ColorSpec(r: 0, g: 1, b: 1), "magenta": ColorSpec(r: 1, g: 0, b: 1),
        "fuchsia": ColorSpec(r: 1, g: 0, b: 1), "orange": ColorSpec(r: 1, g: 0.647, b: 0),
        "purple": ColorSpec(r: 0.5, g: 0, b: 0.5), "pink": ColorSpec(r: 1, g: 0.753, b: 0.796),
        "brown": ColorSpec(r: 0.647, g: 0.165, b: 0.165), "gray": ColorSpec(r: 0.5, g: 0.5, b: 0.5),
        "grey": ColorSpec(r: 0.5, g: 0.5, b: 0.5), "silver": ColorSpec(r: 0.753, g: 0.753, b: 0.753),
        "navy": ColorSpec(r: 0, g: 0, b: 0.5), "teal": ColorSpec(r: 0, g: 0.5, b: 0.5),
        "maroon": ColorSpec(r: 0.5, g: 0, b: 0), "olive": ColorSpec(r: 0.5, g: 0.5, b: 0),
        "transparent": ColorSpec(r: 0, g: 0, b: 0, a: 0),
    ]

    /// Accepts `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)`,
    /// `rgba(r, g, b, a)` (0–255 channels, 0–1 alpha), CSS colour names, or
    /// an object `{r, g, b, a}` with 0–1 channels. sRGB, straight alpha.
    static func color(from value: Any) throws -> ColorSpec {
        if let dict = value as? [String: Any] {
            func channel(_ key: String, _ fallback: Double) -> Double {
                (dict[key] as? NSNumber)?.doubleValue ?? fallback
            }
            return ColorSpec(r: channel("r", 0), g: channel("g", 0), b: channel("b", 0),
                             a: channel("a", 1))
        }
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else {
            throw ScriptError("Expected a colour like \"#ff8800\", \"rgb(255, 136, 0)\" or \"orange\"")
        }
        if let named = namedColors[string] { return named }
        if string.hasPrefix("#") {
            let hex = String(string.dropFirst())
            let digits: [Int] = try hex.map {
                guard let d = $0.hexDigitValue else { throw ScriptError("Bad hex colour \"\(string)\"") }
                return d
            }
            switch digits.count {
            case 3, 4:
                let c = digits.map { Double($0 * 17) / 255 }
                return ColorSpec(r: c[0], g: c[1], b: c[2], a: digits.count == 4 ? c[3] : 1)
            case 6, 8:
                var c: [Double] = []
                for i in stride(from: 0, to: digits.count, by: 2) {
                    c.append(Double(digits[i] * 16 + digits[i + 1]) / 255)
                }
                return ColorSpec(r: c[0], g: c[1], b: c[2], a: digits.count == 8 ? c[3] : 1)
            default:
                throw ScriptError("Bad hex colour \"\(string)\"; use #rgb, #rrggbb or #rrggbbaa")
            }
        }
        if string.hasPrefix("rgb") {
            guard let open = string.firstIndex(of: "("), let close = string.lastIndex(of: ")") else {
                throw ScriptError("Bad colour \"\(string)\"")
            }
            let parts = string[string.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3 || parts.count == 4 else {
                throw ScriptError("Bad colour \"\(string)\"; use rgb(r, g, b) or rgba(r, g, b, a)")
            }
            return ColorSpec(r: parts[0] / 255, g: parts[1] / 255, b: parts[2] / 255,
                             a: parts.count == 4 ? parts[3] : 1)
        }
        throw ScriptError("Unknown colour \"\(string)\"")
    }

    /// `#rrggbb`, or `#rrggbbaa` when not fully opaque — what state reports.
    static func css(_ color: ColorSpec) -> String {
        func hex(_ v: Double) -> String {
            String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded()))
        }
        let rgb = "#" + hex(color.r) + hex(color.g) + hex(color.b)
        return color.a >= 0.999 ? rgb : rgb + hex(color.a)
    }
}

/// A script-facing failure: the message is what the JavaScript exception
/// (and so the model) sees, so it should say what to do instead.
struct ScriptError: Error, CustomStringConvertible, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

import AppKit
import CoreText

/// Replays a recorded subset of the HTML Canvas 2D API into a layer's
/// pixels. The JavaScript side (`DrawingContext` in `ScriptPrelude`) records
/// every call as `[name, ...args]`; one `draw` op carries the whole list, so
/// a script can draw thousands of primitives for one round trip and one
/// undo step.
///
/// Coordinates are CANVAS pixels, top-left origin — the same space as every
/// other API coordinate — regardless of where the layer sits; anything
/// outside the layer's own pixels is clipped (the layer does not grow).
/// Paths and the transform follow Canvas semantics: the path is stored in
/// canvas space (points go through the current transform as they are
/// added), `save`/`restore` snapshot styles, transform and clip, and the
/// pen width is transformed at stroke time.
enum ScriptDrawing {
    /// The layer's pixels with the commands drawn over them (source-over),
    /// clipped to `coverage` (source space) when the selection has one.
    static func render(_ layer: Layer, commands: [[Any]], canvasHeight: CGFloat,
                       coverage: MaskTexture?) throws -> CGImage? {
        let width = layer.source.width, height = layer.source.height
        guard width >= 1, height >= 1, layer.transform.isInvertible,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: BrushyColorSpace.displayP3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(layer.source, in: layer.sourceRect)
        if let coverage, coverage.width == width, coverage.height == height, let mask = coverage.cgImage {
            ctx.clip(to: layer.sourceRect, mask: mask)
        }
        // Canvas (top-left, y down) → canvas (y up) → source pixels.
        ctx.concatenate(layer.transform.inverted())
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvasHeight))
        ctx.setLineWidth(1)
        var replayer = Replayer(ctx: ctx)
        for (n, command) in commands.enumerated() {
            do { try replayer.perform(command) } catch let error as ScriptError {
                throw ScriptError("draw command \(n + 1) (\(command.first ?? "?")): \(error.message)")
            }
        }
        return ctx.makeImage()
    }

    /// `measureText`: the advance width in canvas pixels for a CSS font.
    static func measureText(_ text: String, font css: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font(fromCSS: css)]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// A CSS font shorthand ("bold 24px Helvetica", "italic 300 12pt 'Avenir Next', sans-serif")
    /// as an NSFont. Anything unparseable falls back to the system font.
    static func font(fromCSS css: String) -> NSFont {
        var size: CGFloat = 10
        var bold = false, italic = false
        var family: String?
        let tokens = css.split(separator: " ").map(String.init)
        for (i, token) in tokens.enumerated() {
            let lower = token.lowercased()
            if let value = Self.length(lower) {
                size = value
                // The family is everything after the size, first of a comma list.
                let rest = tokens[(i + 1)...].joined(separator: " ")
                family = rest.split(separator: ",").first.map {
                    $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "'", with: "")
                }
                break
            }
            if lower == "bold" || lower == "bolder" || (Int(lower).map { $0 >= 600 } ?? false) { bold = true }
            if lower == "italic" || lower == "oblique" { italic = true }
        }
        let weight: NSFont.Weight = bold ? .bold : .regular
        var font: NSFont
        switch family?.lowercased() {
        case nil, "sans-serif", "system-ui", "-apple-system", "ui-sans-serif":
            font = NSFont.systemFont(ofSize: size, weight: weight)
        case "serif": font = NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        case "monospace", "ui-monospace": font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case "cursive": font = NSFont(name: "Snell Roundhand", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        default:
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            font = NSFontManager.shared.font(withFamily: family!, traits: traits, weight: bold ? 9 : 5, size: size)
                ?? NSFont(name: family!, size: size)
                ?? NSFont.systemFont(ofSize: size, weight: weight)
        }
        if bold, !NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if italic, !NSFontManager.shared.traits(of: font).contains(.italicFontMask) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private static func length(_ token: String) -> CGFloat? {
        for (suffix, factor) in [("px", 1.0), ("pt", 1.0), ("em", 16.0), ("rem", 16.0)] where token.hasSuffix(suffix) {
            // "24px/1.2" — a line-height after a slash is allowed by CSS.
            let number = token.dropLast(suffix.count).split(separator: "/").first.map(String.init) ?? ""
            if let value = Double(number) { return CGFloat(value * factor) }
        }
        return nil
    }

    // MARK: - Replay

    /// A fill or stroke style: a colour, or a gradient (drawn through a clip).
    enum Style {
        case color(CGColor)
        case gradient(Gradient)

        init(_ value: Any) throws {
            if let dict = value as? [String: Any], let kind = dict["kind"] as? String {
                self = .gradient(try Gradient(kind: kind, dict))
            } else {
                self = .color(try ScriptGeometry.color(from: value).cgColor)
            }
        }
    }

    struct Gradient {
        enum Kind { case linear, radial }
        let kind: Kind
        let start: CGPoint, end: CGPoint
        let startRadius: CGFloat, endRadius: CGFloat
        let gradient: CGGradient

        init(kind: String, _ dict: [String: Any]) throws {
            func n(_ key: String) -> CGFloat { CGFloat((dict[key] as? NSNumber)?.doubleValue ?? 0) }
            switch kind {
            case "linear": self.kind = .linear
            case "radial": self.kind = .radial
            default: throw ScriptError("Unknown gradient kind \(kind)")
            }
            start = CGPoint(x: n("x0"), y: n("y0"))
            end = CGPoint(x: n("x1"), y: n("y1"))
            startRadius = n("r0")
            endRadius = n("r1")
            let raw = dict["stops"] as? [[Any]] ?? []
            guard !raw.isEmpty else { throw ScriptError("A gradient needs addColorStop(offset, color) at least once") }
            var stops: [(CGFloat, CGColor)] = []
            for stop in raw where stop.count == 2 {
                let offset = CGFloat((stop[0] as? NSNumber)?.doubleValue ?? 0)
                let color = try ScriptGeometry.color(from: stop[1]).cgColor
                    .converted(to: BrushyColorSpace.sRGB, intent: .defaultIntent, options: nil)
                stops.append((min(max(offset, 0), 1), color ?? CGColor(gray: 0, alpha: 1)))
            }
            stops.sort { $0.0 < $1.0 }
            if stops.count == 1 { stops.append(stops[0]) }
            guard let gradient = CGGradient(colorsSpace: BrushyColorSpace.sRGB, colors: stops.map(\.1) as CFArray,
                                            locations: stops.map(\.0)) else {
                throw ScriptError("Could not build the gradient")
            }
            self.gradient = gradient
        }

        func draw(in ctx: CGContext) {
            let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            switch kind {
            case .linear:
                ctx.drawLinearGradient(gradient, start: start, end: end, options: options)
            case .radial:
                ctx.drawRadialGradient(gradient, startCenter: start, startRadius: startRadius,
                                       endCenter: end, endRadius: endRadius, options: options)
            }
        }
    }

    struct State {
        var fill: Style = .color(CGColor(gray: 0, alpha: 1))
        var stroke: Style = .color(CGColor(gray: 0, alpha: 1))
        var lineWidth: CGFloat = 1
        var lineCap: CGLineCap = .butt
        var lineJoin: CGLineJoin = .miter
        var lineDash: [CGFloat] = []
        var alpha: CGFloat = 1
        var font = "10px sans-serif"
        var textAlign = "left"
        var textBaseline = "alphabetic"
        var transform: CGAffineTransform = .identity
    }

    struct Replayer {
        let ctx: CGContext
        var state = State()
        var stack: [State] = []
        var path = CGMutablePath()

        init(ctx: CGContext) { self.ctx = ctx }

        private func num(_ args: [Any], _ i: Int, _ fallback: CGFloat = 0) -> CGFloat {
            guard i < args.count, let n = args[i] as? NSNumber else { return fallback }
            let v = CGFloat(n.doubleValue)
            return v.isFinite ? v : fallback
        }

        private func need(_ args: [Any], _ count: Int, _ name: String) throws {
            guard args.count >= count else { throw ScriptError("\(name) needs \(count) numbers") }
        }

        private func point(_ args: [Any], _ i: Int) -> CGPoint {
            CGPoint(x: num(args, i), y: num(args, i + 1)).applying(state.transform)
        }

        private func rect(_ args: [Any], _ i: Int) -> CGRect {
            CGRect(x: num(args, i), y: num(args, i + 1), width: num(args, i + 2), height: num(args, i + 3))
        }

        mutating func perform(_ command: [Any]) throws {
            guard let name = command.first as? String else { throw ScriptError("Malformed draw command") }
            let args = Array(command.dropFirst())
            switch name {
            // Styles
            case "fillStyle": state.fill = try Style(args.first ?? "black")
            case "strokeStyle": state.stroke = try Style(args.first ?? "black")
            case "lineWidth": state.lineWidth = max(num(args, 0, 1), 0)
            case "lineCap":
                switch (args.first as? String) ?? "butt" {
                case "round": state.lineCap = .round
                case "square": state.lineCap = .square
                default: state.lineCap = .butt
                }
            case "lineJoin":
                switch (args.first as? String) ?? "miter" {
                case "round": state.lineJoin = .round
                case "bevel": state.lineJoin = .bevel
                default: state.lineJoin = .miter
                }
            case "setLineDash":
                state.lineDash = (args.first as? [Any] ?? []).compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
            case "globalAlpha":
                state.alpha = min(max(num(args, 0, 1), 0), 1)
            case "font": state.font = (args.first as? String) ?? "10px sans-serif"
            case "textAlign": state.textAlign = (args.first as? String) ?? "left"
            case "textBaseline": state.textBaseline = (args.first as? String) ?? "alphabetic"

            // State and transform
            case "save":
                stack.append(state)
                ctx.saveGState()
            case "restore":
                guard let previous = stack.popLast() else { return }
                state = previous
                ctx.restoreGState()
            case "translate": state.transform = state.transform.translatedBy(x: num(args, 0), y: num(args, 1))
            case "rotate": state.transform = state.transform.rotated(by: num(args, 0))
            case "scale": state.transform = state.transform.scaledBy(x: num(args, 0, 1), y: num(args, 1, 1))
            case "transform":
                try need(args, 6, name)
                state.transform = CGAffineTransform(a: num(args, 0), b: num(args, 1), c: num(args, 2),
                                                    d: num(args, 3), tx: num(args, 4), ty: num(args, 5))
                    .concatenating(state.transform)
            case "setTransform":
                try need(args, 6, name)
                state.transform = CGAffineTransform(a: num(args, 0), b: num(args, 1), c: num(args, 2),
                                                    d: num(args, 3), tx: num(args, 4), ty: num(args, 5))
            case "resetTransform": state.transform = .identity

            // Rectangles
            case "fillRect":
                try need(args, 4, name)
                let p = CGMutablePath()
                p.addRect(rect(args, 0), transform: state.transform)
                fill(p)
            case "strokeRect":
                try need(args, 4, name)
                let p = CGMutablePath()
                p.addRect(rect(args, 0), transform: state.transform)
                stroke(p)
            case "clearRect":
                try need(args, 4, name)
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                ctx.addRect(rect(args, 0).applying(state.transform))
                ctx.fillPath()
                ctx.restoreGState()

            // Paths
            case "beginPath": path = CGMutablePath()
            case "closePath": if !path.isEmpty { path.closeSubpath() }
            case "moveTo": path.move(to: point(args, 0))
            case "lineTo":
                if path.isEmpty { path.move(to: point(args, 0)) } else { path.addLine(to: point(args, 0)) }
            case "rect":
                try need(args, 4, name)
                path.addRect(rect(args, 0), transform: state.transform)
            case "roundRect":
                try need(args, 4, name)
                let r = rect(args, 0).standardized
                let radius = min(num(args, 4), r.width / 2, r.height / 2)
                path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius, transform: state.transform)
            case "arc":
                try need(args, 5, name)
                let anticlockwise = (args.count > 5 ? (args[5] as? Bool) : nil) ?? false
                addArc(center: CGPoint(x: num(args, 0), y: num(args, 1)), radii: CGSize(width: num(args, 2), height: num(args, 2)),
                       rotation: 0, start: num(args, 3), end: num(args, 4), anticlockwise: anticlockwise)
            case "ellipse":
                try need(args, 7, name)
                let anticlockwise = (args.count > 7 ? (args[7] as? Bool) : nil) ?? false
                addArc(center: CGPoint(x: num(args, 0), y: num(args, 1)), radii: CGSize(width: num(args, 2), height: num(args, 3)),
                       rotation: num(args, 4), start: num(args, 5), end: num(args, 6), anticlockwise: anticlockwise)
            case "quadraticCurveTo":
                try need(args, 4, name)
                if path.isEmpty { path.move(to: point(args, 0)) }
                path.addQuadCurve(to: point(args, 2), control: point(args, 0))
            case "bezierCurveTo":
                try need(args, 6, name)
                if path.isEmpty { path.move(to: point(args, 0)) }
                path.addCurve(to: point(args, 4), control1: point(args, 0), control2: point(args, 2))
            case "fill": fill(path)
            case "stroke": stroke(path)
            case "clip":
                ctx.addPath(path.isEmpty ? CGPath(rect: .null, transform: nil) : path)
                if (args.first as? String) == "evenodd" { ctx.clip(using: .evenOdd) } else { ctx.clip() }

            // Text
            case "fillText", "strokeText":
                guard let text = args.first as? String else { throw ScriptError("\(name) needs a string") }
                try need(args, 3, name)
                try drawText(text, at: CGPoint(x: num(args, 1), y: num(args, 2)), stroke: name == "strokeText")
            default:
                throw ScriptError("Unsupported: \(name)")
            }
        }

        private mutating func addArc(center: CGPoint, radii: CGSize, rotation: CGFloat,
                                     start: CGFloat, end: CGFloat, anticlockwise: Bool) {
            guard radii.width > 0, radii.height > 0 else { return }
            // Unit circle through (scale, rotate, translate, then the current
            // transform). Canvas angles increase clockwise on screen (y down);
            // Core Graphics' `clockwise` means "angle decreasing", so
            // Canvas's anticlockwise IS CG's clockwise.
            let t = state.transform.translatedBy(x: center.x, y: center.y).rotated(by: rotation)
                .scaledBy(x: radii.width, y: radii.height)
            path.addArc(center: .zero, radius: 1, startAngle: start, endAngle: end, clockwise: anticlockwise, transform: t)
        }

        private func fill(_ p: CGPath) {
            guard !p.isEmpty else { return }
            ctx.saveGState()
            ctx.setAlpha(state.alpha)
            switch state.fill {
            case .color(let color):
                ctx.setFillColor(color)
                ctx.addPath(p)
                ctx.fillPath()
            case .gradient(let gradient):
                ctx.addPath(p)
                ctx.clip()
                ctx.concatenate(state.transform)
                gradient.draw(in: ctx)
            }
            ctx.restoreGState()
        }

        /// Strokes in the current user space so the pen width scales with
        /// the transform, as Canvas does — the path is stored in canvas
        /// space, so it goes back through the inverse first.
        private func stroke(_ p: CGPath) {
            guard !p.isEmpty, state.transform.isInvertible else { return }
            ctx.saveGState()
            ctx.setAlpha(state.alpha)
            ctx.setLineWidth(state.lineWidth)
            ctx.setLineCap(state.lineCap)
            ctx.setLineJoin(state.lineJoin)
            ctx.setLineDash(phase: 0, lengths: state.lineDash.isEmpty ? [] : state.lineDash)
            var inverse = state.transform.inverted()
            let local = p.copy(using: &inverse) ?? p
            switch state.stroke {
            case .color(let color):
                ctx.concatenate(state.transform)
                ctx.setStrokeColor(color)
                ctx.addPath(local)
                ctx.strokePath()
            case .gradient(let gradient):
                ctx.concatenate(state.transform)
                ctx.addPath(local)
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                gradient.draw(in: ctx)
            }
            ctx.restoreGState()
        }

        private func drawText(_ text: String, at origin: CGPoint, stroke: Bool) throws {
            let font = ScriptDrawing.font(fromCSS: state.font)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            var x = origin.x, y = origin.y
            switch state.textAlign {
            case "center": x -= width / 2
            case "right", "end": x -= width
            default: break
            }
            switch state.textBaseline {
            case "top", "hanging": y += ascent
            case "middle": y += (ascent - descent) / 2
            case "bottom", "ideographic": y -= descent
            default: break // alphabetic
            }
            ctx.saveGState()
            ctx.setAlpha(state.alpha)
            ctx.concatenate(state.transform)
            // The context is y-flipped for top-left coordinates; glyphs are
            // flipped back through the text matrix.
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            if stroke {
                ctx.setTextDrawingMode(.stroke)
                ctx.setLineWidth(state.lineWidth)
                if case .color(let color) = state.stroke { ctx.setStrokeColor(color) }
            } else {
                ctx.setTextDrawingMode(.fill)
                if case .color(let color) = state.fill { ctx.setFillColor(color) }
            }
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}

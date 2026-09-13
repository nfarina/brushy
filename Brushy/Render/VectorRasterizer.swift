import AppKit
import CoreGraphics
import Foundation

/// Renders text/shape specs into layer source images (Display P3, RGBA8,
/// premultiplied — same as paint layers). Content space is y-up like
/// everything else; text draws through a flipped sub-context because AppKit
/// string drawing expects one.
enum VectorRasterizer {
    /// Renders through the shared TextKit 1 stack (`TextLayout`) — the inline
    /// canvas editor lays out with the identical system, so editing and
    /// committed glyphs match exactly.
    static func render(text spec: TextSpec) -> CGImage? {
        var effective = spec
        if effective.text.isEmpty { effective.text = " " }
        let (storage, layoutManager, container) = TextLayout.makeTextSystem(for: effective)
        return withExtendedLifetime(storage) { () -> CGImage? in
            let used = TextLayout.usedSize(layoutManager, container)
            let (width, height) = TextLayout.paddedPixelSize(for: used)
            guard let ctx = makeContext(width: width, height: height) else { return nil }

            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let glyphs = layoutManager.glyphRange(for: container)
            let origin = CGPoint(x: TextLayout.padding, y: TextLayout.padding)
            layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            return ctx.makeImage()
        }
    }

    static func render(shape spec: ShapeSpec) -> CGImage? {
        let width = max(1, spec.size.width.rounded().saturatingInt)
        let height = max(1, spec.size.height.rounded().saturatingInt)
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        let pad = CGFloat(spec.padding)
        let strokeWidth = CGFloat(spec.strokeWidth)

        switch spec.kind {
        case .rectangle, .ellipse:
            // Geometry is inset so the stroke stays inside the content box.
            let inset = (spec.stroke != nil) ? strokeWidth / 2 + 1 : 1
            let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
                .insetBy(dx: inset, dy: inset)
            guard rect.width > 0, rect.height > 0 else { break }
            let path = spec.kind == .rectangle ? CGPath(rect: rect, transform: nil)
                                               : CGPath(ellipseIn: rect, transform: nil)
            if let fill = spec.fill {
                ctx.addPath(path)
                ctx.setFillColor(fill.cgColor)
                ctx.fillPath()
            }
            if let stroke = spec.stroke {
                ctx.addPath(path)
                ctx.setStrokeColor(stroke.cgColor)
                ctx.setLineWidth(strokeWidth)
                applyDash(ctx, spec: spec)
                ctx.strokePath()
            }

        case .line:
            guard let stroke = spec.stroke else { break }
            let start = spec.lineStart
            let end = spec.lineEnd
            let delta = end - start
            let length = delta.length
            guard length > 0.5 else { break }
            let direction = delta * (1 / length)
            let arrowLength = CGFloat(spec.arrowLength)

            ctx.setFillColor(stroke.cgColor)
            ctx.setStrokeColor(stroke.cgColor)

            // Arrowheads are solid triangles; the shaft is shortened so a
            // dashed/dotted pattern never pokes past the tip.
            var shaftStart = start
            var shaftEnd = end
            if spec.arrowStart {
                drawArrowHead(ctx, tip: start, direction: direction * -1, length: arrowLength)
                shaftStart = start + direction * (arrowLength * 0.75)
            }
            if spec.arrowEnd {
                drawArrowHead(ctx, tip: end, direction: direction, length: arrowLength)
                shaftEnd = end - direction * (arrowLength * 0.75)
            }
            guard (shaftEnd - shaftStart).dot(direction) > 0 else { break }
            ctx.setLineWidth(strokeWidth)
            applyDash(ctx, spec: spec)
            ctx.move(to: shaftStart)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()
        }
        _ = pad // padding is baked into `size`/`lineStart`/`lineEnd` at creation
        return ctx.makeImage()
    }

    private static func applyDash(_ ctx: CGContext, spec: ShapeSpec) {
        let w = max(1, CGFloat(spec.strokeWidth))
        switch spec.strokeStyle {
        case .solid:
            ctx.setLineCap(.butt)
            ctx.setLineDash(phase: 0, lengths: [])
        case .dashed:
            ctx.setLineCap(.butt)
            ctx.setLineDash(phase: 0, lengths: [max(4, w * 2.5), max(3, w * 1.6)])
        case .dotted:
            // Zero-length dashes with round caps render as true dots.
            ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [0.01, max(3, w * 2.2)])
        }
    }

    private static func drawArrowHead(_ ctx: CGContext, tip: CGPoint,
                                      direction: CGPoint, length: CGFloat) {
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let base = tip - direction * length
        let halfWidth = length * 0.42
        ctx.move(to: tip)
        ctx.addLine(to: base + normal * halfWidth)
        ctx.addLine(to: base - normal * halfWidth)
        ctx.closePath()
        ctx.fillPath()
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: BrushyColorSpace.displayP3,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: - Creation geometry

    /// Builds a shape spec from a canvas-space drag, returning the spec plus
    /// the canvas position of its content box origin (padding included).
    static func shapeSpec(from dragRect: CGRect,
                          lineFrom: CGPoint?, lineTo: CGPoint?,
                          style: ShapeSpec) -> (spec: ShapeSpec, origin: CGPoint) {
        var spec = style
        let pad = CGFloat(spec.padding)
        if spec.kind == .line, let from = lineFrom, let to = lineTo {
            let box = CGRect.aabb(of: [from, to]).insetBy(dx: -pad, dy: -pad)
            spec.size = box.size
            spec.lineStart = from - box.origin
            spec.lineEnd = to - box.origin
            return (spec, box.origin)
        }
        let box = dragRect.standardized.insetBy(dx: -pad, dy: -pad)
        spec.size = CGSize(width: max(box.width, pad * 2 + 2),
                           height: max(box.height, pad * 2 + 2))
        return (spec, box.origin)
    }
}

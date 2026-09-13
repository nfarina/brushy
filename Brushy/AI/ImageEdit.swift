import CoreGraphics
import Foundation

/// The geometry and rendering behind the `edit_image` tool: the user
/// selects part of a document and asks for a change, the image model sees
/// the composite around that area with the area outlined, and its result
/// lands back exactly where the crop came from, masked to the selection.
///
/// Everything here is top-left, y-down canvas coordinates except where a
/// `CGPath` from `SelectionState` (canvas y-up) is converted for drawing.
enum ImageEdit {
    /// The crop sent to the image model: the region padded for context on
    /// every side, then grown to one of the model's aspect ratios so the
    /// returned image maps back onto the crop 1:1. Kept inside the canvas
    /// where it fits; where it can't (a region at an edge, or wider than the
    /// canvas) it overhangs and the overhang renders white.
    static func frame(around region: CGRect, padding: CGFloat, canvas: CGSize) -> (frame: CGRect, ratio: String) {
        let pad = max(32, max(region.width, region.height) * padding)
        var frame = region.insetBy(dx: -pad, dy: -pad)
        let ratio = ChatTools.nearestAspectRatio(Double(frame.width / max(frame.height, 1)))
        let target = ChatTools.aspectRatios.first { $0.name == ratio }?.value ?? 1
        // Grow only — never cut into the padding.
        if Double(frame.width / frame.height) < target {
            let width = frame.height * CGFloat(target)
            frame = frame.insetBy(dx: -(width - frame.width) / 2, dy: 0)
        } else {
            let height = frame.width / CGFloat(target)
            frame = frame.insetBy(dx: 0, dy: -(height - frame.height) / 2)
        }
        if frame.width <= canvas.width {
            frame.origin.x = min(max(frame.origin.x, 0), canvas.width - frame.width)
        }
        if frame.height <= canvas.height {
            frame.origin.y = min(max(frame.origin.y, 0), canvas.height - frame.height)
        }
        return (frame.integral, ratio)
    }

    /// The reference image: `composite` (the whole canvas rendered at
    /// `scale`, top-left at canvas (0,0)) cropped to `frame`, white outside
    /// the canvas, with `outline` (canvas y-up path) stroked in red so the
    /// prompt can say "the area outlined in red".
    static func reference(composite: CGImage, scale: CGFloat, frame: CGRect, canvas: CGSize,
                          outline: CGPath?) -> CGImage? {
        let width = max(1, Int((frame.width * scale).rounded()))
        let height = max(1, Int((frame.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: BrushyColorSpace.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        // The composite covers canvas (0,0)–(W,H); in the crop's own top-left
        // space that is (−frame.minX, −frame.minY), which in CG's y-up space
        // puts its bottom edge at frame.maxY − H.
        ctx.draw(composite, in: CGRect(x: -frame.minX * scale, y: (frame.maxY - canvas.height) * scale,
                                       width: canvas.width * scale, height: canvas.height * scale))
        if let outline {
            var transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: -frame.minX, y: frame.maxY - canvas.height)
            if let path = outline.copy(using: &transform) {
                ctx.addPath(path)
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
                ctx.setLineWidth(max(3, CGFloat(max(width, height)) * 0.006))
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }

    /// What the image model is told, around the user's own words.
    static func prompt(for change: String, outlined: Bool) -> String {
        var text = "Edit this image: \(change.trimmingCharacters(in: .whitespacesAndNewlines))"
        if !text.hasSuffix(".") { text += "." }
        if outlined {
            text += " Apply the change only to the area outlined in red and leave everything else exactly as it is. Do not draw the red outline in the result."
        } else {
            text += " Leave everything else exactly as it is."
        }
        text += " Return the whole image with the same framing, composition and size."
        return text
    }

    /// The script that places the result: stretched onto the crop frame so
    /// it registers with the original, masked to the selection (or to the
    /// given region, selected for the purpose and released again).
    static func placementScript(document id: String, frame: CGRect, region: CGRect?, name: String) -> String {
        let options = JSONValue(any: ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                                      "stretch": true, "name": name]).jsonString
        var lines = ["const target = brushy.doc(\(JSONValue.string(id).jsonString));"]
        if let region {
            let rect = JSONValue(any: ["x": region.minX, "y": region.minY,
                                       "width": region.width, "height": region.height]).jsonString
            lines.append("target.select(\(rect));")
        }
        lines.append("const placed = target.addImage(\"generated\", \(options));")
        lines.append("placed.addMask(\"selection\");")
        if region != nil { lines.append("target.deselect();") }
        return lines.joined(separator: "\n")
    }
}

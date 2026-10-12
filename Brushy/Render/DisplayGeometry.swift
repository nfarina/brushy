import CoreGraphics

/// Pure geometry for putting the canvas on screen pixel-exactly (§3, §4).
/// Shared by the Metal composite (`RenderEngine.displayImage`) and the
/// overlay's pixel grid, so the two can never disagree by a device pixel.
enum DisplayGeometry {
    /// Zoom (view points per canvas px) above which the pixel grid shows —
    /// Photoshop's 500%.
    static let pixelGridMinimumZoom: CGFloat = 5

    /// `transform` (canvas → device px, scale + translation only) nudged so
    /// all four canvas edges land on device-pixel boundaries: the origin is
    /// rounded, and the scale stretched by under one device pixel across the
    /// whole canvas so the far edges round too. Unsnapped, the fractional edge
    /// pixel is covered partly by the composite and partly by the
    /// checkerboard, and that sliver changes with every zoom step — a line
    /// flickering along the canvas border.
    static func pixelAligned(_ transform: CGAffineTransform, canvasSize: CGSize) -> CGAffineTransform {
        guard transform.b == 0, transform.c == 0, transform.a > 0, transform.d > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return transform }
        let minX = transform.tx.rounded()
        let minY = transform.ty.rounded()
        let maxX = max((transform.tx + canvasSize.width * transform.a).rounded(), minX + 1)
        let maxY = max((transform.ty + canvasSize.height * transform.d).rounded(), minY + 1)
        return CGAffineTransform(a: (maxX - minX) / canvasSize.width, b: 0, c: 0,
                                 d: (maxY - minY) / canvasSize.height, tx: minX, ty: minY)
    }

    /// Where nearest-neighbour magnification under `aligned` switches from
    /// one canvas pixel to the next: the device column (x) / row (y, y-up)
    /// holding the first device pixel of canvas column/row k, for each
    /// interior boundary (k = 1 ..< size) inside `visible` (device px).
    /// Core Image samples device pixel j at its centre, so canvas pixel k
    /// starts at the first j with j + 0.5 ≥ offset + k·scale.
    static func pixelGridLines(aligned: CGAffineTransform, canvasSize: CGSize,
                               visible: CGRect) -> (columns: [Int], rows: [Int]) {
        func lines(offset: CGFloat, scale: CGFloat, count: CGFloat,
                   lower: CGFloat, upper: CGFloat) -> [Int] {
            guard scale > 0, count > 1 else { return [] }
            let first = max(1, ((lower - offset) / scale).rounded(.down))
            let last = min(count - 1, ((upper - offset) / scale).rounded(.up))
            guard first <= last else { return [] }
            return stride(from: first, through: last, by: 1).compactMap { k in
                let j = (offset + k * scale - 0.5).rounded(.up)
                return j >= lower && j < upper ? Int(j) : nil
            }
        }
        return (lines(offset: aligned.tx, scale: aligned.a, count: canvasSize.width,
                      lower: visible.minX, upper: visible.maxX),
                lines(offset: aligned.ty, scale: aligned.d, count: canvasSize.height,
                      lower: visible.minY, upper: visible.maxY))
    }

    /// Frame (view space, y-up) for a readout of `size` floating beside the
    /// pointer — below and right of it as in Photoshop, flipped to the other
    /// side of the pointer when that would leave `bounds`, then clamped in.
    static func readoutFrame(size: CGSize, beside pointer: CGPoint, in bounds: CGRect,
                             offset: CGFloat = 16, margin: CGFloat = 4) -> CGRect {
        var x = pointer.x + offset
        if x + size.width > bounds.maxX - margin { x = pointer.x - offset - size.width }
        var y = pointer.y - offset - size.height
        if y < bounds.minY + margin { y = pointer.y + offset }
        x = min(max(x, bounds.minX + margin), bounds.maxX - margin - size.width)
        y = min(max(y, bounds.minY + margin), bounds.maxY - margin - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// `path` (canvas space) in view points, every vertex snapped to the
    /// device-pixel boundary where the composite switches canvas pixels (the
    /// `pixelGridLines` rule), so a stroke along a whole-pixel edge — a
    /// marquee's marching ants — fills whole device pixels rather than
    /// blurring across two. `viewTransform` is canvas → view points, `scale`
    /// the backing scale. A stroke an odd number of device pixels wide is
    /// centred on a pixel, an even one on a boundary. Curves and diagonals
    /// move by under one device pixel.
    static func pixelSnappedViewPath(_ path: CGPath, viewTransform: CGAffineTransform,
                                     canvasSize: CGSize, scale: CGFloat,
                                     lineWidth: CGFloat = 1) -> CGPath {
        let aligned = pixelAligned(viewTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale)),
                                   canvasSize: canvasSize)
        let devicePixels = (lineWidth * scale).rounded()
        let inset: CGFloat = Int(devicePixels) % 2 == 1 ? 0.5 : 0
        func snap(_ point: CGPoint) -> CGPoint {
            let device = point.applying(aligned)
            return CGPoint(x: ((device.x - 0.5).rounded(.up) + inset) / scale,
                           y: ((device.y - 0.5).rounded(.up) + inset) / scale)
        }
        let snapped = CGMutablePath()
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: snapped.move(to: snap(points[0]))
            case .addLineToPoint: snapped.addLine(to: snap(points[0]))
            case .addQuadCurveToPoint: snapped.addQuadCurve(to: snap(points[1]), control: snap(points[0]))
            case .addCurveToPoint:
                snapped.addCurve(to: snap(points[2]), control1: snap(points[0]), control2: snap(points[1]))
            case .closeSubpath: snapped.closeSubpath()
            @unknown default: break
            }
        }
        return snapped
    }
}

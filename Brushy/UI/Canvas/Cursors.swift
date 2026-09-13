import AppKit

/// Procedurally drawn cursors (rotate arrows, angled resize arrows) — no image
/// assets. White glyphs with black outlines so they read on any canvas.
enum Cursors {
    static let rotate: NSCursor = {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let center = CGPoint(x: 11, y: 11)
            let radius: CGFloat = 6.5
            func strokeArc(_ color: NSColor, _ width: CGFloat) {
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius,
                               startAngle: -50, endAngle: 200)
                path.lineWidth = width
                path.lineCapStyle = .round
                color.setStroke()
                path.stroke()
            }
            func head(at angle: CGFloat, direction: CGFloat) {
                let rad = angle * .pi / 180
                let tip = CGPoint(x: center.x + radius * cos(rad), y: center.y + radius * sin(rad))
                let tangent = rad + direction * .pi / 2
                let path = NSBezierPath()
                path.move(to: CGPoint(x: tip.x + 4.5 * cos(tangent), y: tip.y + 4.5 * sin(tangent)))
                path.line(to: CGPoint(x: tip.x + 3.2 * cos(rad), y: tip.y + 3.2 * sin(rad)))
                path.line(to: CGPoint(x: tip.x - 3.2 * cos(rad), y: tip.y - 3.2 * sin(rad)))
                path.close()
                NSColor.black.setStroke()
                path.lineWidth = 2
                path.stroke()
                NSColor.white.setFill()
                path.fill()
            }
            strokeArc(.black, 3.5)
            strokeArc(.white, 1.8)
            head(at: -50, direction: -1)
            head(at: 200, direction: 1)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 11, y: 11))
    }()

    /// Tiny dot for brush-family tools — the overlay draws the size ring.
    static let dot: NSCursor = {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { _ in
            let outer = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 6, height: 6))
            NSColor.black.setStroke()
            outer.lineWidth = 2.5
            outer.stroke()
            NSColor.white.setStroke()
            outer.lineWidth = 1
            outer.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 5, y: 5))
    }()

    private static var resizeCache: [Int: NSCursor] = [:]

    /// Double-headed resize arrow rotated to `angle` (radians), quantised to 45°.
    static func resize(angle: CGFloat) -> NSCursor {
        var quantized = Int((angle / (.pi / 4)).rounded()) % 4
        if quantized < 0 { quantized += 4 }
        if let cached = resizeCache[quantized] { return cached }
        let drawAngle = CGFloat(quantized) * .pi / 4
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let center = CGPoint(x: 12, y: 12)
            let direction = CGPoint(x: cos(drawAngle), y: sin(drawAngle))
            let normal = CGPoint(x: -direction.y, y: direction.x)
            let half: CGFloat = 8
            let tipA = center + direction * half
            let tipB = center - direction * half
            func arrow(_ tip: CGPoint, _ dir: CGPoint) -> NSBezierPath {
                let path = NSBezierPath()
                let back = tip - dir * 4.5
                path.move(to: tip)
                path.line(to: back + normal * 3.5)
                path.line(to: back - normal * 3.5)
                path.close()
                return path
            }
            let shaft = NSBezierPath()
            shaft.move(to: tipA - direction * 3)
            shaft.line(to: tipB + direction * 3)
            for width in [(NSColor.black, CGFloat(4.0)), (NSColor.white, CGFloat(2.0))] {
                width.0.setStroke()
                shaft.lineWidth = width.1
                shaft.stroke()
            }
            for path in [arrow(tipA, direction), arrow(tipB, direction * -1)] {
                NSColor.black.setStroke()
                path.lineWidth = 2
                path.stroke()
                NSColor.white.setFill()
                path.fill()
            }
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
        resizeCache[quantized] = cursor
        return cursor
    }
}

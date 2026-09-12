import CoreGraphics

extension CGAffineTransform {
    /// Lengths of the transformed unit axes — the effective scale factors.
    /// (For our transforms — compositions of scale, rotation and translation —
    /// the columns stay orthogonal, so these are exact.)
    var scaleComponents: (sx: CGFloat, sy: CGFloat) {
        (hypot(a, b), hypot(c, d))
    }

    /// Rotation of the transformed x-axis, in radians (counterclockwise).
    var rotationAngle: CGFloat { atan2(b, a) }

    var isInvertible: Bool {
        let det = a * d - b * c
        return det.isFinite && abs(det) > 1e-10
    }

    var asArray: [Double] { [a, b, c, d, tx, ty] }

    /// A pure translation by whole pixels — the one transform that can move a
    /// pixel buffer without resampling it (Crop's shift, an outline drag, a
    /// nudge). Identity qualifies.
    var isWholePixelTranslation: Bool {
        a == 1 && b == 0 && c == 0 && d == 1
            && tx.isFinite && ty.isFinite
            && tx == tx.rounded() && ty == ty.rounded()
    }

    /// Every component finite. `isInvertible` only inspects a/b/c/d, so a
    /// transform can be "invertible" with a `tx` of 1e300 — which then reaches
    /// hit-testing and pixel indexing as a non-finite source coordinate.
    var isFinite: Bool {
        a.isFinite && b.isFinite && c.isFinite && d.isFinite && tx.isFinite && ty.isFinite
    }

    /// The furthest a layer may legitimately be translated. Canvas sizes top
    /// out at 16384 points (`Document.canvasSizeLimits`), so 64× that is far
    /// past anything reachable by dragging and far short of the range where
    /// `tx / scale` starts producing source coordinates that overflow `Int`.
    static let translationLimit: CGFloat = 1_048_576  // 1 << 20

    /// Rejects anything that isn't six sane components.
    ///
    /// Both callers — the `.dezzy` reader and the clipboard — take this array
    /// straight from a file, and validating the count alone let NaN, infinity
    /// and 1e300 into layer transforms. Note that finiteness alone is not
    /// enough: 1e300 *is* finite, and it still turns into a non-finite source
    /// coordinate once inverted and applied.
    init?(array: [Double]) {
        guard array.count == 6 else { return nil }
        self.init(a: array[0], b: array[1], c: array[2], d: array[3], tx: array[4], ty: array[5])
        guard isFinite,
              abs(tx) <= Self.translationLimit, abs(ty) <= Self.translationLimit else {
            return nil
        }
    }
}

extension Double {
    /// Saturating conversion to `Int`.
    ///
    /// `Int(someDouble)` **traps** on NaN, on infinity, and on anything
    /// outside `Int`'s range. Several of the doubles this app converts arrive
    /// from files — canvas sizes, layer transforms, selection bounds — so the
    /// plain initialiser is a crash waiting for a malformed document rather
    /// than a conversion. Use this wherever the value's provenance isn't
    /// provably in range.
    var saturatingInt: Int {
        guard !isNaN else { return 0 }
        // 2^62 is well inside Int and exactly representable as a Double, so
        // the comparisons can't themselves round into the trap they guard.
        let limit = 4_611_686_018_427_387_904.0
        if self >= limit { return Int(limit) }
        if self <= -limit { return -Int(limit) }
        return Int(self)
    }
}

extension CGFloat {
    /// See `Double.saturatingInt`.
    var saturatingInt: Int { native.saturatingInt }
}

extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: CGPoint, r: CGFloat) -> CGPoint { CGPoint(x: l.x * r, y: l.y * r) }

    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
    var length: CGFloat { hypot(x, y) }

    func dot(_ other: CGPoint) -> CGFloat { x * other.x + y * other.y }

    var normalized: CGPoint {
        let len = length
        guard len > 1e-12 else { return .zero }
        return CGPoint(x: x / len, y: y / len)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// All four components finite. `isNull`/`isEmpty`/`isInfinite` between
    /// them do not cover NaN or a merely astronomical rect, and both reach
    /// `Int(…)` conversions in the exporters.
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }

    /// Corner order: bottom-left, bottom-right, top-right, top-left (y-up space).
    var corners: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
         CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }

    static func aabb(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

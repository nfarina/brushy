import CoreGraphics

/// Polygonal Lasso geometry (§5): click to place vertices, a rubber band runs
/// from the last one to the pointer, and the outline closes on a click near
/// the first vertex, a double-click, or Return — as in Photoshop.
enum PolygonLasso {
    /// View points from the first vertex within which a click closes the
    /// polygon instead of adding a vertex.
    static let closeRadius: CGFloat = 6

    static func closes(at viewPoint: CGPoint, firstVertex: CGPoint, vertexCount: Int) -> Bool {
        vertexCount >= 3 && (viewPoint - firstVertex).length <= closeRadius
    }

    /// Where the next vertex lands: the pointer, or with ⇧ the pointer
    /// constrained to 45° steps from the last vertex.
    static func nextVertex(after last: CGPoint, toward pointer: CGPoint, constrained: Bool) -> CGPoint {
        constrained ? last + TransformMath.constrainedTo45(pointer - last) : pointer
    }

    /// The open outline drawn while placing vertices, through the pointer
    /// when there is one.
    static func previewPath(vertices: [CGPoint], pointer: CGPoint?) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: vertices + (pointer.map { [$0] } ?? []))
        return path
    }

    /// The selection outline, or nil with fewer than three vertices.
    static func closedPath(vertices: [CGPoint]) -> CGPath? {
        guard vertices.count >= 3 else { return nil }
        let path = CGMutablePath()
        path.addLines(between: vertices)
        path.closeSubpath()
        return path
    }
}

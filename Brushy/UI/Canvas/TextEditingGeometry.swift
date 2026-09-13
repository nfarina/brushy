import CoreGraphics
import Foundation

/// Pure placement math for the inline text editor. The wrapper NSView's
/// BOUNDS hold the content at native size (source points) while its FRAME is
/// scaled by (layer scale × viewport zoom) and rotated by the layer's
/// rotation — so the editor is a pure function of (session, content size,
/// viewport) and can be recomputed from scratch on every change with no
/// drift.
///
/// The session's `anchorTopLeft` (canvas space) stays pinned to the text
/// box's top-left through zoom, pan, and text growth — matching the
/// commit-side anchoring in `DocumentStore.updateVectorLayer` (text keeps its
/// top-left; boxes grow rightward and downward).
enum TextEditingGeometry {
    struct Placement {
        /// Wrapper frame in view points, BEFORE rotation is applied.
        var frame: CGRect
        /// Wrapper bounds size (content space, source points).
        var boundsSize: CGSize
        /// `frameCenterRotation`, degrees (AppKit y-up, CCW positive).
        var rotationDegrees: CGFloat
    }

    static func placement(anchorTopLeft: CGPoint,
                          rotation: CGFloat,
                          scaleX: CGFloat,
                          scaleY: CGFloat,
                          contentSize: CGSize,
                          viewport: Viewport) -> Placement {
        // Content-box centre relative to the pinned top-left, in canvas space:
        // half-extent rightward along the rotated x-axis, half-extent DOWN
        // along the rotated y-axis (y-up ⇒ minus).
        let halfWidth = contentSize.width * scaleX / 2
        let halfHeight = contentSize.height * scaleY / 2
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let centerCanvas = CGPoint(
            x: anchorTopLeft.x + halfWidth * cosR + halfHeight * sinR,
            y: anchorTopLeft.y + halfWidth * sinR - halfHeight * cosR)
        let centerView = viewport.toView(centerCanvas)
        let frameSize = CGSize(width: contentSize.width * scaleX * viewport.zoom,
                               height: contentSize.height * scaleY * viewport.zoom)
        let frame = CGRect(x: centerView.x - frameSize.width / 2,
                           y: centerView.y - frameSize.height / 2,
                           width: frameSize.width,
                           height: frameSize.height)
        return Placement(frame: frame,
                         boundsSize: contentSize,
                         rotationDegrees: rotation * 180 / .pi)
    }

    /// The floating task bar's frame: centred under the editing box's AABB
    /// (host coords are y-up, so "below" is the minY side, matching
    /// Photoshop's bar-under-the-text). Flips above the box when there is no
    /// room below, then clamps fully inside the host with a margin. The bar
    /// itself never rotates.
    static func taskBarFrame(editingBox: CGRect,
                             barSize: CGSize,
                             hostBounds: CGRect,
                             gap: CGFloat = 10,
                             margin: CGFloat = 8) -> CGRect {
        var origin = CGPoint(x: editingBox.midX - barSize.width / 2,
                             y: editingBox.minY - gap - barSize.height)
        if origin.y < hostBounds.minY + margin {
            origin.y = editingBox.maxY + gap
        }
        origin.x = min(max(origin.x, hostBounds.minX + margin),
                       hostBounds.maxX - margin - barSize.width)
        origin.y = min(max(origin.y, hostBounds.minY + margin),
                       hostBounds.maxY - margin - barSize.height)
        return CGRect(origin: origin, size: barSize)
    }

    /// The box corners in canvas space (top-left, top-right, bottom-right,
    /// bottom-left), for the overlay hairline and hit tests.
    static func canvasCorners(anchorTopLeft: CGPoint,
                              rotation: CGFloat,
                              scaleX: CGFloat,
                              scaleY: CGFloat,
                              contentSize: CGSize) -> [CGPoint] {
        let width = contentSize.width * scaleX
        let height = contentSize.height * scaleY
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let right = CGPoint(x: cosR, y: sinR)
        let down = CGPoint(x: sinR, y: -cosR)
        let topLeft = anchorTopLeft
        let topRight = topLeft + right * width
        let bottomRight = topRight + down * height
        let bottomLeft = topLeft + down * height
        return [topLeft, topRight, bottomRight, bottomLeft]
    }
}

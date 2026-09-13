import CoreGraphics

/// Canvas↔view mapping. View space is the canvas NSView's coordinate system in
/// points, non-flipped (y-up) — so it differs from canvas space only by zoom
/// and pan, never by orientation.
struct Viewport: Equatable {
    var zoom: CGFloat = 1
    /// Canvas origin in view points.
    var origin: CGPoint = .zero
    /// The hosting view's bounds size; kept current by the view on layout.
    var viewSize: CGSize = .zero
    /// Set once the first layout pass has run and the initial fit happened.
    var isInitialized = false
    /// False until the user pans/zooms; while false the canvas auto-refits on
    /// view resizes (SwiftUI hosting produces small early layout passes).
    var hasUserAdjusted = false

    ///: stepped keyboard zoom levels.
    static let zoomSteps: [CGFloat] = [0.125, 0.25, 0.333, 0.5, 0.667, 1, 2, 3, 4, 8]
    static let minZoom: CGFloat = 0.03
    static let maxZoom: CGFloat = 32

    var viewTransform: CGAffineTransform {
        CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: origin.x, ty: origin.y)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + origin.x, y: p.y * zoom + origin.y)
    }

    func fromView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / zoom, y: (p.y - origin.y) / zoom)
    }

    mutating func pan(by delta: CGPoint) {
        origin = origin + delta
        hasUserAdjusted = true
    }

    /// Rescales keeping the canvas point under `anchorView` fixed on screen.
    mutating func setZoom(_ newZoom: CGFloat, anchorView: CGPoint) {
        let clamped = min(max(newZoom, Self.minZoom), Self.maxZoom)
        let scale = clamped / zoom
        origin = CGPoint(x: anchorView.x - (anchorView.x - origin.x) * scale,
                         y: anchorView.y - (anchorView.y - origin.y) * scale)
        zoom = clamped
        hasUserAdjusted = true
    }

    /// Keyboard zoom: next stepped level, centred on the canvas centre.
    mutating func stepZoom(_ direction: Int, canvasSize: CGSize) {
        let next: CGFloat
        if direction > 0 {
            next = Self.zoomSteps.first(where: { $0 > zoom * 1.001 }) ?? Self.zoomSteps.last!
        } else {
            next = Self.zoomSteps.last(where: { $0 < zoom * 0.999 }) ?? Self.zoomSteps.first!
        }
        let canvasCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        setZoom(next, anchorView: toView(canvasCenter))
    }

    /// Cmd+0 — fit the canvas in the view with a small margin. Fit is the
    /// "auto" state: the canvas keeps refitting on window resizes until the
    /// user pans or zooms manually.
    mutating func fit(canvasSize: CGSize) {
        guard viewSize.width > 1, viewSize.height > 1,
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        let margin: CGFloat = 24
        let fitZoom = min((viewSize.width - margin * 2) / canvasSize.width,
                          (viewSize.height - margin * 2) / canvasSize.height)
        zoom = min(max(fitZoom, Self.minZoom), Self.maxZoom)
        center(canvasSize: canvasSize)
        hasUserAdjusted = false
    }

    /// Cmd+1 — 100%, canvas centre at view centre.
    mutating func actualSize(canvasSize: CGSize) {
        zoom = 1
        center(canvasSize: canvasSize)
        hasUserAdjusted = true
    }

    mutating func center(canvasSize: CGSize) {
        origin = CGPoint(x: (viewSize.width - canvasSize.width * zoom) / 2,
                         y: (viewSize.height - canvasSize.height * zoom) / 2)
    }
}

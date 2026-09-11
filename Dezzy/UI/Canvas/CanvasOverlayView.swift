import AppKit
import CoreGraphics

/// Vector overlay above the Metal canvas: marching ants, the transform box and
/// handles, crop dimming/thirds, and magenta smart guides. Transparent to
/// events — the host view routes everything.
final class CanvasOverlayView: NSView {
    unowned let store: DocumentStore
    private var antsTimer: Timer?
    private var antsPhase: CGFloat = 0

    init(store: DocumentStore) {
        self.store = store
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The ants timer is scheduled on the run loop, which holds it — so it
    /// keeps firing after the view is gone. `[weak self]` prevents a retain
    /// cycle but not the leak: `manageAntsTimer` only invalidates while the
    /// view is alive AND the selection goes away, so closing a document with
    /// an active selection left a 15 Hz no-op timer behind for the lifetime
    /// of the process, one per such document.
    deinit {
        antsTimer?.invalidate()
    }

    /// Also stop when the view leaves the window: a closing document tears
    /// down its window before the view is necessarily released, and there is
    /// nothing to animate for a view with no window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            antsTimer?.invalidate()
            antsTimer = nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let viewport = store.viewport
        manageAntsTimer()

        // View furniture draws first — under selection ants, session
        // boxes and the crop dim, over the composite.
        if store.pixelGridVisible, viewport.zoom > DisplayGeometry.pixelGridMinimumZoom {
            drawPixelGrid(viewport: viewport)
        }
        if store.gridVisible { drawGrid(viewport: viewport) }
        if store.guidesVisible { drawUserGuides(viewport: viewport) }

        if let session = store.selectionTransformSession {
            // Live Transform Selection preview: the ants follow the session's
            // transformed outline; the committed selection is hidden until
            // commit/cancel resolves it.
            drawAnts(session.currentPath, viewport: viewport)
        } else if let path = store.selection.path {
            drawAnts(path, viewport: viewport)
        }
        if let preview = store.previewSelectionPath {
            drawAnts(preview, viewport: viewport)
        }
        if store.activeTool == .crop, let session = store.cropSession {
            drawCrop(session, viewport: viewport)
        }
        if let session = store.transformSession {
            drawTransformBox(rect: session.sourceRect, transform: session.currentTransform,
                             viewport: viewport)
        }
        if let session = store.selectionTransformSession {
            drawTransformBox(rect: session.baseBounds, transform: session.currentTransform,
                             viewport: viewport)
        }
        drawGuides(store.activeGuides, viewport: viewport)
        if store.activeTool.isBrushFamily, let center = store.brushCursorPoint {
            drawBrushRing(at: center, viewport: viewport)
        }
        if let shapePath = store.previewShapePath {
            drawShapePreview(shapePath, viewport: viewport)
        }
        if let line = store.previewGradientLine {
            drawGradientLine(line, viewport: viewport)
        }
        if let session = store.textSession {
            drawTextSessionBox(session, viewport: viewport)
        }
    }

    /// Hairline around the live text-editing box (Photoshop-style) — keeps the
    /// edit region visible when the text colour matches the composite behind.
    private func drawTextSessionBox(_ session: DocumentStore.TextEditSession,
                                    viewport: Viewport) {
        let contentSize = TextLayout.editorContentSize(for: session.spec)
        let corners = TextEditingGeometry.canvasCorners(anchorTopLeft: session.anchorTopLeft,
                                                        rotation: session.rotation,
                                                        scaleX: session.scaleX,
                                                        scaleY: session.scaleY,
                                                        contentSize: contentSize)
            .map { viewport.toView($0) }
        let path = NSBezierPath()
        path.move(to: corners[0])
        for corner in corners.dropFirst() { path.line(to: corner) }
        path.close()
        NSColor.black.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 2
        path.stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }

    /// Rubber-band outline while dragging out a new shape.
    private func drawShapePreview(_ canvasPath: CGPath, viewport: Viewport) {
        var transform = viewport.viewTransform
        guard let viewPath = canvasPath.copy(using: &transform) else { return }
        let path = NSBezierPath(cgPath: viewPath)
        NSColor.black.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 2.5
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The gradient drag vector, endpoints marked. The gradient itself bakes
    /// on mouse-up — the drag shows this line only, not Photoshop's live
    /// gradient preview (a deliberate, documented simplification).
    private func drawGradientLine(_ line: GradientLine, viewport: Viewport) {
        let start = viewport.toView(line.start)
        let end = viewport.toView(line.end)
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        NSColor.black.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 2.5
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = 1
        path.stroke()
        for point in [start, end] {
            let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3,
                                                  width: 6, height: 6))
            NSColor.white.setFill()
            dot.fill()
            NSColor.black.setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
    }

    ///: live brush-size cursor ring.
    private func drawBrushRing(at canvasPoint: CGPoint, viewport: Viewport) {
        let center = viewport.toView(canvasPoint)
        let radius = max(1.5, CGFloat(store.brushSize) / 2 * viewport.zoom)
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        let ring = NSBezierPath(ovalIn: rect)
        NSColor.black.withAlphaComponent(0.7).setStroke()
        ring.lineWidth = 2.5
        ring.stroke()
        NSColor.white.setStroke()
        ring.lineWidth = 1
        ring.stroke()
    }

    // MARK: Marching ants

    private func manageAntsTimer() {
        let needsAnts = store.selection.path != nil || store.previewSelectionPath != nil
        if needsAnts && antsTimer == nil {
            antsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.antsPhase = (self.antsPhase + 1).truncatingRemainder(dividingBy: 8)
                self.needsDisplay = true
            }
        } else if !needsAnts, let timer = antsTimer {
            timer.invalidate()
            antsTimer = nil
        }
    }

    private func drawAnts(_ canvasPath: CGPath, viewport: Viewport) {
        var transform = viewport.viewTransform
        guard let viewPath = canvasPath.copy(using: &transform) else { return }
        let path = NSBezierPath(cgPath: viewPath)
        path.lineWidth = 1

        NSColor.black.setStroke()
        path.setLineDash([4, 4], count: 2, phase: antsPhase)
        path.stroke()
        NSColor.white.setStroke()
        path.setLineDash([4, 4], count: 2, phase: antsPhase + 4)
        path.stroke()
    }

    // MARK: Transform box

    /// Shared by Free Transform and Transform Selection: `rect` in the
    /// session's local space, `transform` mapping it to canvas. Drawn
    /// unclipped, so a selection that sits entirely outside the canvas rect
    /// still gets a visible, grabbable handle box (only the host view's
    /// bounds clamp it — the path itself is never clamped).
    private func drawTransformBox(rect: CGRect, transform: CGAffineTransform,
                                  viewport: Viewport) {
        let corners = rect.corners.map { viewport.toView($0.applying(transform)) }
        guard corners.count == 4 else { return }

        let outline = NSBezierPath()
        outline.move(to: corners[0])
        for corner in corners.dropFirst() { outline.line(to: corner) }
        outline.close()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        outline.lineWidth = 2.5
        outline.stroke()
        NSColor.white.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        for handle in TransformHandle.allCases {
            let point = viewport.toView(handle.localPoint(in: rect).applying(transform))
            drawHandleSquare(at: point)
        }

        // Centre-point marker.
        let center = viewport.toView(rect.center.applying(transform))
        let circle = NSBezierPath(ovalIn: CGRect(x: center.x - 3.5, y: center.y - 3.5,
                                                 width: 7, height: 7))
        NSColor.black.withAlphaComponent(0.7).setStroke()
        circle.lineWidth = 2.5
        circle.stroke()
        NSColor.white.setStroke()
        circle.lineWidth = 1
        circle.stroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: center.x - 6, y: center.y))
        cross.line(to: CGPoint(x: center.x + 6, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - 6))
        cross.line(to: CGPoint(x: center.x, y: center.y + 6))
        cross.lineWidth = 1
        cross.stroke()
    }

    private func drawHandleSquare(at point: CGPoint) {
        let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
        let square = NSBezierPath(rect: rect)
        NSColor.white.setFill()
        square.fill()
        NSColor.black.setStroke()
        square.lineWidth = 1
        square.stroke()
    }

    // MARK: Crop

    private func drawCrop(_ session: CropSession, viewport: Viewport) {
        let rect = session.rect.standardized.applying(viewport.viewTransform)

        //: area outside the crop dims to ~65% black.
        let dim = NSBezierPath(rect: bounds)
        dim.appendRect(rect)
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.65).setFill()
        dim.fill()

        let border = NSBezierPath(rect: rect)
        NSColor.white.setStroke()
        border.lineWidth = 1
        border.stroke()

        // Rule-of-thirds while dragging.
        if session.isAdjusting {
            let thirds = NSBezierPath()
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                thirds.move(to: CGPoint(x: x, y: rect.minY))
                thirds.line(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(i) / 3
                thirds.move(to: CGPoint(x: rect.minX, y: y))
                thirds.line(to: CGPoint(x: rect.maxX, y: y))
            }
            NSColor.white.withAlphaComponent(0.45).setStroke()
            thirds.lineWidth = 1
            thirds.stroke()
        }

        let canvasRectStandardized = session.rect.standardized
        for handle in TransformHandle.allCases {
            drawHandleSquare(at: viewport.toView(handle.localPoint(in: canvasRectStandardized)))
        }
    }

    // MARK: User guides & grid

    /// User guides in cyan — the Photoshop convention — so they read apart
    /// from the magenta dynamic smart guides. Guides positioned outside the
    /// canvas stay in the document (crop keeps them, like layer content) but
    /// are not drawn, and a guide's line spans the canvas only, never the
    /// pasteboard.
    private func drawUserGuides(viewport: Viewport) {
        let guides = store.document.guides
        guard !guides.isEmpty else { return }
        let canvasSize = store.document.canvasSize
        let path = NSBezierPath()
        for guide in guides {
            switch guide.axis {
            case .vertical:
                guard (0...canvasSize.width).contains(guide.position) else { continue }
                path.move(to: viewport.toView(CGPoint(x: guide.position, y: 0)))
                path.line(to: viewport.toView(CGPoint(x: guide.position, y: canvasSize.height)))
            case .horizontal:
                guard (0...canvasSize.height).contains(guide.position) else { continue }
                path.move(to: viewport.toView(CGPoint(x: 0, y: guide.position)))
                path.line(to: viewport.toView(CGPoint(x: canvasSize.width, y: guide.position)))
            }
        }
        NSColor(cgColor: store.guideColor.cgColor)?.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The optional grid: major lines every `gridSpacing` canvas px with
    /// subdivision lines between, anchored at the canvas TOP-left to match
    /// the top-down rulers (and Photoshop). Density guard: subdivisions
    /// collapse below ~4 screen px, then the whole grid — zoomed way out it
    /// would otherwise paint the canvas solid.
    private func drawGrid(viewport: Viewport) {
        let spacing = CGFloat(store.gridSpacing)
        let canvasSize = store.document.canvasSize
        guard spacing > 0, spacing * viewport.zoom >= 4 else { return }
        let subdivisions = max(1, store.gridSubdivisions)
        let minorStep = spacing / CGFloat(subdivisions)
        let drawMinors = subdivisions > 1 && minorStep * viewport.zoom >= 4

        let majors = NSBezierPath()
        let minors = NSBezierPath()
        let step = drawMinors ? minorStep : spacing
        var index = 0
        while true {
            let x = CGFloat(index) * step
            guard x <= canvasSize.width + 0.001 else { break }
            let isMajor = !drawMinors || index % subdivisions == 0
            let path = isMajor ? majors : minors
            path.move(to: viewport.toView(CGPoint(x: x, y: 0)))
            path.line(to: viewport.toView(CGPoint(x: x, y: canvasSize.height)))
            index += 1
        }
        index = 0
        while true {
            let y = canvasSize.height - CGFloat(index) * step
            guard y >= -0.001 else { break }
            let isMajor = !drawMinors || index % subdivisions == 0
            let path = isMajor ? majors : minors
            path.move(to: viewport.toView(CGPoint(x: 0, y: y)))
            path.line(to: viewport.toView(CGPoint(x: canvasSize.width, y: y)))
            index += 1
        }
        // Minor lines draw at 45% of the major alpha — the ratio the fixed
        // 0.25/0.55 pair had, preserved now that the colour is a preference.
        let grid = store.gridColor
        let majorColor = NSColor(srgbRed: grid.r, green: grid.g, blue: grid.b, alpha: grid.a)
        majorColor.withAlphaComponent(grid.a * 0.45).setStroke()
        minors.lineWidth = 1
        minors.stroke()
        majorColor.setStroke()
        majors.lineWidth = 1
        majors.stroke()
    }

    /// Photoshop's pixel grid: a one-device-pixel hairline at every boundary
    /// between document pixels once zoomed past 500%. Positions come from
    /// `DisplayGeometry` on the same pixel-aligned transform the composite
    /// renders with, so each line sits exactly where the magnified pixels
    /// change rather than drifting a device pixel off.
    private func drawPixelGrid(viewport: Viewport) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        let canvasSize = store.document.canvasSize
        let aligned = DisplayGeometry.pixelAligned(
            viewport.viewTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale)),
            canvasSize: canvasSize)
        let visible = CGRect(origin: .zero, size: canvasSize).applying(aligned)
            .intersection(CGRect(x: 0, y: 0, width: bounds.width * scale,
                                 height: bounds.height * scale))
        guard !visible.isNull, !visible.isEmpty else { return }
        let lines = DisplayGeometry.pixelGridLines(aligned: aligned, canvasSize: canvasSize,
                                                   visible: visible)
        let hairline = 1 / scale
        var rects: [CGRect] = []
        rects.reserveCapacity(lines.columns.count + lines.rows.count)
        for column in lines.columns {
            rects.append(CGRect(x: CGFloat(column) / scale, y: visible.minY / scale,
                                width: hairline, height: visible.height / scale))
        }
        for row in lines.rows {
            rects.append(CGRect(x: visible.minX / scale, y: CGFloat(row) / scale,
                                width: visible.width / scale, height: hairline))
        }
        // Mid-grey at half strength reads on both black and white pixels.
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 0.5))
        ctx.fill(rects)
    }

    // MARK: Smart guides

    private func drawGuides(_ guides: [SmartGuideLine], viewport: Viewport) {
        guard !guides.isEmpty else { return }
        let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        magenta.setStroke()
        for guide in guides {
            let path = NSBezierPath()
            let pad: CGFloat = 4
            switch guide.axis {
            case .vertical:
                let a = viewport.toView(CGPoint(x: guide.position, y: guide.start - pad))
                let b = viewport.toView(CGPoint(x: guide.position, y: guide.end + pad))
                path.move(to: a); path.line(to: b)
            case .horizontal:
                let a = viewport.toView(CGPoint(x: guide.start - pad, y: guide.position))
                let b = viewport.toView(CGPoint(x: guide.end + pad, y: guide.position))
                path.move(to: a); path.line(to: b)
            }
            path.lineWidth = 1
            path.stroke()
        }
    }
}

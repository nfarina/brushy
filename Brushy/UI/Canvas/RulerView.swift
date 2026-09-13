import AppKit

/// Pure tick-spacing math for the rulers, separated from the view so
/// it is unit-testable like TransformMath/SmartGuides/Viewport.
enum RulerMetrics {
    /// The tick/label step in canvas units for a zoom level: the smallest
    /// value from the sequence 1 / 2 / 5 / 10 / 25 / 50 / 100 / 250 / …
    /// ({1, 2.5, 5} scaled by decade, with the ones decade using 2) whose
    /// on-screen spacing is at least `minimumScreenSpacing`, so labels never
    /// collide. Decades below 1 (0.5, 0.25, …) extend the sequence for
    /// extreme zoom-in.
    static func niceStep(for zoom: CGFloat, minimumScreenSpacing: CGFloat = 50) -> CGFloat {
        guard zoom > 0 else { return 1 }
        let needed = minimumScreenSpacing / zoom
        let decade = pow(10, (log10(needed)).rounded(.down))
        let mantissa = needed / decade
        let two: CGFloat = decade == 1 ? 2 : 2.5
        if mantissa <= 1 { return decade }
        if mantissa <= two { return two * decade }
        if mantissa <= 5 { return 5 * decade }
        return 10 * decade
    }

    /// How many minor ticks subdivide a major step: the finest of 10/5/2 that
    /// keeps at least `minimumSpacing` screen px between ticks, else 1 (no
    /// minor ticks).
    static func minorDivisions(forScreenStep screenStep: CGFloat,
                               minimumSpacing: CGFloat = 5) -> Int {
        for n in [10, 5, 2] where screenStep / CGFloat(n) >= minimumSpacing { return n }
        return 1
    }

    /// Tick labels: integers without decimals, fractional steps trimmed.
    static func label(for value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}

/// One ruler edge: tick marks and labels in canvas units, reading
/// `store.viewport` for zoom/pan. Like the overlay it is transparent to
/// events — CanvasHostView routes ruler presses to the controller.
///
/// Coordinate contract (kept by CanvasHostView.layout): the horizontal
/// ruler's local x axis and the vertical ruler's local y axis coincide with
/// the canvas subviews' axes, so `viewport.toView(_:)` values plot directly.
///
/// Origin convention: the horizontal scale is canvas x. The vertical scale
/// displays TOP-DOWN values (0 at the canvas top edge, increasing downward)
/// — Photoshop's convention and what users expect of a ruler — while the
/// model stays y-up; the flip `display = canvasHeight − canvasY` happens
/// here, at the view boundary, and nowhere else.
final class RulerView: NSView {
    static let thickness: CGFloat = 22

    enum Orientation {
        case horizontal
        case vertical
    }

    unowned let store: DocumentStore
    let orientation: Orientation

    init(store: DocumentStore, orientation: Orientation) {
        self.store = store
        self.orientation = orientation
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let viewport = store.viewport
        guard viewport.zoom > 0, bounds.width > 0, bounds.height > 0 else { return }
        let step = RulerMetrics.niceStep(for: viewport.zoom)
        let screenStep = step * viewport.zoom
        let minorCount = RulerMetrics.minorDivisions(forScreenStep: screenStep)

        let ticks = NSBezierPath()
        let minors = NSBezierPath()
        switch orientation {
        case .horizontal: drawHorizontal(viewport, step: step, minorCount: minorCount,
                                         ticks: ticks, minors: minors)
        case .vertical: drawVertical(viewport, step: step, minorCount: minorCount,
                                     ticks: ticks, minors: minors)
        }
        NSColor.secondaryLabelColor.setStroke()
        ticks.lineWidth = 1
        ticks.stroke()
        NSColor.tertiaryLabelColor.setStroke()
        minors.lineWidth = 1
        minors.stroke()

        // Separator on the canvas-facing edge (bottom for the top ruler,
        // right for the left ruler).
        let separator = NSBezierPath()
        switch orientation {
        case .horizontal:
            separator.move(to: CGPoint(x: 0, y: 0.5))
            separator.line(to: CGPoint(x: bounds.width, y: 0.5))
        case .vertical:
            separator.move(to: CGPoint(x: bounds.width - 0.5, y: 0))
            separator.line(to: CGPoint(x: bounds.width - 0.5, y: bounds.height))
        }
        NSColor.separatorColor.setStroke()
        separator.lineWidth = 1
        separator.stroke()
    }

    private func drawHorizontal(_ viewport: Viewport, step: CGFloat, minorCount: Int,
                                ticks: NSBezierPath, minors: NSBezierPath) {
        let minCanvas = viewport.fromView(.zero).x
        let maxCanvas = viewport.fromView(CGPoint(x: bounds.width, y: 0)).x
        let first = (minCanvas / step).rounded(.down) * step
        var value = first
        while value <= maxCanvas + step {
            let x = viewport.toView(CGPoint(x: value, y: 0)).x
            ticks.move(to: CGPoint(x: x, y: 0))
            ticks.line(to: CGPoint(x: x, y: 8))
            for minor in 1..<minorCount {
                let mx = x + step / CGFloat(minorCount) * CGFloat(minor) * viewport.zoom
                minors.move(to: CGPoint(x: mx, y: 0))
                minors.line(to: CGPoint(x: mx, y: 4))
            }
            RulerMetrics.label(for: value)
                .draw(at: CGPoint(x: x + 2, y: bounds.height - 13),
                      withAttributes: Self.labelAttributes)
            value += step
        }
    }

    private func drawVertical(_ viewport: Viewport, step: CGFloat, minorCount: Int,
                              ticks: NSBezierPath, minors: NSBezierPath) {
        let canvasHeight = store.document.canvasSize.height
        // Display value D = canvasHeight − canvasY (top-down); D grows as the
        // view y shrinks.
        let dAtBottom = canvasHeight - viewport.fromView(.zero).y
        let dAtTop = canvasHeight - viewport.fromView(CGPoint(x: 0, y: bounds.height)).y
        let first = (min(dAtTop, dAtBottom) / step).rounded(.down) * step
        let last = max(dAtTop, dAtBottom)
        var display = first
        while display <= last + step {
            let y = viewport.toView(CGPoint(x: 0, y: canvasHeight - display)).y
            ticks.move(to: CGPoint(x: bounds.width - 8, y: y))
            ticks.line(to: CGPoint(x: bounds.width, y: y))
            for minor in 1..<minorCount {
                // Display grows downward, so minor ticks descend in view y.
                let my = y - step / CGFloat(minorCount) * CGFloat(minor) * viewport.zoom
                minors.move(to: CGPoint(x: bounds.width - 4, y: my))
                minors.line(to: CGPoint(x: bounds.width, y: my))
            }
            // Rotated −90°: the label reads top-to-bottom (matching the
            // top-down scale) with glyph tops toward the canvas.
            if let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                context.cgContext.translateBy(x: 3, y: y - 3)
                context.cgContext.rotate(by: -.pi / 2)
                RulerMetrics.label(for: display)
                    .draw(at: .zero, withAttributes: Self.labelAttributes)
                context.restoreGraphicsState()
            }
            display += step
        }
    }
}

/// The dead square where the two rulers meet.
final class RulerCornerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let border = NSBezierPath()
        border.move(to: CGPoint(x: 0, y: 0.5))
        border.line(to: CGPoint(x: bounds.width, y: 0.5))
        border.move(to: CGPoint(x: bounds.width - 0.5, y: 0))
        border.line(to: CGPoint(x: bounds.width - 0.5, y: bounds.height))
        NSColor.separatorColor.setStroke()
        border.lineWidth = 1
        border.stroke()
    }
}

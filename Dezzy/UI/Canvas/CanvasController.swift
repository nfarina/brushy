import AppKit
import CoreGraphics

/// Translates canvas mouse/keyboard events into tool behaviour. All geometry
/// decisions delegate to the pure helpers (TransformMath, SmartGuides), and all
/// state changes go through the store.
final class CanvasController {
    unowned let store: DocumentStore
    weak var view: NSView?

    /// Space-bar pan: works mid-tool without cancelling the tool — while
    /// space is down drags pan the viewport; tool gestures use canvas-space
    /// anchors, so they resume seamlessly on release. The one exception is a
    /// marquee being drawn, which space repositions instead (Photoshop).
    var spaceDown = false {
        didSet { refreshCursor() }
    }

    private var currentModifiers: NSEvent.ModifierFlags = []
    private var lastViewPoint: CGPoint = .zero
    private var currentViewPoint: CGPoint = .zero
    private var hoverViewPoint: CGPoint?

    /// A move drag counts as a click below this many *screen* px — the
    /// threshold that decides ⇧-click (add to selection) from ⇧-drag
    /// (constrain to 45°); see `mouseUp`. Same order as the marquee's
    /// click-vs-drag threshold.
    private static let clickSlop: CGFloat = 3

    private enum Drag {
        case pan
        // `shiftAtDown` / `startView` exist for the ⇧ click-vs-drag decision,
        // which is deferred to mouseUp.
        case moveLayer(layerID: UUID, startCanvas: CGPoint, initial: CGAffineTransform,
                       viaSession: Bool, moved: Bool, duplicated: Bool,
                       shiftAtDown: Bool, startView: CGPoint)
        case scaleHandle(handle: TransformHandle, initial: CGAffineTransform)
        case rotate(initial: CGAffineTransform, startCanvas: CGPoint)
        // Transform Selection (gestures on the selection outline).
        case selectionMove(startCanvas: CGPoint, initial: CGAffineTransform)
        case selectionScaleHandle(handle: TransformHandle, initial: CGAffineTransform)
        case selectionRotate(initial: CGAffineTransform, startCanvas: CGPoint)
        case cropNew(startCanvas: CGPoint)
        case cropHandle(handle: TransformHandle, initialRect: CGRect)
        case cropMove(startCanvas: CGPoint, initialRect: CGRect)
        case marquee(startCanvas: CGPoint, mode: SelectionState.CombineMode)
        case lasso(points: [CGPoint], mode: SelectionState.CombineMode)
        case brushStroke
        case sampleColor(transient: Bool)
        case shapeNew(startCanvas: CGPoint)
        case gradientDrag(startCanvas: CGPoint)
        // Ruler-guide gestures: dragging out a new guide from a
        // ruler (`original` nil) or moving an existing one. `base` is the
        // document before the gesture — live updates rebuild from it, so the
        // gesture stays one atomic edit and cancelling is just re-committing
        // the base. `baseAxis` is the axis before any ⌥ flip.
        case guide(id: UUID, baseAxis: Guide.Axis, original: Guide?, base: Document)
    }

    private var drag: Drag?

    init(store: DocumentStore) {
        self.store = store
    }

    private var viewport: Viewport { store.viewport }
    private var snapDisabled: Bool { currentModifiers.contains(.command) }
    private var shiftDown: Bool { currentModifiers.contains(.shift) }
    private var optionDown: Bool { currentModifiers.contains(.option) }

    // MARK: - Mouse

    func mouseDown(at viewPoint: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        currentModifiers = modifiers
        lastViewPoint = viewPoint
        currentViewPoint = viewPoint
        let canvasPoint = viewport.fromView(viewPoint)

        if spaceDown {
            drag = .pan
            refreshCursor()
            return
        }

        if let session = store.transformSession {
            if clickCount >= 2 && insideBox(viewPoint, rect: session.sourceRect,
                                            transform: session.currentTransform) {
                store.commitTransformSession()
                drag = nil
                return
            }
            if let handle = hitTransformHandle(viewPoint, rect: session.sourceRect,
                                               transform: session.currentTransform) {
                drag = .scaleHandle(handle: handle, initial: session.currentTransform)
            } else if hitRotateZone(viewPoint, rect: session.sourceRect,
                                    transform: session.currentTransform) {
                drag = .rotate(initial: session.currentTransform, startCanvas: canvasPoint)
            } else if insideBox(viewPoint, rect: session.sourceRect,
                                transform: session.currentTransform) {
                drag = .moveLayer(layerID: session.layerID, startCanvas: canvasPoint,
                                  initial: session.currentTransform, viaSession: true, moved: false,
                                  duplicated: false, shiftAtDown: false, startView: viewPoint)
            }
            return
        }

        // Transform Selection mirrors the Cmd+T gesture set, with
        // `baseBounds` playing the role of the layer's sourceRect.
        if let session = store.selectionTransformSession {
            if clickCount >= 2 && insideBox(viewPoint, rect: session.baseBounds,
                                            transform: session.currentTransform) {
                store.commitSelectionTransformSession()
                drag = nil
                return
            }
            if let handle = hitTransformHandle(viewPoint, rect: session.baseBounds,
                                               transform: session.currentTransform) {
                drag = .selectionScaleHandle(handle: handle, initial: session.currentTransform)
            } else if hitRotateZone(viewPoint, rect: session.baseBounds,
                                    transform: session.currentTransform) {
                drag = .selectionRotate(initial: session.currentTransform, startCanvas: canvasPoint)
            } else if insideBox(viewPoint, rect: session.baseBounds,
                                transform: session.currentTransform) {
                drag = .selectionMove(startCanvas: canvasPoint, initial: session.currentTransform)
            }
            return
        }

        switch store.activeTool {
        case .move:
            // A guide within grab range wins over layer picking —
            // the 4 px tolerance is small enough not to shadow layer drags.
            if let guide = hitGuide(at: viewPoint) {
                drag = .guide(id: guide.id, baseAxis: guide.axis, original: guide,
                              base: store.document)
                refreshCursor()
                return
            }
            // With a selection up, the Move tool drags the selected PIXELS,
            // wherever on the canvas the drag starts (Photoshop). ⌥ duplicates
            // them instead of cutting them out. Falls through to moving the
            // whole layer when there is nothing liftable under the selection.
            if !store.selection.isEmpty,
               let float = store.beginSelectionFloat(cutting: !optionDown) {
                drag = .moveLayer(layerID: float.floatLayerID, startCanvas: canvasPoint,
                                  initial: float.initialTransform, viaSession: false,
                                  moved: false, duplicated: false, shiftAtDown: false,
                                  startView: viewPoint)
                return
            }
            // move tool: click-to-select and ⌥-drag duplicate. The ⌥ state
            // latches at mouse-down (modifiers are re-read live mid-drag, and
            // releasing ⌥ must not un-duplicate).
            guard let target = moveTarget(at: canvasPoint) else { return }
            if optionDown {
                guard let copy = store.beginDuplicateDrag(of: target.id) else { return }
                drag = .moveLayer(layerID: copy.id, startCanvas: canvasPoint,
                                  initial: copy.transform, viaSession: false, moved: false,
                                  duplicated: true, shiftAtDown: false, startView: viewPoint)
            } else {
                // ⇧ means two things on the Move tool: add to the
                // selection (Photoshop's ⇧-click) and constrain the drag to
                // 45° (the pre-existing meaning). They coexist because the
                // decision is deferred to mouse-up — a press that never moves
                // past `clickSlop` was a click, anything further was a drag —
                // so ⇧-down deliberately selects NOTHING yet. ⌘ is not
                // overloaded here: it already means "disable snapping".
                if store.autoSelectLayer && !shiftDown {
                    store.selectLayer(target.id)
                }
                drag = .moveLayer(layerID: target.id, startCanvas: canvasPoint,
                                  initial: target.transform, viaSession: false, moved: false,
                                  duplicated: false, shiftAtDown: shiftDown, startView: viewPoint)
            }
        case .marquee:
            drag = .marquee(startCanvas: canvasPoint, mode: combineMode())
        case .lasso:
            drag = .lasso(points: [canvasPoint], mode: combineMode())
        case .crop:
            guard var session = store.cropSession else { return }
            if let handle = hitCropHandle(viewPoint, session) {
                drag = .cropHandle(handle: handle, initialRect: session.rect)
            } else if viewRect(of: session.rect).insetBy(dx: 4, dy: 4).contains(viewPoint) {
                drag = .cropMove(startCanvas: canvasPoint, initialRect: session.rect)
            } else {
                drag = .cropNew(startCanvas: canvasPoint)
            }
            session.isAdjusting = true
            store.updateCropSession(session)
        case .eyedropper:
            drag = .sampleColor(transient: false)
            applySample(at: canvasPoint, transient: false)
        case .brush, .eraser:
            if optionDown {
                // ⌥ turns the brush into a transient eyedropper for the
                // duration of the press. ⌥ is otherwise unused by the brush
                // tools (it means subtract for marquee/lasso and from-centre
                // for transform handles), so there is no conflict — do not
                // extend this to any other tool. The size ring hides while
                // sampling.
                store.brushCursorPoint = nil
                drag = .sampleColor(transient: true)
                applySample(at: canvasPoint, transient: true)
                return
            }
            store.brushCursorPoint = canvasPoint
            store.beginBrushStroke(at: canvasPoint, eraser: store.activeTool == .eraser)
            drag = .brushStroke
        case .text:
            // Clicking existing text edits it in place; empty canvas creates.
            if let layer = store.textLayer(at: canvasPoint) {
                store.beginTextSession(editing: layer.id, caretAt: canvasPoint)
            } else {
                store.beginTextSession(creatingAt: canvasPoint)
            }
        case .shape:
            drag = .shapeNew(startCanvas: canvasPoint)
        case .gradient:
            drag = .gradientDrag(startCanvas: canvasPoint)
        }
    }

    /// Mouse-down on a ruler: starts dragging out a new guide — the
    /// top ruler makes horizontal guides, the left ruler vertical ones, like
    /// Photoshop. The host view routes ruler presses here; creation is inert
    /// while guides are locked and during transform sessions (interleaving a
    /// guide commit with a live session would entangle their history entries).
    func rulerMouseDown(axis: Guide.Axis, at viewPoint: CGPoint,
                        modifiers: NSEvent.ModifierFlags) {
        currentModifiers = modifiers
        lastViewPoint = viewPoint
        currentViewPoint = viewPoint
        guard !spaceDown, !store.guidesLocked,
              store.transformSession == nil,
              store.selectionTransformSession == nil else { return }
        // Dragging a guide out while guides are hidden would place it
        // invisibly — turn them back on, like Photoshop.
        store.guidesVisible = true
        let canvasPoint = viewport.fromView(viewPoint)
        let guide = Guide(axis: axis,
                          position: axis == .vertical ? canvasPoint.x : canvasPoint.y)
        drag = .guide(id: guide.id, baseAxis: axis, original: nil, base: store.document)
        store.setLiveDocument(store.document.addingGuide(guide))
        refreshCursor()
    }

    /// The layer a Move-tool click targets: with Auto-Select, the topmost
    /// layer with visible pixels under the cursor (pixel-accurate —
    /// `Document.topmostLayer(at:)`); otherwise the panel selection, as
    /// before. Empty-canvas clicks target nothing, deliberately leaving the
    /// current selection alone.
    private func moveTarget(at canvasPoint: CGPoint) -> Layer? {
        if store.autoSelectLayer {
            return store.document.topmostLayer(at: canvasPoint)
        }
        guard let layer = store.selectedLayer, layer.isVisible else { return nil }
        return layer
    }

    func mouseDragged(to viewPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {
        currentModifiers = modifiers
        currentViewPoint = viewPoint
        defer { lastViewPoint = viewPoint }

        // Space mid-marquee moves the rectangle being drawn: the anchor
        // travels with the pointer, so the size holds; releasing space
        // resumes sizing from the moved anchor.
        if spaceDown, case .marquee(let startCanvas, let mode) = drag {
            let delta = viewport.fromView(viewPoint) - viewport.fromView(lastViewPoint)
            drag = .marquee(startCanvas: startCanvas + delta, mode: mode)
            applyDrag(at: viewPoint)
            return
        }
        // Space pans mid-gesture without cancelling the tool.
        if spaceDown || isPanDrag {
            let delta = viewPoint - lastViewPoint
            store.viewport.pan(by: delta)
            return
        }
        applyDrag(at: viewPoint)
    }

    /// Modifier changes mid-drag re-evaluate the gesture from the stored points,
    /// so Shift/Option/Cmd take effect live, like Photoshop.
    func modifiersChanged(_ modifiers: NSEvent.ModifierFlags) {
        currentModifiers = modifiers
        if drag != nil, !isPanDrag, !spaceDown || isMarqueeDrag {
            applyDrag(at: currentViewPoint)
        }
        syncBrushRingVisibility()
        refreshCursor()
    }

    /// The ⌥ transient eyedropper hides the brush size ring while ⌥ is held —
    /// ring and sampling crosshair together would be contradictory. Restored
    /// here (and by hover) as soon as ⌥ lifts.
    private func syncBrushRingVisibility() {
        guard drag == nil, store.activeTool.isBrushFamily, let hoverViewPoint else { return }
        store.brushCursorPoint = optionDown ? nil : viewport.fromView(hoverViewPoint)
    }

    func mouseUp(at viewPoint: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        currentModifiers = modifiers
        currentViewPoint = viewPoint
        defer {
            drag = nil
            refreshCursor()
        }
        guard let drag else { return }

        switch drag {
        case .pan:
            return
        case .moveLayer(let layerID, _, let initial, let viaSession, let moved,
                        let duplicated, let shiftAtDown, let startView):
            store.activeGuides = []
            let screenDistance = (viewPoint - startView).length
            // A floating selection: land it, or unwind the lift if the drag
            // never actually moved (a click must leave no history).
            if store.selectionFloat != nil {
                if moved {
                    store.commitSelectionFloat()
                } else {
                    store.cancelSelectionFloat()
                }
                return
            }
            if duplicated {
                // The live document already holds the copy; land the whole
                // ⌥-drag gesture as one "Duplicate Layer" undo step.
                store.commitDuplicateDrag()
            } else if shiftAtDown && !viaSession && screenDistance < Self.clickSlop {
                // ⇧-CLICK: toggle this layer's membership in the selection.
                // Sub-threshold jitter may already have nudged the layer
                // live; a click must leave it exactly where it was, so the
                // initial transform is restored before selecting (no history
                // entry either way).
                if moved { store.setLiveLayerTransform(layerID, initial) }
                // Only with Auto-Select on — with it off, canvas clicks never
                // change the selection at all, and ⇧-click must not either.
                if store.autoSelectLayer {
                    store.toggleLayerSelection(layerID)
                }
            } else if !viaSession && moved {
                store.commitMove()
            }
        case .scaleHandle, .rotate:
            store.activeGuides = []
        case .selectionMove, .selectionScaleHandle, .selectionRotate:
            // The session persists across drags; only Return / double-click /
            // Esc / a landing operation ends it. Snap feedback still clears.
            store.activeGuides = []
        case .cropNew, .cropHandle, .cropMove:
            if var session = store.cropSession {
                session.isAdjusting = false
                store.updateCropSession(session)
            }
        case .marquee(let startCanvas, let mode):
            store.previewSelectionPath = nil
            let endCanvas = viewport.fromView(viewPoint)
            let screenDistance = (viewPoint - viewport.toView(startCanvas)).length
            let rect = SelectionState.marqueeRect(from: startCanvas, to: endCanvas,
                                                  square: shiftDown, fromCenter: optionDown)
            if screenDistance < 2 {
                store.deselect()
            } else if rect.width >= 1, rect.height >= 1 {
                store.combineSelection(CGPath(rect: rect, transform: nil), mode: mode)
            }
        case .lasso(let points, let mode):
            store.previewSelectionPath = nil
            let bounds = CGRect.aabb(of: points)
            if points.count < 3 || (bounds.width < 2 / viewport.zoom && bounds.height < 2 / viewport.zoom) {
                store.deselect()
            } else {
                let path = CGMutablePath()
                path.addLines(between: points)
                path.closeSubpath()
                store.combineSelection(path, mode: mode)
            }

        case .brushStroke:
            store.endBrushStroke()

        case .sampleColor:
            // Nothing to land: sampling already applied live during the press,
            // and colours are UI state, not document state (see applySample).
            return

        case .shapeNew(let startCanvas):
            store.previewShapePath = nil
            let endCanvas = constrainedShapeEnd(from: startCanvas,
                                               to: viewport.fromView(viewPoint))
            let screenDistance = (viewPoint - viewport.toView(startCanvas)).length
            guard screenDistance >= 4 else { return }
            if store.shapeStyle.kind == .line {
                store.addShapeLayer(dragRect: .null, lineFrom: startCanvas, lineTo: endCanvas)
            } else {
                store.addShapeLayer(dragRect: CGRect.aabb(of: [startCanvas, endCanvas]),
                                    lineFrom: nil, lineTo: nil)
            }

        case .gradientDrag(let startCanvas):
            store.previewGradientLine = nil
            let endCanvas = constrainedGradientEnd(from: startCanvas,
                                                   to: viewport.fromView(viewPoint))
            let screenDistance = (viewPoint - viewport.toView(startCanvas)).length
            // A click is a zero-length drag: no-op, no history (same 2 px
            // screen threshold the marquee uses to tell clicks from drags).
            guard screenDistance >= 2 else { return }
            store.applyGradient(from: startCanvas, to: endCanvas)

        case .guide(let id, let baseAxis, let original, let base):
            let axis = optionDown ? baseAxis.flipped : baseAxis
            let canvasPoint = viewport.fromView(viewPoint)
            let position = axis == .vertical ? canvasPoint.x : canvasPoint.y
            let span: ClosedRange<CGFloat> = axis == .vertical
                ? 0...base.canvasSize.width
                : 0...base.canvasSize.height
            // Dropping a guide back on a ruler (left of / above the canvas
            // view) or outside the canvas deletes it. A cancelled new guide
            // commits the untouched base, which dissolves without a history
            // entry — as does an existing guide dropped exactly where it was.
            let overRuler = viewPoint.x < 0 || viewPoint.y > viewport.viewSize.height
            if overRuler || !span.contains(position) {
                store.commitGuideDrag(original == nil ? base : base.removingGuide(id: id),
                                      actionName: "Remove Guide")
            } else {
                let guide = Guide(id: id, axis: axis, position: position)
                store.commitGuideDrag(original == nil ? base.addingGuide(guide)
                                                      : base.replacingGuide(guide),
                                      actionName: original == nil ? "Add Guide" : "Move Guide")
            }
        }
    }

    /// Samples the composite into the colour wells. Dedicated tool: click sets
    /// the foreground, ⌥-click the background — re-evaluated per event, so
    /// toggling ⌥ mid-drag retargets live. Transient (⌥ + brush-family press):
    /// always the foreground — there ⌥ is the trigger, not the target switch.
    /// Colours are UI state, not document state: sampling intentionally makes
    /// no commit and creates no history entry — do not "fix" that.
    private func applySample(at canvasPoint: CGPoint, transient: Bool) {
        guard let color = store.sampleColor(at: canvasPoint) else { return }
        if !transient && optionDown {
            store.backgroundColor = color
        } else {
            store.foregroundColor = color
        }
    }

    /// Shift constrains shapes to squares/circles and lines to 45° steps.
    private func constrainedShapeEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        guard shiftDown else { return end }
        let delta = end - start
        if store.shapeStyle.kind == .line {
            return start + TransformMath.constrainedTo45(delta)
        }
        let side = max(abs(delta.x), abs(delta.y))
        return CGPoint(x: start.x + (delta.x < 0 ? -side : side),
                       y: start.y + (delta.y < 0 ? -side : side))
    }

    /// ⇧ constrains the gradient vector to 45° steps — the same convention as
    /// constrained moves and shape lines.
    private func constrainedGradientEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        guard shiftDown else { return end }
        return start + TransformMath.constrainedTo45(end - start)
    }

    private func shapePreviewPath(from start: CGPoint, to rawEnd: CGPoint) -> CGPath {
        let end = constrainedShapeEnd(from: start, to: rawEnd)
        switch store.shapeStyle.kind {
        case .rectangle:
            return CGPath(rect: CGRect.aabb(of: [start, end]), transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: CGRect.aabb(of: [start, end]), transform: nil)
        case .line:
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: end)
            return path
        }
    }

    private var isPanDrag: Bool {
        if case .pan = drag { return true }
        return false
    }

    private func applyDrag(at viewPoint: CGPoint) {
        guard let drag else { return }
        let canvasPoint = viewport.fromView(viewPoint)
        let threshold = SmartGuides.screenThreshold / viewport.zoom

        switch drag {
        case .pan:
            break

        case .moveLayer(let layerID, let startCanvas, let initial, let viaSession, _,
                        let duplicated, let shiftAtDown, let startView):
            guard let layer = store.document[layerID: layerID] else { return }
            var delta = canvasPoint - startCanvas
            if shiftDown { delta = TransformMath.constrainedTo45(delta) }
            var guides: [SmartGuideLine] = []
            if !snapDisabled {
                let targets = snapTargets(excluding: layerID)
                let movingBounds = layer.sourceRect.applying(initial)
                let snapped = SmartGuides.snappedMoveDelta(movingBounds: movingBounds,
                                                          rawDelta: delta,
                                                          targets: targets,
                                                          threshold: threshold)
                delta = snapped.delta
                guides = snapped.guides
            }
            // Whole-pixel moves, as in Photoshop: a drag at a fractional zoom
            // would otherwise park the layer between pixels, resampling every
            // one of them soft.
            delta = CGPoint(x: delta.x.rounded(), y: delta.y.rounded())
            let transform = TransformMath.moved(initial: initial, delta: delta)
            if viaSession {
                store.updateTransformSession(transform)
            } else {
                store.setLiveLayerTransform(layerID, transform)
            }
            store.activeGuides = guides
            self.drag = .moveLayer(layerID: layerID, startCanvas: startCanvas, initial: initial,
                                   viaSession: viaSession, moved: true, duplicated: duplicated,
                                   shiftAtDown: shiftAtDown, startView: startView)

        case .scaleHandle(let handle, let initial):
            guard let session = store.transformSession else { return }
            let proportional = handle.isCorner && !shiftDown
            let anchor = optionDown ? session.sourceRect.center
                                    : handle.opposite.localPoint(in: session.sourceRect)
            var (fx, fy) = TransformMath.scaleFactors(handle: handle,
                                                     initial: initial,
                                                     sourceRect: session.sourceRect,
                                                     currentCanvasPoint: canvasPoint,
                                                     proportional: proportional,
                                                     fromCenter: optionDown)
            var guides: [SmartGuideLine] = []
            if !snapDisabled {
                let targets = snapTargets(excluding: session.layerID)
                let anchorCanvas = anchor.applying(initial)
                let unscaledBounds = session.sourceRect.applying(initial)
                if proportional {
                    let f = SmartGuides.snappedUniformScale(fx, anchorCanvas: anchorCanvas,
                                                            unscaledBounds: unscaledBounds,
                                                            targets: targets, threshold: threshold)
                    fx = f; fy = f
                } else {
                    if handle.scalesX {
                        fx = SmartGuides.snappedAxisScale(fx, anchor: anchorCanvas.x,
                                                          unscaledEdges: [unscaledBounds.minX, unscaledBounds.maxX],
                                                          axisTargets: targets.xs,
                                                          gridLine: targets.gridLineX,
                                                          threshold: threshold)
                    }
                    if handle.scalesY {
                        fy = SmartGuides.snappedAxisScale(fy, anchor: anchorCanvas.y,
                                                          unscaledEdges: [unscaledBounds.minY, unscaledBounds.maxY],
                                                          axisTargets: targets.ys,
                                                          gridLine: targets.gridLineY,
                                                          threshold: threshold)
                    }
                }
                let transform = TransformMath.scaleAboutLocalAnchor(initial: initial, anchor: anchor,
                                                                    fx: fx, fy: fy)
                guides = SmartGuides.guides(for: session.sourceRect.applying(transform), targets: targets)
            }
            let transform = TransformMath.scaleAboutLocalAnchor(initial: initial, anchor: anchor,
                                                                fx: fx, fy: fy)
            store.updateTransformSession(transform)
            store.activeGuides = guides

        case .rotate(let initial, let startCanvas):
            guard let session = store.transformSession else { return }
            let transform = TransformMath.rotated(initial: initial,
                                                  sourceRect: session.sourceRect,
                                                  startCanvasPoint: startCanvas,
                                                  currentCanvasPoint: canvasPoint,
                                                  snapTo15Degrees: shiftDown)
            store.updateTransformSession(transform)
            store.activeGuides = []

        // Transform Selection: same TransformMath as Cmd+T. It snaps to user
        // guides and the grid only (`selectionSnapTargets`) — never
        // to layer bounds, which Photoshop doesn't do either.
        case .selectionMove(let startCanvas, let initial):
            guard let session = store.selectionTransformSession else { return }
            var delta = canvasPoint - startCanvas
            if shiftDown { delta = TransformMath.constrainedTo45(delta) }
            var guides: [SmartGuideLine] = []
            if !snapDisabled {
                let targets = selectionSnapTargets()
                let snapped = SmartGuides.snappedMoveDelta(
                    movingBounds: session.baseBounds.applying(initial),
                    rawDelta: delta, targets: targets, threshold: threshold)
                delta = snapped.delta
                guides = snapped.guides
            }
            // Whole pixels, like layer moves: keeps a marquee's edges on the grid.
            delta = CGPoint(x: delta.x.rounded(), y: delta.y.rounded())
            store.updateSelectionTransformSession(TransformMath.moved(initial: initial,
                                                                      delta: delta))
            store.activeGuides = guides

        case .selectionScaleHandle(let handle, let initial):
            guard let session = store.selectionTransformSession else { return }
            let proportional = handle.isCorner && !shiftDown
            let anchor = optionDown ? session.baseBounds.center
                                    : handle.opposite.localPoint(in: session.baseBounds)
            var (fx, fy) = TransformMath.scaleFactors(handle: handle,
                                                      initial: initial,
                                                      sourceRect: session.baseBounds,
                                                      currentCanvasPoint: canvasPoint,
                                                      proportional: proportional,
                                                      fromCenter: optionDown)
            var guides: [SmartGuideLine] = []
            if !snapDisabled {
                let targets = selectionSnapTargets()
                let anchorCanvas = anchor.applying(initial)
                let unscaledBounds = session.baseBounds.applying(initial)
                if proportional {
                    let f = SmartGuides.snappedUniformScale(fx, anchorCanvas: anchorCanvas,
                                                            unscaledBounds: unscaledBounds,
                                                            targets: targets, threshold: threshold)
                    fx = f; fy = f
                } else {
                    if handle.scalesX {
                        fx = SmartGuides.snappedAxisScale(fx, anchor: anchorCanvas.x,
                                                          unscaledEdges: [unscaledBounds.minX, unscaledBounds.maxX],
                                                          axisTargets: targets.xs,
                                                          gridLine: targets.gridLineX,
                                                          threshold: threshold)
                    }
                    if handle.scalesY {
                        fy = SmartGuides.snappedAxisScale(fy, anchor: anchorCanvas.y,
                                                          unscaledEdges: [unscaledBounds.minY, unscaledBounds.maxY],
                                                          axisTargets: targets.ys,
                                                          gridLine: targets.gridLineY,
                                                          threshold: threshold)
                    }
                }
                let transform = TransformMath.scaleAboutLocalAnchor(initial: initial, anchor: anchor,
                                                                    fx: fx, fy: fy)
                guides = SmartGuides.guides(for: session.baseBounds.applying(transform),
                                            targets: targets)
            }
            store.updateSelectionTransformSession(
                TransformMath.scaleAboutLocalAnchor(initial: initial, anchor: anchor,
                                                    fx: fx, fy: fy))
            store.activeGuides = guides

        case .selectionRotate(let initial, let startCanvas):
            guard let session = store.selectionTransformSession else { return }
            store.updateSelectionTransformSession(
                TransformMath.rotated(initial: initial,
                                      sourceRect: session.baseBounds,
                                      startCanvasPoint: startCanvas,
                                      currentCanvasPoint: canvasPoint,
                                      snapTo15Degrees: shiftDown))

        case .cropNew(let startCanvas):
            guard var session = store.cropSession else { return }
            session.rect = cropRect(from: startCanvas, to: canvasPoint,
                                    aspect: store.cropAspectRatio)
            store.updateCropSession(session)

        case .cropHandle(let handle, let initialRect):
            guard var session = store.cropSession else { return }
            session.rect = adjustedCropRect(initial: initialRect, handle: handle,
                                            to: canvasPoint, aspect: store.cropAspectRatio)
            store.updateCropSession(session)

        case .cropMove(let startCanvas, let initialRect):
            guard var session = store.cropSession else { return }
            let delta = canvasPoint - startCanvas
            session.rect = initialRect.offsetBy(dx: delta.x, dy: delta.y)
            store.updateCropSession(session)

        case .marquee(let startCanvas, _):
            // ⇧/⌥ at mouse-down chose add/subtract (`combineMode`); held
            // during the drag they also mean square / from centre, read live
            // so pressing or releasing mid-drag takes effect, as in Photoshop.
            let rect = SelectionState.marqueeRect(from: startCanvas, to: canvasPoint,
                                                  square: shiftDown, fromCenter: optionDown)
            store.previewSelectionPath = CGPath(rect: rect, transform: nil)

        case .lasso(var points, let mode):
            if let last = points.last, (canvasPoint - last).length >= 0.5 / viewport.zoom {
                points.append(canvasPoint)
                self.drag = .lasso(points: points, mode: mode)
            }
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            store.previewSelectionPath = path

        case .brushStroke:
            store.brushCursorPoint = canvasPoint
            store.continueBrushStroke(to: canvasPoint)

        case .sampleColor(let transient):
            // Drag = continuous sampling; the colour wells update live.
            applySample(at: canvasPoint, transient: transient)

        case .shapeNew(let startCanvas):
            store.previewShapePath = shapePreviewPath(from: startCanvas, to: canvasPoint)

        case .gradientDrag(let startCanvas):
            store.previewGradientLine = GradientLine(
                start: startCanvas,
                end: constrainedGradientEnd(from: startCanvas, to: canvasPoint))

        case .guide(let id, let baseAxis, let original, let base):
            // ⌥ mid-drag toggles the guide's orientation (Photoshop parity);
            // rebuilding from `base` each event keeps the gesture atomic.
            let axis = optionDown ? baseAxis.flipped : baseAxis
            let guide = Guide(id: id, axis: axis,
                              position: axis == .vertical ? canvasPoint.x : canvasPoint.y)
            store.setLiveDocument(original == nil ? base.addingGuide(guide)
                                                  : base.replacingGuide(guide))
        }
    }

    // MARK: - Keys

    func handleReturn() {
        if store.transformSession != nil {
            store.commitTransformSession()
        } else if store.selectionTransformSession != nil {
            store.commitSelectionTransformSession()
        } else if store.activeTool == .crop {
            store.commitCropSession()
        }
    }

    func handleEscape() {
        if store.transformSession != nil {
            store.cancelTransformSession()
        } else if store.selectionTransformSession != nil {
            store.cancelSelectionTransformSession()
        } else if store.activeTool == .crop {
            store.resetCropSession()
        }
    }

    func nudge(dx: CGFloat, dy: CGFloat, big: Bool) {
        let factor: CGFloat = big ? 10 : 1
        store.nudgeSelectedLayer(dx: dx * factor, dy: dy * factor)
    }

    // MARK: - Hover / cursors

    func hover(at viewPoint: CGPoint) {
        hoverViewPoint = viewPoint
        if store.activeTool.isBrushFamily && !optionDown {
            store.brushCursorPoint = viewport.fromView(viewPoint)
        } else if store.brushCursorPoint != nil {
            store.brushCursorPoint = nil
        }
        refreshCursor()
    }

    func hoverEnded() {
        hoverViewPoint = nil
        store.brushCursorPoint = nil
    }

    func refreshCursor() {
        cursor(at: hoverViewPoint ?? currentViewPoint).set()
    }

    private var isMarqueeDrag: Bool {
        if case .marquee = drag { return true }
        return false
    }

    private func cursor(at viewPoint: CGPoint) -> NSCursor {
        if (spaceDown && !isMarqueeDrag) || isPanDrag {
            return (drag != nil && isPanDrag) ? .closedHand : .openHand
        }
        if case .rotate = drag { return Cursors.rotate }
        if case .sampleColor = drag { return .crosshair }
        if case .selectionRotate = drag { return Cursors.rotate }
        if case .guide(_, let baseAxis, _, _) = drag {
            let axis = optionDown ? baseAxis.flipped : baseAxis
            return axis == .vertical ? .resizeLeftRight : .resizeUpDown
        }
        if case .scaleHandle(let handle, _) = drag,
           let session = store.transformSession {
            return resizeCursor(for: handle, rotation: session.currentTransform.rotationAngle)
        }
        if case .selectionScaleHandle(let handle, _) = drag,
           let session = store.selectionTransformSession {
            return resizeCursor(for: handle, rotation: session.currentTransform.rotationAngle)
        }
        if let session = store.transformSession {
            if let handle = hitTransformHandle(viewPoint, rect: session.sourceRect,
                                               transform: session.currentTransform) {
                return resizeCursor(for: handle, rotation: session.currentTransform.rotationAngle)
            }
            if hitRotateZone(viewPoint, rect: session.sourceRect,
                             transform: session.currentTransform) { return Cursors.rotate }
            return .arrow
        }
        if let session = store.selectionTransformSession {
            if let handle = hitTransformHandle(viewPoint, rect: session.baseBounds,
                                               transform: session.currentTransform) {
                return resizeCursor(for: handle, rotation: session.currentTransform.rotationAngle)
            }
            if hitRotateZone(viewPoint, rect: session.baseBounds,
                             transform: session.currentTransform) { return Cursors.rotate }
            return .arrow
        }
        switch store.activeTool {
        case .move:
            if let guide = hitGuide(at: viewPoint) {
                return guide.axis == .vertical ? .resizeLeftRight : .resizeUpDown
            }
            return .arrow
        case .marquee, .lasso: return .crosshair
        case .crop:
            if let session = store.cropSession, let handle = hitCropHandle(viewPoint, session) {
                let direction = CGPoint(x: handle.unitPoint.x - 0.5, y: handle.unitPoint.y - 0.5)
                return Cursors.resize(angle: atan2(direction.y, direction.x))
            }
            return .crosshair
        case .eyedropper:
            return .crosshair
        case .brush, .eraser:
            if optionDown { return .crosshair } // ⌥ = transient eyedropper
            return Cursors.dot // the overlay draws the live size ring
        case .text:
            return .iBeam
        case .shape, .gradient:
            return .crosshair
        }
    }

    private func resizeCursor(for handle: TransformHandle, rotation: CGFloat) -> NSCursor {
        // Handle direction in canvas space, so cursors follow a rotated box.
        let local = CGPoint(x: handle.unitPoint.x - 0.5, y: handle.unitPoint.y - 0.5)
        let angle = atan2(local.y, local.x) + rotation
        return Cursors.resize(angle: angle)
    }

    // MARK: - Hit testing

    private func combineMode() -> SelectionState.CombineMode {
        if shiftDown { return .add }
        if optionDown { return .subtract }
        return .replace
    }

    private func snapTargets(excluding layerID: UUID) -> SmartGuides.Targets {
        // View → Snap is the master switch over all snapping; ⌘ is
        // still checked per drag at the call sites.
        guard store.snappingEnabled else { return SmartGuides.Targets() }
        let others = store.document.layers
            .filter { $0.id != layerID && $0.isVisible }
            .map { $0.canvasBounds }
        return SmartGuides.targets(canvasRect: store.document.canvasRect,
                                   otherLayerBounds: others,
                                   guides: store.snapGuides,
                                   grid: store.snapGrid)
    }

    /// Transform Selection snaps to user guides and the grid only —
    /// deliberately not to layer bounds or the canvas centre, preserving the
    /// pre-existing behaviour (Photoshop does not snap a selection transform
    /// to layers either).
    private func selectionSnapTargets() -> SmartGuides.Targets {
        guard store.snappingEnabled else { return SmartGuides.Targets() }
        return SmartGuides.targets(canvasRect: store.document.canvasRect,
                                   otherLayerBounds: [],
                                   guides: store.snapGuides,
                                   grid: store.snapGrid,
                                   canvasEdges: false)
    }

    /// The drawn guide nearest `viewPoint` within ~4 *screen* px.
    /// Guides outside the canvas aren't drawn, so they aren't grabbable
    /// either; locked or hidden guides never grab.
    private func hitGuide(at viewPoint: CGPoint) -> Guide? {
        guard store.guidesVisible, !store.guidesLocked else { return nil }
        let tolerance: CGFloat = 4
        let canvasPoint = viewport.fromView(viewPoint)
        let canvasSize = store.document.canvasSize
        var best: (guide: Guide, distance: CGFloat)?
        for guide in store.document.guides {
            let distance: CGFloat
            switch guide.axis {
            case .vertical:
                guard (0...canvasSize.width).contains(guide.position),
                      (0...canvasSize.height).contains(canvasPoint.y) else { continue }
                distance = abs(viewport.toView(CGPoint(x: guide.position, y: 0)).x - viewPoint.x)
            case .horizontal:
                guard (0...canvasSize.height).contains(guide.position),
                      (0...canvasSize.width).contains(canvasPoint.x) else { continue }
                distance = abs(viewport.toView(CGPoint(x: 0, y: guide.position)).y - viewPoint.y)
            }
            if distance <= tolerance && distance < (best?.distance ?? .infinity) {
                best = (guide, distance)
            }
        }
        return best?.guide
    }

    // Box hit-testing shared by Free Transform and Transform Selection:
    // `rect` in the session's local space, `transform` mapping it to canvas.

    private func handleViewPoints(rect: CGRect,
                                  transform: CGAffineTransform) -> [(TransformHandle, CGPoint)] {
        TransformHandle.allCases.map { handle in
            (handle, viewport.toView(handle.localPoint(in: rect).applying(transform)))
        }
    }

    private func hitTransformHandle(_ viewPoint: CGPoint, rect: CGRect,
                                    transform: CGAffineTransform) -> TransformHandle? {
        let points = handleViewPoints(rect: rect, transform: transform)
        // Corners take priority over edge midpoints.
        for (handle, point) in points where handle.isCorner {
            if point.distance(to: viewPoint) <= 7 { return handle }
        }
        for (handle, point) in points where !handle.isCorner {
            if point.distance(to: viewPoint) <= 7 { return handle }
        }
        return nil
    }

    ///: rotate when the press is just outside a corner, within ~20pt.
    private func hitRotateZone(_ viewPoint: CGPoint, rect: CGRect,
                               transform: CGAffineTransform) -> Bool {
        guard !insideBox(viewPoint, rect: rect, transform: transform) else { return false }
        let corners = handleViewPoints(rect: rect, transform: transform).filter { $0.0.isCorner }
        return corners.contains { $0.1.distance(to: viewPoint) <= 22 }
    }

    private func insideBox(_ viewPoint: CGPoint, rect: CGRect,
                           transform: CGAffineTransform) -> Bool {
        let path = CGMutablePath()
        path.addLines(between: rect.corners.map { viewport.toView($0.applying(transform)) })
        path.closeSubpath()
        return path.contains(viewPoint)
    }

    private func viewRect(of canvasRect: CGRect) -> CGRect {
        canvasRect.applying(viewport.viewTransform)
    }

    private func hitCropHandle(_ viewPoint: CGPoint, _ session: CropSession) -> TransformHandle? {
        let rect = session.rect.standardized
        for handle in TransformHandle.allCases {
            let point = viewport.toView(handle.localPoint(in: rect))
            if point.distance(to: viewPoint) <= 7 { return handle }
        }
        return nil
    }

    // MARK: - Crop geometry

    private func cropRect(from start: CGPoint, to current: CGPoint, aspect: CGSize?) -> CGRect {
        var dx = current.x - start.x
        var dy = current.y - start.y
        if let aspect, aspect.width > 0, aspect.height > 0 {
            let ratio = aspect.height / aspect.width
            let width = max(abs(dx), abs(dy) / ratio)
            dx = (dx < 0 ? -1 : 1) * width
            dy = (dy < 0 ? -1 : 1) * width * ratio
        }
        return CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy),
                      width: max(1, abs(dx)), height: max(1, abs(dy)))
    }

    private func adjustedCropRect(initial: CGRect, handle: TransformHandle,
                                  to point: CGPoint, aspect: CGSize?) -> CGRect {
        if handle.isCorner {
            let anchor = handle.opposite.localPoint(in: initial)
            return cropRect(from: anchor, to: point, aspect: aspect)
        }
        var rect = initial
        switch handle {
        case .middleLeft:
            rect = CGRect(x: point.x, y: rect.minY, width: rect.maxX - point.x, height: rect.height)
        case .middleRight:
            rect = CGRect(x: rect.minX, y: rect.minY, width: point.x - rect.minX, height: rect.height)
        case .bottomCenter:
            rect = CGRect(x: rect.minX, y: point.y, width: rect.width, height: rect.maxY - point.y)
        case .topCenter:
            rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: point.y - rect.minY)
        default:
            break
        }
        rect = rect.standardized
        if let aspect, aspect.width > 0, aspect.height > 0 {
            let ratio = aspect.height / aspect.width
            if handle == .middleLeft || handle == .middleRight {
                let height = rect.width * ratio
                rect = CGRect(x: rect.minX, y: rect.midY - height / 2,
                              width: rect.width, height: height)
            } else {
                let width = rect.height / ratio
                rect = CGRect(x: rect.midX - width / 2, y: rect.minY,
                              width: width, height: rect.height)
            }
        }
        return CGRect(x: rect.minX, y: rect.minY,
                      width: max(1, rect.width), height: max(1, rect.height))
    }
}

private extension Guide.Axis {
    /// ⌥ while dragging a guide toggles its orientation.
    var flipped: Guide.Axis { self == .vertical ? .horizontal : .vertical }
}

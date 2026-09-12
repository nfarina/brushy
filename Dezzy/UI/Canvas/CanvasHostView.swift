import AppKit
import Combine
import UniformTypeIdentifiers

/// The canvas container: Metal composite underneath, vector overlay on top,
/// and all event routing (navigation and tool input). Non-flipped, so view
/// coordinates are y-up like canvas space.
final class CanvasHostView: NSView {
    let store: DocumentStore
    private let metalView: CanvasMetalView
    private let overlayView: CanvasOverlayView
    private let controller: CanvasController
    private var cancellables = Set<AnyCancellable>()
    // ⌘R rulers. While visible they inset the canvas subviews; the
    // viewport's view space is the *subviews'* space, so `canvasOrigin` is
    // subtracted from every event location.
    private let topRuler: RulerView
    private let leftRuler: RulerView
    private let rulerCorner = RulerCornerView()
    private var canvasOrigin: CGPoint = .zero

    var overlay: NSView { overlayView }
    /// The floating text task bar while a session is active (DebugSnapshot
    /// re-draws it after painting the composite over the canvas area).
    var textTaskBar: NSView? { textCoordinator.taskBarView }
    private let textCoordinator: TextEditingCoordinator

    init(store: DocumentStore) {
        self.store = store
        metalView = CanvasMetalView(store: store)
        overlayView = CanvasOverlayView(store: store)
        controller = CanvasController(store: store)
        textCoordinator = TextEditingCoordinator(store: store)
        topRuler = RulerView(store: store, orientation: .horizontal)
        leftRuler = RulerView(store: store, orientation: .vertical)
        super.init(frame: .zero)
        controller.view = self
        textCoordinator.hostView = self
        // macOS 14 defaults to false; a zoomed inline text editor must not
        // paint over the surrounding chrome.
        clipsToBounds = true

        // layout() owns every frame; no autoresizing.
        for subview in [metalView, overlayView, topRuler, leftRuler, rulerCorner] as [NSView] {
            addSubview(subview)
        }
        registerForDraggedTypes([.fileURL])

        store.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private var renderedVersion = -1
    private var renderedViewport = Viewport()
    private var renderedStrokeImage: ObjectIdentifier?
    private var renderedExcludedLayer: UUID?

    /// The overlay (ants, guides, cursor ring) redraws on any change — it's
    /// cheap vector work. The Metal composite re-renders only when something
    /// that feeds it changed; hover and panel-only updates skip it.
    private func refresh() {
        overlayView.needsDisplay = true
        if store.rulersVisible {
            topRuler.needsDisplay = true
            leftRuler.needsDisplay = true
        }
        if store.rulersVisible != (canvasOrigin.x > 0) {
            needsLayout = true // ⌘R toggled — re-inset the canvas
        }
        textCoordinator.syncWithStore()
        let strokeImage = store.strokePreview.map { ObjectIdentifier($0.coverageImage) }
        // A text session excludes its layer from the composite without
        // bumping renderVersion (the document is untouched).
        let excludedLayer = store.textSession?.layerID
        if store.renderVersion != renderedVersion
            || store.viewport != renderedViewport
            || strokeImage != renderedStrokeImage
            || excludedLayer != renderedExcludedLayer {
            renderedVersion = store.renderVersion
            renderedViewport = store.viewport
            renderedStrokeImage = strokeImage
            renderedExcludedLayer = excludedLayer
            metalView.needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        // ⌘R rulers inset the canvas from the top and left. The
        // viewport's viewSize must be the INSET size — Viewport.fit reads it,
        // and would centre the canvas under the rulers otherwise.
        let inset: CGFloat = store.rulersVisible ? RulerView.thickness : 0
        let canvasFrame = CGRect(x: inset, y: 0,
                                 width: max(0, bounds.width - inset),
                                 height: max(0, bounds.height - inset))
        canvasOrigin = canvasFrame.origin
        textCoordinator.canvasOriginInHost = canvasFrame.origin
        metalView.frame = canvasFrame
        overlayView.frame = canvasFrame
        topRuler.isHidden = !store.rulersVisible
        leftRuler.isHidden = !store.rulersVisible
        rulerCorner.isHidden = !store.rulersVisible
        if store.rulersVisible {
            // Frames keep ruler-local axes aligned with the canvas subviews'
            // (RulerView's coordinate contract): the top ruler starts at the
            // inset x, the left ruler shares the canvas's y span.
            topRuler.frame = CGRect(x: inset, y: bounds.height - inset,
                                    width: max(0, bounds.width - inset), height: inset)
            leftRuler.frame = CGRect(x: 0, y: 0,
                                     width: inset, height: max(0, bounds.height - inset))
            rulerCorner.frame = CGRect(x: 0, y: bounds.height - inset,
                                       width: inset, height: inset)
            topRuler.needsDisplay = true
            leftRuler.needsDisplay = true
        }
        guard canvasFrame.width > 50, canvasFrame.height > 50 else { return }
        let sizeChanged = store.viewport.viewSize != canvasFrame.size
        if sizeChanged {
            store.viewport.viewSize = canvasFrame.size
        }
        if !store.viewport.isInitialized || (sizeChanged && !store.viewport.hasUserAdjusted) {
            store.viewport.fit(canvasSize: store.document.canvasSize)
            store.viewport.isInitialized = true
        }
    }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { true }

    /// The canvas owns the keyboard when a window opens, so tool keys work
    /// immediately. With macOS Keyboard Navigation turned on, the window
    /// otherwise gives initial focus to the first control in its key-view
    /// loop — the options bar's Auto-Select checkbox — and bare-key
    /// shortcuts go there instead.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            // Never pull focus out of text being typed.
            if !(window.firstResponder is NSText) { window.makeFirstResponder(self) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    // MARK: - Mouse

    /// Event locations in the canvas subviews' space — the space Viewport and
    /// the controller work in. Differs from host space by the ruler inset.
    private func location(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x - canvasOrigin.x, y: p.y - canvasOrigin.y)
    }

    /// Which ruler a host-space point presses: the top ruler drags out
    /// horizontal guides, the left ruler vertical ones.
    private func rulerAxis(at hostPoint: CGPoint) -> Guide.Axis? {
        guard store.rulersVisible else { return nil }
        if topRuler.frame.contains(hostPoint) { return .horizontal }
        if leftRuler.frame.contains(hostPoint) { return .vertical }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        // Clicks inside the inline text editor never reach us; a click out
        // here while editing commits the session and is consumed (Photoshop
        // behaviour — the next click starts the next action).
        if store.textSession != nil {
            store.commitTextSession()
            return
        }
        window?.makeFirstResponder(self)
        if let axis = rulerAxis(at: convert(event.locationInWindow, from: nil)) {
            controller.rulerMouseDown(axis: axis, at: location(event),
                                      modifiers: event.modifierFlags)
            return
        }
        controller.mouseDown(at: location(event), modifiers: event.modifierFlags,
                             clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        controller.mouseDragged(to: location(event), modifiers: event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        controller.mouseUp(at: location(event), modifiers: event.modifierFlags,
                           clickCount: event.clickCount)
    }

    override func mouseMoved(with event: NSEvent) {
        hover(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        hover(with: event)
    }

    /// Hovering the rulers (or the corner) is hovering chrome, not canvas:
    /// plain arrow, no brush ring.
    private func hover(with event: NSEvent) {
        let hostPoint = convert(event.locationInWindow, from: nil)
        if store.rulersVisible, !metalView.frame.contains(hostPoint) {
            controller.hoverEnded()
            NSCursor.arrow.set()
            return
        }
        controller.hover(at: location(event))
    }

    override func mouseExited(with event: NSEvent) {
        controller.hoverEnded()
        NSCursor.arrow.set()
    }

    override func flagsChanged(with event: NSEvent) {
        controller.modifiersChanged(event.modifierFlags)
    }

    // MARK: - Scroll / zoom (navigation)

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 8; dy *= 8
        }
        // Shift + scroll pans horizontally (wheel mice report only deltaY).
        if event.modifierFlags.contains(.shift) && abs(dx) < 0.001 {
            dx = dy; dy = 0
        }
        store.viewport.pan(by: CGPoint(x: dx, y: -dy))
    }

    override func magnify(with event: NSEvent) {
        let factor = 1 + event.magnification
        let anchor = location(event)
        store.viewport.setZoom(store.viewport.zoom * factor, anchorView: anchor)
    }

    // MARK: - Keyboard

    /// ⌘Z / ⇧⌘Z during a live canvas gesture must apply to the gesture, not
    /// committed history (defect D). The task plan called for a
    /// keyDown interception, but keyDown can never see these keys: the Edit
    /// menu claims its key equivalents during the performKeyEquivalent pass,
    /// which runs before key events reach any responder — so the interception
    /// lives here instead. performKeyEquivalent walks the window's whole view
    /// tree regardless of first responder, so it fires during inline text
    /// editing too: the textSession guard keeps the NSTextView's own undo
    /// untouched (its ⌘Z falls through to the menu exactly as before).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command] || flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "z",
           store.textSession == nil,
           store.handleUndoKeyDuringModalSession(redo: flags.contains(.shift)) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // ⌥⌫ / ⌘⌫ fill the selection (Photoshop muscle memory); handled here,
        // not as menu equivalents, so text fields keep their delete behaviour.
        if event.keyCode == 51 {
            if event.modifierFlags.contains(.option) {
                store.fillSelection()
                return
            }
            if event.modifierFlags.contains(.command) {
                store.fillSelection(withBackgroundColor: true)
                return
            }
        }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 49: // space — pan mode, works mid-tool
            if !event.isARepeat { controller.spaceDown = true }
            return
        case 53: // esc
            controller.handleEscape()
            return
        case 36, 76: // return / enter
            controller.handleReturn()
            return
        case 51, 117: // delete / forward delete
            // With a selection up ⌫ clears the selected pixels, as in
            // Photoshop; with none it still deletes the layer.
            if store.selection.isEmpty {
                store.deleteSelectedLayer()
            } else {
                store.clearSelection()
            }
            return
        case 123: controller.nudge(dx: -1, dy: 0, big: event.modifierFlags.contains(.shift)); return
        case 124: controller.nudge(dx: 1, dy: 0, big: event.modifierFlags.contains(.shift)); return
        case 125: controller.nudge(dx: 0, dy: -1, big: event.modifierFlags.contains(.shift)); return
        case 126: controller.nudge(dx: 0, dy: 1, big: event.modifierFlags.contains(.shift)); return
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": store.activeTool = .move
        case "m": store.activeTool = .marquee
        case "l": store.activeTool = .lasso
        case "c": store.activeTool = .crop
        case "b": store.activeTool = .brush
        case "e": store.activeTool = .eraser
        case "t": store.activeTool = .text
        case "u": store.activeTool = .shape
        case "i": store.activeTool = .eyedropper
        case "g": store.activeTool = .gradient
        case "x": store.swapBrushColors()
        case "d": store.resetBrushColors()
        case "[":
            if event.modifierFlags.contains(.shift) {
                store.adjustBrushHardness(increase: false)
            } else {
                store.adjustBrushSize(increase: false)
            }
        case "]":
            if event.modifierFlags.contains(.shift) {
                store.adjustBrushHardness(increase: true)
            } else {
                store.adjustBrushSize(increase: true)
            }
        case "{": store.adjustBrushHardness(increase: false)
        case "}": store.adjustBrushHardness(increase: true)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            controller.spaceDown = false
            return
        }
        super.keyUp(with: event)
    }

    // Select > All is a DezzyDocument action (reached through the
    // responder chain), so there is deliberately no selectAll override here.

    // MARK: - Drag & drop placement

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(from: sender)
        guard !urls.isEmpty else { return false }
        store.placeImages(from: urls)
        return true
    }

    private func imageURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: options) as? [URL]
        return urls ?? []
    }
}

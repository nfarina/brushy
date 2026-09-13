import AppKit
import CoreGraphics
import SwiftUI

/// Classifies editing keys. Pure, for headless tests: numpad Enter (76) and
/// ⌘Return commit; Esc (53) cancels; plain Return falls through to insert a
/// newline.
enum TextCommitKeys {
    enum Action: Equatable {
        case commit
        case cancel
    }

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Action? {
        switch keyCode {
        case 53: return .cancel
        case 76: return .commit
        case 36 where modifiers.contains(.command): return .commit
        default: return nil
        }
    }
}

/// The on-canvas text editor. Built on the shared TextKit 1 stack
/// (`TextLayout`), so its glyph layout is identical to the committed raster.
final class CanvasTextView: NSTextView {
    weak var store: DocumentStore?
    /// The canvas host — scroll/pinch forward so pan/zoom work mid-session.
    weak var eventForwardTarget: NSView?

    override func keyDown(with event: NSEvent) {
        // Classify before super: Esc arrives bound to complete:, and numpad
        // Enter is indistinguishable from Return at the selector level.
        if let action = TextCommitKeys.action(keyCode: event.keyCode,
                                              modifiers: event.modifierFlags) {
            switch action {
            case .commit: store?.commitTextSession()
            case .cancel: store?.cancelTextSession()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        eventForwardTarget?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        eventForwardTarget?.magnify(with: event)
    }
}

/// Reconciles the store's `textSession` with an overlay editor: a wrapper
/// NSView whose BOUNDS hold the content at native size while its FRAME is
/// scaled by (layer scale × zoom) and rotated via `frameCenterRotation` —
/// AppKit scales drawing and events, and the text lays out at the native font
/// size (glyph-identical to the commit). Idempotent `syncWithStore()` is
/// driven by the host's refresh; the editor is a pure function of
/// (session, content size, viewport).
final class TextEditingCoordinator: NSObject, NSTextViewDelegate {
    unowned let store: DocumentStore
    weak var hostView: NSView?
    /// Where the canvas subviews sit inside the host (ruler inset).
    /// The viewport's view space is the *subviews'* space, but the editor
    /// chrome lives on the host — placement frames shift by this origin.
    var canvasOriginInHost: CGPoint = .zero

    // Rotation and scaling live on SEPARATE views: AppKit's
    // frameCenterRotation computes its centre wrongly on a bounds-scaled view
    // (shifting the frame by (frameSize−boundsSize)/2 even for rotation 0).
    // The outer view rotates (frame == bounds, unscaled); the inner view
    // bounds-scales (never rotated); the text view lays out at native size.
    private var rotationView: NSView?
    private var scaleView: NSView?
    private var textView: CanvasTextView?
    /// Floating style/commit bar (Photoshop's contextual task bar). Kept
    /// BELOW the editor in z-order so a clamped bar never hides the text,
    /// and so `host.subviews.last` stays the editor (DebugSnapshot relies
    /// on that).
    private(set) var taskBarView: NSView?
    // TextKit ownership: nothing downstream retains the storage — we must.
    private var storage: NSTextStorage?
    private var layoutManager: NSLayoutManager?
    private var container: NSTextContainer?
    /// Typing undo stays out of the document's snapshot history (⌘Z mid-edit
    /// undoes typing, Photoshop-style); discarded at session end.
    private var sessionUndoManager: UndoManager?
    private var builtSessionID: UUID?
    private var needsCaretPlacement = false

    init(store: DocumentStore) {
        self.store = store
    }

    func syncWithStore() {
        guard let session = store.textSession else {
            tearDown()
            return
        }
        if builtSessionID != session.id {
            tearDown()
            build(for: session)
        }
        reconcile(session)
    }

    // MARK: - Lifecycle

    private func build(for session: DocumentStore.TextEditSession) {
        guard let host = hostView else { return }
        let (storage, layoutManager, container) = TextLayout.makeTextSystem(for: session.spec)
        self.storage = storage
        self.layoutManager = layoutManager
        self.container = container

        let textView = CanvasTextView(frame: .zero, textContainer: container)
        textView.store = store
        textView.eventForwardTarget = host
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.typingAttributes = TextLayout.attributes(for: session.spec)
        textView.insertionPointColor = Self.caretColor(for: session.spec)

        let scaleView = NSView()
        scaleView.addSubview(textView)
        let rotationView = NSView()
        rotationView.wantsLayer = true // deterministic compositing above the MTKView
        rotationView.addSubview(scaleView)
        host.addSubview(rotationView) // added last → topmost sibling

        let taskBar = NSHostingView(rootView: TextTaskBar(store: store))
        taskBar.wantsLayer = true
        host.addSubview(taskBar, positioned: .below, relativeTo: rotationView)

        self.rotationView = rotationView
        self.scaleView = scaleView
        self.textView = textView
        self.taskBarView = taskBar
        sessionUndoManager = UndoManager()
        builtSessionID = session.id
        needsCaretPlacement = true
    }

    private func tearDown() {
        guard rotationView != nil else {
            builtSessionID = nil
            return
        }
        let window = textView?.window
        let hadFocus = window?.firstResponder === textView
        textView?.delegate = nil
        rotationView?.removeFromSuperview()
        taskBarView?.removeFromSuperview()
        if hadFocus, let host = hostView {
            window?.makeFirstResponder(host)
        }
        rotationView = nil
        scaleView = nil
        textView = nil
        taskBarView = nil
        storage = nil
        layoutManager = nil
        container = nil
        sessionUndoManager = nil
        builtSessionID = nil
        needsCaretPlacement = false
    }

    // MARK: - Reconcile

    private func reconcile(_ session: DocumentStore.TextEditSession) {
        guard let textView else { return }
        // Style sync — never during IME composition (breaks marked text).
        if !textView.hasMarkedText() {
            let wanted = TextLayout.attributes(for: session.spec)
            let currentFont = textView.typingAttributes[.font] as? NSFont
            let currentColor = textView.typingAttributes[.foregroundColor] as? NSColor
            if currentFont != wanted[.font] as? NSFont
                || currentColor != wanted[.foregroundColor] as? NSColor {
                let range = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
                textView.textStorage?.setAttributes(wanted, range: range)
                textView.typingAttributes = wanted
                textView.insertionPointColor = Self.caretColor(for: session.spec)
            }
        }
        updateGeometry(session)
        if needsCaretPlacement {
            needsCaretPlacement = false
            placeCaret(session)
            if let window = hostView?.window {
                window.makeFirstResponder(textView)
            }
        }
    }

    private func updateGeometry(_ session: DocumentStore.TextEditSession) {
        guard let rotationView, let scaleView, let textView,
              let layoutManager, let container else { return }
        let used = TextLayout.usedSize(layoutManager, container)
        let (pixelWidth, pixelHeight) = TextLayout.paddedPixelSize(for: used)
        // Minimum width keeps an empty box clickable with a visible caret band.
        let contentSize = CGSize(width: max(CGFloat(pixelWidth), 12),
                                 height: CGFloat(pixelHeight))
        let placement = TextEditingGeometry.placement(anchorTopLeft: session.anchorTopLeft,
                                                      rotation: session.rotation,
                                                      scaleX: session.scaleX,
                                                      scaleY: session.scaleY,
                                                      contentSize: contentSize,
                                                      viewport: store.viewport)
        // Reset → set frame → re-apply rotation (setting frame while rotated
        // composes wrongly). The rotation view is never scaled, so
        // frameCenterRotation's centre math is exact.
        rotationView.frameCenterRotation = 0
        rotationView.frame = placement.frame.offsetBy(dx: canvasOriginInHost.x,
                                                      dy: canvasOriginInHost.y)
        scaleView.frame = CGRect(origin: .zero, size: placement.frame.size)
        scaleView.bounds = CGRect(origin: .zero, size: placement.boundsSize)
        rotationView.frameCenterRotation = placement.rotationDegrees
        textView.frame = CGRect(x: TextLayout.padding,
                                y: TextLayout.padding,
                                width: contentSize.width - TextLayout.padding * 2,
                                height: contentSize.height - TextLayout.padding * 2)
        if let taskBar = taskBarView, let host = hostView,
           let box = editingBoxInHost() {
            taskBar.frame = TextEditingGeometry.taskBarFrame(editingBox: box,
                                                             barSize: taskBar.fittingSize,
                                                             hostBounds: host.bounds)
        }
    }

    private func placeCaret(_ session: DocumentStore.TextEditSession) {
        guard let textView, let host = hostView else { return }
        if let hint = session.caretHint {
            let canvasView = store.viewport.toView(hint)
            let viewPoint = CGPoint(x: canvasView.x + canvasOriginInHost.x,
                                    y: canvasView.y + canvasOriginInHost.y)
            let inTextView = textView.convert(viewPoint, from: host)
            let index = textView.characterIndexForInsertion(at: inTextView)
            textView.setSelectedRange(NSRange(location: index, length: 0))
        } else {
            textView.selectAll(nil)
        }
    }

    /// Where AppKit actually places the editing box, in host coordinates
    /// (AABB when rotated). Regression hook: must match TextEditingGeometry —
    /// frameCenterRotation on a bounds-scaled view silently shifts frames,
    /// which is why rotation and scale live on separate views.
    func editingBoxInHost() -> CGRect? {
        guard let scaleView, let host = hostView else { return nil }
        return host.convert(scaleView.bounds, from: scaleView)
    }

    private static func caretColor(for spec: TextSpec) -> NSColor {
        // The caret must not inherit a translucent text colour.
        let base = NSColor(cgColor: spec.color.cgColor) ?? .black
        return base.withAlphaComponent(1)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        store.updateTextSessionText(textView.string)
        // The publish also schedules a sync; updating now avoids a one-frame
        // lag between the glyphs and the box.
        if let session = store.textSession {
            updateGeometry(session)
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        sessionUndoManager
    }

    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)), Selector(("complete:")):
            store.cancelTextSession()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Safety net behind CanvasTextView.keyDown for synthetic events.
            if let event = NSApp.currentEvent,
               TextCommitKeys.action(keyCode: event.keyCode,
                                     modifiers: event.modifierFlags) == .commit {
                store.commitTextSession()
                return true
            }
            return false // plain Return inserts a newline
        default:
            return false
        }
    }
}

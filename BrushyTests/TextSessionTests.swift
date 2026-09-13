import AppKit
import CoreGraphics
import Foundation
import XCTest

final class TextSessionTests: XCTestCase {
    private func makeStore(withText: Bool = false) -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: CGSize(width: 600, height: 400))
        document.layers = [Layer(name: "bg",
                                 source: GeneratedImages.solid(width: 600, height: 400,
                                                               r: 240, g: 240, b: 240,
                                                               colorSpace: BrushyColorSpace.displayP3))]
        let store = DocumentStore(document: document)
        if withText {
            var spec = TextSpec()
            spec.text = "Existing"
            spec.fontSize = 40
            store.insertTextLayer(spec, topLeftAt: CGPoint(x: 60, y: 300))
        }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        return (store, undoManager)
    }

    private func grouped(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    func testCreateSessionCommitProducesOneLayerOneUndoStep() {
        let (store, um) = makeStore()
        let layersBefore = store.document.layers.count

        store.beginTextSession(creatingAt: CGPoint(x: 100, y: 250))
        XCTAssertNotNil(store.textSession)
        XCTAssertNil(store.textSession?.layerID)
        XCTAssertEqual(store.document.layers.count, layersBefore,
                       "beginning a session must not touch the document")

        store.updateTextSessionText("Hello canvas")
        XCTAssertEqual(store.document.layers.count, layersBefore,
                       "typing must not touch the document")

        grouped(um) { store.commitTextSession() }
        XCTAssertNil(store.textSession)
        XCTAssertEqual(store.document.layers.count, layersBefore + 1)
        let layer = store.document.layers.last!
        XCTAssertEqual(layer.kind.textSpec?.text, "Hello canvas")
        XCTAssertEqual(layer.canvasBounds.minX, 100, accuracy: 0.5,
                       "click point is the text top-left")
        XCTAssertEqual(layer.canvasBounds.maxY, 250, accuracy: 0.5)
        XCTAssertEqual(um.undoActionName, "New Text Layer")
        um.undo()
        XCTAssertEqual(store.document.layers.count, layersBefore)
    }

    func testCreateSessionEmptyCommitLeavesNoTrace() {
        let (store, um) = makeStore()
        let before = store.document
        store.beginTextSession(creatingAt: CGPoint(x: 100, y: 250))
        store.updateTextSessionText("   \n  ")
        store.commitTextSession()
        XCTAssertEqual(store.document, before)
        XCTAssertFalse(um.canUndo, "no history entry for an empty commit")
    }

    func testCancelNeverTouchesDocument() {
        let (store, um) = makeStore(withText: true)
        let before = store.document
        let textLayer = store.document.layers.last!

        store.beginTextSession(editing: textLayer.id, caretAt: CGPoint(x: 70, y: 290))
        store.updateTextSessionText("Totally different words")
        store.cancelTextSession()
        XCTAssertNil(store.textSession)
        XCTAssertEqual(store.document, before,
                       "cancel restores nothing because nothing was mutated")
        XCTAssertFalse(um.canUndo)
    }

    func testEditCommitIsOneStepAndUnchangedCommitIsNone() {
        let (store, um) = makeStore(withText: true)
        let textLayer = store.document.layers.last!

        // Unchanged commit → no history entry.
        store.beginTextSession(editing: textLayer.id, caretAt: nil)
        store.commitTextSession()
        XCTAssertFalse(um.canUndo)

        // Changed commit → exactly one entry.
        store.beginTextSession(editing: textLayer.id, caretAt: nil)
        store.updateTextSessionText("Existing plus more")
        grouped(um) { store.commitTextSession() }
        XCTAssertEqual(store.document.layers.last?.kind.textSpec?.text, "Existing plus more")
        XCTAssertEqual(um.undoActionName, "Edit Text")
        um.undo()
        XCTAssertEqual(store.document.layers.last?.kind.textSpec?.text, "Existing")
        XCTAssertFalse(um.canUndo, "exactly one undo step per edit session")
    }

    func testEmptyingExistingTextDeletesTheLayer() {
        let (store, um) = makeStore(withText: true)
        let textLayer = store.document.layers.last!

        store.beginTextSession(editing: textLayer.id, caretAt: nil)
        store.updateTextSessionText("")
        grouped(um) { store.commitTextSession() }
        XCTAssertNil(store.document[layerID: textLayer.id],
                     "Photoshop parity: committing emptied text deletes the layer")
        XCTAssertEqual(um.undoActionName, "Delete Layer")
        um.undo()
        XCTAssertNotNil(store.document[layerID: textLayer.id])
    }

    func testToolAndLayerSwitchesCommitTheSession() {
        let (store, _) = makeStore(withText: true)
        let bgID = store.document.layers.first!.id
        let textLayer = store.document.layers.last!

        store.beginTextSession(editing: textLayer.id, caretAt: nil)
        store.updateTextSessionText("Committed by tool switch")
        store.activeTool = .move
        XCTAssertNil(store.textSession)
        XCTAssertEqual(store.document.layers.last?.kind.textSpec?.text, "Committed by tool switch")

        store.activeTool = .text
        store.beginTextSession(editing: store.document.layers.last!.id, caretAt: nil)
        store.updateTextSessionText("Committed by layer switch")
        store.selectLayer(bgID)
        XCTAssertNil(store.textSession)
        XCTAssertEqual(store.document.layers.last?.kind.textSpec?.text, "Committed by layer switch")
    }

    func testSessionDecomposition() {
        let (store, _) = makeStore(withText: true)
        var layer = store.document.layers.last!

        // Rotated + scaled, positive determinant.
        layer.transform = CGAffineTransform(rotationAngle: .pi / 6)
            .scaledBy(x: 2, y: 3)
            .concatenating(CGAffineTransform(translationX: 100, y: 50))
        store.replaceDocument(store.document.replacingLayer(layer))
        store.beginTextSession(editing: layer.id, caretAt: nil)
        var session = store.textSession!
        XCTAssertTrue(session.isDecomposable)
        XCTAssertEqual(session.rotation, .pi / 6, accuracy: 1e-6)
        XCTAssertEqual(session.scaleX, 2, accuracy: 1e-6)
        XCTAssertEqual(session.scaleY, 3, accuracy: 1e-6)
        let expectedAnchor = CGPoint(x: 0, y: layer.sourceSize.height).applying(layer.transform)
        XCTAssertEqual(session.anchorTopLeft.x, expectedAnchor.x, accuracy: 1e-6)
        XCTAssertEqual(session.anchorTopLeft.y, expectedAnchor.y, accuracy: 1e-6)
        store.cancelTextSession()

        // Mirrored (negative determinant) → upright fallback.
        layer = store.document.layers.last!
        layer.transform = CGAffineTransform(scaleX: -1, y: 1)
            .concatenating(CGAffineTransform(translationX: 300, y: 100))
        store.replaceDocument(store.document.replacingLayer(layer))
        store.beginTextSession(editing: layer.id, caretAt: nil)
        session = store.textSession!
        XCTAssertFalse(session.isDecomposable)
        XCTAssertEqual(session.rotation, 0)
        let bounds = store.document.layers.last!.canvasBounds
        XCTAssertEqual(session.anchorTopLeft.x, bounds.minX, accuracy: 1e-6)
        XCTAssertEqual(session.anchorTopLeft.y, bounds.maxY, accuracy: 1e-6)
        store.cancelTextSession()

        // 180° rotation (double flip) has positive determinant: decomposable.
        layer = store.document.layers.last!
        layer.transform = CGAffineTransform(scaleX: -1, y: -1)
        store.replaceDocument(store.document.replacingLayer(layer))
        store.beginTextSession(editing: layer.id, caretAt: nil)
        XCTAssertTrue(store.textSession!.isDecomposable)
        XCTAssertEqual(abs(store.textSession!.rotation), .pi, accuracy: 1e-6)
    }

    func testProgrammaticUndoDiscardsSession() {
        let (store, um) = makeStore(withText: true)
        let id = store.document.layers.first!.id
        grouped(um) { store.renameLayer(id, to: "renamed") }

        store.beginTextSession(editing: store.document.layers.last!.id, caretAt: nil)
        store.updateTextSessionText("doomed")
        um.undo()
        XCTAssertNil(store.textSession, "undo mid-session discards the session")
        XCTAssertEqual(store.document[layerID: id]?.name, "bg")
    }

    func testStyleUpdatesFlowToSessionAndDefaults() {
        let (store, _) = makeStore()
        store.beginTextSession(creatingAt: CGPoint(x: 50, y: 200))
        store.updateTextSessionStyle { $0.fontSize = 96; $0.fontName = "Menlo" }
        XCTAssertEqual(store.textSession?.spec.fontSize, 96)
        XCTAssertEqual(store.textSession?.spec.fontName, "Menlo")
        XCTAssertEqual(store.textStyle.fontSize, 96,
                       "session styling becomes the creation default")
        XCTAssertEqual(store.textStyle.fontName, "Menlo")
        store.cancelTextSession()
    }

    // MARK: Placeholder seeding

    func testCreateSessionSeedsPlaceholderAndCommitsItAsTyped() {
        let (store, um) = makeStore()
        let layersBefore = store.document.layers.count

        store.beginTextSession(creatingAt: CGPoint(x: 100, y: 250))
        XCTAssertEqual(store.textSession?.spec.text, DocumentStore.textPlaceholder,
                       "new sessions seed the placeholder so typing replaces it")
        XCTAssertNil(store.textSession?.caretHint, "nil hint ⇒ editor selects all")

        um.beginUndoGrouping()
        store.commitTextSession()
        um.endUndoGrouping()
        XCTAssertEqual(store.document.layers.count, layersBefore + 1,
                       "accepting the placeholder makes the layer you can see — ⌘Z drops it")
        XCTAssertEqual(store.document.layers.last?.kind.textSpec?.text,
                       DocumentStore.textPlaceholder)
        XCTAssertTrue(um.canUndo)
    }

    func testStyledPlaceholderCommitsAndKeepsTheDefaults() {
        let (store, um) = makeStore()
        let layersBefore = store.document.layers.count

        store.beginTextSession(creatingAt: CGPoint(x: 100, y: 250))
        store.updateTextSessionStyle { $0.fontSize = 90; $0.fontName = "Menlo" }
        um.beginUndoGrouping()
        store.commitTextSession()
        um.endUndoGrouping()
        XCTAssertEqual(store.document.layers.count, layersBefore + 1)
        XCTAssertEqual(store.textStyle.fontSize, 90,
                       "and the styling sticks as the creation default")
        XCTAssertEqual(store.textStyle.fontName, "Menlo")
    }

    func testClearingThePlaceholderCommitsToNothing() {
        let (store, um) = makeStore()
        let before = store.document

        store.beginTextSession(creatingAt: CGPoint(x: 100, y: 250))
        store.updateTextSessionText("")
        store.commitTextSession()

        XCTAssertEqual(store.document, before, "emptying the box is how you say no")
        XCTAssertFalse(um.canUndo)
    }

    func testTypedPlaceholderReplacementCommitsNormally() {
        let (store, _) = makeStore()
        let layersBefore = store.document.layers.count

        store.beginTextSession(creatingAt: CGPoint(x: 100, y: 250))
        store.updateTextSessionText("Hood River")
        store.commitTextSession()
        XCTAssertEqual(store.document.layers.count, layersBefore + 1)
        XCTAssertEqual(store.document.layers.last?.kind.textSpec?.text, "Hood River")
    }

    /// The editor must show the placeholder fully selected (typing replaces
    /// it in one stroke) with the floating task bar placed under the box by
    /// the shared geometry. View-level, no window needed.
    func testEditorSelectsPlaceholderAndPlacesTaskBar() {
        let (store, _) = makeStore()
        store.viewport.viewSize = CGSize(width: 1000, height: 700)
        store.viewport.zoom = 1
        store.viewport.origin = .zero

        let host = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        let coordinator = TextEditingCoordinator(store: store)
        coordinator.hostView = host

        store.beginTextSession(creatingAt: CGPoint(x: 200, y: 400))
        coordinator.syncWithStore()

        let textView = host.subviews.last?.subviews.first?.subviews.first as? NSTextView
        XCTAssertNotNil(textView, "rotation → scale → text view hierarchy")
        let length = (DocumentStore.textPlaceholder as NSString).length
        XCTAssertEqual(textView?.string, DocumentStore.textPlaceholder)
        XCTAssertEqual(textView?.selectedRange(), NSRange(location: 0, length: length),
                       "placeholder starts fully selected")

        guard let bar = coordinator.taskBarView,
              let box = coordinator.editingBoxInHost() else {
            XCTFail("no task bar/editing box"); return
        }
        XCTAssertGreaterThan(bar.frame.width, 100, "bar laid out at its fitting size")
        let expected = TextEditingGeometry.taskBarFrame(editingBox: box,
                                                        barSize: bar.frame.size,
                                                        hostBounds: host.bounds)
        XCTAssertEqual(bar.frame, expected, "coordinator placed the bar via the shared math")
        XCTAssertLessThanOrEqual(bar.frame.maxY, box.minY,
                                 "bar sits below the box (host is y-up)")

        store.cancelTextSession()
        coordinator.syncWithStore()
        XCTAssertNil(coordinator.taskBarView, "bar torn down with the session")
    }

    /// AppKit's ACTUAL editor placement must match the geometry that draws the
    /// hairline and anchors the commit — for plain, zoomed, and rotated
    /// sessions. (Catches frameCenterRotation/bounds-scaling interactions;
    /// view geometry works without a window.)
    func testEditorViewLandsExactlyOnSessionGeometry() {
        let (store, _) = makeStore(withText: true)
        store.viewport.viewSize = CGSize(width: 1000, height: 700)
        store.viewport.zoom = 1.2325
        store.viewport.origin = CGPoint(x: 24, y: 50.75)

        let host = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        let coordinator = TextEditingCoordinator(store: store)
        coordinator.hostView = host

        func assertAligned(_ label: String, accuracy: CGFloat = 0.01) {
            coordinator.syncWithStore()
            guard let session = store.textSession,
                  let actual = coordinator.editingBoxInHost() else {
                XCTFail("\(label): no session/editor"); return
            }
            let contentSize = TextLayout.editorContentSize(for: session.spec)
            let corners = TextEditingGeometry.canvasCorners(
                anchorTopLeft: session.anchorTopLeft,
                rotation: session.rotation,
                scaleX: session.scaleX, scaleY: session.scaleY,
                contentSize: contentSize)
                .map { store.viewport.toView($0) }
            let expected = CGRect.aabb(of: corners)
            XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, label)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, label)
            XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, label)
            XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, label)
        }

        // Unrotated existing layer.
        let textLayer = store.document.layers.last!
        store.beginTextSession(editing: textLayer.id, caretAt: nil)
        assertAligned("unrotated")
        store.cancelTextSession()
        coordinator.syncWithStore()

        // Rotated + scaled layer.
        var rotated = store.document.layers.last!
        rotated.transform = CGAffineTransform(rotationAngle: 0.4)
            .scaledBy(x: 1.5, y: 1.5)
            .concatenating(CGAffineTransform(translationX: 200, y: 120))
        store.replaceDocument(store.document.replacingLayer(rotated))
        store.beginTextSession(editing: rotated.id, caretAt: nil)
        assertAligned("rotated")
        store.cancelTextSession()
        coordinator.syncWithStore()

        // Zoom change mid-session must re-place the editor. (Uses real text:
        // empty-session live metrics legitimately differ from fresh measures.)
        store.beginTextSession(creatingAt: CGPoint(x: 90, y: 200))
        store.updateTextSessionText("Zoom me")
        coordinator.syncWithStore()
        store.viewport.setZoom(2.0, anchorView: CGPoint(x: 500, y: 350))
        assertAligned("after zoom change")
        store.cancelTextSession()
        coordinator.syncWithStore()
    }

    func testCommitKeyClassification() {
        XCTAssertEqual(TextCommitKeys.action(keyCode: 53, modifiers: []), .cancel)
        XCTAssertEqual(TextCommitKeys.action(keyCode: 76, modifiers: []), .commit)
        XCTAssertEqual(TextCommitKeys.action(keyCode: 36, modifiers: [.command]), .commit)
        XCTAssertNil(TextCommitKeys.action(keyCode: 36, modifiers: []),
                     "plain Return inserts a newline")
        XCTAssertNil(TextCommitKeys.action(keyCode: 0, modifiers: []))
    }

    // MARK: - Panel mutators land the session first

    /// The layers panel stays live while type is being edited, so its controls
    /// are reachable mid-session. Each of these used to commit straight to
    /// history without landing the session, which left the in-flight text
    /// hanging off a document the edit had already moved past.
    ///
    /// Asserted per mutator rather than once, because each resolves the layer
    /// itself and the ordering has to be right in every one.
    func testLayersPanelMutatorsCommitAnInFlightTextSession() {
        func check(_ name: String, _ mutate: (DocumentStore, UUID) -> Void) {
            let (store, _) = makeStore(withText: true)
            let textID = store.document.layers.last!.id
            store.beginTextSession(editing: textID, caretAt: nil)
            store.updateTextSessionText("Landed by \(name)")
            mutate(store, textID)
            XCTAssertNil(store.textSession, "\(name) must land the text session")
            XCTAssertEqual(store.document.layers.last?.kind.textSpec?.text,
                           "Landed by \(name)",
                           "\(name) must not discard the in-flight text")
        }
        check("setLayerVisibility") { $0.setLayerVisibility($1, false) }
        check("setLayerBlendMode") { $0.setLayerBlendMode($1, .multiply) }
        check("renameLayer") { $0.renameLayer($1, to: "Renamed") }
        check("toggleClippingMask") { $0.toggleClippingMask($1) }
    }

    /// Landing the session REPLACES the layer, so a mutator that resolved the
    /// layer before committing would then write a stale copy back over the
    /// freshly committed pixels. Pins the ordering, not just the call.
    func testMutatorAfterSessionCommitSeesTheUpdatedLayer() {
        let (store, _) = makeStore(withText: true)
        let textID = store.document.layers.last!.id
        let sourceBefore = store.document[layerID: textID]!.sourceID

        store.beginTextSession(editing: textID, caretAt: nil)
        store.updateTextSessionText("Much longer text than before")
        store.setLayerBlendMode(textID, .multiply)

        let after = store.document[layerID: textID]!
        XCTAssertEqual(after.blendMode, .multiply)
        XCTAssertNotEqual(after.sourceID, sourceBefore,
                          "the committed session's pixels must survive the mutator")
        XCTAssertEqual(after.kind.textSpec?.text, "Much longer text than before")
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class BrushyDocument: NSDocument {
    let store: DocumentStore
    private let serializer = DocumentSerializer()

    override init() {
        var document = Document(canvasSize: CGSize(width: 1920, height: 1080))
        // Every new document starts with a transparent "Layer 1", like
        // Photoshop — the canvas is immediately brushable. Content arrivals
        // replace it while it is pristine (DocumentStore.isPristineBlankDocument),
        // so opening/placing into a fresh window still adopts the image.
        // SEED-ONLY preference (General pane): it was hardcoded here.
        if Defaults.value(Defaults.Keys.startWithBlankLayer),
           let blank = DocumentStore.blankPaintLayer(canvasSize: document.canvasSize,
                                                     name: "Layer 1") {
            document.layers = [blank]
        }
        store = DocumentStore(document: document)
        super.init()
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        store.undoManager = undoManager
        // Matches the store's history cap (Performance pane) — the two must
        // agree, or ⌘Z stops before the snapshots do. Kept in step live by
        // DocumentStore's `undoDepth` didSet.
        undoManager?.levelsOfUndo = AppSettings.shared.undoDepth
        let hosting = NSHostingController(rootView: RootView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1360, height: 880))
        window.minSize = NSSize(width: 1000, height: 640)
        window.appearance = NSAppearance(named: .darkAqua)
        // Documents group as tabs of one window, Photoshop-style.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "BrushyDocument"
        // The AI chat toggle sits at the trailing end of the title bar, so
        // it is still there once the sidebar is hidden.
        let toggle = NSHostingView(rootView: ChatSidebarToggle())
        toggle.frame.size = toggle.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = toggle
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        window.center()
        addWindowController(NSWindowController(window: window))
    }

    // MARK: - File IO

    /// Runs `work` on the main thread and returns its result.
    ///
    /// The store is main-thread state, and NSDocument may call the file
    /// methods off the main thread. Written as a returning hop so the value
    /// cannot exist in a half-initialised state: this was an implicitly
    /// unwrapped `Document!` assigned inside a closure, which is a crash
    /// rather than an error if the hop is ever skipped or reordered.
    private func onMainThread<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let snapshot = onMainThread { () -> Document in
            store.commitPendingSessions()
            return store.document
        }
        return try serializer.fileWrapper(for: snapshot)
    }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        // Deserialisation happens off the hop deliberately — it is the slow
        // part, and it touches nothing the main thread owns.
        let document = try serializer.document(from: fileWrapper)
        onMainThread { store.replaceDocument(document) }
    }

    // MARK: - Menu actions (responder chain)

    @objc func exportFlattened(_ sender: Any?) { store.requestExport() }
    @objc func showImageSize(_ sender: Any?) {
        store.commitPendingSessions()
        store.imageSizeRequested = true
    }
    @objc func showCanvasSize(_ sender: Any?) {
        store.commitPendingSessions()
        store.canvasSizeRequested = true
    }
    @objc func cropToSelection(_ sender: Any?) { store.cropToSelection() }
    @objc func freeTransform(_ sender: Any?) { store.enterTransformMode() }
    @objc func newPaintLayer(_ sender: Any?) { store.addPaintLayer() }
    @objc func flipHorizontal(_ sender: Any?) { store.flipSelectedLayer(vertical: false) }
    @objc func flipVertical(_ sender: Any?) { store.flipSelectedLayer(vertical: true) }
    @objc func rotate90Left(_ sender: Any?) { store.rotateSelectedLayer90(clockwise: false) }
    @objc func rotate90Right(_ sender: Any?) { store.rotateSelectedLayer90(clockwise: true) }
    @objc func showFill(_ sender: Any?) {
        store.commitPendingSessions()
        store.fillRequested = true
    }
    @objc func duplicateLayer(_ sender: Any?) { store.duplicateSelectedLayer() }
    @objc func layerViaCopy(_ sender: Any?) { store.layerViaCopy() }
    @objc func layerViaCut(_ sender: Any?) { store.layerViaCut() }
    // Cross-document transfer: "Duplicate Layer to" submenu items carry the
    // target document as representedObject; the action resolves through the
    // responder chain to the frontmost document.
    @objc func duplicateLayerToDocument(_ sender: Any?) {
        guard let target = (sender as? NSMenuItem)?.representedObject as? BrushyDocument,
              target !== self else { return }
        transferSelectedLayer(to: target)
    }
    @objc func duplicateLayerToNewDocument(_ sender: Any?) {
        guard store.selectedLayer != nil,
              let target = (try? NSDocumentController.shared
                  .openUntitledDocumentAndDisplay(true)) as? BrushyDocument else { return }
        transferSelectedLayer(to: target)
    }
    private func transferSelectedLayer(to target: BrushyDocument) {
        guard let layer = store.selectedLayer else { return }
        target.store.receiveLayer(layer, from: store.document.canvasSize)
        target.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
    }
    // Align & Distribute: one selector per family, the specific
    // command carried as representedObject (like the Layer Style items), so
    // ten menu items need two actions and two validation cases.
    @objc func alignLayers(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let edge = AlignEdge(rawValue: raw) else { return }
        store.alignSelection(to: edge)
    }
    @objc func distributeLayers(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let command = DistributeCommand(rawValue: raw) else { return }
        store.distributeSelection(command)
    }
    @objc func newAdjustmentLayer(_ sender: Any?) {
        guard let title = (sender as? NSMenuItem)?.representedObject as? String else { return }
        switch title {
        case "Levels": store.addAdjustmentLayer(.levels(AdjustmentSpec.Levels()))
        case "Curves": store.addAdjustmentLayer(.curves(AdjustmentSpec.Curves()))
        default: store.addAdjustmentLayer(.hueSaturation(AdjustmentSpec.HueSaturation()))
        }
    }
    @objc func editAdjustment(_ sender: Any?) { store.requestAdjustmentEdit() }
    @objc func rasterizeLayer(_ sender: Any?) {
        if let id = store.selectedLayerID { store.rasterizeLayer(id) }
    }
    @objc func mergeDown(_ sender: Any?) { store.mergeDownSelectedLayer() }
    @objc func deleteLayer(_ sender: Any?) { store.deleteSelectedLayer() }
    // Layer groups: ⌘G / ⇧⌘G.
    @objc func groupLayer(_ sender: Any?) { store.groupSelection() }
    @objc func ungroupLayer(_ sender: Any?) { store.ungroupSelection() }
    // Layer Style. The per-effect items carry their
    // `LayerEffects.Kind` raw value as representedObject, so the effects
    // panel can switch that effect on and open it.
    @objc func showLayerStyle(_ sender: Any?) { store.showLayerEffects() }
    @objc func showLayerStyleEffect(_ sender: Any?) {
        let kind = ((sender as? NSMenuItem)?.representedObject as? String)
            .flatMap(LayerEffects.Kind.init(rawValue:))
        store.showLayerEffects(focus: kind)
    }
    @objc func clearLayerStyle(_ sender: Any?) {
        if let id = store.selectedLayerID { store.clearLayerStyle(id) }
    }
    @objc func addLayerMask(_ sender: Any?) { store.addLayerMask() }
    @objc func deleteLayerMask(_ sender: Any?) { store.deleteLayerMask() }
    @objc func toggleLayerMask(_ sender: Any?) {
        if let id = store.selectedLayerID { store.toggleMaskEnabled(id) }
    }
    @objc func toggleClippingMask(_ sender: Any?) {
        if let id = store.selectedLayerID { store.toggleClippingMask(id) }
    }
    // Clipboard. `cut:`/`copy:`/`paste:` deliberately match the
    // standard NSText selectors: while inline text editing is active the
    // NSTextView is first responder and claims them before they reach the
    // document, so text keeps its normal clipboard behaviour.
    @objc func cut(_ sender: Any?) { store.cutSelection() }
    @objc func copy(_ sender: Any?) { store.copySelection() }
    @objc func copyMerged(_ sender: Any?) { store.copyMerged() }
    @objc func paste(_ sender: Any?) { store.paste() }
    @objc func pasteInto(_ sender: Any?) { store.pasteInto() }
    @objc func deselect(_ sender: Any?) { store.deselect() }
    @objc func invertSelection(_ sender: Any?) { store.invertSelection() }
    // Select > All. The single Select All implementation (the old
    // CanvasHostView.selectAll override is gone): `selectAll:` deliberately
    // matches the standard NSResponder selector, like cut:/copy:/paste: above,
    // so a focused text view claims ⌘A and keeps select-all-text; from any
    // other responder the action falls through the chain to the document.
    @objc func selectAll(_ sender: Any?) { store.selectAll() }
    @objc func transformSelection(_ sender: Any?) { store.enterSelectionTransformMode() }
    @objc func showGrowSelection(_ sender: Any?) { showSelectionModify(.grow) }
    @objc func showContractSelection(_ sender: Any?) { showSelectionModify(.contract) }
    @objc func showBorderSelection(_ sender: Any?) { showSelectionModify(.border) }
    private func showSelectionModify(_ kind: DocumentStore.SelectionModifyKind) {
        store.commitPendingSessions()
        store.selectionModifyRequested = kind
    }
    @objc func selectSubject(_ sender: Any?) { store.selectSubject() }
    @objc func toggleQuickMask(_ sender: Any?) { store.toggleQuickMask() }
    @objc func zoomIn(_ sender: Any?) { store.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { store.zoomOut() }
    @objc func zoomToFit(_ sender: Any?) { store.zoomToFit() }
    @objc func zoomToActualSize(_ sender: Any?) { store.zoomToActualSize() }
    // View furniture: rulers, guides, grid, snapping. All view
    // state on the store except Clear Guides, which edits the document (and
    // is undoable).
    @objc func toggleRulers(_ sender: Any?) { store.rulersVisible.toggle() }
    @objc func toggleGuides(_ sender: Any?) { store.guidesVisible.toggle() }
    @objc func toggleLockGuides(_ sender: Any?) { store.guidesLocked.toggle() }
    @objc func clearGuides(_ sender: Any?) { store.clearGuides() }
    @objc func toggleGrid(_ sender: Any?) { store.gridVisible.toggle() }
    @objc func togglePixelGrid(_ sender: Any?) { store.pixelGridVisible.toggle() }
    @objc func toggleSnapping(_ sender: Any?) { store.snappingEnabled.toggle() }
    @objc func toggleSelectionEdges(_ sender: Any?) { store.selectionEdgesVisible.toggle() }
    /// Tab on the canvas does the same — Photoshop's "just the artwork" view.
    @objc func togglePanels(_ sender: Any?) { store.panelsHidden.toggle() }

    /// Layer-structure actions grey out while type is being edited in place,
    /// like Photoshop.
    private static let actionsDisabledDuringTextEditing: Set<Selector> = [
        #selector(freeTransform(_:)), #selector(transformSelection(_:)),
        #selector(selectSubject(_:)), #selector(cropToSelection(_:)),
        #selector(duplicateLayer(_:)),
        #selector(duplicateLayerToDocument(_:)), #selector(duplicateLayerToNewDocument(_:)),
        #selector(deleteLayer(_:)), #selector(mergeDown(_:)), #selector(rasterizeLayer(_:)),
        #selector(newAdjustmentLayer(_:)), #selector(editAdjustment(_:)),
        #selector(layerViaCopy(_:)), #selector(layerViaCut(_:)),
        #selector(groupLayer(_:)), #selector(ungroupLayer(_:)),
        #selector(alignLayers(_:)), #selector(distributeLayers(_:)),
        #selector(flipHorizontal(_:)), #selector(flipVertical(_:)),
        #selector(rotate90Left(_:)), #selector(rotate90Right(_:)),
        #selector(addLayerMask(_:)), #selector(deleteLayerMask(_:)),
        #selector(toggleLayerMask(_:)), #selector(toggleClippingMask(_:)),
        #selector(showLayerStyle(_:)), #selector(showLayerStyleEffect(_:)),
        #selector(clearLayerStyle(_:)),
        // Clipboard: cut:/copy:/paste: normally reach the editing NSTextView
        // first (it is first responder), so these entries matter for ⇧⌘C and
        // ⌥⌘V — which the text view does not claim — and as a backstop if the
        // document is ever asked directly during a text session.
        #selector(cut(_:)), #selector(copy(_:)), #selector(copyMerged(_:)),
        #selector(paste(_:)), #selector(pasteInto(_:)),
    ]

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if store.textSession != nil, let action = item.action,
           Self.actionsDisabledDuringTextEditing.contains(action) {
            return false
        }
        switch item.action {
        case #selector(freeTransform(_:)):
            return store.selectedLayerEffectivelyVisible && store.transformSession == nil
        case #selector(duplicateLayer(_:)), #selector(deleteLayer(_:)),
             #selector(flipHorizontal(_:)), #selector(flipVertical(_:)),
             #selector(rotate90Left(_:)), #selector(rotate90Right(_:)):
            return store.selectedLayer != nil
        case #selector(alignLayers(_:)):
            // Two objects, or one against the canvas (the reference picker
            // forces .canvas below two — see DocumentStore).
            return store.canAlignSelection
        case #selector(distributeLayers(_:)):
            return store.canDistributeSelection
        case #selector(groupLayer(_:)):
            return store.canGroupSelection
        case #selector(ungroupLayer(_:)):
            return store.ungroupTargetID != nil
        case #selector(duplicateLayerToDocument(_:)), #selector(duplicateLayerToNewDocument(_:)):
            // The parent "Duplicate Layer to" item validates through the
            // responder chain every time the Layer menu opens — before its
            // submenu can possibly open — so the frontmost document adopts
            // the submenu here and menuNeedsUpdate builds the target list
            // against the right "self" as tabs come and go.
            if let submenu = (item as? NSMenuItem)?.submenu, submenu.delegate !== self {
                submenu.delegate = self
            }
            return store.selectedLayer != nil
        case #selector(showFill(_:)):
            return store.canFillSelection
        case #selector(mergeDown(_:)):
            guard let layer = store.selectedLayer,
                  let index = store.document.layerIndex(of: layer.id), index > 0 else { return false }
            let below = store.document.layers[index - 1]
            // Merge Down never crosses a group boundary — same guard as
            // `mergeDownSelectedLayer` — and an adjustment has no pixels to
            // merge (Photoshop merges it INTO the layer below; not yet here).
            return below.groupID == layer.groupID && layer.isVisible && below.isVisible
                && layer.kind.adjustmentSpec == nil && below.kind.adjustmentSpec == nil
        case #selector(rasterizeLayer(_:)):
            return store.canRasterizeSelectedLayer
        case #selector(layerViaCopy(_:)):
            // With nothing selected this duplicates the layer, like Photoshop.
            return store.selectedLayerEffectivelyVisible
        case #selector(layerViaCut(_:)):
            return store.canMakeLayerFromSelection
        case #selector(newAdjustmentLayer(_:)):
            return true
        case #selector(editAdjustment(_:)):
            return store.editableAdjustmentLayerID != nil
        case #selector(showLayerStyle(_:)), #selector(showLayerStyleEffect(_:)):
            return store.selectedLayer != nil
        case #selector(clearLayerStyle(_:)):
            return !(store.selectedLayer?.effects.isEmpty ?? true)
        case #selector(addLayerMask(_:)):
            // Adjustment masks need a canvas-space mask, which this app's
            // source-space masks can't be yet — so no masking them for now.
            return store.selectedLayer != nil && store.selectedLayer?.mask == nil
                && store.selectedLayer?.kind.adjustmentSpec == nil
        case #selector(deleteLayerMask(_:)), #selector(toggleLayerMask(_:)):
            return store.selectedLayer?.mask != nil
        case #selector(toggleClippingMask(_:)):
            // The title doubles as the state display (Photoshop's ⌥⌘G
            // toggle); refreshed here because, like the View-menu check
            // marks, the menu is rebuilt nowhere else. The bottom layer has
            // nothing below to clip to.
            guard let layer = store.selectedLayer,
                  let index = store.document.layerIndex(of: layer.id), index > 0 else {
                (item as? NSMenuItem)?.title = "Create Clipping Mask"
                return false
            }
            (item as? NSMenuItem)?.title = layer.isClippedToBelow
                ? "Release Clipping Mask" : "Create Clipping Mask"
            return true
        case #selector(cut(_:)), #selector(copy(_:)):
            return store.selectedLayerEffectivelyVisible
        case #selector(copyMerged(_:)):
            return store.document.layers.contains {
                store.document.isEffectivelyVisible(layerID: $0.id)
            }
        case #selector(paste(_:)):
            return LayerPasteboard.canRead(.general)
        case #selector(pasteInto(_:)):
            return !store.selection.isEmpty && LayerPasteboard.canRead(.general)
        case #selector(deselect(_:)), #selector(invertSelection(_:)),
             #selector(showGrowSelection(_:)), #selector(showContractSelection(_:)),
             #selector(showBorderSelection(_:)):
            return !store.selection.isEmpty
        case #selector(transformSelection(_:)):
            return !store.selection.isEmpty && store.selectionTransformSession == nil
        case #selector(selectSubject(_:)):
            return store.selectedLayerEffectivelyVisible
        case #selector(toggleQuickMask(_:)):
            // The title is the state, like the clipping-mask item's.
            (item as? NSMenuItem)?.title = store.quickMaskActive
                ? "Edit in Standard Mode" : "Edit in Quick Mask Mode"
            return true
        case #selector(cropToSelection(_:)):
            return store.canCropToSelection
        case #selector(exportFlattened(_:)):
            return !store.document.layers.isEmpty
        // View-furniture toggles: always enabled; validation doubles
        // as the checkmark refresh, since the menu is rebuilt nowhere else.
        case #selector(toggleRulers(_:)):
            (item as? NSMenuItem)?.state = store.rulersVisible ? .on : .off
            return true
        case #selector(togglePanels(_:)):
            (item as? NSMenuItem)?.title = store.panelsHidden ? "Show Panels" : "Hide Panels"
            return true
        case #selector(toggleGuides(_:)):
            (item as? NSMenuItem)?.state = store.guidesVisible ? .on : .off
            return true
        case #selector(toggleLockGuides(_:)):
            (item as? NSMenuItem)?.state = store.guidesLocked ? .on : .off
            return true
        case #selector(toggleGrid(_:)):
            (item as? NSMenuItem)?.state = store.gridVisible ? .on : .off
            return true
        case #selector(togglePixelGrid(_:)):
            (item as? NSMenuItem)?.state = store.pixelGridVisible ? .on : .off
            return true
        case #selector(toggleSnapping(_:)):
            (item as? NSMenuItem)?.state = store.snappingEnabled ? .on : .off
            return true
        case #selector(toggleSelectionEdges(_:)):
            (item as? NSMenuItem)?.state = store.selectionEdgesVisible ? .on : .off
            return true
        case #selector(clearGuides(_:)):
            return !store.document.guides.isEmpty
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(zoomToFit(_:)), #selector(zoomToActualSize(_:)),
             #selector(selectAll(_:)),
             #selector(showImageSize(_:)), #selector(showCanvasSize(_:)),
             #selector(newPaintLayer(_:)):
            return true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

// MARK: - "Duplicate Layer to" submenu

extension BrushyDocument: NSMenuDelegate {
    /// Rebuilds the "Duplicate Layer to" submenu each time it opens: one item
    /// per *other* open document, then "New Document". Built once at launch it
    /// would go stale as tabs open and close.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let others = NSDocumentController.shared.documents
            .compactMap { $0 as? BrushyDocument }
            .filter { $0 !== self }
        for document in others {
            let item = menu.addItem(withTitle: document.displayName ?? "Untitled",
                                    action: #selector(duplicateLayerToDocument(_:)),
                                    keyEquivalent: "")
            item.representedObject = document
        }
        if !others.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "New Document",
                     action: #selector(duplicateLayerToNewDocument(_:)),
                     keyEquivalent: "")
    }
}

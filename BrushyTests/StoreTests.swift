import CoreGraphics
import Foundation
import XCTest

final class StoreTests: XCTestCase {
    private func makeStore(layers: Int = 2) -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        let p3 = BrushyColorSpace.displayP3
        for i in 0..<layers {
            var layer = Layer(name: "L\(i)",
                              source: GeneratedImages.solid(width: 100, height: 100,
                                                            r: UInt8(60 * i + 40), g: 80, b: 120,
                                                            colorSpace: p3))
            layer.transform = CGAffineTransform(translationX: CGFloat(i * 120), y: 40)
            document.layers.append(layer)
        }
        let store = DocumentStore(document: document)
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        return (store, undoManager)
    }

    private func commitGrouped(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    func testCommitUndoRedoTraversal() {
        let (store, um) = makeStore()
        let id = store.document.layers[0].id
        let originalName = store.document.layers[0].name

        commitGrouped(um) { store.renameLayer(id, to: "Renamed") }
        XCTAssertEqual(store.document[layerID: id]?.name, "Renamed")
        XCTAssertEqual(um.undoActionName, "Rename Layer")

        um.undo()
        XCTAssertEqual(store.document[layerID: id]?.name, originalName)
        XCTAssertTrue(um.canRedo)

        um.redo()
        XCTAssertEqual(store.document[layerID: id]?.name, "Renamed")
    }

    func testUndoDepthCapsAt100() {
        let (store, um) = makeStore()
        let id = store.document.layers[0].id
        for i in 1...120 {
            commitGrouped(um) { store.renameLayer(id, to: "N\(i)") }
        }
        var undos = 0
        while um.canUndo && undos < 300 {
            um.undo()
            undos += 1
        }
        // 121 snapshots capped to 100: the oldest reachable state is commit 21.
        XCTAssertEqual(store.document[layerID: id]?.name, "N21")
        XCTAssertLessThanOrEqual(undos, 100)
    }

    func testDuplicateSharesSourceStorage() {
        let (store, um) = makeStore()
        let original = store.document.layers[1]
        store.selectLayer(original.id)
        commitGrouped(um) { store.duplicateSelectedLayer() }

        XCTAssertEqual(store.document.layers.count, 3)
        let copy = store.selectedLayer
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy?.id, original.id)
        XCTAssertEqual(copy?.sourceID, original.sourceID)
        XCTAssertTrue(copy?.source === original.source)
        XCTAssertEqual(copy?.name, original.name + " copy")
        // Inserted directly above the original.
        XCTAssertEqual(store.document.layerIndex(of: copy!.id),
                       store.document.layerIndex(of: original.id)! + 1)
    }

    /// Merge down is destructive by design, but must not change what the
    /// composite looks like.
    func testMergeDownPreservesAppearance() throws {
        var document = Document(canvasSize: CGSize(width: 150, height: 100))
        let p3 = BrushyColorSpace.displayP3
        let bottom = Layer(name: "red",
                           source: GeneratedImages.solid(width: 100, height: 100,
                                                         r: 220, g: 30, b: 30, colorSpace: p3))
        var top = Layer(name: "blue",
                        source: GeneratedImages.solid(width: 100, height: 100,
                                                      r: 30, g: 40, b: 230, colorSpace: p3),
                        transform: CGAffineTransform(translationX: 50, y: 0))
        top.opacity = 0.5
        document.layers = [bottom, top]

        let store = DocumentStore(document: document)
        let before = try rawRGBA8(RenderEngine.shared.renderFlattened(
            document: store.document, profile: p3, sixteenBit: false)!)

        store.selectLayer(top.id)
        store.mergeDownSelectedLayer()
        XCTAssertEqual(store.document.layers.count, 1)
        XCTAssertEqual(store.document.layers[0].name, "red")

        let after = try rawRGBA8(RenderEngine.shared.renderFlattened(
            document: store.document, profile: p3, sixteenBit: false)!)
        var maxDelta = 0
        for y in 0..<before.height {
            for x in 0..<before.width {
                let a = before[x, y], b = after[x, y]
                maxDelta = max(maxDelta,
                               abs(Int(a.r) - Int(b.r)), abs(Int(a.g) - Int(b.g)),
                               abs(Int(a.b) - Int(b.b)), abs(Int(a.a) - Int(b.a)))
            }
        }
        XCTAssertLessThanOrEqual(maxDelta, 1, "merge down changed the composite by \(maxDelta)/255")
    }

    func testPlaceIntoEmptyDocumentAdoptsImageSize() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brushy-tests-\(UUID().uuidString)")
        let small = dir.appendingPathComponent("small.png")
        let large = dir.appendingPathComponent("large.png")
        try writePNG(GeneratedImages.solid(width: 400, height: 300, r: 10, g: 200, b: 10,
                                           colorSpace: BrushyColorSpace.sRGB), to: small)
        try writePNG(GeneratedImages.solid(width: 800, height: 600, r: 200, g: 10, b: 10,
                                           colorSpace: BrushyColorSpace.sRGB), to: large)

        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 1920, height: 1080)))
        store.placeImages(from: [small])
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(store.document.layers.count, 1)
        XCTAssertEqual(store.document.layers[0].transform, .identity)
        XCTAssertNil(store.transformSession,
                     "opening into an empty document is Open semantics — no transform box")

        // Second image is larger than the canvas: scaled to fit via transform,
        // centred — source untouched — and it arrives with Free Transform
        // active (Photoshop Place behaviour) so it is always discoverable,
        // even a tiny image.
        store.placeImages(from: [large])
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 400, height: 300),
                       "canvas size only adopts the first image in an empty document")
        XCTAssertEqual(store.transformSession?.layerID, store.document.layers[1].id,
                       "placing into a non-empty document begins Free Transform on the new layer")
        store.commitTransformSession()
        let placed = store.document.layers[1]
        let (sx, sy) = placed.transform.scaleComponents
        XCTAssertEqual(sx, 0.5, accuracy: 0.001)
        XCTAssertEqual(sy, 0.5, accuracy: 0.001)
        XCTAssertEqual(placed.canvasBounds.midX, 200, accuracy: 0.5)
        XCTAssertEqual(placed.canvasBounds.midY, 150, accuracy: 0.5)
        XCTAssertEqual(placed.source.width, 800)
    }

    func testCropCommitViaStoreIsUndoable() {
        let (store, um) = makeStore()
        let originalSize = store.document.canvasSize
        let originalTransforms = store.document.layers.map(\.transform)

        store.activeTool = .crop
        XCTAssertEqual(store.cropSession?.rect, store.document.canvasRect)
        var session = store.cropSession!
        session.rect = CGRect(x: 50, y: 30, width: 200, height: 150)
        commitGrouped(um) {
            store.updateCropSession(session)
            store.commitCropSession()
        }
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 200, height: 150))
        XCTAssertEqual(store.document.layers[0].transform.tx, originalTransforms[0].tx - 50)
        XCTAssertEqual(um.undoActionName, "Crop")

        um.undo()
        XCTAssertEqual(store.document.canvasSize, originalSize)
        XCTAssertEqual(store.document.layers.map(\.transform), originalTransforms)
    }

    func testPlacedAndRecenteredLayersLandOnWholePixels() {
        let image = GeneratedImages.solid(width: 101, height: 51, r: 200, g: 40, b: 40,
                                          colorSpace: BrushyColorSpace.displayP3)
        let canvas = CGSize(width: 400, height: 300)
        let placed = DocumentStore.placedLayer(image, named: "odd", canvasSize: canvas)
        XCTAssertEqual(placed.transform.tx, placed.transform.tx.rounded())
        XCTAssertEqual(placed.transform.ty, placed.transform.ty.rounded())
        XCTAssertEqual(placed.canvasBounds.midX, 200, accuracy: 0.5)

        var offset = placed
        offset.transform = CGAffineTransform(translationX: 13, y: 7)
        let recentered = DocumentStore.recentered(offset, canvasSize: canvas)
        XCTAssertEqual(recentered.canvasBounds.minX, recentered.canvasBounds.minX.rounded())
        XCTAssertEqual(recentered.canvasBounds.minY, recentered.canvasBounds.minY.rounded())
    }

    func testCanvasSizeChangesRecenterTheViewAtTheSameZoom() {
        let (store, um) = makeStore() // 400×300
        store.viewport.viewSize = CGSize(width: 1000, height: 800)
        store.viewport.isInitialized = true
        store.viewport.setZoom(2, anchorView: CGPoint(x: 37, y: 91)) // user-adjusted, off-centre
        commitGrouped(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 10, y: 20, width: 100, height: 60),
                                          transform: nil), mode: .replace)
        }
        commitGrouped(um) { store.cropToSelection() }
        XCTAssertEqual(store.viewport.zoom, 2)
        XCTAssertEqual(store.viewport.origin, CGPoint(x: (1000 - 200) / 2, y: (800 - 120) / 2))

        um.undo()
        XCTAssertEqual(store.viewport.zoom, 2)
        XCTAssertEqual(store.viewport.origin, CGPoint(x: (1000 - 800) / 2, y: (800 - 600) / 2),
                       "undoing the crop re-centres the restored canvas too")
    }

    func testCropToSelectionIsOneUndoableStepAndKeepsTheSelection() {
        let (store, um) = makeStore()
        let originalTransforms = store.document.layers.map(\.transform)
        XCTAssertFalse(store.canCropToSelection, "no selection, nothing to crop to")

        // A fractional lasso-ish triangle: crops to its outward-rounded bounds.
        let triangle = CGMutablePath()
        triangle.move(to: CGPoint(x: 50.4, y: 30.6))
        triangle.addLine(to: CGPoint(x: 249.5, y: 30.6))
        triangle.addLine(to: CGPoint(x: 150, y: 179.2))
        triangle.closeSubpath()
        commitGrouped(um) { store.combineSelection(triangle, mode: .replace) }
        XCTAssertTrue(store.canCropToSelection)

        commitGrouped(um) { store.cropToSelection() }
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 200, height: 150))
        XCTAssertEqual(store.document.layers[0].transform.tx, originalTransforms[0].tx - 50)
        XCTAssertEqual(store.document.layers[0].transform.ty, originalTransforms[0].ty - 30)
        XCTAssertEqual(um.undoActionName, "Crop")
        let bounds = store.selection.path!.boundingBoxOfPath
        XCTAssertEqual(bounds.minX, 0.4, accuracy: 0.001, "selection shifts with the content")
        XCTAssertEqual(bounds.minY, 0.6, accuracy: 0.001)

        // Cropping again to the same bounds is a no-op, not a history entry.
        let entryCount = store.historyEntries.count
        store.cropToSelection()
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 200, height: 150))
        XCTAssertEqual(store.historyEntries.count, entryCount)

        um.undo()
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(store.document.layers.map(\.transform), originalTransforms)
        XCTAssertEqual(store.selection.path?.boundingBoxOfPath.minX ?? 0, 50.4, accuracy: 0.001)
    }

    func testSelectionAndMaskLifecycle() {
        let (store, um) = makeStore()
        let layerID = store.document.layers[0].id
        store.selectLayer(layerID)
        store.featherAmount = 0

        let rect = CGRect(x: 20, y: 60, width: 60, height: 50)
        commitGrouped(um) {
            store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace)
        }
        XCTAssertFalse(store.selection.isEmpty)

        commitGrouped(um) { store.addLayerMask() }
        let layer = store.document[layerID: layerID]
        XCTAssertNotNil(layer?.mask)
        XCTAssertTrue(store.selection.isEmpty, "Photoshop consumes the selection into the mask")
        XCTAssertTrue(store.maskTargeted, "the new mask is targeted, with a visible ring")

        // Mask pixels: selection rect is canvas [20,60,60,50]; the layer sits at
        // translate(0..) — layer 0 is at (0, 40), so in source space the rect is
        // [20, 20, 60, 50]. Sample inside and outside (row 0 = top of source).
        let texture = layer!.mask!.texture
        func sample(_ x: Int, _ yUp: Int) -> UInt8 {
            texture.data[(texture.height - 1 - yUp) * texture.width + x]
        }
        XCTAssertEqual(sample(50, 45), 255, "inside the selection must be white")
        XCTAssertEqual(sample(90, 45), 0, "outside the selection must be black")
        XCTAssertEqual(sample(50, 5), 0, "below the selection must be black")

        um.undo() // undo Add Layer Mask
        XCTAssertNil(store.document[layerID: layerID]?.mask)
        XCTAssertFalse(store.selection.isEmpty, "undo restores the consumed selection")

        um.undo() // undo Select
        XCTAssertTrue(store.selection.isEmpty)
    }

    func testOpacityLiveEditCommitsOnce() {
        let (store, um) = makeStore()
        let id = store.document.layers[0].id
        store.selectLayer(id)
        for value in stride(from: 1.0, through: 0.42, by: -0.02) {
            store.setLiveOpacity(id, Float(value))
        }
        XCTAssertFalse(um.canUndo, "live edits must not create undo steps")
        commitGrouped(um) { store.endOpacityEdit() }
        XCTAssertEqual(store.document[layerID: id]!.opacity, 0.42, accuracy: 0.001)
        um.undo()
        XCTAssertEqual(store.document[layerID: id]!.opacity, 1)
    }

    func testTransformSessionCommitAndCancel() {
        let (store, um) = makeStore()
        let id = store.document.layers[1].id
        store.selectLayer(id)
        let original = store.document[layerID: id]!.transform

        // Cancel restores the pre-transform state (Esc).
        store.enterTransformMode()
        XCTAssertNotNil(store.transformSession)
        store.updateTransformSession(original.concatenating(CGAffineTransform(translationX: 33, y: 7)))
        store.cancelTransformSession()
        XCTAssertEqual(store.document[layerID: id]!.transform, original)
        XCTAssertFalse(um.canUndo)

        // Commit pushes exactly one step for the whole session.
        store.enterTransformMode()
        store.updateTransformSession(original.concatenating(CGAffineTransform(translationX: 10, y: 0)))
        store.updateTransformSession(original.concatenating(CGAffineTransform(translationX: 25, y: -4)))
        commitGrouped(um) { store.commitTransformSession() }
        XCTAssertEqual(store.document[layerID: id]!.transform.tx, original.tx + 25)
        um.undo()
        XCTAssertEqual(store.document[layerID: id]!.transform, original)
    }

    func testDeleteAndVisibility() {
        let (store, um) = makeStore(layers: 3)
        let ids = store.document.layers.map(\.id)
        store.selectLayer(ids[1])
        commitGrouped(um) { store.deleteSelectedLayer() }
        XCTAssertEqual(store.document.layers.count, 2)
        XCTAssertEqual(store.selectedLayerID, ids[0], "selection falls to the layer below")

        commitGrouped(um) { store.setLayerVisibility(ids[0], false) }
        XCTAssertEqual(store.document[layerID: ids[0]]?.isVisible, false)
        XCTAssertEqual(um.undoActionName, "Hide Layer")
        um.undo()
        XCTAssertEqual(store.document[layerID: ids[0]]?.isVisible, true)
        um.undo()
        XCTAssertEqual(store.document.layers.count, 3)
    }

    // MARK: - Modal-session undo (defect D)

    func testUndoDuringTransformRevertsGestureThenSessionThenHistory() {
        let (store, um) = makeStore()
        let id = store.document.layers[1].id
        store.selectLayer(id)
        commitGrouped(um) { store.renameLayer(id, to: "Committed") }
        let committed = store.document

        store.enterTransformMode()
        let initial = store.transformSession!.initialTransform
        store.updateTransformSession(
            initial.concatenating(CGAffineTransform(translationX: 40, y: -12)))

        // First ⌘Z: the gesture reverts, the box stays, history is untouched.
        XCTAssertTrue(store.handleUndoKeyDuringModalSession(redo: false))
        XCTAssertNotNil(store.transformSession, "revert keeps the session alive")
        XCTAssertEqual(store.transformSession?.currentTransform, initial)
        XCTAssertEqual(store.document[layerID: id]?.transform, initial)
        XCTAssertEqual(store.document[layerID: id]?.name, "Committed",
                       "the committed operation must still be applied")

        // Second ⌘Z: the session ends; the document equals the committed state.
        XCTAssertTrue(store.handleUndoKeyDuringModalSession(redo: false))
        XCTAssertNil(store.transformSession)
        XCTAssertEqual(store.document, committed)

        // Third ⌘Z: nothing claims it → normal history undo reverts the commit.
        XCTAssertFalse(store.handleUndoKeyDuringModalSession(redo: false))
        um.undo()
        XCTAssertNotEqual(store.document[layerID: id]?.name, "Committed")
    }

    func testRedoDuringTransformSessionIsConsumedNoOp() {
        let (store, _) = makeStore()
        store.selectLayer(store.document.layers[0].id)
        store.enterTransformMode()
        let initial = store.transformSession!.initialTransform
        let dragged = initial.concatenating(CGAffineTransform(translationX: 5, y: 5))
        store.updateTransformSession(dragged)
        XCTAssertTrue(store.handleUndoKeyDuringModalSession(redo: true),
                      "⇧⌘Z is consumed during a session")
        XCTAssertEqual(store.transformSession?.currentTransform, dragged,
                       "…but must not touch the live gesture")
    }

    func testUndoDuringAdjustedCropResetsRectOnly() {
        let (store, um) = makeStore()
        commitGrouped(um) { store.renameLayer(store.document.layers[0].id, to: "Kept") }
        store.activeTool = .crop
        var session = store.cropSession!
        session.rect = CGRect(x: 40, y: 20, width: 120, height: 90)
        store.updateCropSession(session)

        XCTAssertTrue(store.handleUndoKeyDuringModalSession(redo: false))
        XCTAssertEqual(store.cropSession?.rect, store.document.canvasRect)
        XCTAssertEqual(store.document.layers[0].name, "Kept", "history untouched")
        XCTAssertTrue(um.canUndo)

        // Untouched rect: falls through to normal undo.
        XCTAssertFalse(store.handleUndoKeyDuringModalSession(redo: false))
    }

    func testUndoDuringSelectionTransformMirrorsFreeTransform() {
        let (store, um) = makeStore()
        commitGrouped(um) {
            store.combineSelection(CGPath(rect: CGRect(x: 10, y: 10, width: 80, height: 60),
                                          transform: nil), mode: .replace)
        }
        let selectionBefore = store.selection
        store.enterSelectionTransformMode()
        store.updateSelectionTransformSession(CGAffineTransform(translationX: 30, y: 0))

        XCTAssertTrue(store.handleUndoKeyDuringModalSession(redo: false))
        XCTAssertNotNil(store.selectionTransformSession)
        XCTAssertEqual(store.selectionTransformSession?.currentTransform, .identity)

        XCTAssertTrue(store.handleUndoKeyDuringModalSession(redo: false))
        XCTAssertNil(store.selectionTransformSession)
        XCTAssertEqual(store.selection, selectionBefore, "the committed selection never changed")
        XCTAssertFalse(store.handleUndoKeyDuringModalSession(redo: false))
    }

    // MARK: - Multi-layer selection

    /// The set is the source of truth; `selectedLayerID` is the anchor, and a
    /// plain `selectLayer` still means "just this one".
    func testSelectLayerCollapsesTheSelectionToOne() {
        let (store, _) = makeStore(layers: 3)
        let ids = store.document.layers.map(\.id)
        XCTAssertEqual(store.selectedLayerIDs, [ids[2]], "a new store selects the topmost layer")
        store.toggleLayerSelection(ids[0])
        XCTAssertEqual(store.selectedLayerIDs, [ids[0], ids[2]])
        store.selectLayer(ids[1])
        XCTAssertEqual(store.selectedLayerIDs, [ids[1]])
        XCTAssertEqual(store.selectedLayerID, ids[1])
    }

    func testCommandClickTogglesMembershipAndMovesTheAnchor() {
        let (store, _) = makeStore(layers: 3)
        let ids = store.document.layers.map(\.id)
        store.selectLayer(ids[0])

        store.toggleLayerSelection(ids[2])
        XCTAssertEqual(store.selectedLayerIDs, [ids[0], ids[2]])
        XCTAssertEqual(store.selectedLayerID, ids[2], "the newly added layer becomes the anchor")

        store.toggleLayerSelection(ids[1])
        XCTAssertEqual(store.selectedLayerIDs, [ids[0], ids[1], ids[2]])

        // Removing the anchor hands the anchor to what is left, so
        // single-layer commands always have a target.
        store.toggleLayerSelection(ids[1])
        XCTAssertEqual(store.selectedLayerIDs, [ids[0], ids[2]])
        XCTAssertEqual(store.selectedLayerID, ids[2])
        store.toggleLayerSelection(ids[2])
        XCTAssertEqual(store.selectedLayerIDs, [ids[0]])
        XCTAssertEqual(store.selectedLayerID, ids[0])
    }

    /// ⇧-click extends over the PANEL's rows, which are a tree — a folder row
    /// inside the range is crossed, and a collapsed one (whose members have no
    /// rows at all) stands in for its whole subtree.
    func testShiftClickExtendsOverPanelDisplayOrder() {
        let (store, _) = makeStore(layers: 4)
        var doc = store.document
        let group = LayerGroup(name: "G")
        doc.groups = [group]
        doc.layers[1].groupID = group.id
        doc.layers[2].groupID = group.id
        store.replaceDocument(doc)
        let ids = store.document.layers.map(\.id) // [x, a(G), b(G), y]

        // Rows: [L:y, G:G, L:b, L:a, L:x]. From y down to a: y, b and a — the
        // top-level x below the folder is outside the range.
        store.selectLayer(ids[3])
        store.extendSelection(to: ids[1])
        XCTAssertEqual(store.selectedLayerIDs, [ids[3], ids[2], ids[1]])
        XCTAssertEqual(store.selectedLayerID, ids[3],
                       "the anchor stays at the range's origin, so ⇧-click re-extends")

        // Collapsed: rows are [L:y, G:G, L:x] — the folder row carries a and b.
        var collapsed = store.document
        collapsed.groups[0].isExpanded = false
        store.replaceDocument(collapsed)
        store.selectLayer(ids[3])
        store.extendSelection(to: ids[0])
        XCTAssertEqual(store.selectedLayerIDs, Set(ids),
                       "a collapsed folder's hidden members join with its row")
    }

    func testPanelRowSelectionRoutesGroupsAndLayers() {
        let (store, _) = makeStore(layers: 3)
        var doc = store.document
        let group = LayerGroup(name: "G")
        doc.groups = [group]
        doc.layers[0].groupID = group.id
        store.replaceDocument(doc)
        let ids = store.document.layers.map(\.id)

        store.selectPanelRows([group.id])
        XCTAssertEqual(store.selectedGroupID, group.id)
        XCTAssertNil(store.selectedLayerID, "a group row has no layer anchor")
        XCTAssertEqual(store.selectedLayerIDs, [ids[0]], "…but its members feed relational commands")

        // A set mixing a folder row with layer rows keeps the layers: group
        // and layer selection are mutually exclusive in this model.
        store.selectPanelRows([group.id, ids[1], ids[2]])
        XCTAssertNil(store.selectedGroupID)
        XCTAssertEqual(store.selectedLayerIDs, [ids[1], ids[2]])
        XCTAssertTrue(store.selectedLayerID.map { [ids[1], ids[2]].contains($0) } ?? false)

        store.selectPanelRows([])
        XCTAssertTrue(store.selectedLayerIDs.isEmpty)
        XCTAssertNil(store.selectedLayerID)
        XCTAssertNil(store.selectedGroupID)
    }

    func testMultiSelectionRidesTheUndoHistory() {
        let (store, um) = makeStore(layers: 3)
        let ids = store.document.layers.map(\.id)
        store.selectPanelRows([ids[0], ids[1]])
        commitGrouped(um) { store.renameLayer(ids[0], to: "Renamed") }
        XCTAssertEqual(store.selectedLayerIDs, [ids[0], ids[1]])

        store.selectLayer(ids[2])
        um.undo()
        // Snapshot semantics: the restored selection is what the
        // PREVIOUS snapshot recorded — the init state's topmost layer.
        XCTAssertEqual(store.selectedLayerIDs, [ids[2]])
        um.redo()
        XCTAssertEqual(store.selectedLayerIDs, [ids[0], ids[1]],
                       "redo restores the multi-selection the commit recorded")
        XCTAssertEqual(store.selectedLayerID, ids[1])
    }

    func testDeletedLayersLeaveTheSelectionSet() {
        let (store, um) = makeStore(layers: 3)
        let ids = store.document.layers.map(\.id)
        store.selectPanelRows(Set(ids))
        store.selectLayer(ids[1])
        store.toggleLayerSelection(ids[0])
        store.toggleLayerSelection(ids[2])
        XCTAssertEqual(store.selectedLayerIDs, Set(ids))

        commitGrouped(um) { store.deleteSelectedLayer() }
        XCTAssertFalse(store.selectedLayerIDs.contains(ids[2]),
                       "a deleted layer's id must not survive in the selection")
        XCTAssertEqual(store.selectedLayerID.map { store.selectedLayerIDs.contains($0) }, true)
        for id in store.selectedLayerIDs {
            XCTAssertNotNil(store.document[layerID: id])
        }
    }

    /// Commands that only make sense on one layer keep using the anchor.
    func testSingleLayerCommandsActOnTheAnchorOnly() {
        let (store, um) = makeStore(layers: 3)
        let ids = store.document.layers.map(\.id)
        store.selectPanelRows(Set(ids))
        store.selectLayer(ids[1])
        store.toggleLayerSelection(ids[0]) // two layers selected, anchored on ids[0]
        XCTAssertEqual(store.selectedLayerIDs, [ids[0], ids[1]])

        commitGrouped(um) { store.addLayerMask() }
        XCTAssertNotNil(store.document[layerID: ids[0]]?.mask)
        XCTAssertNil(store.document[layerID: ids[1]]?.mask,
                     "Add Layer Mask must not fan out over the whole selection")
    }

    /// Appendix check 8: any operation that restructures the stack must leave
    /// `normalizingGroups()` a no-op — including a multi-row drag.
    func testMultiRowPanelMoveKeepsTheGroupInvariant() {
        let (store, um) = makeStore(layers: 4)
        var doc = store.document
        let group = LayerGroup(name: "G")
        doc.groups = [group]
        doc.layers[0].groupID = group.id
        doc.layers[1].groupID = group.id
        store.replaceDocument(doc)
        let names = store.document.layers.map(\.name) // [L0(G), L1(G), L2, L3]

        // Rows: [L:L3, L:L2, G:G, L:L1, L:L0]. Drag rows 0 and 4 (L3 and the
        // group's bottom member L0) into the gap above the folder header.
        commitGrouped(um) {
            store.reorderPanelRows(fromDisplayOffsets: IndexSet([0, 4]), toDisplayOffset: 2)
        }
        XCTAssertEqual(store.document.layers.map(\.name), [names[1], names[0], names[3], names[2]])
        XCTAssertEqual(store.document.normalizingGroups(), store.document,
                       "the contiguous-run invariant survives a multi-row move")
        XCTAssertEqual(store.document.normalizingClipping(), store.document)
        XCTAssertEqual(store.document.memberRun(ofGroup: group.id), 0...0)
        XCTAssertNil(store.document.layers[1].groupID)
        XCTAssertNil(store.document.layers[2].groupID)

        um.undo()
        XCTAssertEqual(store.document.layers.map(\.name), names)
    }

    func testTextSessionUndoIsNotClaimedByModalHandler() {
        let (store, _) = makeStore()
        store.beginTextSession(creatingAt: CGPoint(x: 50, y: 50))
        XCTAssertNotNil(store.textSession)
        XCTAssertFalse(store.handleUndoKeyDuringModalSession(redo: false),
                       "text sessions own their undo — the store handler must decline")
        store.cancelTextSession()
    }
}

import AppKit
import CoreGraphics
import Foundation
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// Layer groups: store flows — ⌘G/⇧⌘G as single undo
/// entries, group-aware delete/duplicate, the merge-down boundary block,
/// arrival adoption, disclosure staying out of history, and the group
/// opacity/blend commit shapes. Windowless throughout (see the note atop
/// NewDocumentTests.swift); undo mechanics follow StoreTests' commitGrouped
/// pattern.
final class GroupStoreTests: XCTestCase {
    private let source = GeneratedImages.solid(width: 8, height: 8, r: 90, g: 120, b: 200,
                                               colorSpace: BrushyColorSpace.displayP3)

    private func makeStore(layerNames: [String],
                           attachUndo: Bool = false) -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        document.layers = layerNames.map { Layer(name: $0, source: source) }
        let store = DocumentStore(document: document)
        let undo = UndoManager()
        undo.levelsOfUndo = 100
        undo.groupsByEvent = false
        if attachUndo { store.undoManager = undo }
        return (store, undo)
    }

    private func commitGrouped(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    // MARK: - Group / Ungroup

    func testGroupLayerIsOneUndoEntryAndSelectsTheGroup() {
        let (store, um) = makeStore(layerNames: ["a", "b"], attachUndo: true)
        store.selectLayer(store.document.layers[0].id)
        XCTAssertFalse(store.canUndo)

        commitGrouped(um) { store.groupSelection() }
        XCTAssertEqual(store.document.groups.count, 1)
        XCTAssertEqual(store.document.layers[0].groupID, store.document.groups[0].id)
        XCTAssertEqual(store.selectedGroupID, store.document.groups[0].id,
                       "⌘G selects the new group")
        XCTAssertNil(store.selectedLayerID, "group selection clears the layer selection")
        XCTAssertEqual(um.undoActionName, "Group Layer")
        XCTAssertTrue(store.canUndo)
        XCTAssertFalse(store.canRedo)

        um.undo()
        XCTAssertTrue(store.document.groups.isEmpty, "one undo removes the group")
        XCTAssertNil(store.document.layers[0].groupID)
        XCTAssertNil(store.selectedGroupID, "undo restores the recorded selection")
        // Selection restores to what the PREVIOUS snapshot recorded (the
        // init-selected topmost layer) — uncommitted selection changes never
        // rewrite history, per the snapshot semantics.
        XCTAssertEqual(store.selectedLayerID, store.document.layers.last?.id)
    }

    func testGroupingASelectedGroupWrapsIt() throws {
        let (store, _) = makeStore(layerNames: ["a"])
        store.selectLayer(store.document.layers[0].id)
        store.groupSelection()
        let innerID = try XCTUnwrap(store.selectedGroupID)
        store.groupSelection()
        let outerID = try XCTUnwrap(store.selectedGroupID)
        XCTAssertNotEqual(innerID, outerID)
        XCTAssertEqual(store.document.group(withID: innerID)?.parentID, outerID,
                       "⌘G on a selected group wraps it in a new parent")
        XCTAssertEqual(store.document.layers[0].groupID, innerID)
    }

    func testUngroupFromGroupAndFromMemberLayer() {
        let (store, um) = makeStore(layerNames: ["a", "b"], attachUndo: true)
        store.selectLayer(store.document.layers[1].id)
        commitGrouped(um) { store.groupSelection() }

        commitGrouped(um) { store.ungroupSelection() }
        XCTAssertTrue(store.document.groups.isEmpty)
        XCTAssertNil(store.document.layers[1].groupID)
        XCTAssertEqual(store.selectedLayerID, store.document.layers[1].id,
                       "ungrouping a selected group selects its topmost freed layer")
        XCTAssertEqual(um.undoActionName, "Ungroup")

        // From a member layer: ⇧⌘G reads the layer's innermost group.
        commitGrouped(um) { store.groupSelection() }
        store.selectLayer(store.document.layers[1].id)
        XCTAssertNotNil(store.ungroupTargetID)
        commitGrouped(um) { store.ungroupSelection() }
        XCTAssertTrue(store.document.groups.isEmpty)
        XCTAssertEqual(store.selectedLayerID, store.document.layers[1].id,
                       "a selected member stays selected through ungroup")
    }

    // MARK: - Delete / duplicate group

    func testDeleteGroupRemovesSubtreeAsOneEntry() {
        let (store, um) = makeStore(layerNames: ["keep", "member"], attachUndo: true)
        store.selectLayer(store.document.layers[1].id)
        commitGrouped(um) { store.groupSelection() }
        XCTAssertEqual(store.document.layers.count, 2)

        commitGrouped(um) { store.deleteSelectedGroup() }
        XCTAssertEqual(store.document.layers.map(\.name), ["keep"],
                       "deleting a group deletes its members")
        XCTAssertTrue(store.document.groups.isEmpty)
        XCTAssertEqual(store.selectedLayerID, store.document.layers[0].id)
        XCTAssertEqual(um.undoActionName, "Delete Group")

        um.undo()
        XCTAssertEqual(store.document.layers.map(\.name), ["keep", "member"],
                       "one undo restores group and members together")
        XCTAssertEqual(store.document.groups.count, 1)
    }

    func testDuplicateGroupSelectsTheCopy() throws {
        let (store, um) = makeStore(layerNames: ["a"], attachUndo: true)
        store.selectLayer(store.document.layers[0].id)
        commitGrouped(um) { store.groupSelection() }
        let originalID = try XCTUnwrap(store.selectedGroupID)

        commitGrouped(um) { store.duplicateSelectedGroup() }
        XCTAssertEqual(store.document.groups.count, 2)
        XCTAssertEqual(store.document.layers.count, 2)
        XCTAssertNotEqual(store.selectedGroupID, originalID, "the copy is selected")
        XCTAssertEqual(store.document.layers[0].sourceID, store.document.layers[1].sourceID,
                       "duplicated members share sources — the serializer stores them once")
        XCTAssertEqual(um.undoActionName, "Duplicate Group")
    }

    // MARK: - Merge Down boundary

    func testMergeDownBlockedAcrossGroupBoundary() {
        let (store, _) = makeStore(layerNames: ["below", "member"])
        store.selectLayer(store.document.layers[1].id)
        store.groupSelection()
        store.selectLayer(store.document.layers[1].id)
        let before = store.document
        store.mergeDownSelectedLayer()
        XCTAssertEqual(store.document, before,
                       "merge down must refuse to cross a group boundary")

        // Two members of the same group merge as usual.
        var doc = Document(canvasSize: CGSize(width: 64, height: 64))
        let g = LayerGroup(name: "G")
        doc.groups = [g]
        doc.layers = [Layer(name: "x", source: source, groupID: g.id),
                      Layer(name: "y", source: source, groupID: g.id)]
        let store2 = DocumentStore(document: doc)
        store2.selectLayer(doc.layers[1].id)
        store2.mergeDownSelectedLayer()
        XCTAssertEqual(store2.document.layers.count, 1, "same-group merge proceeds")
        XCTAssertEqual(store2.document.layers[0].groupID, g.id,
                       "the merged layer stays in the group")
        XCTAssertEqual(store2.document.normalizingGroups(), store2.document)
    }

    // MARK: - Arrivals adopt the selection's group

    func testNewPaintLayerJoinsSelectedLayersGroup() throws {
        let (store, _) = makeStore(layerNames: ["below", "member", "above"])
        store.selectLayer(store.document.layers[1].id)
        store.groupSelection()
        store.selectLayer(store.document.layers[1].id)

        store.addPaintLayer()
        let inserted = try XCTUnwrap(store.selectedLayer)
        XCTAssertEqual(store.document.layerIndex(of: inserted.id), 2,
                       "new layer lands directly above the selection")
        XCTAssertEqual(inserted.groupID, store.document.layers[1].groupID,
                       "and joins its group, keeping the run contiguous")
        XCTAssertEqual(store.document.normalizingGroups(), store.document)
    }

    func testReceivedLayerAdoptsDestinationGroupNotSource() throws {
        // Source document: the layer lives inside a group there.
        var sourceDoc = Document(canvasSize: CGSize(width: 64, height: 64))
        let sg = LayerGroup(name: "SourceGroup")
        sourceDoc.groups = [sg]
        sourceDoc.layers = [Layer(name: "traveller", source: source, groupID: sg.id)]

        let (store, _) = makeStore(layerNames: ["below", "member"])
        store.selectLayer(store.document.layers[1].id)
        store.groupSelection()
        store.selectLayer(store.document.layers[1].id)
        let destinationGroup = store.document.layers[1].groupID

        store.receiveLayer(sourceDoc.layers[0], from: sourceDoc.canvasSize)
        let arrived = try XCTUnwrap(store.selectedLayer)
        XCTAssertEqual(arrived.name, "traveller")
        XCTAssertEqual(arrived.groupID, destinationGroup,
                       "membership never travels — the landing spot decides")
        XCTAssertFalse(store.document.groups.contains { $0.id == sg.id },
                       "the source document's group is not imported")
        XCTAssertEqual(store.document.normalizingGroups(), store.document)
    }

    func testPastedLayerArrivesUngroupedFromSourceAndAdoptsDestination() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("group-tests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }

        // Copy a grouped layer out of one store…
        var sourceDoc = Document(canvasSize: CGSize(width: 64, height: 64))
        let sg = LayerGroup(name: "SourceGroup")
        sourceDoc.groups = [sg]
        sourceDoc.layers = [Layer(name: "copied", source: source, groupID: sg.id)]
        let sourceStore = DocumentStore(document: sourceDoc)
        sourceStore.selectLayer(sourceDoc.layers[0].id)
        sourceStore.copySelection(to: pasteboard)

        // …into another store with a grouped selection.
        let (store, _) = makeStore(layerNames: ["below", "member"])
        store.selectLayer(store.document.layers[1].id)
        store.groupSelection()
        store.selectLayer(store.document.layers[1].id)
        let destinationGroup = store.document.layers[1].groupID

        store.paste(from: pasteboard)
        let pasted = try XCTUnwrap(store.selectedLayer)
        XCTAssertEqual(pasted.name, "copied")
        XCTAssertEqual(pasted.groupID, destinationGroup)
        XCTAssertEqual(store.document.normalizingGroups(), store.document)
    }

    // MARK: - Disclosure stays out of history

    func testExpansionToggleAddsNoHistoryAndSurvivesUndo() throws {
        let (store, um) = makeStore(layerNames: ["a"], attachUndo: true)
        store.selectLayer(store.document.layers[0].id)
        commitGrouped(um) { store.groupSelection() }
        let groupID = try XCTUnwrap(store.selectedGroupID)
        XCTAssertTrue(store.canUndo)
        XCTAssertEqual(um.undoActionName, "Group Layer")

        store.toggleGroupExpanded(groupID)
        XCTAssertEqual(store.document.group(withID: groupID)?.isExpanded, false)
        XCTAssertEqual(um.undoActionName, "Group Layer",
                       "collapsing a folder is not an edit")

        // Stepping history must not fight the disclosure state.
        um.undo()
        um.redo()
        XCTAssertEqual(store.document.group(withID: groupID)?.isExpanded, false,
                       "undo/redo keeps the patched disclosure state")
    }

    // MARK: - Group opacity / blend commit shapes

    func testGroupOpacitySliderLiveThenSingleCommit() throws {
        let (store, um) = makeStore(layerNames: ["a"], attachUndo: true)
        store.selectLayer(store.document.layers[0].id)
        commitGrouped(um) { store.groupSelection() }
        let groupID = try XCTUnwrap(store.selectedGroupID)

        store.setLiveGroupOpacity(groupID, 0.7)
        store.setLiveGroupOpacity(groupID, 0.4)
        XCTAssertEqual(um.undoActionName, "Group Layer",
                       "live drags create no history")
        commitGrouped(um) { store.endGroupOpacityEdit() }
        XCTAssertEqual(um.undoActionName, "Change Group Opacity")
        XCTAssertEqual(store.document.group(withID: groupID)?.opacity, 0.4)

        commitGrouped(um) { store.setGroupBlendMode(groupID, .multiply) }
        XCTAssertEqual(um.undoActionName, "Change Group Blend Mode")
        commitGrouped(um) { store.setGroupBlendMode(groupID, nil) }
        XCTAssertNil(store.document.group(withID: groupID)?.blendMode,
                     "Pass Through round-trips as nil")
    }

    // MARK: - Group visibility gates member-dependent commands

    func testHiddenGroupDisablesCopyOfMembers() throws {
        let (store, _) = makeStore(layerNames: ["a"])
        store.selectLayer(store.document.layers[0].id)
        store.groupSelection()
        let groupID = try XCTUnwrap(store.selectedGroupID)
        store.setGroupVisibility(groupID, false)
        store.selectLayer(store.document.layers[0].id)
        XCTAssertTrue(store.document.layers[0].isVisible, "the member's own eye is untouched")
        XCTAssertFalse(store.selectedLayerEffectivelyVisible,
                       "hidden ancestors make the layer effectively hidden")
    }
}

import AppKit
import CoreGraphics
import Darwin
import Foundation
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// — the History panel's model: the named-snapshot projection, the
/// no-op dedupe that survives the `actionName` schema change, click-to-jump
/// through `undoStep`/`redoStep`, and the byte budget that keeps a long paint
/// session from retaining gigabytes.
///
/// Windowless throughout (see the note atop NewDocumentTests.swift); undo
/// mechanics follow StoreTests' `commitGrouped` pattern.
final class HistoryTests: XCTestCase {
    private let source = GeneratedImages.solid(width: 8, height: 8, r: 90, g: 120, b: 200,
                                               colorSpace: BrushyColorSpace.displayP3)

    private func makeStore(layerNames: [String] = ["a", "b"]) -> (DocumentStore, UndoManager) {
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        document.layers = layerNames.map { Layer(name: $0, source: source) }
        let store = DocumentStore(document: document)
        let undo = UndoManager()
        undo.levelsOfUndo = 100
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    private func commitGrouped(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    private func names(_ store: DocumentStore) -> [String] {
        store.historyEntries.map(\.actionName)
    }

    // MARK: - Projection

    func testHistoryEntriesListOpeningStateThenEachNamedCommit() {
        let (store, um) = makeStore()
        let id = store.document.layers[0].id
        XCTAssertEqual(names(store), ["New"], "a fresh store opens on one unnamed-edit row")
        XCTAssertEqual(store.historyPosition, 0)
        XCTAssertNil(store.historyLimitNote, "nothing has been discarded yet")

        commitGrouped(um) { store.renameLayer(id, to: "one") }
        commitGrouped(um) { store.duplicateSelectedLayer() }
        commitGrouped(um) { store.renameLayer(id, to: "two") }

        XCTAssertEqual(names(store), ["New", "Rename Layer", "Duplicate Layer", "Rename Layer"])
        XCTAssertEqual(store.historyPosition, 3)
        XCTAssertEqual(store.historyEntries.filter(\.isCurrent).map(\.id), [3])
        XCTAssertTrue(store.historyEntries.allSatisfy { !$0.isRedoTail },
                      "nothing is ahead of the newest state")
    }

    func testRedoTailIsFlaggedAfterSteppingBack() {
        let (store, um) = makeStore()
        let id = store.document.layers[0].id
        commitGrouped(um) { store.renameLayer(id, to: "one") }
        commitGrouped(um) { store.renameLayer(id, to: "two") }

        store.jumpToHistory(index: 1)
        XCTAssertEqual(store.historyEntries.map(\.isRedoTail), [false, false, true])
        XCTAssertEqual(store.historyEntries.map(\.isCurrent), [false, true, false])
    }

    /// The `Snapshot.==` exclusion: two different command names producing an
    /// identical document must still dissolve as a no-op.
    func testNoOpCommitWithDifferentActionNameAddsNoRow() {
        let (store, um) = makeStore()
        let id = store.document.layers[0].id
        commitGrouped(um) { store.renameLayer(id, to: "one") }
        XCTAssertEqual(names(store), ["New", "Rename Layer"])

        // Same document, different label — this is what an unchanged Free
        // Transform or an empty-selection Fill lands as.
        commitGrouped(um) { store.commit("Free Transform", document: store.document) }
        commitGrouped(um) { store.commit("Fill", document: store.document) }
        XCTAssertEqual(names(store), ["New", "Rename Layer"],
                       "actionName must stay out of Snapshot equality")
        XCTAssertEqual(store.historyPosition, 1)
    }

    func testReplaceDocumentNamesTheOpeningStateOpenOrNew() {
        let (store, _) = makeStore()
        var loaded = Document(canvasSize: CGSize(width: 32, height: 32))
        loaded.layers = [Layer(name: "from disk", source: source)]

        store.replaceDocument(loaded)
        XCTAssertEqual(names(store), ["Open"])

        store.replaceDocument(loaded, actionName: DocumentStore.newDocumentActionName)
        XCTAssertEqual(names(store), ["New"])
        XCTAssertEqual(store.historyPosition, 0)
        XCTAssertFalse(store.canUndo)
    }

    // MARK: - Jumping

    func testJumpBackRestoresThatStateAndLeavesARedoTail() {
        let (store, um) = makeStore()
        let id = store.document.layers[0].id
        commitGrouped(um) { store.renameLayer(id, to: "one") }
        let afterFirst = store.document
        commitGrouped(um) { store.renameLayer(id, to: "two") }
        commitGrouped(um) { store.renameLayer(id, to: "three") }

        store.jumpToHistory(index: 1)
        XCTAssertEqual(store.document, afterFirst)
        XCTAssertEqual(store.historyPosition, 1)
        XCTAssertTrue(store.canRedo, "two states are still ahead")
        // The whole jump is ONE undo group, and ⌘Z returns to where the user
        // jumped from — Photoshop's "Undo State Change".
        XCTAssertTrue(um.canUndo)
        XCTAssertEqual(um.undoActionName, "State Change")
        um.undo()
        XCTAssertEqual(store.historyPosition, 3, "one ⌘Z undoes the whole jump")
        XCTAssertEqual(store.document[layerID: id]?.name, "three")
    }

    func testJumpBackThenForwardReturnsTheIdenticalDocument() {
        let (store, um) = makeStore()
        let id = store.document.layers[0].id
        commitGrouped(um) { store.renameLayer(id, to: "one") }
        commitGrouped(um) { store.renameLayer(id, to: "two") }
        commitGrouped(um) { store.renameLayer(id, to: "three") }
        let top = store.document

        store.jumpToHistory(index: 0)
        XCTAssertEqual(store.document[layerID: id]?.name, "a")
        store.jumpToHistory(index: 3)
        XCTAssertEqual(store.document, top)
        XCTAssertFalse(store.canRedo)
    }

    func testJumpToCurrentRowIsANoOpAndRegistersNoUndo() {
        let (store, um) = makeStore()
        let id = store.document.layers[0].id
        commitGrouped(um) { store.renameLayer(id, to: "one") }
        while um.canUndo { um.undo() }
        while um.canRedo { um.redo() }
        let before = store.historyPosition

        store.jumpToHistory(index: before)
        XCTAssertEqual(store.historyPosition, before)
        store.jumpToHistory(index: 99)
        XCTAssertEqual(store.historyPosition, before, "out-of-range rows are ignored")
    }

    func testCommitAfterJumpingBackTruncatesTheRedoTail() {
        let (store, um) = makeStore()
        let id = store.document.layers[0].id
        commitGrouped(um) { store.renameLayer(id, to: "one") }
        commitGrouped(um) { store.renameLayer(id, to: "two") }
        commitGrouped(um) { store.duplicateSelectedLayer() }
        XCTAssertEqual(store.historyEntries.count, 4)

        store.jumpToHistory(index: 1)
        commitGrouped(um) { store.renameLayer(id, to: "branch") }
        XCTAssertEqual(names(store), ["New", "Rename Layer", "Rename Layer"])
        XCTAssertEqual(store.historyPosition, 2)
        XCTAssertFalse(store.canRedo)
    }

    /// `apply(_:)` re-validates the selected layer against each restored
    /// document; a multi-step jump crosses states where it no longer exists.
    func testMultiStepJumpAcrossADeletedLayerKeepsSelectionLive() {
        let (store, um) = makeStore(layerNames: ["a", "b", "c"])
        let doomed = store.document.layers[2].id
        store.selectLayer(doomed)
        commitGrouped(um) { store.renameLayer(doomed, to: "c2") }
        commitGrouped(um) { store.deleteSelectedLayer() }
        commitGrouped(um) { store.renameLayer(store.document.layers[0].id, to: "a2") }

        store.jumpToHistory(index: 1)
        XCTAssertNotNil(store.selectedLayerID)
        XCTAssertNotNil(store.document[layerID: store.selectedLayerID!],
                        "the restored selection must exist in the restored document")
        store.jumpToHistory(index: 3)
        XCTAssertNotNil(store.selectedLayerID)
        XCTAssertNotNil(store.document[layerID: store.selectedLayerID!])
    }

    /// Disclosure state is model data but deliberately NOT an undoable edit —
    /// the store patches it through every snapshot. A history jump must not
    /// collapse folders the user has opened.
    func testHistoryJumpDoesNotCollapseOpenGroups() {
        let (store, um) = makeStore(layerNames: ["a", "b"])
        store.selectLayer(store.document.layers[0].id)
        commitGrouped(um) { store.groupSelection() }
        let groupID = store.document.groups[0].id
        commitGrouped(um) { store.renameLayer(store.document.layers[1].id, to: "b2") }
        commitGrouped(um) { store.renameLayer(store.document.layers[1].id, to: "b3") }

        store.toggleGroupExpanded(groupID)   // collapse — not a history entry
        XCTAssertFalse(store.document.group(withID: groupID)!.isExpanded)
        let rowsBefore = store.historyEntries.count

        store.jumpToHistory(index: 1)
        XCTAssertEqual(store.historyEntries.count, rowsBefore,
                       "toggling disclosure adds no history row")
        XCTAssertFalse(store.document.group(withID: groupID)!.isExpanded,
                       "a jump must not revert the user's disclosure state")

        store.toggleGroupExpanded(groupID)   // re-open, then jump forward
        store.jumpToHistory(index: 3)
        XCTAssertTrue(store.document.group(withID: groupID)!.isExpanded)
    }

    // MARK: - Memory: the byte budget

    /// One 400×400 RGBA8 bitmap ≈ 640 kB. Committing a fresh source each time
    /// is what a brush stroke does (`endBrushStroke` bakes a new CGImage).
    private func commitFreshSource(_ store: DocumentStore, _ um: UndoManager,
                                   side: Int, index: Int) {
        commitGrouped(um) {
            var layer = store.document.layers[0]
            layer = Layer(id: layer.id, sourceID: UUID(), name: layer.name,
                          source: GeneratedImages.solid(width: side, height: side,
                                                        r: UInt8(index % 255), g: 10, b: 10,
                                                        colorSpace: BrushyColorSpace.displayP3),
                          transform: layer.transform, isPaintable: true)
            store.commit("Brush Stroke", document: store.document.replacingLayer(layer))
        }
    }

    func testByteBudgetEvictsOldestStatesAndSaysSo() {
        let (store, um) = makeStore(layerNames: ["paint"])
        let side = 400
        let imageBytes = side * side * 4
        store.undoByteBudget = imageBytes * 5     // ~5 states' worth
        XCTAssertFalse(store.historyDiscardedOldSteps)

        for i in 0..<20 { commitFreshSource(store, um, side: side, index: i) }

        XCTAssertLessThanOrEqual(store.historyEntries.count, 6,
                                 "the byte cap bites long before the 100-step count cap")
        XCTAssertGreaterThan(store.historyEntries.count, 1)
        XCTAssertTrue(store.historyDiscardedOldSteps)
        XCTAssertEqual(store.historyLimitNote, "Older steps discarded to stay within memory",
                       "the panel must name the byte budget, not the step cap")
        XCTAssertLessThanOrEqual(store.historyByteCost, store.undoByteBudget)
        // The oldest states went, the newest stayed, and the position is the top.
        XCTAssertEqual(store.historyPosition, store.historyEntries.count - 1)
        XCTAssertFalse(names(store).contains("New"), "the opening state was evicted")

        // Undoing as far as the history allows must not fall off the end.
        var undos = 0
        while um.canUndo && undos < 100 { um.undo(); undos += 1 }
        XCTAssertEqual(store.historyPosition, 0)
    }

    /// The 100-step count cap still applies to cheap edits, and the panel says
    /// which of the two caps trimmed the list.
    func testCountCapTrimsCheapEditsAndSaysWhy() {
        let (store, um) = makeStore(layerNames: ["a"])
        let id = store.document.layers[0].id
        for i in 1...120 { commitGrouped(um) { store.renameLayer(id, to: "n\(i)") } }

        XCTAssertEqual(store.historyEntries.count, store.undoDepth)
        XCTAssertEqual(store.historyLimitNote, "Older steps discarded at the 100-step limit")
        XCTAssertLessThan(store.historyByteCost, 1_000_000, "cheap edits share one bitmap")
    }

    func testTheNewestStateSurvivesABudgetSmallerThanOneSnapshot() {
        let (store, um) = makeStore(layerNames: ["paint"])
        store.undoByteBudget = 1
        for i in 0..<3 { commitFreshSource(store, um, side: 200, index: i) }
        XCTAssertEqual(store.historyEntries.count, 1,
                       "a history that cannot hold the state on screen is worse than one over budget")
        XCTAssertEqual(store.historyPosition, 0)
        XCTAssertFalse(store.canUndo)
    }

    /// Shared storage is counted once for the whole history: 50 snapshots that
    /// share one `sourceID` cost roughly one image, not 50. This is what makes
    /// a long run of transform/rename edits free.
    func testSharedSourceStorageIsNotDoubleCounted() {
        let side = 400
        let imageBytes = side * side * 4
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        document.layers = [Layer(name: "big",
                                 source: GeneratedImages.solid(width: side, height: side,
                                                               r: 10, g: 20, b: 30,
                                                               colorSpace: BrushyColorSpace.displayP3))]
        let store = DocumentStore(document: document)
        let um = UndoManager()
        um.levelsOfUndo = 100
        um.groupsByEvent = false
        store.undoManager = um
        store.undoByteBudget = imageBytes * 3
        let id = document.layers[0].id

        for i in 0..<50 { commitGrouped(um) { store.renameLayer(id, to: "n\(i)") } }

        XCTAssertEqual(store.historyEntries.count, 51,
                       "51 snapshots sharing one bitmap must not evict under a 3-image budget")
        XCTAssertFalse(store.historyDiscardedOldSteps)
        XCTAssertLessThan(store.historyByteCost, imageBytes * 2,
                          "the union of retained storage is one image, not 51")
    }

    /// Duplicates share a `sourceID` and the same `CGImage`; a snapshot must
    /// be charged for those pixels once, not once per layer.
    func testDuplicatedLayersInOneSnapshotAreChargedOnce() {
        let side = 400
        let imageBytes = side * side * 4
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        document.layers = [Layer(name: "big",
                                 source: GeneratedImages.solid(width: side, height: side,
                                                               r: 10, g: 20, b: 30,
                                                               colorSpace: BrushyColorSpace.displayP3))]
        let store = DocumentStore(document: document)
        let um = UndoManager()
        um.groupsByEvent = false
        store.undoManager = um
        store.selectLayer(document.layers[0].id)
        let baseline = store.historyByteCost

        for _ in 0..<5 { commitGrouped(um) { store.duplicateSelectedLayer() } }

        XCTAssertEqual(store.document.layers.count, 6)
        XCTAssertLessThan(store.historyByteCost, baseline + imageBytes,
                          "six layers over one shared bitmap cost one bitmap")
    }

    // MARK: - Memory: the measured end-to-end case

    /// The appendix's measurement, kept reproducible but opt-in: 200 strokes
    /// on a 1500×1000 paint layer, sampling `phys_footprint` every 50.
    ///
    /// What it asserts is the SHAPE of the curve, not an absolute number.
    /// Measured on this machine: with no byte budget the footprint grows
    /// linearly at ~5.8 MB per stroke, exactly tracking `historyByteCost`
    /// (200 strokes = 1,157 MB grown vs 1,153 MB accounted). With the budget
    /// the curve plateaus — 356 MB after 50 strokes, 357 MB after 200. That
    /// plateau is Core Image's own tiling/intermediate pool, which scales with
    /// the layer's dimensions (~60–80× one bitmap) and does not grow with the
    /// number of strokes; the history was the only unbounded term, and it is
    /// the one this cap removes. Same run at 6000×4000 (the plan's figures):
    /// 9,640 MB before the budget, of which the history was 9.6 GB; after, the
    /// history holds at ≤2 GB.
    ///
    /// Run with `TEST_RUNNER_MEMORY_PROBE=1 xcodebuild … \
    /// -only-testing:BrushyTests/HistoryTests/testMemoryProbePaintSessionPlateaus`.
    func testMemoryProbePaintSessionPlateaus() throws {
        guard ProcessInfo.processInfo.environment["MEMORY_PROBE"] == "1" else {
            throw XCTSkip("opt-in memory probe — see the doc comment")
        }
        let size = CGSize(width: 1500, height: 1000)
        var document = Document(canvasSize: size)
        document.layers = [DocumentStore.blankPaintLayer(canvasSize: size, name: "Paint")!]
        let store = DocumentStore(document: document)
        let um = UndoManager()
        um.levelsOfUndo = 300
        um.groupsByEvent = false
        store.undoManager = um
        store.activeTool = .brush
        store.brushSize = 120
        // 30 strokes' worth, so the cap engages inside a 200-stroke run.
        store.undoDepth = 1000
        store.undoByteBudget = 1500 * 1000 * 4 * 30

        let before = Self.footprintBytes()
        var atFifty = before
        for i in 0..<200 {
            let y = CGFloat(20 + (i * 37) % 950)
            autoreleasepool {
                commitGrouped(um) {
                    store.beginBrushStroke(at: CGPoint(x: 50, y: y), eraser: false)
                    store.continueBrushStroke(to: CGPoint(x: 1450, y: y + 20))
                    store.endBrushStroke()
                }
            }
            if i == 49 { atFifty = Self.footprintBytes() }
        }
        let firstHalf = Int(atFifty) - Int(before)
        let rest = Int(Self.footprintBytes()) - Int(atFifty)
        print("MEMORY PROBE 1500×1000: first 50 strokes=\(firstHalf / 1_048_576) MB, "
              + "next 150=\(rest / 1_048_576) MB, rows=\(store.historyEntries.count), "
              + "history=\(store.historyByteCost / 1_048_576) MB")
        XCTAssertTrue(store.historyDiscardedOldSteps)
        XCTAssertLessThanOrEqual(store.historyByteCost, store.undoByteBudget)
        // The curve is flat once the cap engages: 150 more strokes must cost a
        // small fraction of the warm-up, not 150 more bitmaps.
        XCTAssertLessThan(rest, firstHalf / 2,
                          "memory must plateau, not keep growing with stroke count")
    }

    /// Resident footprint of this process (`phys_footprint`) — the number
    /// Activity Monitor and the jetsam limits use.
    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}

import CoreGraphics
import Foundation
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// Layer groups: the pure model — membership chains, the
/// contiguity invariant and its normalization, structural ops (group /
/// ungroup / delete / duplicate), the panel row model, drag-reorder
/// semantics, and clip-run scoping. All `Document -> Document` functions,
/// tested without a store or window (pattern).
final class GroupOpsTests: XCTestCase {
    private let source = GeneratedImages.solid(width: 4, height: 4, r: 128, g: 128, b: 128,
                                               colorSpace: BrushyColorSpace.displayP3)

    private func layer(_ name: String, groupID: UUID? = nil, clipped: Bool = false) -> Layer {
        Layer(name: name, source: source, isClippedToBelow: clipped, groupID: groupID)
    }

    private func document(_ layers: [Layer], groups: [LayerGroup] = []) -> Document {
        var doc = Document(canvasSize: CGSize(width: 64, height: 64))
        doc.layers = layers
        doc.groups = groups
        return doc
    }

    private func rowSummary(_ doc: Document) -> [String] {
        doc.panelRows().map { row in
            switch row {
            case .layer(let layer, let depth): return "L:\(layer.name)@\(depth)"
            case .group(let group, let depth): return "G:\(group.name)@\(depth)"
            }
        }
    }

    // MARK: - Chains & runs

    func testChainsAndMemberRuns() {
        let outer = LayerGroup(name: "Outer")
        let inner = LayerGroup(name: "Inner", parentID: outer.id)
        let doc = document([layer("a"),
                            layer("b", groupID: outer.id),
                            layer("c", groupID: inner.id),
                            layer("d", groupID: outer.id),
                            layer("e")],
                           groups: [outer, inner])
        XCTAssertEqual(doc.groupChain(from: inner.id), [outer.id, inner.id])
        XCTAssertEqual(doc.groupChain(from: nil), [])
        XCTAssertEqual(doc.memberRun(ofGroup: outer.id), 1...3)
        XCTAssertEqual(doc.memberRun(ofGroup: inner.id), 2...2)
        XCTAssertEqual(doc.normalizingGroups(), doc, "well-formed document normalizes to itself")
    }

    // MARK: - Normalization

    func testNormalizationClearsDanglingIDs() {
        let ghost = UUID()
        let group = LayerGroup(name: "G", parentID: ghost)
        let doc = document([layer("a", groupID: ghost), layer("b", groupID: group.id)],
                           groups: [group])
        let normalized = doc.normalizingGroups()
        XCTAssertNil(normalized.layers[0].groupID, "membership in a nonexistent group clears")
        XCTAssertNil(normalized.group(withID: group.id)?.parentID,
                     "a nonexistent parent clears")
        XCTAssertEqual(normalized.layers[1].groupID, group.id)
    }

    func testNormalizationBreaksParentCycles() {
        var a = LayerGroup(name: "A")
        var b = LayerGroup(name: "B")
        a.parentID = b.id
        b.parentID = a.id
        let doc = document([layer("x", groupID: a.id), layer("y", groupID: b.id)],
                           groups: [a, b])
        let normalized = doc.normalizingGroups()
        let parents = normalized.groups.compactMap(\.parentID)
        XCTAssertLessThan(parents.count, 2, "a parent cycle must be broken")
        // Chains must terminate for every layer afterwards.
        for l in normalized.layers {
            XCTAssertLessThanOrEqual(normalized.groupChain(from: l.groupID).count,
                                     normalized.groups.count)
        }
    }

    func testNormalizationRepairsInterleavedMembership() {
        let g = LayerGroup(name: "G")
        let doc = document([layer("a", groupID: g.id),
                            layer("gap"),
                            layer("b", groupID: g.id)],
                           groups: [g])
        let normalized = doc.normalizingGroups()
        XCTAssertEqual(normalized.layers[0].groupID, g.id, "first run survives")
        XCTAssertNil(normalized.layers[2].groupID,
                     "a membership reopened past a gap is truncated — groups stay contiguous")
        XCTAssertEqual(normalized.memberRun(ofGroup: g.id), 0...0)
    }

    func testNormalizationDropsEmptyGroupsIncludingEmptyAncestors() {
        let outer = LayerGroup(name: "Outer")
        let inner = LayerGroup(name: "Inner", parentID: outer.id)
        let unrelated = LayerGroup(name: "Kept")
        let doc = document([layer("a"), layer("b", groupID: unrelated.id)],
                           groups: [outer, inner, unrelated])
        let normalized = doc.normalizingGroups()
        XCTAssertNil(normalized.group(withID: outer.id),
                     "a group with no member layers anywhere in its subtree dissolves")
        XCTAssertNil(normalized.group(withID: inner.id))
        XCTAssertNotNil(normalized.group(withID: unrelated.id))
    }

    // MARK: - Clipping × groups

    func testClippingNormalizesAtGroupBoundaries() {
        let g = LayerGroup(name: "G")
        // clipped-at-bottom-of-group and clipped-above-the-group both lose
        // their flags; a clipped layer with a same-group neighbour keeps it.
        let doc = document([layer("below"),
                            layer("first", groupID: g.id, clipped: true),
                            layer("second", groupID: g.id, clipped: true),
                            layer("above", clipped: true)],
                           groups: [g])
        let normalized = doc.normalizingClipping()
        XCTAssertFalse(normalized.layers[1].isClippedToBelow,
                       "bottom-of-group clip has no base — released like bottom-of-stack")
        XCTAssertTrue(normalized.layers[2].isClippedToBelow,
                      "an in-group clip above an in-group neighbour survives")
        XCTAssertFalse(normalized.layers[3].isClippedToBelow,
                       "a clip whose neighbour below is inside a group is released")
    }

    func testClippingBaseResolutionStopsAtBoundary() {
        let g = LayerGroup(name: "G")
        let doc = document([layer("out"),
                            layer("base", groupID: g.id),
                            layer("clip1", groupID: g.id, clipped: true),
                            layer("clip2", groupID: g.id, clipped: true)],
                           groups: [g])
        XCTAssertEqual(doc.clippingBaseIndex(below: 3), 1, "run resolves within the group")
        XCTAssertEqual(doc.clippingBaseIndex(below: 2), 1)
        // A hand-built clip whose immediate neighbour is outside the scope
        // resolves to no base at all.
        let orphan = document([layer("out"), layer("clip", groupID: g.id, clipped: true)],
                              groups: [g])
        XCTAssertNil(orphan.clippingBaseIndex(below: 1))
    }

    // MARK: - Structural ops

    func testGroupingSingleLayerNestsInsideItsCurrentGroup() {
        let outer = LayerGroup(name: "Outer")
        let doc = document([layer("a", groupID: outer.id), layer("b", groupID: outer.id)],
                           groups: [outer])
        let (grouped, newID) = doc.addingGroup(named: "Group 1",
                                               aroundLayer: doc.layers[0].id)!
        XCTAssertEqual(grouped.layers[0].groupID, newID)
        XCTAssertEqual(grouped.group(withID: newID)?.parentID, outer.id,
                       "a new group nests inside the wrapped layer's group")
        XCTAssertEqual(grouped.memberRun(ofGroup: outer.id), 0...1,
                       "the outer run is untouched")
        XCTAssertEqual(grouped.normalizingGroups(), grouped)
    }

    func testGroupingReleasesClipsAcrossTheNewBoundary() {
        let doc = document([layer("base"), layer("clip", clipped: true)])
        let (grouped, _) = doc.addingGroup(named: "G", aroundLayer: doc.layers[0].id)!
        XCTAssertFalse(grouped.layers[1].isClippedToBelow,
                       "wrapping the base in a folder releases the clip above it")
    }

    func testGroupingAGroupWrapsIt() {
        let g = LayerGroup(name: "G")
        let doc = document([layer("a", groupID: g.id)], groups: [g])
        let (wrapped, wrapperID) = doc.addingGroup(named: "Wrapper", aroundGroup: g.id)!
        XCTAssertEqual(wrapped.group(withID: g.id)?.parentID, wrapperID)
        XCTAssertNil(wrapped.group(withID: wrapperID)?.parentID)
        XCTAssertEqual(wrapped.memberRun(ofGroup: wrapperID), 0...0)
        XCTAssertEqual(wrapped.layers[0].groupID, g.id, "direct membership is untouched")
    }

    func testUngroupingMovesDirectMembersToParent() {
        let outer = LayerGroup(name: "Outer")
        let inner = LayerGroup(name: "Inner", parentID: outer.id)
        let doc = document([layer("a", groupID: outer.id),
                            layer("b", groupID: inner.id),
                            layer("c", groupID: outer.id)],
                           groups: [outer, inner])
        let ungrouped = doc.ungrouping(outer.id)
        XCTAssertNil(ungrouped.group(withID: outer.id))
        XCTAssertNil(ungrouped.layers[0].groupID)
        XCTAssertNil(ungrouped.layers[2].groupID)
        XCTAssertEqual(ungrouped.layers[1].groupID, inner.id,
                       "nested members stay in their own group")
        XCTAssertNil(ungrouped.group(withID: inner.id)?.parentID,
                     "the nested group re-parents to the dissolved group's parent")
        XCTAssertEqual(ungrouped.layers.map(\.name), ["a", "b", "c"],
                       "stack positions never change on ungroup")
    }

    func testRemovingGroupDeletesSubtreeAndDissolvesEmptiedAncestors() {
        let outer = LayerGroup(name: "Outer")
        let inner = LayerGroup(name: "Inner", parentID: outer.id)
        let doc = document([layer("keep"),
                            layer("gone", groupID: inner.id)],
                           groups: [outer, inner])
        let removed = doc.removingGroup(inner.id)
        XCTAssertEqual(removed.layers.map(\.name), ["keep"])
        XCTAssertNil(removed.group(withID: inner.id))
        XCTAssertNil(removed.group(withID: outer.id),
                     "an ancestor left empty dissolves (this model has no empty folders)")
    }

    func testDuplicatingGroupCopiesSubtreeAboveWithFreshIDsSharedSources() {
        let outer = LayerGroup(name: "Outer")
        let inner = LayerGroup(name: "Inner", parentID: outer.id)
        let doc = document([layer("below"),
                            layer("a", groupID: outer.id),
                            layer("b", groupID: inner.id),
                            layer("above")],
                           groups: [outer, inner])
        let (dup, copyID) = doc.duplicatingGroup(outer.id)!
        XCTAssertEqual(dup.layers.count, 6)
        XCTAssertEqual(dup.layers.map(\.name), ["below", "a", "b", "a", "b", "above"],
                       "the copy inserts directly above the original run")
        XCTAssertEqual(dup.group(withID: copyID)?.name, "Outer copy")
        XCTAssertEqual(dup.memberRun(ofGroup: copyID), 3...4)
        XCTAssertEqual(dup.memberRun(ofGroup: outer.id), 1...2, "original untouched")
        // Fresh layer/group ids; shared bitmaps via sourceID (dedupe).
        XCTAssertNotEqual(dup.layers[3].id, dup.layers[1].id)
        XCTAssertEqual(dup.layers[3].sourceID, dup.layers[1].sourceID)
        XCTAssertTrue(dup.layers[3].source === dup.layers[1].source)
        // Nested structure is isomorphic: the copied inner group parents to
        // the copied outer group.
        let innerCopyID = dup.layers[4].groupID
        XCTAssertNotEqual(innerCopyID, inner.id)
        XCTAssertEqual(innerCopyID.flatMap { dup.group(withID: $0)?.parentID }, copyID)
        XCTAssertEqual(dup.normalizingGroups(), dup)
    }

    // MARK: - Panel rows

    func testPanelRowsPutFolderAboveMembersWithDepths() {
        let outer = LayerGroup(name: "Outer")
        let inner = LayerGroup(name: "Inner", parentID: outer.id)
        let doc = document([layer("bottom"),
                            layer("a", groupID: outer.id),
                            layer("b", groupID: inner.id),
                            layer("top")],
                           groups: [outer, inner])
        XCTAssertEqual(rowSummary(doc),
                       ["L:top@0",
                        "G:Outer@0", "G:Inner@1", "L:b@2", "L:a@1",
                        "L:bottom@0"])
    }

    func testPanelRowsHideCollapsedSubtrees() {
        var outer = LayerGroup(name: "Outer")
        let inner = LayerGroup(name: "Inner", parentID: outer.id)
        outer.isExpanded = false
        let doc = document([layer("a", groupID: outer.id),
                            layer("b", groupID: inner.id),
                            layer("top")],
                           groups: [outer, inner])
        XCTAssertEqual(rowSummary(doc), ["L:top@0", "G:Outer@0"],
                       "a collapsed folder shows its header only")
        var expandedOuter = doc
        expandedOuter.groups[0].isExpanded = true
        expandedOuter.groups[1].isExpanded = false
        XCTAssertEqual(rowSummary(expandedOuter),
                       ["L:top@0", "G:Outer@0", "G:Inner@1", "L:a@1"],
                       "a collapsed nested folder hides only its own subtree")
    }

    // MARK: - Drag-reorder over rows

    func testMoveLayerIntoGroupThroughHeaderGap() {
        let g = LayerGroup(name: "G")
        let doc = document([layer("member", groupID: g.id), layer("free")],
                           groups: [g])
        // Rows: [L:free@0, G:G@0, L:member@1]. Gap 2 = between the header and
        // its top member → inside the group.
        let moved = doc.movingPanelRow(fromDisplayOffsets: IndexSet(integer: 0),
                                       toDisplayOffset: 2)
        XCTAssertEqual(moved.layers.map(\.name), ["member", "free"],
                       "free lands above member in flat order")
        XCTAssertEqual(moved.layers[1].groupID, g.id, "the gap below a header joins the group")
        XCTAssertEqual(moved.memberRun(ofGroup: g.id), 0...1)
    }

    func testMoveLayerOutBelowGroup() {
        let g = LayerGroup(name: "G")
        let doc = document([layer("free"),
                            layer("a", groupID: g.id),
                            layer("b", groupID: g.id)],
                           groups: [g])
        // Rows: [G:G@0, L:b@1, L:a@1, L:free@0]. Move "b" to gap 3 (between
        // the group's bottom member and the top-level "free") → exits.
        let moved = doc.movingPanelRow(fromDisplayOffsets: IndexSet(integer: 1),
                                       toDisplayOffset: 3)
        XCTAssertEqual(moved.layers.map(\.name), ["free", "b", "a"])
        XCTAssertNil(moved.layers[1].groupID,
                     "the gap below a group's last member is outside the group")
        XCTAssertEqual(moved.memberRun(ofGroup: g.id), 2...2)
    }

    func testMoveWholeGroupAboveTopLevelLayer() {
        let g = LayerGroup(name: "G")
        let doc = document([layer("a", groupID: g.id),
                            layer("b", groupID: g.id),
                            layer("top")],
                           groups: [g])
        // Rows: [L:top@0, G:G@0, L:b@1, L:a@1]. Move the header row to gap 0
        // (very top) — the whole subtree relocates above "top".
        let moved = doc.movingPanelRow(fromDisplayOffsets: IndexSet(integer: 1),
                                       toDisplayOffset: 0)
        XCTAssertEqual(moved.layers.map(\.name), ["top", "a", "b"])
        XCTAssertEqual(moved.memberRun(ofGroup: g.id), 1...2)
        XCTAssertNil(moved.group(withID: g.id)?.parentID)
    }

    func testMoveCollapsedGroupBetweenMembersNestsIt() {
        var a = LayerGroup(name: "A")
        a.isExpanded = false
        let b = LayerGroup(name: "B")
        let doc = document([layer("a1", groupID: a.id),
                            layer("b1", groupID: b.id),
                            layer("b2", groupID: b.id)],
                           groups: [a, b])
        // Rows: [G:B@0, L:b2@1, L:b1@1, G:A@0]. Move collapsed A to gap 2
        // (between b2 and b1) → nested inside B.
        let moved = doc.movingPanelRow(fromDisplayOffsets: IndexSet(integer: 3),
                                       toDisplayOffset: 2)
        XCTAssertEqual(moved.layers.map(\.name), ["b1", "a1", "b2"])
        XCTAssertEqual(moved.group(withID: a.id)?.parentID, b.id,
                       "a gap between two members adopts their group")
        XCTAssertEqual(moved.memberRun(ofGroup: b.id), 0...2)
        XCTAssertEqual(moved.memberRun(ofGroup: a.id), 1...1)
        XCTAssertEqual(moved.normalizingGroups(), moved)
    }

    func testMoveGroupIntoOwnSubtreeIsRefused() {
        let outer = LayerGroup(name: "Outer")
        let inner = LayerGroup(name: "Inner", parentID: outer.id)
        let doc = document([layer("a", groupID: outer.id),
                            layer("b", groupID: inner.id)],
                           groups: [outer, inner])
        // Rows: [G:Outer@0, G:Inner@1, L:b@2, L:a@1]. Dropping Outer at gap 2
        // (inside Inner) would swallow itself.
        let moved = doc.movingPanelRow(fromDisplayOffsets: IndexSet(integer: 0),
                                       toDisplayOffset: 2)
        XCTAssertEqual(moved, doc)
    }

    func testDropAtOwnEdgeIsANoOp() {
        let g = LayerGroup(name: "G")
        let doc = document([layer("free"),
                            layer("a", groupID: g.id)],
                           groups: [g])
        // Rows: [G:G@0, L:a@1, L:free@0]. Dropping "a" at gap 2 (its own lower
        // edge) changes no order — it must NOT eject the layer from its group.
        let moved = doc.movingPanelRow(fromDisplayOffsets: IndexSet(integer: 1),
                                       toDisplayOffset: 2)
        XCTAssertEqual(moved, doc)
    }

    func testFlatMoveRepairsGroupsThroughNormalization() {
        let g = LayerGroup(name: "G")
        let doc = document([layer("free"),
                            layer("a", groupID: g.id),
                            layer("b", groupID: g.id)],
                           groups: [g])
        // The flat display-index op (used by group-free callers) drags "free"
        // between the two members; normalization keeps contiguity by
        // adopting or truncating.
        let moved = doc.movingLayers(fromDisplayOffsets: IndexSet(integer: 2),
                                     toDisplayOffset: 1)
        let run = moved.memberRun(ofGroup: g.id)
        if let run {
            let members = Set(moved.layers[run].compactMap(\.groupID))
            XCTAssertEqual(members, [g.id], "run must be contiguous after a flat move")
        }
        XCTAssertEqual(moved.normalizingGroups(), moved)
    }

    // MARK: - Names

    func testNextGroupNameSkipsTaken() {
        let doc = document([], groups: [])
        XCTAssertEqual(doc.nextGroupName(), "Group 1")
        let g1 = LayerGroup(name: "Group 1")
        let withOne = document([layer("a", groupID: g1.id)], groups: [g1])
        XCTAssertEqual(withOne.nextGroupName(), "Group 2")
    }
}

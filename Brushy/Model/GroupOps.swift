import CoreGraphics
import Foundation

/// Layer-group operations(— Photoshop's folders).
///
/// The design keeps `Document.layers` FLAT in render order (stay
/// untouched); groups are a parallel table plus per-layer membership, held to
/// one invariant: a group's members — nested groups' members included —
/// occupy a contiguous run of the flat array, and nested groups nest their
/// runs. Everything here is a pure `Document -> Document` function.

/// The layer stack as a nesting tree, bottom-first at every level. Shared by
/// the renderer (pass-through vs isolated compositing) and the PSD writer
/// (section-divider emission), so the two can never disagree about structure.
enum StackNode {
    case layer(Layer)
    case group(LayerGroup, [StackNode])
}

extension Document {
    // MARK: - Chains & membership

    /// The group path enclosing a direct membership, outermost first
    /// (`[]` for top level). Total even on malformed documents: unknown ids
    /// terminate the walk and a length cap defuses parent cycles.
    func groupChain(from directGroupID: UUID?) -> [UUID] {
        var chain: [UUID] = []
        var current = directGroupID
        while let id = current, chain.count <= groups.count {
            chain.append(id)
            current = group(withID: id)?.parentID
        }
        return chain.reversed()
    }

    /// The chain enclosing the group itself (its ancestors), outermost first.
    func ancestorChain(ofGroup id: UUID) -> [UUID] {
        groupChain(from: group(withID: id)?.parentID)
    }

    /// Indices of every layer inside the group's subtree (nested members
    /// included), ascending. Contiguous under the invariant.
    func memberLayerIndices(ofGroup id: UUID) -> [Int] {
        layers.indices.filter { groupChain(from: layers[$0].groupID).contains(id) }
    }

    /// The contiguous flat run the group's subtree occupies, or nil for a
    /// (transient, invalid) empty group.
    func memberRun(ofGroup id: UUID) -> ClosedRange<Int>? {
        let indices = memberLayerIndices(ofGroup: id)
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }

    // MARK: - Effective visibility

    /// A layer renders/hit-tests/copies only when it and every ancestor group
    /// are visible. Feeds render, hit-testing, Copy Merged and export
    /// identically (the renderer applies it structurally via `stackNodes`).
    func isEffectivelyVisible(layerID: UUID) -> Bool {
        guard let layer = self[layerID: layerID], layer.isVisible else { return false }
        return ancestorsVisible(fromDirectGroup: layer.groupID)
    }

    func isEffectivelyVisible(groupID: UUID) -> Bool {
        guard let group = group(withID: groupID), group.isVisible else { return false }
        return ancestorsVisible(fromDirectGroup: group.parentID)
    }

    func ancestorsVisible(fromDirectGroup id: UUID?) -> Bool {
        groupChain(from: id).allSatisfy { group(withID: $0)?.isVisible ?? true }
    }

    // MARK: - Normalization

    /// Enforces the group invariants; a well-formed document round-trips
    /// unchanged. Applied by every structural op and on load, mirroring
    /// `normalizingClipping()`:
    ///   1. memberships and parent links must name existing groups;
    ///   2. parent links must be acyclic (a cycle detaches where detected);
    ///   3. contiguity — walking the flat stack, the chain may only pop
    ///      closed groups and push never-seen ones; an out-of-place
    ///      membership truncates to its deepest valid prefix;
    ///   4. a group with no member layers in its subtree cannot exist (this
    ///      model has no place in the stack for an empty folder — deleting or
    ///      moving out a group's last member dissolves the group).
    func normalizingGroups() -> Document {
        guard !groups.isEmpty || layers.contains(where: { $0.groupID != nil }) else { return self }
        var doc = self
        // 1. Dangling references.
        let known = Set(doc.groups.map(\.id))
        for i in doc.layers.indices {
            if let gid = doc.layers[i].groupID, !known.contains(gid) {
                doc.layers[i].groupID = nil
            }
        }
        for i in doc.groups.indices {
            if let pid = doc.groups[i].parentID, !known.contains(pid) {
                doc.groups[i].parentID = nil
            }
        }
        // 2. Cycles.
        for i in doc.groups.indices {
            var seen: Set<UUID> = [doc.groups[i].id]
            var current = doc.groups[i].parentID
            while let id = current {
                if seen.contains(id) {
                    doc.groups[i].parentID = nil
                    break
                }
                seen.insert(id)
                current = doc.group(withID: id)?.parentID
            }
        }
        // 3. Contiguity (Dyck walk over the flat stack).
        var open: [UUID] = []
        var closed: Set<UUID> = []
        for i in doc.layers.indices {
            let want = doc.groupChain(from: doc.layers[i].groupID)
            var shared = 0
            while shared < min(open.count, want.count), open[shared] == want[shared] {
                shared += 1
            }
            closed.formUnion(open[shared...])
            open.removeSubrange(shared...)
            for id in want[shared...] {
                if closed.contains(id) { break } // reopened elsewhere — truncate
                open.append(id)
            }
            if doc.layers[i].groupID != open.last {
                doc.layers[i].groupID = open.last
            }
        }
        // 4. Empty groups. (Membership is by repaired chains; a group whose
        // only content was another, now-empty group has no member layers
        // either, so one pass removes whole empty subtrees.)
        var membered = Set<UUID>()
        for layer in doc.layers {
            membered.formUnion(doc.groupChain(from: layer.groupID))
        }
        doc.groups.removeAll { !membered.contains($0.id) }
        return doc
    }

    // MARK: - Structural operations

    /// ⌘G on a layer: wraps it in a new one-member group (valid Photoshop)
    /// nested inside the layer's current group. Layers above that clipped to
    /// the wrapped layer lose their base across the new boundary and are
    /// released, as is a clip on the wrapped layer itself.
    func addingGroup(named name: String, aroundLayer layerID: UUID) -> (document: Document, groupID: UUID)? {
        guard let index = layerIndex(of: layerID) else { return nil }
        var doc = self
        let group = LayerGroup(name: name, parentID: layers[index].groupID)
        doc.groups.append(group)
        doc.layers[index].groupID = group.id
        return (doc.normalizingClipping(), group.id)
    }

    /// ⌘G on a group: wraps the whole subtree in a new parent group.
    func addingGroup(named name: String, aroundGroup groupID: UUID) -> (document: Document, groupID: UUID)? {
        guard let index = groupIndex(of: groupID) else { return nil }
        var doc = self
        let wrapper = LayerGroup(name: name, parentID: groups[index].parentID)
        doc.groups.append(wrapper)
        doc.groups[index].parentID = wrapper.id
        return (doc.normalizingClipping(), wrapper.id)
    }

    /// ⇧⌘G: dissolves the group in place — direct members (layers and nested
    /// groups) move to its parent; their stack positions don't change.
    func ungrouping(_ groupID: UUID) -> Document {
        guard let index = groupIndex(of: groupID) else { return self }
        let parent = groups[index].parentID
        var doc = self
        for i in doc.layers.indices where doc.layers[i].groupID == groupID {
            doc.layers[i].groupID = parent
        }
        for i in doc.groups.indices where doc.groups[i].parentID == groupID {
            doc.groups[i].parentID = parent
        }
        doc.groups.remove(at: index)
        return doc.normalizingClipping()
    }

    /// Deletes the group AND its entire subtree — member layers and nested
    /// groups — in one step (the panel's Delete Group). An ancestor left with
    /// no other content dissolves too (rule 4 of `normalizingGroups`).
    func removingGroup(_ groupID: UUID) -> Document {
        guard group(withID: groupID) != nil else { return self }
        var doc = self
        let memberIDs = Set(memberLayerIndices(ofGroup: groupID).map { layers[$0].id })
        let subtree = Set(groups.map(\.id).filter { id in
            id == groupID || groupChain(from: id).contains(groupID)
        })
        doc.layers.removeAll { memberIDs.contains($0.id) }
        doc.groups.removeAll { subtree.contains($0.id) }
        return doc.normalizingGroups().normalizingClipping()
    }

    /// Duplicates the subtree directly above the original: fresh layer ids
    /// sharing `sourceID`s (like `Layer.duplicated`, so the file format
    /// stores pixels once), fresh group ids with remapped nesting. The copy
    /// keeps member names; the root copy gains " copy".
    func duplicatingGroup(_ groupID: UUID) -> (document: Document, newGroupID: UUID)? {
        guard let run = memberRun(ofGroup: groupID),
              let original = group(withID: groupID) else { return nil }
        var doc = self
        let subtree = groups.filter { id in
            id.id == groupID || groupChain(from: id.id).contains(groupID)
        }
        var idMap: [UUID: UUID] = [:]
        for g in subtree { idMap[g.id] = UUID() }
        let copies = subtree.map { g in
            LayerGroup(id: idMap[g.id]!,
                       name: g.id == groupID ? original.name + " copy" : g.name,
                       isVisible: g.isVisible, opacity: g.opacity,
                       blendMode: g.blendMode, isExpanded: g.isExpanded,
                       parentID: g.id == groupID ? g.parentID
                                                 : g.parentID.flatMap { idMap[$0] })
        }
        let layerCopies: [Layer] = layers[run].map { layer in
            var copy = layer.duplicated(name: layer.name)
            copy.groupID = layer.groupID.flatMap { idMap[$0] }
            return copy
        }
        doc.groups.append(contentsOf: copies)
        doc.layers.insert(contentsOf: layerCopies, at: run.upperBound + 1)
        return (doc, idMap[groupID]!)
    }

    // MARK: - Stack tree

    /// Builds the nesting tree from the flat stack in one pass. Robust
    /// against malformed documents (an unknown group id closes the scope; a
    /// non-contiguous group yields one node per run) — normalization keeps
    /// real documents out of those states.
    func stackNodes() -> [StackNode] {
        var root: [StackNode] = []
        var stack: [(group: LayerGroup, children: [StackNode])] = []
        var openChain: [UUID] = []

        func append(_ node: StackNode) {
            if stack.isEmpty {
                root.append(node)
            } else {
                stack[stack.count - 1].children.append(node)
            }
        }

        func close(downTo depth: Int) {
            while openChain.count > depth {
                let (group, children) = stack.removeLast()
                openChain.removeLast()
                append(.group(group, children))
            }
        }

        for layer in layers {
            let chain = groupChain(from: layer.groupID)
            var shared = 0
            while shared < min(openChain.count, chain.count),
                  openChain[shared] == chain[shared] {
                shared += 1
            }
            close(downTo: shared)
            for id in chain[shared...] {
                guard let group = group(withID: id) else { break }
                stack.append((group, []))
                openChain.append(id)
            }
            append(.layer(layer))
        }
        close(downTo: 0)
        return root
    }

    // MARK: - Layers-panel rows

    /// One row of the layers panel's display model (topmost first): a folder
    /// row sits directly above its topmost member; collapsed groups hide
    /// their subtree's rows. Pure so drag-reorder semantics are unit-testable.
    enum PanelRow: Identifiable, Equatable {
        case layer(Layer, depth: Int)
        case group(LayerGroup, depth: Int)

        var id: UUID {
            switch self {
            case .layer(let layer, _): return layer.id
            case .group(let group, _): return group.id
            }
        }

        var depth: Int {
            switch self {
            case .layer(_, let depth), .group(_, let depth): return depth
            }
        }
    }

    func panelRows() -> [PanelRow] {
        var rows: [PanelRow] = []
        var previous: [UUID] = []
        for layer in layers.reversed() {
            let chain = groupChain(from: layer.groupID)
            var shared = 0
            while shared < min(previous.count, chain.count), previous[shared] == chain[shared] {
                shared += 1
            }
            for depth in shared..<chain.count {
                guard let group = group(withID: chain[depth]) else { continue }
                // The folder row itself shows unless an ANCESTOR is collapsed.
                if !chain[..<depth].contains(where: { self.group(withID: $0)?.isExpanded == false }) {
                    rows.append(.group(group, depth: depth))
                }
            }
            if !chain.contains(where: { self.group(withID: $0)?.isExpanded == false }) {
                rows.append(.layer(layer, depth: chain.count))
            }
            previous = chain
        }
        return rows
    }

    // MARK: - Drag-reorder over panel rows

    /// Reorders by display rows (the panel's `onMove`): moving a folder row
    /// relocates its whole subtree; the drop gap decides the moved item's new
    /// group — the deepest chain shared by the gap's two neighbours (top and
    /// bottom of the list count as top level). Dropping a contiguous
    /// selection on its own edges (SwiftUI's "didn't move") is a no-op —
    /// those gaps are ambiguous about membership and a non-move must never
    /// eject a layer from its group. A drop elsewhere may change membership
    /// alone (dragging through a folder header re-parents without
    /// reordering). Moving a group into its own subtree is refused.
    ///
    /// Multi-row drags: every selected row moves, keeping its
    /// relative stacking order, and each lands in the gap's group. Rows nested
    /// inside a selected folder are dropped from the move — the folder already
    /// carries them — and `normalizingGroups()` at the end keeps the
    /// contiguous-run invariant true however the selection straddled folders.
    func movingPanelRow(fromDisplayOffsets offsets: IndexSet, toDisplayOffset destination: Int) -> Document {
        let rows = panelRows()
        let sources = offsets.sorted().filter { rows.indices.contains($0) }
        guard let firstSource = sources.first, let lastSource = sources.last,
              destination >= 0, destination <= rows.count else { return self }
        // A contiguous block dropped on its own edges didn't move. (For one
        // row this is exactly `destination == source || destination == source + 1`.)
        if sources.count == lastSource - firstSource + 1,
           destination >= firstSource, destination <= lastSource + 1 { return self }

        // A row nested inside another moved folder rides along with it.
        let movedGroupIDs = Set(sources.compactMap { index -> UUID? in
            if case .group(let group, _) = rows[index] { return group.id }
            return nil
        })
        let topSources = sources.filter { index in
            let ancestors: [UUID]
            switch rows[index] {
            case .layer(let layer, _): ancestors = groupChain(from: layer.groupID)
            case .group(let group, _): ancestors = ancestorChain(ofGroup: group.id)
            }
            return !ancestors.contains(where: movedGroupIDs.contains)
        }

        // The moved flat spans (each contiguous, ascending) and their identity
        // — nil for a layer row, the group id for a folder row.
        var moved: [(span: ClosedRange<Int>, groupID: UUID?, anchorLayerID: UUID)] = []
        for index in topSources {
            switch rows[index] {
            case .layer(let layer, _):
                guard let flat = layerIndex(of: layer.id) else { return self }
                moved.append((flat...flat, nil, layer.id))
            case .group(let group, _):
                guard let run = memberRun(ofGroup: group.id) else { return self }
                moved.append((run, group.id, layers[run.lowerBound].id))
            }
        }
        moved.sort { $0.span.lowerBound < $1.span.lowerBound }
        guard !moved.isEmpty else { return self }

        // The destination gap's group context: deepest chain both neighbours
        // agree on. A row's top context is its chain from above (a folder row
        // is entered *below* its header); its bottom context is its chain
        // from below (an expanded folder's contents; a collapsed folder hides
        // them, so below it is its parent scope).
        func topContext(_ row: PanelRow) -> [UUID] {
            switch row {
            case .layer(let layer, _): return groupChain(from: layer.groupID)
            case .group(let group, _): return ancestorChain(ofGroup: group.id)
            }
        }
        func bottomContext(_ row: PanelRow) -> [UUID] {
            switch row {
            case .layer(let layer, _): return groupChain(from: layer.groupID)
            case .group(let group, _):
                return group.isExpanded ? ancestorChain(ofGroup: group.id) + [group.id]
                                        : ancestorChain(ofGroup: group.id)
            }
        }
        let above: [UUID] = destination > 0 ? bottomContext(rows[destination - 1]) : []
        let below: [UUID] = destination < rows.count ? topContext(rows[destination]) : []
        var gapChain: [UUID] = []
        for (a, b) in zip(above, below) where a == b {
            gapChain.append(a)
        }
        if destination == 0 { gapChain = [] }
        if destination == rows.count { gapChain = [] }

        // A group must not land inside its own subtree.
        if moved.contains(where: { $0.groupID.map(gapChain.contains) ?? false }) { return self }

        // Flat insertion position for the gap (pre-removal coordinates):
        // directly above the row below the gap; the very bottom is index 0.
        let target: Int
        if destination == rows.count {
            target = 0
        } else {
            switch rows[destination] {
            case .layer(let layer, _):
                guard let index = layerIndex(of: layer.id) else { return self }
                target = index + 1
            case .group(let group, _):
                guard let run = memberRun(ofGroup: group.id) else { return self }
                target = run.upperBound + 1
            }
        }

        // Standard move: remove the spans (flat order preserved), shift the
        // target by what was removed beneath it, insert.
        var doc = self
        let movingIndices = moved.flatMap { Array($0.span) }
        let moving = movingIndices.map { doc.layers[$0] }
        for index in movingIndices.reversed() { doc.layers.remove(at: index) }
        var insertAt = target - movingIndices.filter { $0 < target }.count
        insertAt = max(0, min(insertAt, doc.layers.count))
        doc.layers.insert(contentsOf: moving, at: insertAt)

        // Adopt the gap's group. A moved folder re-parents; a moved layer
        // changes its own membership (its span is a single layer).
        for item in moved {
            if let groupID = item.groupID {
                if let index = doc.groupIndex(of: groupID) {
                    doc.groups[index].parentID = gapChain.last
                }
            } else if let index = doc.layerIndex(of: item.anchorLayerID) {
                doc.layers[index].groupID = gapChain.last
            }
        }
        return doc.normalizingGroups().normalizingClipping()
    }

    // MARK: - Naming

    /// The next free "Group N" name, Photoshop-style.
    func nextGroupName() -> String {
        var n = groups.count + 1
        let taken = Set(groups.map(\.name))
        while taken.contains("Group \(n)") { n += 1 }
        return "Group \(n)"
    }
}

import CoreGraphics
import Foundation

/// Align & Distribute — Photoshop's Layer ▸ Align / Distribute, also
/// on the Move tool's options bar where they are actually used.
///
/// Pure `Document -> Document` functions, **translation only**:
/// each operation derives one canvas-space delta per object and composes it
/// into the members' transforms through `TransformMath.moved(initial:delta:)`.
/// No scaling, no rotation — alignment must never resample.
///
/// Geometry works from `layer.canvasBounds`, the AABB of the transformed
/// content. For a rotated layer the AABB is the right target: it matches what
/// the user sees as the layer's extent, and it is what the smart guides
/// already snap to.

/// What align/distribute treats as ONE thing. A group aligns as a **unit** —
/// the union of its members' bounds yields a single translation applied to
/// every member — because aligning a folder's members individually would
/// scatter the folder, which is never what the user means.
enum AlignObject: Hashable {
    case layer(UUID)
    case group(UUID)
}

/// The six align commands, in Photoshop's order within each axis.
enum AlignEdge: String, CaseIterable, Identifiable {
    case left, centerH, right, top, centerV, bottom

    var id: String { rawValue }

    /// Canvas space is y-up, so `top` is `maxY` and `bottom` is `minY`.
    var isHorizontal: Bool {
        switch self {
        case .left, .centerH, .right: return true
        case .top, .centerV, .bottom: return false
        }
    }

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .centerH: return "Horizontal Centers"
        case .right: return "Right"
        case .top: return "Top"
        case .centerV: return "Vertical Centers"
        case .bottom: return "Bottom"
        }
    }

    /// One history entry per operation, named like the command.
    var actionName: String { "Align " + displayName }

    var systemImage: String {
        switch self {
        case .left: return "align.horizontal.left"
        case .centerH: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .centerV: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        }
    }
}

/// The two flavours people confuse. `.spacing` is what they almost always
/// mean, so it is the default and is labelled "Distribute Spacing".
enum DistributeMode: String {
    /// Equal spacing between object *centres*. Simple, but visually uneven
    /// when the objects differ in size.
    case centers
    /// Equal *gaps* between bounding boxes.
    case spacing
}

enum AlignAxis: String {
    case horizontal, vertical
}

/// Photoshop's "Align To: Selection / Canvas".
enum AlignReference: String {
    case canvas
    case selectionBounds
}

/// The four distribute commands as one menu-friendly token — the Layer menu
/// items carry the raw value as `representedObject`, like the Layer Style
/// items, so one selector and one validation case cover them all.
enum DistributeCommand: String, CaseIterable, Identifiable {
    case horizontalSpacing, verticalSpacing, horizontalCenters, verticalCenters

    var id: String { rawValue }

    var axis: AlignAxis {
        switch self {
        case .horizontalSpacing, .horizontalCenters: return .horizontal
        case .verticalSpacing, .verticalCenters: return .vertical
        }
    }

    var mode: DistributeMode {
        switch self {
        case .horizontalSpacing, .verticalSpacing: return .spacing
        case .horizontalCenters, .verticalCenters: return .centers
        }
    }

    var displayName: String {
        switch self {
        case .horizontalSpacing: return "Horizontal Spacing"
        case .verticalSpacing: return "Vertical Spacing"
        case .horizontalCenters: return "Horizontal Centers"
        case .verticalCenters: return "Vertical Centers"
        }
    }

    var actionName: String { "Distribute " + displayName }

    var systemImage: String {
        switch self {
        case .horizontalSpacing: return "arrow.left.and.right"
        case .verticalSpacing: return "arrow.up.and.down"
        case .horizontalCenters: return "square.split.2x1"
        case .verticalCenters: return "square.split.1x2"
        }
    }
}

extension Document {
    /// One align/distribute object resolved against the document.
    struct AlignItem: Equatable {
        let object: AlignObject
        /// Union of the object's visible, unclipped members' `canvasBounds` —
        /// what positions the object.
        let bounds: CGRect
        /// Every layer that moves by this object's delta: its own members plus
        /// any clipped riders that must follow their base.
        let layerIDs: [UUID]
    }

    // MARK: - Resolution

    /// Turns objects into movable items, applying the edge-case rules:
    ///
    /// - **Hidden layers are skipped** (`isEffectivelyVisible`, so a hidden
    ///   group hides its members too) — aligning something you cannot see is
    ///   confusing, and it would make the selection bounds jump for no visible
    ///   reason.
    /// - **Clipped layers are never aligned independently.** A clipping layer
    ///   is confined to its base's alpha, so in Photoshop it moves *with* the
    ///   base; here it is dropped as an object and appended to its base's
    ///   `layerIDs` instead.
    /// - **Degenerate bounds are skipped** rather than divided by in
    ///   distribute.
    ///
    /// A selected group carries ALL its members (hidden and clipped included)
    /// in `layerIDs` — the whole folder moves — while only the visible,
    /// unclipped ones define its bounds.
    func alignItems(for objects: [AlignObject]) -> [AlignItem] {
        var items: [AlignItem] = []
        for object in objects {
            switch object {
            case .layer(let id):
                guard let index = layerIndex(of: id) else { continue }
                let layer = layers[index]
                guard isEffectivelyVisible(layerID: id), !layer.isClippedToBelow else { continue }
                let bounds = layer.canvasBounds
                guard isUsableBounds(bounds) else { continue }
                items.append(AlignItem(object: object, bounds: bounds,
                                       layerIDs: [id] + clippedRiderIDs(above: index)))
            case .group(let id):
                let indices = memberLayerIndices(ofGroup: id)
                guard !indices.isEmpty else { continue }
                var bounds = CGRect.null
                for i in indices where isEffectivelyVisible(layerID: layers[i].id)
                                        && !layers[i].isClippedToBelow {
                    let memberBounds = layers[i].canvasBounds
                    if isUsableBounds(memberBounds) { bounds = bounds.union(memberBounds) }
                }
                guard isUsableBounds(bounds) else { continue }
                items.append(AlignItem(object: object, bounds: bounds,
                                       layerIDs: indices.map { layers[$0].id }))
            }
        }
        return items
    }

    /// A fully transparent or zero-area layer has nothing to align to.
    private func isUsableBounds(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.width.isFinite && rect.height.isFinite
    }

    /// The run of clipped layers riding on the base at `index` — the same
    /// positional membership `clippingBaseIndex(below:)` resolves, walked
    /// upward. They move with their base (Photoshop parity).
    private func clippedRiderIDs(above index: Int) -> [UUID] {
        var ids: [UUID] = []
        var j = index + 1
        while j < layers.count, layers[j].isClippedToBelow,
              layers[j].groupID == layers[index].groupID {
            ids.append(layers[j].id)
            j += 1
        }
        return ids
    }

    /// Composes a canvas-space translation into every named layer's transform.
    func translatingLayers(_ ids: [UUID], by delta: CGPoint) -> Document {
        guard delta != .zero else { return self }
        var doc = self
        for id in ids {
            guard let index = doc.layerIndex(of: id) else { continue }
            doc.layers[index].transform = TransformMath.moved(initial: doc.layers[index].transform,
                                                              delta: delta)
        }
        return doc
    }

    // MARK: - Align

    /// Moves each object so the named edge lands on the reference frame's.
    /// With one object, selection bounds ARE the object, so the operation is a
    /// no-op there — the UI forces `.canvas` for a single object and disables
    /// the picker (Photoshop does the same).
    func aligning(_ objects: [AlignObject], to edge: AlignEdge,
                  reference: AlignReference) -> Document {
        let items = alignItems(for: objects)
        guard !items.isEmpty else { return self }
        let frame: CGRect
        switch reference {
        case .canvas:
            frame = canvasRect
        case .selectionBounds:
            frame = items.dropFirst().reduce(items[0].bounds) { $0.union($1.bounds) }
        }
        var doc = self
        for item in items {
            let delta: CGPoint
            switch edge {
            case .left: delta = CGPoint(x: frame.minX - item.bounds.minX, y: 0)
            case .centerH: delta = CGPoint(x: frame.midX - item.bounds.midX, y: 0)
            case .right: delta = CGPoint(x: frame.maxX - item.bounds.maxX, y: 0)
            // y-up canvas space: "top" is the high edge.
            case .top: delta = CGPoint(x: 0, y: frame.maxY - item.bounds.maxY)
            case .centerV: delta = CGPoint(x: 0, y: frame.midY - item.bounds.midY)
            case .bottom: delta = CGPoint(x: 0, y: frame.minY - item.bounds.minY)
            }
            doc = doc.translatingLayers(item.layerIDs, by: delta)
        }
        return doc
    }

    // MARK: - Distribute

    /// Spreads the interior objects between the two extremes, which never
    /// move. Fewer than three objects is not a distribution — with two there
    /// is nothing between them — and is refused.
    ///
    /// `.spacing` equalises the GAPS between bounding boxes; `.centers`
    /// equalises the distance between centres. When the objects' total extent
    /// exceeds the span, `.spacing` produces negative gaps (overlaps). That is
    /// correct and Photoshop does the same — do not clamp it.
    func distributing(_ objects: [AlignObject], along axis: AlignAxis,
                      mode: DistributeMode) -> Document {
        let items = alignItems(for: objects)
        guard items.count >= 3 else { return self }
        let horizontal = axis == .horizontal
        func minEdge(_ item: AlignItem) -> CGFloat { horizontal ? item.bounds.minX : item.bounds.minY }
        func maxEdge(_ item: AlignItem) -> CGFloat { horizontal ? item.bounds.maxX : item.bounds.maxY }
        func center(_ item: AlignItem) -> CGFloat { horizontal ? item.bounds.midX : item.bounds.midY }
        func extent(_ item: AlignItem) -> CGFloat { horizontal ? item.bounds.width : item.bounds.height }

        var doc = self
        switch mode {
        case .spacing:
            let sorted = items.sorted { minEdge($0) < minEdge($1) }
            let span = maxEdge(sorted[sorted.count - 1]) - minEdge(sorted[0])
            let total = sorted.reduce(CGFloat(0)) { $0 + extent($1) }
            let gap = (span - total) / CGFloat(sorted.count - 1)
            var cursor = minEdge(sorted[0])
            for item in sorted {
                doc = doc.translatingLayers(item.layerIDs,
                                            by: offset(cursor - minEdge(item), horizontal))
                cursor += extent(item) + gap
            }
        case .centers:
            let sorted = items.sorted { center($0) < center($1) }
            let first = center(sorted[0])
            let step = (center(sorted[sorted.count - 1]) - first) / CGFloat(sorted.count - 1)
            for (i, item) in sorted.enumerated() {
                doc = doc.translatingLayers(item.layerIDs,
                                            by: offset(first + CGFloat(i) * step - center(item),
                                                       horizontal))
            }
        }
        return doc
    }

    private func offset(_ amount: CGFloat, _ horizontal: Bool) -> CGPoint {
        horizontal ? CGPoint(x: amount, y: 0) : CGPoint(x: 0, y: amount)
    }
}

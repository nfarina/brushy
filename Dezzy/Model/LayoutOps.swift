import CoreGraphics
import Foundation

/// Layout-shaped pure ops (§2) that the scripting API composes from — the
/// sentence-sized operations a script (or a model writing one) reaches for:
/// "arrange these in a row", "fit the canvas to the content", "group these".
/// Translation only, like `AlignOps`; nothing here resamples pixels.
enum ArrangeDirection: String {
    case horizontal, vertical
}

/// Cross-axis alignment for `arranging`: for a horizontal row these read as
/// top / center / bottom; for a vertical column as left / center / right.
/// `.start` is top or left, `.end` is bottom or right — canvas y-up is
/// hidden behind these names on purpose.
enum ArrangeAlignment: String {
    case start, center, end
}

extension Document {
    /// Lays the named layers out in a row or column, in the order given,
    /// separated by `gap` canvas points, each one's cross-axis edge aligned
    /// per `alignment`. `origin` is the canvas-space (y-up) TOP-LEFT of the
    /// resulting run; nil keeps the run's current top-left (the union of the
    /// layers' bounds). Layers that don't exist or have no usable bounds are
    /// skipped. Clipped layers ride along with their base, like align does.
    func arranging(_ ids: [UUID], direction: ArrangeDirection, gap: CGFloat,
                   alignment: ArrangeAlignment, origin: CGPoint?) -> Document {
        let items = ids.compactMap { id -> (ids: [UUID], bounds: CGRect)? in
            guard let index = layerIndex(of: id) else { return nil }
            let bounds = layers[index].canvasBounds
            guard !bounds.isNull, !bounds.isEmpty, bounds.width.isFinite,
                  bounds.height.isFinite else { return nil }
            return ([id] + clippedRiders(above: index), bounds)
        }
        guard !items.isEmpty else { return self }
        let union = items.dropFirst().reduce(items[0].bounds) { $0.union($1.bounds) }
        let topLeft = origin ?? CGPoint(x: union.minX, y: union.maxY)
        let crossExtent: CGFloat
        switch direction {
        case .horizontal: crossExtent = items.map(\.bounds.height).max() ?? 0
        case .vertical: crossExtent = items.map(\.bounds.width).max() ?? 0
        }
        var doc = self
        var cursor: CGFloat = 0
        for item in items {
            let target: CGPoint  // desired top-left of this item's bounds
            switch direction {
            case .horizontal:
                let offset: CGFloat
                switch alignment {
                case .start: offset = 0
                case .center: offset = (crossExtent - item.bounds.height) / 2
                case .end: offset = crossExtent - item.bounds.height
                }
                target = CGPoint(x: topLeft.x + cursor, y: topLeft.y - offset)
                cursor += item.bounds.width + gap
            case .vertical:
                let offset: CGFloat
                switch alignment {
                case .start: offset = 0
                case .center: offset = (crossExtent - item.bounds.width) / 2
                case .end: offset = crossExtent - item.bounds.width
                }
                target = CGPoint(x: topLeft.x + offset, y: topLeft.y - cursor)
                cursor += item.bounds.height + gap
            }
            let delta = CGPoint(x: (target.x - item.bounds.minX).rounded(),
                                y: (target.y - item.bounds.maxY).rounded())
            doc = doc.translatingLayers(item.ids, by: delta)
        }
        return doc
    }

    /// Crops the canvas to the union of the visible layers' (style-inclusive)
    /// bounds, grown by `padding` on every side. A document with nothing
    /// visible is returned unchanged. Like every crop, no pixels are lost.
    func fittingCanvasToContent(padding: CGFloat) -> Document {
        var union = CGRect.null
        for layer in layers where isEffectivelyVisible(layerID: layer.id) {
            let bounds = layer.styledCanvasBounds
            guard !bounds.isNull, !bounds.isEmpty, bounds.width.isFinite,
                  bounds.height.isFinite else { continue }
            union = union.union(bounds)
        }
        guard !union.isNull else { return self }
        let frame = union.insetBy(dx: -padding, dy: -padding).integral
        guard frame.width >= 1, frame.height >= 1 else { return self }
        return cropped(to: frame)
    }

    /// Wraps several layers in one new group. The members are gathered into
    /// one contiguous run at the position of the topmost member (their
    /// relative order kept), so the contiguity invariant holds without
    /// `normalizingGroups` having to guess. The group joins the innermost
    /// group that contains ALL the members (nil at top level), so grouping
    /// two siblings inside a folder nests the new group in that folder.
    func addingGroup(named name: String, aroundLayers ids: [UUID])
        -> (document: Document, groupID: UUID)? {
        let indices = ids.compactMap { layerIndex(of: $0) }
        guard !indices.isEmpty else { return nil }
        let members = Set(indices)
        let ordered = indices.sorted()
        // Common ancestor: the deepest group every member's chain shares.
        var common: UUID? = nil
        let chains = ordered.map { groupChain(from: layers[$0].groupID) }
        if let first = chains.first {
            for candidate in first where chains.allSatisfy({ $0.contains(candidate) }) {
                common = candidate
                break
            }
        }
        let group = LayerGroup(name: name, parentID: common)
        var doc = self
        // Pull the members out and re-insert them as one run ending where the
        // topmost member was.
        let pulled = ordered.map { layers[$0] }
        var remaining: [Layer] = []
        var insertAt = 0
        for (i, layer) in layers.enumerated() {
            if members.contains(i) {
                if i == ordered.last { insertAt = remaining.count }
                continue
            }
            remaining.append(layer)
        }
        var run = pulled
        for i in run.indices { run[i].groupID = group.id }
        remaining.insert(contentsOf: run, at: insertAt)
        doc.layers = remaining
        doc.groups.append(group)
        return (doc.normalizingGroups().normalizingClipping(), group.id)
    }

    /// Inserts a layer directly above `aboveID`, adopting that layer's group
    /// (paste-into-a-group behaviour); with no anchor it lands on top of the
    /// whole stack, outside every group.
    func insertingLayer(_ layer: Layer, above aboveID: UUID?) -> Document {
        var doc = self
        var incoming = layer
        if let aboveID, let index = layerIndex(of: aboveID) {
            incoming.groupID = layers[index].groupID
            doc.layers.insert(incoming, at: index + 1)
        } else {
            incoming.groupID = nil
            doc.layers.append(incoming)
        }
        return doc.normalizingClipping()
    }

    /// The run of clipped layers directly above `index` that ride on it (the
    /// membership `clippingBaseIndex(below:)` resolves, walked upward).
    private func clippedRiders(above index: Int) -> [UUID] {
        var ids: [UUID] = []
        var j = index + 1
        while j < layers.count, layers[j].isClippedToBelow,
              layers[j].groupID == layers[index].groupID {
            ids.append(layers[j].id)
            j += 1
        }
        return ids
    }
}

import CoreGraphics
import Foundation

/// Pure `Document -> Document` operations. UI code never mutates documents any
/// other way, which keeps undo a snapshot array.
extension Document {
    /// Crop changes `canvasSize` and shifts layer transforms so content keeps
    /// its position relative to the new origin. Layer pixels are never touched;
    /// content pushed out of frame survives and can be dragged back.
    func cropped(to rect: CGRect) -> Document {
        var doc = self
        doc.canvasSize = rect.size
        let shift = CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y)
        doc.layers = layers.map { layer in
            var l = layer
            l.transform = l.transform.concatenating(shift)
            return l
        }
        // Guides shift with the content. Ones pushed outside the new frame
        // survive, like layer content does — they just aren't drawn until the
        // canvas grows back over them.
        doc.guides = guides.map { guide in
            var g = guide
            switch g.axis {
            case .vertical: g.position -= rect.origin.x
            case .horizontal: g.position -= rect.origin.y
            }
            return g
        }
        return doc
    }

    /// Image Size: rescales the whole document to `newSize` by scaling every
    /// layer transform — sources are never resampled, so repeated resizes lose
    /// nothing (each render still samples the original pixels).
    func scaled(to newSize: CGSize) -> Document {
        guard canvasSize.width > 0, canvasSize.height > 0,
              newSize.width >= 1, newSize.height >= 1 else { return self }
        var doc = self
        let scale = CGAffineTransform(scaleX: newSize.width / canvasSize.width,
                                      y: newSize.height / canvasSize.height)
        doc.canvasSize = newSize
        doc.layers = layers.map { layer in
            var l = layer
            l.transform = l.transform.concatenating(scale)
            return l
        }
        // Guides rescale with the content.
        doc.guides = guides.map { guide in
            var g = guide
            switch g.axis {
            case .vertical: g.position *= scale.a
            case .horizontal: g.position *= scale.d
            }
            return g
        }
        return doc
    }

    /// Canvas Size: resizes the canvas frame around an anchor (unit
    /// coordinates, y-up: (0,0) pins content to the bottom-left, (0.5,0.5)
    /// centres it, (0,1) pins to the top-left). Like crop, this only shifts
    /// layer transforms — content outside the frame survives.
    func resizingCanvas(to newSize: CGSize, anchor: CGPoint) -> Document {
        let origin = CGPoint(x: ((canvasSize.width - newSize.width) * anchor.x).rounded(),
                             y: ((canvasSize.height - newSize.height) * anchor.y).rounded())
        return cropped(to: CGRect(origin: origin, size: newSize))
    }

    func replacingLayer(_ layer: Layer) -> Document {
        var doc = self
        doc[layerID: layer.id] = layer
        return doc
    }

    func removingLayer(id: UUID) -> Document {
        var doc = self
        doc.layers.removeAll { $0.id == id }
        return doc.normalizingGroups().normalizingClipping()
    }

    /// Reorders using the layers-panel convention (topmost first): the panel
    /// hands us indices in its own reversed display order. (The panel itself
    /// now reorders through `movingPanelRow`, which understands folder rows;
    /// this flat-index op remains for group-free callers.)
    func movingLayers(fromDisplayOffsets offsets: IndexSet, toDisplayOffset destination: Int) -> Document {
        var doc = self
        let display = Array(doc.layers.reversed())
        doc.layers = Self.moved(display, fromOffsets: offsets, toOffset: destination).reversed()
        return doc.normalizingGroups().normalizingClipping()
    }

    // MARK: - Clipping masks

    /// Clipping invariant: a clipped layer needs a neighbour below WITHIN ITS
    /// OWN GROUP SCOPE — the bottom layer has nothing below it, and a group
    /// boundary breaks clip runs (a clipped layer at the bottom of a group,
    /// or sitting directly above a nested group, has no base). Applied
    /// wherever stack order or grouping changes and on load. Matches
    /// Photoshop, where dragging a clipped layer to the bottom releases its
    /// clip. Clipped layers higher up keep their flag through reorders and
    /// deletions: membership is positional, so they simply re-resolve to the
    /// nearest unclipped layer below (`clippingBaseIndex(below:)`).
    func normalizingClipping() -> Document {
        var doc = self
        for i in doc.layers.indices where doc.layers[i].isClippedToBelow {
            if i == 0 || doc.layers[i - 1].groupID != doc.layers[i].groupID {
                doc.layers[i].isClippedToBelow = false
            }
        }
        return doc
    }

    /// The base a clipped layer at `index` clips to: the nearest layer below
    /// in the SAME direct group that is not itself clipped; nil when a group
    /// boundary interrupts the run first. The first layer of a scope acts as
    /// a base even if its flag is (invalidly) set, matching the renderer's
    /// bottom-layer rule.
    func clippingBaseIndex(below index: Int) -> Int? {
        guard index > 0, index < layers.count else { return nil }
        let scope = layers[index].groupID
        var j = index - 1
        while j >= 0 {
            guard layers[j].groupID == scope else { return nil }
            if !layers[j].isClippedToBelow { return j }
            if j == 0 || layers[j - 1].groupID != scope { return j }
            j -= 1
        }
        return nil
    }

    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`: `destination`
    /// is a gap index in the pre-removal array.
    private static func moved<T>(_ array: [T], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [T] {
        let moving = offsets.compactMap { array.indices.contains($0) ? array[$0] : nil }
        var rest: [T] = []
        var insertAt = min(destination, array.count)
        for (index, element) in array.enumerated() {
            if offsets.contains(index) {
                if index < destination { insertAt -= 1 }
                continue
            }
            rest.append(element)
        }
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        return rest
    }

    // MARK: - Guides

    func addingGuide(_ guide: Guide) -> Document {
        var doc = self
        doc.guides.append(guide)
        return doc
    }

    func movingGuide(id: UUID, to position: CGFloat) -> Document {
        var doc = self
        doc.guides = guides.map { guide in
            var g = guide
            if g.id == id { g.position = position }
            return g
        }
        return doc
    }

    /// Replaces a guide wholesale by id (⌥ mid-drag flips the axis, not just
    /// the position). Order-preserving on purpose: a drag that ends where it
    /// started produces a document equal to its base, which is how the store's
    /// commit-on-equality no-op dissolves unchanged gestures.
    func replacingGuide(_ guide: Guide) -> Document {
        var doc = self
        doc.guides = guides.map { $0.id == guide.id ? guide : $0 }
        return doc
    }

    func removingGuide(id: UUID) -> Document {
        var doc = self
        doc.guides.removeAll { $0.id == id }
        return doc
    }

    func clearingGuides() -> Document {
        var doc = self
        doc.guides = []
        return doc
    }

    // MARK: - Hit-testing (pure queries)

    /// Move-tool Auto-Select: the topmost visible layer whose composited
    /// alpha at `canvasPoint` exceeds `alphaThreshold` (0…1). Pixel-accurate,
    /// not bounds-accurate — a transparent source pixel, a low layer opacity
    /// or an enabled mask lets the click fall through to the layer beneath,
    /// so a rotated or mostly-transparent layer hits only where the user
    /// actually sees pixels. Visibility is EFFECTIVE: a layer hidden through
    /// an ancestor group is exactly as unclickable as a hidden layer.
    func topmostLayer(at canvasPoint: CGPoint, alphaThreshold: CGFloat = 0.02) -> Layer? {
        for (index, layer) in layers.enumerated().reversed() {
            guard layer.isVisible, ancestorsVisible(fromDirectGroup: layer.groupID) else { continue }
            var alpha = Self.ownAlpha(of: layer, at: canvasPoint)
            // A clipped layer only shows where its base has content, so a
            // click outside the base falls through to whatever is beneath
            // (and a hidden base hides the whole clipped group).
            if alpha > 0, layer.isClippedToBelow,
               let baseIndex = clippingBaseIndex(below: index) {
                let base = layers[baseIndex]
                alpha *= base.isVisible ? Self.ownAlpha(of: base, at: canvasPoint) : 0
            }
            if alpha > alphaThreshold { return layer }
        }
        return nil
    }

    /// The layer's own composited alpha at a canvas point — source alpha ×
    /// opacity × enabled mask — or 0 outside its content.
    private static func ownAlpha(of layer: Layer, at canvasPoint: CGPoint) -> CGFloat {
        guard layer.canvasBounds.contains(canvasPoint),
              layer.transform.isInvertible else { return 0 }
        let sourcePoint = canvasPoint.applying(layer.transform.inverted())
        guard layer.sourceRect.contains(sourcePoint) else { return 0 }
        var alpha = Self.sourceAlpha(of: layer.source, at: sourcePoint)
        alpha *= CGFloat(layer.opacity)
        if let mask = layer.mask, mask.isEnabled {
            alpha *= Self.maskValue(of: mask.texture, at: sourcePoint,
                                    sourceSize: layer.sourceSize)
        }
        return alpha
    }

    /// Alpha (0…1) of the source pixel containing `sourcePoint` (source
    /// space, y-up), read by drawing just that pixel into a 1×1 scratch
    /// context — never by copying the whole data provider. Premultiplication
    /// scales the colour channels only, so the alpha byte is exact, and any
    /// RGB colour conversion is irrelevant to it. `draw` places the image
    /// upright, so the CGImage's row-0-at-top layout maps to y-up source
    /// space automatically.
    private static func sourceAlpha(of source: CGImage, at sourcePoint: CGPoint) -> CGFloat {
        let x = sourcePoint.x.rounded(.down)
        let y = sourcePoint.y.rounded(.down)
        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .none
            ctx.draw(source, in: CGRect(x: -x, y: -y,
                                        width: CGFloat(source.width),
                                        height: CGFloat(source.height)))
        }
        return CGFloat(pixel[3]) / 255
    }

    /// Mask value (0 hidden … 1 opaque) at a source-space point. Mask buffers
    /// are stored row-0-at-top — flipped relative to y-up source space — so
    /// the row index inverts. Masks are built at source resolution, but scale
    /// defensively in case the two ever differ.
    private static func maskValue(of texture: MaskTexture, at sourcePoint: CGPoint,
                                  sourceSize: CGSize) -> CGFloat {
        guard texture.width > 0, texture.height > 0,
              sourceSize.width > 0, sourceSize.height > 0 else { return 1 }
        // `saturatingInt` before `clamped`, not `Int` — the clamp cannot
        // rescue a conversion that has already trapped, and `sourcePoint`
        // comes through an inverted layer transform, so it is exactly the
        // kind of value that goes non-finite.
        let col = (sourcePoint.x / sourceSize.width * CGFloat(texture.width))
            .saturatingInt.clamped(0, texture.width - 1)
        let rowFromBottom = (sourcePoint.y / sourceSize.height * CGFloat(texture.height))
            .saturatingInt.clamped(0, texture.height - 1)
        let row = texture.height - 1 - rowFromBottom
        return CGFloat(texture.data[row * texture.width + col]) / 255
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(hi, Swift.max(lo, self)) }
}

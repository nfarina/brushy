import CoreGraphics
import Foundation

/// The document model (of the spec).
///
/// Coordinate convention: canvas space uses the Core Graphics / Core Image
/// convention — origin at the bottom-left, y increasing upward, one canvas
/// point == one exported pixel. All model-level geometry (layer transforms,
/// selection paths, crop rects) lives in this space; only the view layer
/// converts to and from screen coordinates.
///
/// `Document` and everything it contains are value types. Every operation is a
/// pure function `Document -> Document`, which makes undo an array index.
struct Document: Equatable {
    /// The crop frame, in points. Crop changes this (and layer translations)
    /// only — it never destroys layer pixels.
    var canvasSize: CGSize
    /// Fixed to Display P3; recorded explicitly so the file format can
    /// round-trip it.
    var workingSpace: WorkingColorSpace = .displayP3
    /// Index 0 renders first (bottom of the stack).
    var layers: [Layer] = []
    /// User-placed ruler guides. Guides belong to the document, not
    /// the session: they persist in the file and, because they ride the
    /// document value, undo/redo of guide edits comes free through the
    /// snapshot history.
    var guides: [Guide] = []
    /// Layer groups. `layers` stays FLAT in render order;
    /// membership lives on `Layer.groupID` and this table holds each group's
    /// properties (nesting via `parentID`). Invariant: a group's members —
    /// including nested groups' members — occupy one contiguous run of
    /// `layers`, and nested groups nest their runs. `normalizingGroups()`
    /// (DocumentOps) enforces it; every structural op preserves it.
    var groups: [LayerGroup] = []

    var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }

    /// Canvas sizes are clamped to Metal-friendly bounds. Lives on the model
    /// rather than the store because the file readers need it too — a canvas
    /// size read from a document is no more trustworthy than one typed into a
    /// dialog. `DocumentStore.sizeLimits` forwards here.
    static let canvasSizeLimits: ClosedRange<CGFloat> = 1...16384

    /// NaN-safe clamp.
    ///
    /// `min(max(x, lo), hi)` looks like it bounds everything, but it does not
    /// bound NaN: `Swift.max(.nan, 1)` returns NaN (because `1 >= .nan` is
    /// false) and `Swift.min(.nan, 16384)` returns it right back. A canvas
    /// size of NaN then traps the first `Int(canvasSize.width)` that renders
    /// it. Sorting NaN out first is the whole point of this function.
    static func clampedCanvasSize(_ size: CGSize) -> CGSize {
        func clamp(_ value: CGFloat) -> CGFloat {
            guard value.isFinite else { return canvasSizeLimits.lowerBound }
            return min(max(value.rounded(), canvasSizeLimits.lowerBound),
                       canvasSizeLimits.upperBound)
        }
        return CGSize(width: clamp(size.width), height: clamp(size.height))
    }

    init(canvasSize: CGSize) {
        self.canvasSize = canvasSize
    }

    func layerIndex(of id: UUID) -> Int? {
        layers.firstIndex(where: { $0.id == id })
    }

    func groupIndex(of id: UUID) -> Int? {
        groups.firstIndex(where: { $0.id == id })
    }

    func group(withID id: UUID) -> LayerGroup? {
        groups.first(where: { $0.id == id })
    }

    subscript(layerID id: UUID) -> Layer? {
        get { layers.first(where: { $0.id == id }) }
        set {
            guard let index = layerIndex(of: id) else { return }
            if let newValue { layers[index] = newValue } else { layers.remove(at: index) }
        }
    }
}

/// A layer group(— Photoshop's folders). Groups are pure
/// organization by default: with no explicit blend mode and full opacity the
/// group is PASS THROUGH — members composite onto the global accumulator
/// exactly as if ungrouped, and the group contributes nothing to the render
/// graph. Setting opacity below 100% or a blend mode other than Pass Through
/// ISOLATES the group: members render over transparency and the result
/// composites once with the group's opacity/mode (+ `RenderEngine`).
struct LayerGroup: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    /// A hidden group hides every member (effective visibility cascades).
    var isVisible: Bool
    var opacity: Float
    /// `nil` means Pass Through — deliberately distinct from `.normal`, which
    /// is an *isolating* mode in Photoshop (a Normal group flattens against
    /// transparency first; a Pass Through group doesn't exist at render time).
    var blendMode: BlendMode?
    /// Layers-panel disclosure state. Persisted with the document; not an
    /// undoable edit (the store patches it through history snapshots).
    var isExpanded: Bool
    /// The containing group for nesting; nil at top level.
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, isVisible: Bool = true,
         opacity: Float = 1, blendMode: BlendMode? = nil,
         isExpanded: Bool = true, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
        self.isExpanded = isExpanded
        self.parentID = parentID
    }

    /// True when the group must composite through an offscreen pass — an
    /// explicit blend mode (Normal included) or reduced opacity. False is the
    /// pass-through fast path.
    var isIsolated: Bool { blendMode != nil || opacity < 1 }
}

/// A user-placed alignment guide: an infinite vertical or horizontal
/// line in canvas space, drawn across the canvas and offered to snapping.
/// Like everything model-side it uses canvas coordinates (y-up); the rulers
/// display top-down values and convert at the view boundary only.
struct Guide: Equatable, Codable, Identifiable {
    let id: UUID
    enum Axis: String, Codable { case vertical, horizontal }
    var axis: Axis
    /// Canvas coordinate: x for vertical, y for horizontal.
    var position: CGFloat

    init(id: UUID = UUID(), axis: Axis, position: CGFloat) {
        self.id = id
        self.axis = axis
        self.position = position
    }
}

enum WorkingColorSpace: String, Codable, Equatable {
    case displayP3

    var cgColorSpace: CGColorSpace {
        switch self {
        case .displayP3: return BrushyColorSpace.displayP3
        }
    }
}

struct Layer: Identifiable, Equatable {
    let id: UUID
    /// Identifies the source bitmap. Duplicated layers share a `sourceID` so the
    /// file format stores the pixels once.
    var sourceID: UUID
    var name: String
    /// ALWAYS the original, full-resolution, unmodified pixels. This is never
    /// mutated; scaling a layer changes `transform` only, and every render
    /// resamples from these pixels.
    let source: CGImage
    /// Maps source space (0,0,w,h) into canvas space.
    var transform: CGAffineTransform
    var opacity: Float
    var isVisible: Bool
    var mask: Mask?
    /// App-created raster layers accept brush/eraser pixels. Imported images
    /// never do — their sources stay original; the eraser hides them through
    /// an auto-created mask instead.
    var isPaintable: Bool
    /// Text/shape layers carry their parameters here; `source` is their
    /// cached rasterization, regenerated on edit.
    var kind: LayerKind
    /// How this layer combines with the composite below it (step 5).
    /// Added on request — the blend-mode exclusion was lifted by the owner.
    var blendMode: BlendMode
    /// Clipping mask (Photoshop's ⌥⌘G): confines this layer to the alpha of
    /// the nearest unclipped layer below it (its base). Membership is
    /// positional — reordering re-resolves which layer is the base — and the
    /// bottom layer can never be clipped (normalized by the ordering/removal
    /// ops and on load; the renderer also treats a clipped bottom layer as
    /// unclipped). Clip runs resolve WITHIN a group's direct scope: a group
    /// boundary breaks the run, so a clipped layer whose neighbour below
    /// belongs to a different group renders unclipped (and is normalized).
    var isClippedToBelow: Bool
    /// The group this layer belongs to directly (innermost), or nil at top
    /// level. Membership pairs with the contiguity invariant on
    /// `Document.groups`.
    var groupID: UUID?
    /// Photoshop's Layer Style: shadows, glows, stroke and
    /// overlays rendered from the layer's own coverage. `.none` — no effect
    /// configured at all — is the pre-effects state and stays free at render
    /// time (`LayerEffects.isActive`).
    var effects: LayerEffects

    init(id: UUID = UUID(),
         sourceID: UUID = UUID(),
         name: String,
         source: CGImage,
         transform: CGAffineTransform = .identity,
         opacity: Float = 1,
         isVisible: Bool = true,
         mask: Mask? = nil,
         isPaintable: Bool = false,
         kind: LayerKind = .raster,
         blendMode: BlendMode = .normal,
         isClippedToBelow: Bool = false,
         groupID: UUID? = nil,
         effects: LayerEffects = .none) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.source = source
        self.transform = transform
        self.opacity = opacity
        self.isVisible = isVisible
        self.mask = mask
        self.isPaintable = isPaintable
        self.kind = kind
        self.blendMode = blendMode
        self.isClippedToBelow = isClippedToBelow
        self.groupID = groupID
        self.effects = effects
    }

    var sourceSize: CGSize { CGSize(width: source.width, height: source.height) }
    var sourceRect: CGRect { CGRect(x: 0, y: 0, width: source.width, height: source.height) }
    /// Axis-aligned bounds of the transformed content in canvas space.
    var canvasBounds: CGRect { sourceRect.applying(transform) }

    /// `canvasBounds` grown by however far the enabled effects reach outside
    /// the layer's pixels — the bounds anything baking a layer down (merge,
    /// clipboard) has to cover if the style is not to be cropped.
    var styledCanvasBounds: CGRect {
        guard effects.isActive else { return canvasBounds }
        let outset = effects.outsetInCanvasPoints
        return canvasBounds.insetBy(dx: -outset, dy: -outset)
    }

    /// A copy with a fresh identity but the same shared source bitmap.
    /// Group membership carries over: a duplicate lands beside its original,
    /// inside the same group.
    func duplicated(name: String) -> Layer {
        Layer(id: UUID(), sourceID: sourceID, name: name, source: source,
              transform: transform, opacity: opacity, isVisible: isVisible,
              mask: mask, isPaintable: isPaintable, kind: kind,
              blendMode: blendMode, isClippedToBelow: isClippedToBelow,
              groupID: groupID, effects: effects)
    }

    static func == (lhs: Layer, rhs: Layer) -> Bool {
        lhs.id == rhs.id
            && lhs.sourceID == rhs.sourceID
            && lhs.name == rhs.name
            && lhs.source === rhs.source
            && lhs.transform == rhs.transform
            && lhs.opacity == rhs.opacity
            && lhs.isVisible == rhs.isVisible
            && lhs.mask == rhs.mask
            && lhs.isPaintable == rhs.isPaintable
            && lhs.kind == rhs.kind
            && lhs.blendMode == rhs.blendMode
            && lhs.isClippedToBelow == rhs.isClippedToBelow
            && lhs.groupID == rhs.groupID
            && lhs.effects == rhs.effects
    }
}

struct Mask: Equatable {
    /// Single-channel 8-bit buffer at SOURCE resolution. White = opaque,
    /// black = hidden.
    var texture: MaskTexture
    var isEnabled: Bool = true
}

/// Copy-on-write wrapper around the mask's pixel buffer, so unrelated undo
/// snapshots share storage.
extension CGImage {
    /// True when every pixel is fully transparent. Reads the provider's bytes
    /// directly — arrivals are rare, so a scan beats keeping a flag in sync —
    /// and answers false for anything it cannot read confidently, so an
    /// unusual format is never mistaken for an empty layer.
    var isFullyTransparent: Bool {
        guard bitsPerComponent == 8, bitsPerPixel == 32,
              let data = dataProvider?.data as Data? else { return false }
        let info = alphaInfo
        let alphaOffset: Int
        switch info {
        case .premultipliedLast, .last: alphaOffset = 3
        case .premultipliedFirst, .first: alphaOffset = 0
        default: return false // no alphaationally opaque, or an odd layout
        }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress,
                  raw.count >= bytesPerRow * height else { return false }
            for row in 0..<height {
                let start = base + row * bytesPerRow
                for column in 0..<width where start[column * 4 + alphaOffset] != 0 {
                    return false
                }
            }
            return true
        }
    }
}

struct MaskTexture: Equatable {
    final class Storage {
        let width: Int
        let height: Int
        private var storedData: Data
        /// Identifies THESE BYTES, not this object.
        ///
        /// This was `ObjectIdentifier(storage)` — an address — used as a key
        /// by three caches that keep nothing alive to stop that address being
        /// recycled (`RenderEngine.maskCache`, `DocumentSerializer`'s PNG
        /// cache, `ThumbnailCache`). A freed `Storage` whose address is reused
        /// makes every one of them return another mask's data; in the
        /// serializer's case that means writing the wrong mask into the saved
        /// file. A UUID cannot be recycled.
        ///
        /// It also has to change when the BYTES change, which an address does
        /// not: `mutate` only replaces the storage object when it isn't
        /// uniquely referenced, so an in-place mutation left every cache
        /// holding stale entries under an unchanged key.
        private(set) var identity = UUID()
        private var cachedImage: CGImage?
        private let lock = NSLock()

        init(width: Int, height: Int, data: Data) {
            precondition(data.count == width * height, "mask buffer must be width*height bytes")
            self.width = width
            self.height = height
            self.storedData = data
        }

        var data: Data {
            lock.lock(); defer { lock.unlock() }
            return storedData
        }

        func copy() -> Storage {
            lock.lock(); defer { lock.unlock() }
            return Storage(width: width, height: height, data: storedData)
        }

        /// The one place the buffer changes. Takes the lock the readers take —
        /// previously `mutate` wrote `storage.data` outside it while
        /// `cgImage`, `copy()` and the invalidation all locked, so the lock
        /// guarded every access except the only writer. Stamps a fresh
        /// `identity` so the caches keyed on it miss.
        fileprivate func write(_ body: (inout Data) -> Void) {
            lock.lock(); defer { lock.unlock() }
            body(&storedData)
            precondition(storedData.count == width * height,
                         "a mask mutation must not resize the buffer")
            identity = UUID()
            cachedImage = nil
        }

        /// Grayscale CGImage view of the buffer (row 0 = top). Cached; the
        /// backing `Data` is snapshotted by the provider, so later mutations
        /// (which invalidate the cache) cannot corrupt an existing image.
        var cgImage: CGImage? {
            lock.lock(); defer { lock.unlock() }
            if let cachedImage { return cachedImage }
            // `storedData`, NOT the `data` accessor: that one takes this same
            // lock, and NSLock is not reentrant, so going through it here
            // deadlocks the first thread to ask a mask for its image.
            guard let provider = CGDataProvider(data: storedData as CFData) else { return nil }
            let image = CGImage(width: width, height: height,
                                bitsPerComponent: 8, bitsPerPixel: 8,
                                bytesPerRow: width,
                                space: BrushyColorSpace.gray,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)
            cachedImage = image
            return image
        }

    }

    private var storage: Storage

    var width: Int { storage.width }
    var height: Int { storage.height }
    var data: Data { storage.data }
    var cgImage: CGImage? { storage.cgImage }
    /// Identity of the current BYTES: stable while they are, different after
    /// any mutation, and never recycled. Used as a cache key by the renderer,
    /// the serializer and thumbnails — see `Storage.identity` for what went
    /// wrong when this was an address.
    var storageIdentity: UUID { storage.identity }

    init(width: Int, height: Int, fill: UInt8) {
        storage = Storage(width: width, height: height,
                          data: Data(repeating: fill, count: width * height))
    }

    init(width: Int, height: Int, data: Data) {
        storage = Storage(width: width, height: height, data: data)
    }

    /// Copy-on-write mutation of the raw buffer (row 0 = top).
    ///
    /// The COW copy alone was not enough to keep `storageIdentity` honest: it
    /// only fires when something else holds the storage, so mutating a texture
    /// nobody else references changed the bytes while leaving the key every
    /// cache had filed them under. `write` re-stamps the identity either way.
    mutating func mutate(_ body: (inout Data) -> Void) {
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }
        storage.write(body)
    }

    static func == (lhs: MaskTexture, rhs: MaskTexture) -> Bool {
        lhs.storage === rhs.storage
            || (lhs.width == rhs.width && lhs.height == rhs.height && lhs.data == rhs.data)
    }
}

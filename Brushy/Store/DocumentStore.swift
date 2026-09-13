import AppKit
import Combine
import CoreGraphics
import Foundation

/// Per-window state: the document value, the selection, tool/session state and
/// the snapshot undo history.
///
/// Undo model: an array of snapshots plus an index. Live drags mutate
/// `document` directly without touching history; `commit` pushes exactly one
/// snapshot per finished operation and registers with NSUndoManager so the
/// Edit menu shows proper action names. Each snapshot also records that name,
/// which the History panel projects read-only through
/// `historyEntries` / `jumpToHistory(index:)`; the array is bounded by a step
/// count AND a byte budget, because paint operations snapshot whole bitmaps.
final class DocumentStore: ObservableObject {
    // MARK: Model state
    @Published private(set) var document: Document {
        didSet { renderVersion &+= 1 }
    }
    @Published private(set) var selection: SelectionState = .empty
    /// Photoshop's Quick Mask (Q): while this is non-nil the selection is being
    /// PAINTED instead of drawn — a canvas-sized 8-bit channel (255 = selected)
    /// shown as a red overlay, which the brush, fill and gradient target
    /// instead of the document. Leaving the mode turns it back into a
    /// selection. It rides in the undo snapshots, so every stroke undoes.
    @Published private(set) var quickMask: MaskTexture? {
        didSet { renderVersion &+= 1 }
    }
    /// Bumped on every document change — the canvas re-renders the composite
    /// only when this (or the viewport/stroke preview) moves, so overlay-only
    /// changes like cursor hover stay cheap.
    private(set) var renderVersion = 0

    // MARK: UI state
    /// The anchor / primary selection — the most recently clicked layer.
    /// Single-layer commands (Add Layer Mask, Free Transform, Layer Style,
    /// Edit Text, brush targeting) act on THIS one and never fan out over the
    /// whole selection; relational commands (align/distribute) read
    /// `selectedLayerIDs`. Kept as a stored property so the ~40 pre-existing
    /// call sites are unchanged: assigning it directly means "select just this
    /// layer", which is what every one of them meant before.
    @Published var selectedLayerID: UUID? {
        didSet {
            guard !isSettingSelectionSet else { return }
            selectedLayerIDs = selectedLayerID.map { [$0] } ?? []
        }
    }
    /// All selected layers — the source of truth for
    /// selection-aware relational commands. A selected GROUP fills this with
    /// the group's member layers (see `selectGroup`), so align/distribute can
    /// treat the folder as one object while the anchor stays nil.
    @Published private(set) var selectedLayerIDs: Set<UUID> = []
    /// Raised while a multi-select entry point assigns the anchor and the set
    /// together, so the anchor's `didSet` doesn't collapse the set behind it.
    private var isSettingSelectionSet = false
    /// Panel-level group selection (layer groups).
    /// Mutually exclusive with `selectedLayerID`: canvas tools (brush,
    /// gradient, transform, clipboard, Select Subject) always operate on the
    /// selected LAYER and stay disabled while a group row is selected, like
    /// Photoshop; group-level operations (ungroup, delete/duplicate group,
    /// group opacity/blend) read this instead.
    @Published var selectedGroupID: UUID?
    /// Focus ring target in the layers panel: false = layer, true = its mask.
    @Published var maskTargeted = false
    /// Layers / History segment of the right column. Per-window UI
    /// state like the active tool — outside the document, outside undo.
    @Published var rightPanel: RightPanel = .layers
    /// Tab (on the canvas) or View ▸ Hide Panels: only the canvas stays.
    /// Per window and never persisted, like Photoshop's.
    @Published var panelsHidden = false
    @Published var activeTool: Tool = .move {
        didSet { toolDidChange(from: oldValue) }
    }
    @Published var viewport = Viewport()
    // View furniture: rulers, guides, grid, snapping. Per-window UI
    // state seeded from app-wide preferences, like Photoshop's — new windows
    // adopt the last-used setup; the guides themselves live in `document` (and
    // its undo history), never here.
    //
    // split these into SEED-ONLY and LIVE (see `Defaults.Keys`, which
    // tags every key). SEED-ONLY: read once here, written back by the View
    // menu, so the next window adopts them. LIVE: mirrored from `AppSettings`
    // and re-pushed to every open window the moment Settings changes them
    // (`observeLiveSettings`). No setting, either kind, ever enters history.
    /// SEED-ONLY (⌘R).
    @Published var rulersVisible = Defaults.value(Defaults.Keys.rulersVisible) {
        didSet { Defaults.set(rulersVisible, for: Defaults.Keys.rulersVisible) }
    }
    /// SEED-ONLY (⌘;).
    @Published var guidesVisible = Defaults.value(Defaults.Keys.guidesVisible) {
        didSet { Defaults.set(guidesVisible, for: Defaults.Keys.guidesVisible) }
    }
    /// View → Lock Guides: guide creation and movement are inert while set.
    /// SEED-ONLY (⌥⌘;).
    @Published var guidesLocked = Defaults.value(Defaults.Keys.guidesLocked) {
        didSet { Defaults.set(guidesLocked, for: Defaults.Keys.guidesLocked) }
    }
    /// View → Snap: the master switch over ALL snapping (smart guides, user
    /// guides, grid), like Photoshop's. ⌘ still suppresses snapping per drag.
    /// LIVE — the View menu's ⇧⌘; pushes back up to `AppSettings`, so open
    /// windows never disagree with the preference.
    @Published var snappingEnabled = AppSettings.shared.snappingEnabled {
        didSet { AppSettings.shared.snappingEnabled = snappingEnabled }
    }
    /// SEED-ONLY (⌘').
    @Published var gridVisible = Defaults.value(Defaults.Keys.gridVisible) {
        didSet { Defaults.set(gridVisible, for: Defaults.Keys.gridVisible) }
    }
    /// SEED-ONLY. View → Show Pixel Grid: Photoshop's hairlines between
    /// document pixels above `DisplayGeometry.pixelGridMinimumZoom`.
    @Published var pixelGridVisible = Defaults.value(Defaults.Keys.pixelGridVisible) {
        didSet { Defaults.set(pixelGridVisible, for: Defaults.Keys.pixelGridVisible) }
    }
    /// Major gridline spacing, canvas px. LIVE.
    @Published var gridSpacing = AppSettings.shared.gridSpacing {
        didSet { AppSettings.shared.gridSpacing = gridSpacing }
    }
    /// LIVE.
    @Published var gridSubdivisions = AppSettings.shared.gridSubdivisions {
        didSet { AppSettings.shared.gridSubdivisions = gridSubdivisions }
    }
    /// User-guide stroke colour, sRGB. LIVE — read by `CanvasOverlayView`,
    /// which redraws on any store change, so mirroring it here is what makes a
    /// Settings colour well repaint open windows.
    @Published private(set) var guideColor = AppSettings.shared.guideColor
    /// Grid stroke colour, sRGB. LIVE — see `guideColor`.
    @Published private(set) var gridColor = AppSettings.shared.gridColor
    @Published var transformSession: TransformSession?
    /// Select > Transform Selection (gestures on the selection outline).
    @Published var selectionTransformSession: SelectionTransformSession?
    @Published var cropSession: CropSession?
    /// Magic Wand options. Deliberately not persisted, like the gradient's:
    /// they read as per-session tool state rather than preferences.
    @Published var wandTolerance: Double = 32
    @Published var wandContiguous = true
    @Published var wandSamplesAllLayers = false
    @Published var activeGuides: [SmartGuideLine] = []
    /// In-progress marquee/lasso outline, canvas space.
    @Published var previewSelectionPath: CGPath?
    /// feather field, canvas px, applied when a mask is created.
    /// SEED-ONLY (Tools pane).
    @Published var featherAmount: Double = Defaults.value(Defaults.Keys.featherAmount)
    // Move options bar.
    /// move tool Auto-Select: clicking the canvas selects the topmost
    /// layer with visible pixels under the cursor. Off = clicks drag the
    /// panel-selected layer, as before. SEED-ONLY (Tools pane), but the
    /// checkbox writes back: the options bar is where anyone actually changes
    /// it, and it should still be off (or on) in the next window.
    @Published var autoSelectLayer = Defaults.value(Defaults.Keys.autoSelectLayer) {
        didSet { Defaults.set(autoSelectLayer, for: Defaults.Keys.autoSelectLayer) }
    }
    /// True once the user explicitly chose this document's canvas size (the
    /// ⌘N New Document dialog, or Image/Canvas Size). Empty-document canvas
    /// adoption — paste, place and cross-document transfer taking their
    /// content's frame — is skipped for these documents: an explicitly chosen
    /// size must never be silently overridden. Content arrives scaled to fit
    /// instead, like any non-empty document (Photoshop parity).
    var canvasSizeChosenExplicitly = false
    // Crop options bar.
    @Published var cropAspectW = ""
    @Published var cropAspectH = ""
    @Published var cropAspectLocked = false
    // Brush/eraser state (Stage B). All SEED-ONLY (Tools pane): read once
    // here, so changing a default never yanks the size out from under a window
    // the user is painting in.
    @Published var brushSize = Defaults.value(Defaults.Keys.brushSize)          // canvas px, diameter
    @Published var brushHardness = Defaults.value(Defaults.Keys.brushHardness)  // %
    @Published var brushOpacity = Defaults.value(Defaults.Keys.brushOpacity)    // %
    // sRGB (— the working space stays linear Display P3; only the wells are
    // sRGB, see `ToolOptionsBar.colorBinding(_:)`). Deliberately NOT persisted
    // by transient tool state, not a preference — X swaps and D
    // resets them, and writing every eyedropper sample to UserDefaults would
    // leak one document's colours into the next window.
    @Published var foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    @Published var backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// Eyedropper box edge in canvas px: 1 = point sample, 3 = 3×3, 5 = 5×5.
    /// SEED-ONLY (Tools pane).
    @Published var eyedropperSampleSize = Defaults.value(Defaults.Keys.eyedropperSampleSize)
    /// Canvas-space pointer position while a brush-family tool is active,
    /// for the live size-ring cursor.
    @Published var brushCursorPoint: CGPoint?
    @Published private(set) var strokePreview: StrokePreview?
    /// One-line explanation when a stroke can't start on the current target.
    @Published var brushHint: String?
    private var activeStroke: BrushStroke?
    private var strokeCanvasToLocal: CGAffineTransform = .identity
    // Gradient tool (G).
    /// Options bar: linear/radial, foreground→transparent, reverse. Not
    /// persisted, for the same reason as the colour wells above.
    @Published var gradientShape: GradientShape = .linear
    @Published var gradientToTransparent = false
    @Published var gradientReversed = false
    /// In-progress gradient drag vector, canvas space, for the overlay line.
    @Published var previewGradientLine: GradientLine?
    // Text & shape tools.
    /// Style defaults applied to the next created shape. SEED-ONLY (Tools pane).
    @Published var shapeStyle = Defaults.value(Defaults.Keys.shapeStyle)
    /// Rubber-band outline while dragging out a shape, canvas space.
    @Published var previewShapePath: CGPath?
    /// Live in-place text editing (§ inline text). The document is NEVER
    /// mutated during a session — the canvas hides the layer via a renderer
    /// exclusion and an NSTextView overlay shows the live text; commit
    /// produces at most one undo step.
    @Published private(set) var textSession: TextEditSession?
    /// Style defaults for the next created text layer (mirrors `shapeStyle`).
    /// SEED-ONLY (Tools pane).
    @Published var textStyle = Defaults.value(Defaults.Keys.textStyle)

    struct TextEditSession {
        /// Identity for the editor's reconcile: a new value means tear down
        /// and rebuild the overlay editor.
        let id = UUID()
        /// nil while creating a new layer.
        var layerID: UUID?
        /// Live text + style — the source of truth during the session.
        var spec: TextSpec
        /// The existing layer's spec at session start (no-op detection).
        let initialSpec: TextSpec?
        /// Canvas point pinned for the whole session: the text box top-left.
        let anchorTopLeft: CGPoint
        /// Decomposed layer transform (identity while creating).
        let rotation: CGFloat
        let scaleX: CGFloat
        let scaleY: CGFloat
        /// False for mirrored transforms → upright fallback editing box.
        let isDecomposable: Bool
        /// Canvas point of the initiating click (caret placement); nil ⇒ select all.
        var caretHint: CGPoint?
        /// The seeded sample text for create sessions (nil when editing).
        /// Committing with the text still exactly this string leaves no layer.
    }
    /// Select > Modify parameter sheets (Grow/Contract/Border).
    enum SelectionModifyKind: String, CaseIterable, Identifiable {
        case grow, contract, border
        var id: String { rawValue }
    }
    // Sheet triggers + error surface.
    @Published var exportRequested = false
    @Published var imageSizeRequested = false
    @Published var canvasSizeRequested = false
    @Published var fillRequested = false
    @Published var selectionModifyRequested: SelectionModifyKind?
    /// An effect the effects panel should expand and scroll to — set by the
    /// Layer Style menu items and the fx badge, consumed by the panel. The
    /// token makes a repeat request for the same effect still register.
    struct EffectsFocus: Equatable {
        let layerID: UUID
        let kind: LayerEffects.Kind
        let token = UUID()
    }
    @Published var effectsFocus: EffectsFocus?
    /// Last-used Modify amounts, reseeding each sheet like Photoshop's dialogs.
    var selectionModifyAmounts: [SelectionModifyKind: Double] = [:]
    @Published var lastErrorMessage: String?

    weak var undoManager: UndoManager?

    // MARK: Undo history
    private struct Snapshot: Equatable {
        var document: Document
        var selection: SelectionState
        /// The Quick Mask channel while that mode is on — painting it is an
        /// ordinary edit, so it has to undo like one.
        var quickMask: MaskTexture?
        var selectedLayerID: UUID?
        var selectedGroupID: UUID?
        /// The whole multi-selection, restored with the same
        /// liveness filtering the anchor gets — see `apply(_:)`.
        var selectedLayerIDs: Set<UUID>
        /// The command name this state was reached by — the History panel's
        /// row label, and the same string `commit` hands to
        /// `NSUndoManager.setActionName`.
        var actionName: String

        /// `actionName` is EXCLUDED from equality ON PURPOSE. `commit` dedupes
        /// no-op operations with `guard snapshot != history[historyIndex]`, so
        /// two differently-named commands that produce an identical document
        /// must still compare equal and dissolve — otherwise every no-op
        /// command (an unchanged Free Transform, a Fill of an empty selection,
        /// a disclosure-triangle patch) would push a history row. Written by
        /// hand rather than synthesized so that stays deliberate.
        ///
        /// Adding a new piece of restorable state = one more line here.
        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.document == b.document
                && a.selection == b.selection
                && a.quickMask == b.quickMask
                && a.selectedLayerID == b.selectedLayerID
                && a.selectedGroupID == b.selectedGroupID
                && a.selectedLayerIDs == b.selectedLayerIDs
        }
    }

    private var history: [Snapshot] = []
    /// `@Published` so the History panel follows undo/redo/jumps. `history`
    /// itself is not: every structural change to it comes with a `document` or
    /// `selection` change that already publishes, and `toggleGroupExpanded`
    /// rewrites all 100 snapshots in a loop.
    @Published private var historyIndex = 0
    /// Count cap on the snapshot history. LIVE (Settings → Performance,
    /// `AppSettings.undoDepth`): lowering it while a deep history is open
    /// evicts from the front right away rather than waiting for the next
    /// commit, so the memory the user was trying to reclaim is actually
    /// released. `var` for that reason, and because tests lower the caps
    /// rather than allocating gigabytes.
    var undoDepth = AppSettings.shared.undoDepth {
        didSet {
            evictOverBudgetHistory()
            // NSUndoManager keeps its own cap; leaving it at the old value
            // would silently hold the real limit below the preference.
            undoManager?.levelsOfUndo = undoDepth
        }
    }
    /// Byte cap on the snapshot history, checked alongside `undoDepth`.
    ///
    /// Most operations are nearly free to snapshot — `Layer.source` is a
    /// shared `CGImage` reference and `MaskTexture` is copy-on-write, so a
    /// hundred transform edits share almost all their storage. Paint is the
    /// exception: `endBrushStroke()` bakes a NEW full-size `CGImage` every
    /// stroke. Measured: 100 brush strokes on a 6000×4000 layer retained
    /// 9.64 GB before this cap existed. 2 GB (or a quarter of physical
    /// memory, whichever is smaller) keeps a long paint session bounded while
    /// leaving ordinary editing at the full 100 steps.
    ///
    /// LIVE alongside `undoDepth`, from the same Performance pane and with the
    /// same immediate-eviction rule.
    var undoByteBudget = AppSettings.shared.undoByteBudget {
        didSet { evictOverBudgetHistory() }
    }
    /// The distinct storages each snapshot references, parallel to `history`.
    /// Kept alongside rather than on `Snapshot` so it stays out of equality
    /// and out of the value copied on every commit.
    private var historyCosts: [SnapshotStorage] = []
    /// Ref-counted union of the storages the WHOLE history retains, and its
    /// byte total. Counting per-snapshot instead would charge 100 transform
    /// edits 100× for one shared bitmap and evict a history that costs
    /// nothing; what the budget must bound is what the array actually keeps
    /// alive, which is the union.
    private var historySourceRefs: [UUID: (bytes: Int, refs: Int)] = [:]
    private var historyMaskRefs: [UUID: (bytes: Int, refs: Int)] = [:]
    /// Approximate bytes retained by the snapshot history right now.
    private(set) var historyByteCost = 0
    /// True once eviction has dropped states off the front of `history` — the
    /// panel says so rather than silently showing a short list.
    private(set) var historyDiscardedOldSteps = false
    /// Keeps the live-settings mirrors alive for this store's lifetime; torn
    /// down with it, so a closed window stops following Settings.
    private var settingsObservers = Set<AnyCancellable>()

    init(document: Document) {
        self.document = document
        self.selectedLayerID = document.layers.last?.id
        // `didSet` doesn't fire during init, so the set is seeded by hand.
        self.selectedLayerIDs = Set(document.layers.last.map { [$0.id] } ?? [])
        history = [Snapshot(document: document, selection: .empty,
                            quickMask: nil,
                            selectedLayerID: selectedLayerID,
                            selectedGroupID: nil,
                            selectedLayerIDs: selectedLayerIDs,
                            actionName: Self.newDocumentActionName)]
        retainStorage(of: history[0])
        observeLiveSettings()
    }

    /// Mirrors the LIVE settings (see `AppSettings`) onto this store. Every
    /// sink guards on equality: the store's own `didSet` pushes back up to
    /// `AppSettings`, and the guard is what keeps that round trip from
    /// looping. SEED-ONLY settings are absent by design — they were read once
    /// in the property initializers above and must not move under an open
    /// window.
    private func observeLiveSettings() {
        let settings = AppSettings.shared
        settings.$gridSpacing.dropFirst().sink { [weak self] value in
            guard let self, self.gridSpacing != value else { return }
            self.gridSpacing = value
        }.store(in: &settingsObservers)
        settings.$gridSubdivisions.dropFirst().sink { [weak self] value in
            guard let self, self.gridSubdivisions != value else { return }
            self.gridSubdivisions = value
        }.store(in: &settingsObservers)
        settings.$snappingEnabled.dropFirst().sink { [weak self] value in
            guard let self, self.snappingEnabled != value else { return }
            self.snappingEnabled = value
        }.store(in: &settingsObservers)
        settings.$guideColor.dropFirst().sink { [weak self] value in
            guard let self, self.guideColor != value else { return }
            self.guideColor = value
        }.store(in: &settingsObservers)
        settings.$gridColor.dropFirst().sink { [weak self] value in
            guard let self, self.gridColor != value else { return }
            self.gridColor = value
        }.store(in: &settingsObservers)
        settings.$undoDepth.dropFirst().sink { [weak self] value in
            guard let self, self.undoDepth != value else { return }
            self.undoDepth = value
        }.store(in: &settingsObservers)
        // Published in MB; the store works in bytes, so this mirrors the
        // derived `AppSettings.undoByteBudget` rather than the raw value.
        settings.$undoByteBudgetMB.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            let bytes = settings.undoByteBudget
            guard self.undoByteBudget != bytes else { return }
            self.undoByteBudget = bytes
        }.store(in: &settingsObservers)
    }

    var selectedLayer: Layer? {
        selectedLayerID.flatMap { document[layerID: $0] }
    }

    var selectedGroup: LayerGroup? {
        selectedGroupID.flatMap { document.group(withID: $0) }
    }

    /// The selected layer is visible on screen — its own eye AND every
    /// ancestor group's. What effective visibility means for render and
    /// hit-testing (GroupOps), applied to command enablement the same way.
    var selectedLayerEffectivelyVisible: Bool {
        selectedLayerID.map { document.isEffectivelyVisible(layerID: $0) } ?? false
    }

    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }

    // MARK: - Live (mid-gesture) mutation — never touches history

    func setLiveDocument(_ doc: Document) {
        document = doc
    }

    func setLiveLayerTransform(_ id: UUID, _ transform: CGAffineTransform) {
        guard var layer = document[layerID: id] else { return }
        layer.transform = transform
        document = document.replacingLayer(layer)
    }

    func setLiveOpacity(_ id: UUID, _ value: Float) {
        guard var layer = document[layerID: id] else { return }
        layer.opacity = min(max(value, 0), 1)
        document = document.replacingLayer(layer)
    }

    // MARK: - Commit / undo core

    func commit(_ actionName: String,
                document newDocument: Document,
                selection newSelection: SelectionState? = nil) {
        let snapshot = Snapshot(document: newDocument,
                                selection: newSelection ?? selection,
                                // Like `selectedLayerID`: ops that change the
                                // Quick Mask assign it before committing.
                                quickMask: quickMask,
                                selectedLayerID: selectedLayerID,
                                selectedGroupID: selectedGroupID,
                                selectedLayerIDs: selectedLayerIDs,
                                actionName: actionName)
        guard snapshot != history[historyIndex] else {
            apply(snapshot)
            return
        }
        if historyIndex < history.count - 1 {
            for i in (historyIndex + 1)..<history.count { releaseStorage(historyCosts[i]) }
            history.removeSubrange((historyIndex + 1)...)
            historyCosts.removeSubrange((historyIndex + 1)...)
        }
        history.append(snapshot)
        retainStorage(of: snapshot)
        evictOverBudgetHistory()
        historyIndex = history.count - 1
        apply(snapshot)
        undoManager?.registerUndo(withTarget: self) { $0.undoStep() }
        undoManager?.setActionName(actionName)
        RenderEngine.shared.pruneCaches(for: newDocument)
    }

    /// Drops the oldest states until BOTH caps hold. The newest snapshot
    /// is never evicted however large it is — a single 6000×4000 stroke can
    /// exceed a small budget on its own, and a history that cannot hold the
    /// state on screen is worse than one over budget.
    ///
    /// Also called from both caps' `didSet`, so lowering either in Settings →
    /// Performance frees the memory immediately rather than at the next commit
    /// (edge case). That is why eviction keeps `historyIndex` pointed
    /// at the same snapshot itself instead of leaving it to the caller: from a
    /// `didSet` there is no following `historyIndex = history.count - 1` to
    /// paper over the shift, and a stale index would restore the wrong state.
    private func evictOverBudgetHistory() {
        while history.count > undoDepth { dropOldestSnapshot() }
        while historyByteCost > undoByteBudget, history.count > 1 { dropOldestSnapshot() }
    }

    private func dropOldestSnapshot() {
        releaseStorage(historyCosts.removeFirst())
        history.removeFirst()
        historyIndex = max(0, historyIndex - 1)
        historyDiscardedOldSteps = true
    }

    /// The distinct storages one snapshot references, with their approximate
    /// byte sizes. Layers sharing a `sourceID` (duplicates) and masks sharing
    /// a `storageIdentity` (copy-on-write clones that were never written)
    /// appear ONCE: the pixels exist once, and charging per layer would
    /// over-count a duplicate-heavy document by its duplicate count.
    private struct SnapshotStorage {
        var sources: [UUID: Int] = [:]
        var masks: [UUID: Int] = [:]

        init(_ snapshot: Snapshot) {
            let document = snapshot.document
            // A Quick Mask channel and a selection's alpha are canvas-sized
            // buffers riding in the snapshot, so they are charged to the
            // budget exactly like layer masks — and, being copy-on-write,
            // counted once across the snapshots that share them.
            for texture in [snapshot.quickMask, snapshot.selection.alpha?.texture].compactMap({ $0 }) {
                masks[texture.storageIdentity] = texture.width * texture.height
            }
            for layer in document.layers {
                // `sourceID` is the pixel identity by invariant: changing a
                // layer's pixels means a fresh `sourceID` (the .brushy
                // serializer's cache depends on the same rule).
                sources[layer.sourceID] = layer.source.height * layer.source.bytesPerRow
                if let texture = layer.mask?.texture {
                    masks[texture.storageIdentity] = texture.width * texture.height
                }
            }
        }
    }

    private func retainStorage(of snapshot: Snapshot) {
        let storage = SnapshotStorage(snapshot)
        historyCosts.append(storage)
        for (key, bytes) in storage.sources {
            if var entry = historySourceRefs[key] {
                entry.refs += 1
                historySourceRefs[key] = entry
            } else {
                historySourceRefs[key] = (bytes, 1)
                historyByteCost += bytes
            }
        }
        for (key, bytes) in storage.masks {
            if var entry = historyMaskRefs[key] {
                entry.refs += 1
                historyMaskRefs[key] = entry
            } else {
                historyMaskRefs[key] = (bytes, 1)
                historyByteCost += bytes
            }
        }
    }

    private func releaseStorage(_ storage: SnapshotStorage) {
        for key in storage.sources.keys {
            guard var entry = historySourceRefs[key] else { continue }
            entry.refs -= 1
            if entry.refs <= 0 {
                historySourceRefs[key] = nil
                historyByteCost -= entry.bytes
            } else {
                historySourceRefs[key] = entry
            }
        }
        for key in storage.masks.keys {
            guard var entry = historyMaskRefs[key] else { continue }
            entry.refs -= 1
            if entry.refs <= 0 {
                historyMaskRefs[key] = nil
                historyByteCost -= entry.bytes
            } else {
                historyMaskRefs[key] = entry
            }
        }
    }

    private func resetHistoryStorageAccounting() {
        historyCosts = []
        historySourceRefs = [:]
        historyMaskRefs = [:]
        historyByteCost = 0
        historyDiscardedOldSteps = false
    }

    private func undoStep() {
        guard historyIndex > 0 else { return }
        discardSessions()
        historyIndex -= 1
        apply(history[historyIndex])
        undoManager?.registerUndo(withTarget: self) { $0.redoStep() }
    }

    private func redoStep() {
        guard historyIndex < history.count - 1 else { return }
        discardSessions()
        historyIndex += 1
        apply(history[historyIndex])
        undoManager?.registerUndo(withTarget: self) { $0.undoStep() }
    }

    // MARK: - History panel projection

    /// One row of the History panel. `id` is the index in `history`, which
    /// EVICTION SHIFTS — the whole array is rebuilt on every read and the view
    /// must not cache ids across commits.
    struct HistoryEntry: Identifiable, Equatable {
        let id: Int
        let actionName: String
        /// The state the document is currently showing.
        let isCurrent: Bool
        /// Past the current position: the redo tail, which the next commit
        /// discards. Photoshop dims these rows; so do we.
        let isRedoTail: Bool
    }

    /// The whole history, oldest first. Row 0 is the document's opening
    /// state ("New" or "Open"), never an edit.
    var historyEntries: [HistoryEntry] {
        history.enumerated().map { index, snapshot in
            HistoryEntry(id: index,
                         actionName: snapshot.actionName,
                         isCurrent: index == historyIndex,
                         isRedoTail: index > historyIndex)
        }
    }

    /// Index into `historyEntries` of the state on screen.
    var historyPosition: Int { historyIndex }

    /// Why the list is shorter than the step cap, when it is — the panel says
    /// so rather than silently showing fewer rows than the user expects. The
    /// byte budget bites first in a paint session (each stroke snapshots a
    /// full-size bitmap) and the count cap first in everything else.
    var historyLimitNote: String? {
        guard historyDiscardedOldSteps else { return nil }
        return history.count < undoDepth
            ? "Older steps discarded to stay within memory"
            : "Older steps discarded at the \(undoDepth)-step limit"
    }

    /// Label for the opening state of a document that was never on disk.
    static let newDocumentActionName = "New"
    /// …and of one that was loaded (file, PSD, demo content).
    static let openedDocumentActionName = "Open"

    /// Click-to-jump. Restores the state at `index` by REPLAYING
    /// `undoStep()` / `redoStep()` one step at a time rather than assigning
    /// `historyIndex`: each of those re-registers its inverse with
    /// `NSUndoManager`, and moving the index behind their back leaves the undo
    /// stack describing a different position than the array does, so the next
    /// ⌘Z lands somewhere the user never was. The loop is one undo group, so
    /// a five-step jump is one ⌘Z afterwards (Photoshop parity).
    func jumpToHistory(index: Int) {
        guard history.indices.contains(index), index != historyIndex else { return }
        // `undoStep()` calls `discardSessions()`, which drops a live transform
        // or text session on the floor; land it first, exactly as every other
        // document-changing operation does.
        commitPendingSessions()
        // …which may itself have committed a step and truncated the redo tail.
        guard history.indices.contains(index), index != historyIndex else { return }
        undoManager?.beginUndoGrouping()
        while historyIndex > index { undoStep() }
        while historyIndex < index { redoStep() }
        // Photoshop names this Edit-menu entry "State Change" — the whole jump
        // is one action, and ⌘Z returns to the row the user jumped FROM.
        undoManager?.setActionName("State Change")
        undoManager?.endUndoGrouping()
    }

    private func apply(_ snapshot: Snapshot) {
        let previousCanvasSize = document.canvasSize
        document = snapshot.document
        if document.canvasSize != previousCanvasSize { recenterViewport() }
        selection = snapshot.selection
        quickMask = snapshot.quickMask
        if let id = snapshot.selectedLayerID, document[layerID: id] != nil {
            selectedLayerID = id
        } else if let id = selectedLayerID, document[layerID: id] == nil {
            selectedLayerID = document.layers.last?.id
        }
        // Group selection restores from the snapshot (validated against its
        // document); snapshots record layer/group selection as mutually
        // exclusive, so a restored group also restores the recorded (nil)
        // layer selection rather than the fallback above.
        selectedGroupID = snapshot.selectedGroupID.flatMap {
            snapshot.document.group(withID: $0) != nil ? $0 : nil
        }
        if selectedGroupID != nil {
            selectedLayerID = snapshot.selectedLayerID
        }
        // The multi-selection restores last, because every anchor
        // assignment above collapses it through `selectedLayerID`'s didSet.
        // Same liveness rule as the anchor: ids whose layers this snapshot's
        // document no longer has are dropped, and a set emptied that way falls
        // back to whatever anchor survived.
        var liveSelection = snapshot.selectedLayerIDs.filter { document[layerID: $0] != nil }
        if liveSelection.isEmpty, let anchor = selectedLayerID {
            liveSelection = [anchor]
        }
        selectedLayerIDs = liveSelection
        if let session = transformSession, document[layerID: session.layerID] == nil {
            transformSession = nil
        }
        if cropSession != nil, activeTool == .crop {
            cropSession = CropSession(rect: document.canvasRect)
        }
    }

    /// A canvas that changed size — crop, Image/Canvas Size, or stepping
    /// history across one — is re-centred in the window at the current zoom,
    /// as Photoshop does; a view still in its fit state refits instead (§4).
    private func recenterViewport() {
        guard viewport.isInitialized else { return }
        if viewport.hasUserAdjusted {
            viewport.center(canvasSize: document.canvasSize)
        } else {
            viewport.fit(canvasSize: document.canvasSize)
        }
    }

    private func discardSessions() {
        transformSession = nil
        // History stepping replaces the document wholesale: a float's base
        // document no longer describes anything.
        selectionFloat = nil
        selectionTransformSession = nil
        activeGuides = []
        previewSelectionPath = nil
        movingSelectionOutline = false
        // Deliberate: a mid-drag brush stroke is dropped by history
        // stepping. The stroke was never committed, and baking it against a
        // different snapshot would paint pixels the user never saw.
        activeStroke = nil
        strokePreview = nil
        quickMaskStrokeBase = nil
        textSession = nil
    }

    /// Loading from disk / demo content: resets history around the new value.
    /// `actionName` labels the one surviving snapshot in the History panel —
    /// "Open" for content that came from a file, "New" for a document the user
    /// created (the ⌘N size dialog, demo content), matching Photoshop's first
    /// history row.
    func replaceDocument(_ newDocument: Document,
                         actionName: String = openedDocumentActionName) {
        discardSessions()
        document = newDocument
        selection = .empty
        quickMask = nil
        selectedLayerID = newDocument.layers.last?.id
        selectedGroupID = nil
        history = [Snapshot(document: newDocument, selection: .empty,
                            quickMask: nil,
                            selectedLayerID: selectedLayerID,
                            selectedGroupID: nil,
                            selectedLayerIDs: selectedLayerIDs,
                            actionName: actionName)]
        resetHistoryStorageAccounting()
        retainStorage(of: history[0])
        historyIndex = 0
        if viewport.isInitialized {
            viewport.fit(canvasSize: newDocument.canvasSize)
        }
        RenderEngine.shared.pruneCaches(for: newDocument)
    }

    // MARK: - Place / import

    /// Places images as layers. Into an empty document, the first image
    /// defines the canvas (open-as-document semantics, no transform box);
    /// into a document with content, the last placed layer arrives with
    /// Free Transform active — Photoshop's Place behaviour — so even a tiny
    /// or oversized image is immediately visible and adjustable.
    func placeImages(from urls: [URL]) {
        commitPendingSessions()
        var doc = document
        stripPristineBlank(from: &doc)
        let adoptedEmptyDocument = doc.layers.isEmpty && !canvasSizeChosenExplicitly
        // A blank layer made to receive the drop is used rather than left
        // under it — the same rule paste follows, and on the same terms (see
        // `insertLayerAboveSelection`). `doc` is local, so a failed import
        // discards this along with everything else.
        if doc.layers.count > 1,
           let selectedIndex = selectedLayerID.flatMap({ doc.layerIndex(of: $0) }),
           Self.isBlankPaintLayer(doc.layers[selectedIndex]) {
            doc.layers.remove(at: selectedIndex)
        }
        var errors: [String] = []
        var lastPlaced: UUID?
        for url in urls {
            do {
                let image = try ImageImporter.importImage(at: url)
                if doc.layers.isEmpty, !canvasSizeChosenExplicitly {
                    doc.canvasSize = CGSize(width: image.width, height: image.height)
                }
                let layer = Self.placedLayer(image,
                                             named: url.deletingPathExtension().lastPathComponent,
                                             canvasSize: doc.canvasSize)
                doc.layers.append(layer)
                lastPlaced = layer.id
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if let lastPlaced {
            selectedLayerID = lastPlaced
            maskTargeted = false
            commit(urls.count > 1 ? "Place Images" : "Place Image", document: doc)
            if !viewport.isInitialized || history.count == 2 {
                zoomToFit()
            }
            armTransformForArrivedLayer(lastPlaced, adoptedCanvas: adoptedEmptyDocument)
        }
        if !errors.isEmpty {
            lastErrorMessage = errors.joined(separator: "\n")
        }
    }

    /// Placement rule: 100% scale, centred; scaled down to fit (proportionally,
    /// via the transform — non-destructive) only if larger than the canvas.
    static func placedLayer(_ image: CGImage, named name: String, canvasSize: CGSize) -> Layer {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var scale: CGFloat = 1
        if w > canvasSize.width || h > canvasSize.height {
            scale = min(canvasSize.width / w, canvasSize.height / h)
        }
        var tx = (canvasSize.width - w * scale) / 2
        var ty = (canvasSize.height - h * scale) / 2
        // At 100% land on whole pixels: an odd size difference would centre
        // the image half a pixel off the grid and resample it soft.
        if scale == 1 { tx.round(); ty.round() }
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        return Layer(name: name, source: image, transform: transform)
    }

    // MARK: - Layer operations

    /// Deliberately REFUSES during a Free Transform rather than landing it
    /// first, unlike every other mutator here. Committing a
    /// transform the user is mid-gesture on and then deleting the layer they
    /// were transforming is a surprising pair of undo entries; refusing is the
    /// conservative reading and is what this has always done. Called out
    /// because the inconsistency otherwise looks like the same oversight that
    /// was just fixed in the mutators above.
    func deleteSelectedLayer() {
        guard let layer = selectedLayer else { return }
        guard transformSession == nil else { return }
        let index = document.layerIndex(of: layer.id) ?? 0
        var doc = document.removingLayer(id: layer.id)
        selectedLayerID = doc.layers.indices.contains(index - 1) ? doc.layers[index - 1].id
                                                                 : doc.layers.first?.id
        maskTargeted = false
        commit("Delete Layer", document: doc)
    }

    func duplicateSelectedLayer() {
        guard let layer = selectedLayer, let index = document.layerIndex(of: layer.id) else { return }
        commitPendingSessions()
        let copy = layer.duplicated(name: layer.name + " copy")
        var doc = document
        doc.layers.insert(copy, at: index + 1)
        selectedLayerID = copy.id
        commit("Duplicate Layer", document: doc)
    }

    func mergeDownSelectedLayer() {
        guard let top = selectedLayer,
              let index = document.layerIndex(of: top.id), index > 0 else { return }
        commitPendingSessions()
        let bottom = document.layers[index - 1]
        // Merge Down never crosses a group boundary (Photoshop blocks it):
        // the neighbour below must sit in the same direct group. Validation
        // mirrors this guard.
        guard bottom.groupID == top.groupID else { return }
        guard top.isVisible, bottom.isVisible else { return }
        guard let (image, origin) = RenderEngine.shared.renderMerged(bottom: bottom, top: top) else {
            lastErrorMessage = "Merge Down failed to render."
            return
        }
        // The merged layer takes the bottom layer's place in the stack, so it
        // keeps the bottom's blend mode, clip flag and group (merging two
        // members of one clipped run stays in the run; merging into an
        // unclipped base bakes the confinement — see `renderMerged`; merging
        // inside a folder stays in the folder). The top layer's blend mode is
        // baked into the pixels.
        let merged = Layer(name: bottom.name, source: image,
                           transform: CGAffineTransform(translationX: origin.x, y: origin.y),
                           blendMode: bottom.blendMode,
                           isClippedToBelow: bottom.isClippedToBelow,
                           groupID: bottom.groupID)
        var doc = document
        doc.layers.replaceSubrange((index - 1)...index, with: [merged])
        selectedLayerID = merged.id
        maskTargeted = false
        commit("Merge Down", document: doc)
    }

    func setLayerVisibility(_ id: UUID, _ visible: Bool) {
        commitPendingSessions()
        guard var layer = document[layerID: id], layer.isVisible != visible else { return }
        layer.isVisible = visible
        commit(visible ? "Show Layer" : "Hide Layer", document: document.replacingLayer(layer))
    }

    func setLayerBlendMode(_ id: UUID, _ mode: BlendMode) {
        commitPendingSessions()
        guard var layer = document[layerID: id], layer.blendMode != mode else { return }
        layer.blendMode = mode
        commit("Change Blend Mode", document: document.replacingLayer(layer))
    }

    /// Photoshop's ⌥⌘G: clips the layer to the nearest unclipped layer below
    /// it, or releases the clip. The bottom layer has nothing below to clip
    /// to and is refused (the panel and menu disable the affordance; this
    /// guard also covers direct calls).
    func toggleClippingMask(_ id: UUID) {
        commitPendingSessions()
        guard var layer = document[layerID: id],
              let index = document.layerIndex(of: id), index > 0 else { return }
        layer.isClippedToBelow.toggle()
        commit(layer.isClippedToBelow ? "Create Clipping Mask" : "Release Clipping Mask",
               document: document.replacingLayer(layer))
    }

    // MARK: - Layer effects (Layer Style)

    /// Brings the effects panel (under the Layers list) up on a layer — the
    /// Layer Style menu items and the fx badge. With `focus`, that effect is
    /// switched on if it isn't (its own commit) and expanded in the panel.
    func showLayerEffects(_ id: UUID? = nil, focus: LayerEffects.Kind? = nil) {
        commitPendingSessions()
        guard let layerID = id ?? selectedLayerID, document[layerID: layerID] != nil else { return }
        selectLayer(layerID)
        rightPanel = .layers
        panelsHidden = false
        guard let focus else { return }
        addLayerEffect(layerID, focus)
        effectsFocus = EffectsFocus(layerID: layerID, kind: focus)
    }

    /// Switches an effect on. A new one is sized to the layer
    /// (`LayerEffects.add(_:layerSize:)`); one that was only unchecked comes
    /// back with its old parameters.
    func addLayerEffect(_ id: UUID, _ kind: LayerEffects.Kind) {
        guard let layer = document[layerID: id], !layer.effects.isOn(kind) else { return }
        var effects = layer.effects
        let wasPresent = effects.isPresent(kind)
        effects.add(kind, layerSize: layer.canvasBounds.size)
        effects.isEnabled = true
        setLayerEffects(id, effects, actionName: wasPresent ? "Enable \(kind.displayName)"
                                                            : "Add \(kind.displayName)")
    }

    /// Deletes an effect with its parameters — the panel's remove button.
    func removeLayerEffect(_ id: UUID, _ kind: LayerEffects.Kind) {
        guard var effects = document[layerID: id]?.effects, effects.isPresent(kind) else { return }
        effects.remove(kind)
        setLayerEffects(id, effects, actionName: "Remove \(kind.displayName)")
    }

    /// Live preview while a panel control moves — no history, like the
    /// opacity slider's mid-drag updates. `endLayerEffectsEdit` lands it.
    func setLiveLayerEffects(_ id: UUID, _ effects: LayerEffects) {
        commitPendingSessions()
        guard var layer = document[layerID: id], layer.effects != effects else { return }
        layer.effects = effects
        document = document.replacingLayer(layer)
    }

    /// Lands the live effect edits on screen as one history entry: the end of
    /// a slider or dial drag, a typed value, a burst of colour-panel changes.
    /// An edit that changed nothing records nothing (`commit` drops a
    /// snapshot identical to the current one).
    func endLayerEffectsEdit(_ actionName: String) {
        commit(actionName, document: document)
    }

    /// One history entry for a whole effects change — what the panel's
    /// add/remove use, and what the fx eye and Clear Layer Style use.
    func setLayerEffects(_ id: UUID, _ effects: LayerEffects,
                         actionName: String = "Layer Style") {
        commitPendingSessions()
        guard var layer = document[layerID: id] else { return }
        layer.effects = effects
        commit(actionName, document: document.replacingLayer(layer))
    }

    /// The fx eye in the layers panel: keeps every parameter, stops rendering.
    func toggleLayerEffectsEnabled(_ id: UUID) {
        guard var effects = document[layerID: id]?.effects, !effects.isEmpty else { return }
        effects.isEnabled.toggle()
        setLayerEffects(id, effects,
                        actionName: effects.isEnabled ? "Enable Layer Effects"
                                                      : "Disable Layer Effects")
    }

    /// Photoshop's Layer > Layer Style > Clear Layer Style.
    func clearLayerStyle(_ id: UUID) {
        guard let effects = document[layerID: id]?.effects, !effects.isEmpty else { return }
        setLayerEffects(id, .none, actionName: "Clear Layer Style")
    }

    /// Unchecking one effect from the panel's fx sub-rows. Photoshop keeps the
    /// parameters, so this clears the checkbox rather than the effect.
    func setLayerEffectOn(_ id: UUID, _ kind: LayerEffects.Kind, _ on: Bool) {
        guard var effects = document[layerID: id]?.effects, effects.isOn(kind) != on else { return }
        effects.setOn(kind, on)
        setLayerEffects(id, effects, actionName: on ? "Enable \(kind.displayName)"
                                                    : "Disable \(kind.displayName)")
    }

    func renameLayer(_ id: UUID, to name: String) {
        commitPendingSessions()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard var layer = document[layerID: id], !trimmed.isEmpty, layer.name != trimmed else { return }
        layer.name = trimmed
        commit("Rename Layer", document: document.replacingLayer(layer))
    }

    func endOpacityEdit() {
        commit("Change Opacity", document: document)
    }

    func reorderLayers(fromDisplayOffsets offsets: IndexSet, toDisplayOffset destination: Int) {
        let doc = document.movingLayers(fromDisplayOffsets: offsets, toDisplayOffset: destination)
        guard doc.layers.map(\.id) != document.layers.map(\.id) else { return }
        commit("Reorder Layers", document: doc)
    }

    func selectLayer(_ id: UUID?) {
        if selectedLayerID != id || selectedGroupID != nil || selectedLayerIDs != Set(id.map { [$0] } ?? []) {
            commitPendingSessions()
            selectedLayerID = id // didSet collapses the multi-selection to this one
            selectedGroupID = nil
            maskTargeted = false
        }
    }

    /// Selects a group row in the panel. Clears the layer ANCHOR — canvas
    /// tools operate on layers only, so they idle while a group is selected
    /// (Photoshop behaviour); group-level commands read `selectedGroupID`.
    /// The group's member layers do fill `selectedLayerIDs`, so
    /// relational commands see the folder's contents while still treating it
    /// as one object (`alignObjects`).
    func selectGroup(_ id: UUID?) {
        if selectedGroupID != id {
            commitPendingSessions()
            selectedGroupID = id
            if let id {
                setSelection(document.memberLayerIndices(ofGroup: id).map { document.layers[$0].id },
                             anchor: nil)
                maskTargeted = false
            }
        }
    }

    // MARK: - Multi-layer selection

    /// Assigns the anchor and the set together without the anchor's `didSet`
    /// collapsing the set behind it.
    private func setSelection<S: Sequence>(_ ids: S, anchor: UUID?) where S.Element == UUID {
        isSettingSelectionSet = true
        selectedLayerID = anchor
        isSettingSelectionSet = false
        selectedLayerIDs = Set(ids)
    }

    /// ⌘-click semantics: adds the layer to the selection, or removes it. The
    /// anchor becomes the newly added layer, or — on removal — whatever is
    /// left (topmost first), so single-layer commands always have a target.
    func toggleLayerSelection(_ id: UUID) {
        guard document[layerID: id] != nil else { return }
        commitPendingSessions()
        selectedGroupID = nil
        maskTargeted = false
        var ids = selectedLayerIDs
        if ids.contains(id) {
            ids.remove(id)
            let anchor = selectedLayerID == id
                ? document.layers.last(where: { ids.contains($0.id) })?.id
                : selectedLayerID
            setSelection(ids, anchor: anchor)
        } else {
            ids.insert(id)
            setSelection(ids, anchor: id)
        }
    }

    /// ⇧-click semantics: extends the selection from the anchor to `id` over
    /// the PANEL's display order — the panel shows a tree, so a range there is
    /// a range of `panelRows()`, never of `layers` indices. A group row inside
    /// the range contributes its members.
    func extendSelection(to id: UUID) {
        guard document[layerID: id] != nil else { return }
        guard let anchor = selectedLayerID, anchor != id else {
            selectLayer(id)
            return
        }
        let rows = document.panelRows()
        guard let from = rows.firstIndex(where: { $0.id == anchor }),
              let to = rows.firstIndex(where: { $0.id == id }) else {
            selectLayer(id)
            return
        }
        commitPendingSessions()
        selectedGroupID = nil
        maskTargeted = false
        var ids = selectedLayerIDs
        for row in rows[min(from, to)...max(from, to)] {
            switch row {
            case .layer(let layer, _):
                ids.insert(layer.id)
            case .group(let group, _):
                // An expanded folder's members have rows of their own, so
                // they join the range on their own account. A COLLAPSED
                // folder shows no member rows, so its row stands in for the
                // whole subtree.
                if !group.isExpanded {
                    ids.formUnion(document.memberLayerIndices(ofGroup: group.id)
                        .map { document.layers[$0].id })
                }
            }
        }
        // Photoshop keeps the range's origin as the anchor, so a second
        // ⇧-click re-extends from the same place; the clicked row is only the
        // far end.
        setSelection(ids, anchor: anchor)
    }

    /// The layers panel's `List(selection:)` set binding: SwiftUI hands over
    /// the whole new set after its own ⇧-range / ⌘-toggle handling, and this
    /// routes it back into the store's group-vs-layer model.
    ///
    /// Group and layer selection stay mutually exclusive (canvas tools idle on
    /// a group row), so a set mixing both keeps the layers and drops the
    /// folder rows — the layers are what the user can act on.
    func selectPanelRows(_ ids: Set<UUID>) {
        let layerIDs = ids.filter { document[layerID: $0] != nil }
        if layerIDs.isEmpty {
            if let groupID = ids.first(where: { document.group(withID: $0) != nil }) {
                selectGroup(groupID)
            } else {
                selectGroup(nil)
                selectLayer(nil) // also clears a group's member set
            }
            return
        }
        guard layerIDs != selectedLayerIDs || selectedGroupID != nil else { return }
        commitPendingSessions()
        selectedGroupID = nil
        maskTargeted = false
        // SwiftUI reports the resulting set, not which row was clicked, so the
        // anchor is inferred: a newly added layer wins, otherwise the previous
        // anchor if it survived, otherwise the topmost remaining row.
        let added = layerIDs.subtracting(selectedLayerIDs)
        let anchor = document.layers.last { added.contains($0.id) }?.id
            ?? selectedLayerID.flatMap { layerIDs.contains($0) ? $0 : nil }
            ?? document.layers.last { layerIDs.contains($0.id) }?.id
        setSelection(layerIDs, anchor: anchor)
    }

    // MARK: - Layer groups

    /// ⌘G targets: the selected layer, or — when a group row is selected —
    /// the group itself (wrapping it in a new parent, Photoshop's group-of-
    /// groups).
    var canGroupSelection: Bool {
        selectedGroup != nil || selectedLayer != nil
    }

    /// ⇧⌘G targets the selected group, or the selected layer's innermost
    /// group (Photoshop enables Ungroup from a member too).
    var ungroupTargetID: UUID? {
        if let group = selectedGroup { return group.id }
        return selectedLayer?.groupID
    }

    /// Layer → Group Layer (⌘G): wraps the selected layer (or selected
    /// group) in a new group and selects the group. One "Group Layer" entry.
    func groupSelection() {
        commitPendingSessions()
        let name = document.nextGroupName()
        let grouped: (document: Document, groupID: UUID)?
        if let group = selectedGroup {
            grouped = document.addingGroup(named: name, aroundGroup: group.id)
        } else if let layer = selectedLayer {
            grouped = document.addingGroup(named: name, aroundLayer: layer.id)
        } else {
            grouped = nil
        }
        guard let (doc, newID) = grouped else { return }
        selectedGroupID = newID
        selectedLayerID = nil
        maskTargeted = false
        commit("Group Layer", document: doc)
    }

    /// Layer → Ungroup (⇧⌘G): dissolves the target group in place; members
    /// keep their stack positions and join the group's parent. One "Ungroup"
    /// entry. A selected group's topmost member layer becomes the selection;
    /// a selected member layer stays selected.
    func ungroupSelection() {
        commitPendingSessions()
        guard let groupID = ungroupTargetID,
              let run = document.memberRun(ofGroup: groupID) else { return }
        let doc = document.ungrouping(groupID)
        if selectedGroupID == groupID {
            selectedGroupID = nil
            selectedLayerID = doc.layers.indices.contains(run.upperBound)
                ? doc.layers[run.upperBound].id : doc.layers.last?.id
            maskTargeted = false
        }
        commit("Ungroup", document: doc)
    }

    /// Deletes the selected group AND its members — the whole subtree — as
    /// one "Delete Group" entry (the panel's trash / context menu).
    func deleteSelectedGroup() {
        guard let groupID = selectedGroupID,
              let run = document.memberRun(ofGroup: groupID) else { return }
        guard transformSession == nil else { return }
        let doc = document.removingGroup(groupID)
        selectedGroupID = nil
        let below = run.lowerBound - 1
        selectedLayerID = doc.layers.indices.contains(below) ? doc.layers[below].id
                                                             : doc.layers.first?.id
        maskTargeted = false
        commit("Delete Group", document: doc)
    }

    /// Duplicates the selected group's subtree directly above it — fresh
    /// layer/group ids, shared `sourceID`s, like Duplicate Layer — and
    /// selects the copy. One "Duplicate Group" entry.
    func duplicateSelectedGroup() {
        guard let groupID = selectedGroupID else { return }
        commitPendingSessions()
        guard let (doc, newID) = document.duplicatingGroup(groupID) else { return }
        selectedGroupID = newID
        selectedLayerID = nil
        commit("Duplicate Group", document: doc)
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let index = document.groupIndex(of: id), !trimmed.isEmpty,
              document.groups[index].name != trimmed else { return }
        var doc = document
        doc.groups[index].name = trimmed
        commit("Rename Group", document: doc)
    }

    /// The folder row's eye: hides/shows the whole subtree (effective
    /// visibility — members keep their own eye state).
    func setGroupVisibility(_ id: UUID, _ visible: Bool) {
        guard let index = document.groupIndex(of: id),
              document.groups[index].isVisible != visible else { return }
        var doc = document
        doc.groups[index].isVisible = visible
        commit(visible ? "Show Group" : "Hide Group", document: doc)
    }

    /// Group blend mode; `nil` is Pass Through (groups only — an explicit
    /// Normal isolates, see LayerGroup).
    func setGroupBlendMode(_ id: UUID, _ mode: BlendMode?) {
        guard let index = document.groupIndex(of: id),
              document.groups[index].blendMode != mode else { return }
        var doc = document
        doc.groups[index].blendMode = mode
        commit("Change Group Blend Mode", document: doc)
    }

    /// Live half of the group-opacity slider (no history), mirroring
    /// `setLiveOpacity` for layers.
    func setLiveGroupOpacity(_ id: UUID, _ value: Float) {
        guard let index = document.groupIndex(of: id) else { return }
        var doc = document
        doc.groups[index].opacity = min(max(value, 0), 1)
        setLiveDocument(doc)
    }

    func endGroupOpacityEdit() {
        commit("Change Group Opacity", document: document)
    }

    /// Disclosure triangle. The state lives in the model (it persists in the
    /// file,) but toggling it is NOT an edit: it is patched through
    /// every history snapshot, so it neither creates an undo entry nor
    /// reverts on undo/redo, and an unchanged-gesture commit still dissolves
    /// against the history top.
    func toggleGroupExpanded(_ id: UUID) {
        guard let index = document.groupIndex(of: id) else { return }
        var doc = document
        doc.groups[index].isExpanded.toggle()
        let expanded = doc.groups[index].isExpanded
        setLiveDocument(doc)
        for i in history.indices {
            if let groupIndex = history[i].document.groupIndex(of: id) {
                history[i].document.groups[groupIndex].isExpanded = expanded
            }
        }
    }

    /// Drag-reorder over the panel's row model (folder rows move their whole
    /// subtree; the drop gap decides membership — see
    /// `Document.movingPanelRow`).
    func reorderPanelRows(fromDisplayOffsets offsets: IndexSet, toDisplayOffset destination: Int) {
        let doc = document.movingPanelRow(fromDisplayOffsets: offsets,
                                          toDisplayOffset: destination)
        guard doc != document else { return }
        commit("Reorder Layers", document: doc)
    }

    // MARK: - Move / nudge

    func commitMove() {
        activeGuides = []
        commit("Move Layer", document: document)
    }

    /// ⌥-drag duplicate (move tool), mouse-down half: live-inserts a copy
    /// of the layer directly above the original and selects it — no history
    /// entry yet. The canvas controller drags the returned copy and lands the
    /// whole gesture with `commitDuplicateDrag()`: one gesture, one undo step.
    func beginDuplicateDrag(of layerID: UUID) -> Layer? {
        commitPendingSessions()
        guard let index = document.layerIndex(of: layerID) else { return nil }
        let original = document.layers[index]
        let copy = original.duplicated(name: original.name + " copy")
        var doc = document
        doc.layers.insert(copy, at: index + 1)
        selectedLayerID = copy.id
        maskTargeted = false
        setLiveDocument(doc)
        return copy
    }

    /// Mouse-up half of an ⌥-drag duplicate: commits the live document (copy
    /// inserted by `beginDuplicateDrag(of:)`, dragged via
    /// `setLiveLayerTransform`) as a single "Duplicate Layer" history entry.
    func commitDuplicateDrag() {
        activeGuides = []
        commit("Duplicate Layer", document: document)
    }

    func nudgeSelectedLayer(dx: CGFloat, dy: CGFloat) {
        if var session = transformSession {
            session.currentTransform = TransformMath.moved(initial: session.currentTransform,
                                                          delta: CGPoint(x: dx, y: dy))
            transformSession = session
            setLiveLayerTransform(session.layerID, session.currentTransform)
            return
        }
        //: arrow keys nudge a live Transform Selection box too.
        if var session = selectionTransformSession {
            session.currentTransform = TransformMath.moved(initial: session.currentTransform,
                                                           delta: CGPoint(x: dx, y: dy))
            selectionTransformSession = session
            return
        }
        // Arrow keys nudge the SELECTED PIXELS when a selection is up
        // (Photoshop), lifting them on the first press and pushing the same
        // float afterwards.
        if activeTool == .move, !selection.isEmpty,
           let float = beginSelectionFloat(), let current = selectionFloatTransform {
            setLiveLayerTransform(float.floatLayerID,
                                  current.concatenating(CGAffineTransform(translationX: dx, y: dy)))
            return
        }
        guard activeTool == .move, let layer = selectedLayer else { return }
        let moved = TransformMath.moved(initial: layer.transform, delta: CGPoint(x: dx, y: dy))
        var doc = document
        doc[layerID: layer.id]?.transform = moved
        commit("Nudge", document: doc)
    }

    // MARK: - Align & distribute

    /// Photoshop's "Align To" picker. Forced to `.canvas` while fewer than two
    /// objects are selected — selection bounds of a single object ARE the
    /// object, so every align would be a no-op (`effectiveAlignReference`).
    @Published var alignReference: AlignReference = .selectionBounds

    /// What the relational commands act on: a selected GROUP is one object
    /// (its members move together); otherwise every selected layer is its own
    /// object, in stack order so the commands are deterministic.
    var alignObjects: [AlignObject] {
        if let groupID = selectedGroupID { return [.group(groupID)] }
        return document.layers.filter { selectedLayerIDs.contains($0.id) }.map { .layer($0.id) }
    }

    var effectiveAlignReference: AlignReference {
        alignObjects.count < 2 ? .canvas : alignReference
    }

    /// Align needs two objects — unless the reference is the canvas, where one
    /// object against the frame is exactly Photoshop's single-layer align.
    var canAlignSelection: Bool {
        let count = alignObjects.count
        return count >= 2 || (count == 1 && effectiveAlignReference == .canvas)
    }

    /// Distribute needs three: with two there is nothing between them.
    var canDistributeSelection: Bool { alignObjects.count >= 3 }

    /// One history entry per operation — not one per layer moved.
    func alignSelection(to edge: AlignEdge) {
        commitPendingSessions()
        guard canAlignSelection else { return }
        activeGuides = []
        commit(edge.actionName,
               document: document.aligning(alignObjects, to: edge,
                                           reference: effectiveAlignReference))
    }

    func distributeSelection(_ command: DistributeCommand) {
        commitPendingSessions()
        guard canDistributeSelection else { return }
        activeGuides = []
        commit(command.actionName,
               document: document.distributing(alignObjects, along: command.axis,
                                               mode: command.mode))
    }

    // MARK: - Transform mode (Cmd+T)

    /// With a selection up, ⌘T transforms the selected PIXELS, not the whole
    /// layer (Photoshop): they float first and the ordinary session runs on
    /// the float, whose base document predates the lift so Esc unwinds both.
    ///
    /// `selectionAware: false` transforms the whole layer regardless — what
    /// arriving content wants (`armTransformForArrivedLayer`). A freshly
    /// placed image has nothing to do with a selection someone left lying
    /// around, and floating it would rasterize it on arrival.
    func enterTransformMode(selectionAware: Bool = true) {
        commitAnySelectionTransformSession()
        guard transformSession == nil else { return }
        // Adjustment layers have nothing to transform.
        if selectedLayer?.kind.adjustmentSpec != nil { return }
        if selectionAware, !selection.isEmpty, let float = beginSelectionFloat(),
           let floating = document[layerID: float.floatLayerID] {
            transformSession = TransformSession(layer: floating,
                                                baseDocument: float.baseDocument)
            return
        }
        guard let layer = selectedLayer, selectedLayerEffectivelyVisible else { return }
        transformSession = TransformSession(layer: layer, baseDocument: document)
    }

    /// Arms Free Transform on a just-arrived layer — Photoshop's Place
    /// behaviour, so even a tiny or oversized arrival is immediately visible
    /// and adjustable — unless the layer defined the canvas (an empty
    /// document adopting its first image is Open semantics, and a transform
    /// box around the whole canvas would be meaningless).
    ///
    /// Every path by which content arrives as a new layer must route through
    /// this one function so the rule cannot drift between paths:
    ///   - Place — `placeImages(from:)`, which drag-and-drop shares via
    ///     `CanvasHostView.performDragOperation`
    ///   - Paste / Paste Into — `finishPaste(_:document:adopted:into:)`
    ///   - cross-document transfer — `receiveLayer(_:from:)`
    /// Add any future arrival path to this list and call this after its
    /// commit.
    ///
    /// Paste Into arms deliberately: its mask is built against the canvas
    /// and stays put while the content moves inside it, which is the point
    /// of Paste Into — Photoshop behaves the same way.
    ///
    /// Callers invoke this *after* their `commit`: arming is not an edit and
    /// must not add a history entry of its own — the session commits
    /// separately as "Free Transform", and only if it changed something.
    private func armTransformForArrivedLayer(_ id: UUID, adoptedCanvas: Bool) {
        guard !adoptedCanvas, document[layerID: id] != nil else { return }
        selectedLayerID = id
        enterTransformMode(selectionAware: false)
    }

    func updateTransformSession(_ transform: CGAffineTransform) {
        guard var session = transformSession else { return }
        session.currentTransform = transform
        transformSession = session
        setLiveLayerTransform(session.layerID, transform)
    }

    func commitTransformSession() {
        guard let session = transformSession else { return }
        transformSession = nil
        activeGuides = []
        // A floating selection lands as one entry; an untouched box unwinds
        // the lift instead, so ⌘T then Return changes nothing.
        if selectionFloat != nil {
            // ⌘T's Return lands the pixels, unlike a move drag, which leaves
            // them floating.
            if session.hasChanges {
                landSelectionFloat(actionName: "Free Transform")
            } else {
                cancelSelectionFloat()
            }
            return
        }
        if session.hasChanges {
            commit("Free Transform", document: document)
        }
    }

    func cancelTransformSession() {
        guard let session = transformSession else { return }
        transformSession = nil
        activeGuides = []
        if let float = selectionFloat {
            // The session's base document predates the lift, so restoring it
            // also puts the floated pixels back where they came from.
            selectionFloat = nil
            selectedLayerID = float.sourceLayerID
        }
        setLiveDocument(session.baseDocument)
    }

    /// Mid-gesture ⌘Z: reverts a changed Free Transform to its
    /// initial transform but keeps the session — and its box — alive,
    /// Photoshop's behaviour. A second ⌘Z then cancels the session.
    func revertTransformSessionToInitial() {
        guard var session = transformSession else { return }
        session.currentTransform = session.initialTransform
        transformSession = session
        activeGuides = []
        setLiveLayerTransform(session.layerID, session.initialTransform)
    }

    /// Tool switches and layer switches commit a pending transform, like
    /// modern Photoshop.
    func commitAnyTransformSession() {
        if transformSession != nil { commitTransformSession() }
    }

    /// Every operation that changes the document (or exports it) first lands
    /// any in-flight transform, selection-transform, or text session.
    func commitPendingSessions() {
        commitAnyTransformSession()
        commitAnySelectionTransformSession()
        commitAnyTextSession()
        landSelectionFloat()
    }

    // MARK: - Floating selection (Move / Free Transform on a selection)

    /// A selection lifted off its layer and riding above it — Photoshop's
    /// floating selection (§5). The Move tool drags it and ⌘T transforms it,
    /// instead of either moving the whole layer.
    ///
    /// Landing it stamps the pixels back into a paint layer (one layer, as in
    /// Photoshop). An imported photo instead keeps every byte and gets a
    /// hide-mask, with the float staying a layer of its own: invariant 5 (a
    /// photo's pixels are never rewritten) applied to moving pixels, the same
    /// routing Cut uses.
    struct SelectionFloat {
        /// The document before the lift — Esc and unmoved drags restore it.
        let baseDocument: Document
        let baseSelection: SelectionState
        let sourceLayerID: UUID
        let floatLayerID: UUID
        let initialTransform: CGAffineTransform
        /// History name when the gesture lands without one of its own.
        let actionName: String
    }

    @Published private(set) var selectionFloat: SelectionFloat?

    // MARK: - Rasterize (the escape hatch from the never-paint rule)

    /// A passing note about something the app did on its own — rasterizing a
    /// layer so an edit could land. Deliberately not a dialog: the edit is
    /// what the user asked for, so it happens, and ⌘Z steps back through it.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    @Published private(set) var toast: Toast?
    private var toastDismissal: DispatchWorkItem?

    func showToast(_ message: String) {
        toastDismissal?.cancel()
        toast = Toast(message: message)
        let dismissal = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: dismissal)
    }

    func dismissToast() {
        toastDismissal?.cancel()
        toast = nil
    }

    /// Rasterizes a layer because the edit at hand needs its pixels, and says
    /// so in a toast. Its own history entry, so ⌘Z unwinds the edit and then
    /// the rasterize. Returns the layer as it now is.
    @discardableResult
    private func autoRasterize(_ layer: Layer, because reason: String) -> Layer? {
        rasterizeLayer(layer.id)
        guard let updated = document[layerID: layer.id], updated.isPaintable else { return nil }
        showToast("Rasterized “\(layer.name)” \(reason)")
        return updated
    }

    /// True for anything whose pixels are off limits: an imported photo, or a
    /// text/shape layer still driven by its spec.
    static func needsRasterize(_ layer: Layer) -> Bool {
        switch layer.kind {
        case .raster: return !layer.isPaintable
        // An adjustment has no pixels to rasterise — it IS its spec.
        case .adjustment: return false
        case .text, .shape: return true
        }
    }

    var canRasterizeSelectedLayer: Bool { selectedLayer.map(Self.needsRasterize) ?? false }

    /// Layer ▸ Rasterize Layer: turns a photo (or a text/shape layer) into
    /// ordinary paintable pixels, baking its transform into the grid. Undo
    /// brings the photo's own bytes straight back.
    ///
    /// The mask is kept as a mask, re-framed onto the new grid — rasterizing
    /// is about the pixels, and edits rasterize on their own now, so this must
    /// not quietly flatten someone's mask away.
    func rasterizeLayer(_ id: UUID) {
        commitPendingSessions()
        guard let layer = document[layerID: id], Self.needsRasterize(layer) else { return }
        let updated: Layer
        if case .raster = layer.kind {
            let bounds = layer.canvasBounds.integral
            guard bounds.width >= 1, bounds.height >= 1 else { return }
            // Baked at full opacity, without the mask, so opacity, blend,
            // clipping, style AND the mask stay where they belong.
            var solo = layer
            solo.opacity = 1
            solo.mask = nil
            guard let image = RenderEngine.shared.renderLayerRegion(
                solo, croppedTo: bounds, sixteenBit: layer.source.bitsPerComponent > 8) else { return }
            updated = Layer(id: layer.id, sourceID: UUID(), name: layer.name, source: image,
                            transform: CGAffineTransform(translationX: bounds.minX, y: bounds.minY),
                            opacity: layer.opacity, isVisible: layer.isVisible,
                            mask: layer.mask.flatMap { Self.maskReframed($0, of: layer, onto: bounds) },
                            isPaintable: true, kind: .raster, blendMode: layer.blendMode,
                            isClippedToBelow: layer.isClippedToBelow, groupID: layer.groupID,
                            effects: layer.effects)
        } else {
            // Text and shapes already carry their rasterization as `source`;
            // rasterizing stops it regenerating and lets pixels land on it, so
            // the same bytes keep the same identity.
            updated = Layer(id: layer.id, sourceID: layer.sourceID, name: layer.name,
                            source: layer.source, transform: layer.transform,
                            opacity: layer.opacity, isVisible: layer.isVisible, mask: layer.mask,
                            isPaintable: true, kind: .raster, blendMode: layer.blendMode,
                            isClippedToBelow: layer.isClippedToBelow, groupID: layer.groupID,
                            effects: layer.effects)
        }
        maskTargeted = false
        commit("Rasterize Layer", document: document.replacingLayer(updated))
    }

    /// Re-frames a mask onto a rasterized layer's new grid (canvas space).
    /// Mask rows are top-down in both the old grid and the new one, so drawing
    /// the old mask through source → canvas → new grid lines the two up.
    private static func maskReframed(_ mask: Mask, of layer: Layer, onto grid: CGRect) -> Mask? {
        let width = Int(grid.width), height = Int(grid.height)
        guard width > 0, height > 0, let image = mask.texture.cgImage else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: BrushyColorSpace.gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.translateBy(x: -grid.minX, y: -grid.minY)
            ctx.concatenate(layer.transform)
            ctx.draw(image, in: layer.sourceRect)
        }
        var texture = MaskTexture(width: width, height: height, fill: 0)
        texture.mutate { data in data = Data(buffer) }
        var reframed = mask
        reframed.texture = texture
        return reframed
    }

    /// Lifts the selection's pixels onto a temporary layer directly above
    /// their own, and returns it — nil when there is nothing liftable, in
    /// which case callers fall back to moving the whole layer.
    ///
    /// `cutting: false` leaves the source untouched, so ⌥-drag duplicates the
    /// pixels rather than moving them.
    @discardableResult
    func beginSelectionFloat(cutting: Bool = true) -> SelectionFloat? {
        // Pixels already floating keep floating: dragging again moves the same
        // pixels rather than cutting a fresh hole out of what just landed.
        if let existing = selectionFloat { return existing }
        // In Quick Mask a selection bounds the painting; it does not hold
        // pixels to drag. Falling through leaves Move dragging the layer.
        guard !quickMaskActive else { return nil }
        commitPendingSessions()
        guard let path = selection.path,
              let selected = selectedLayer, selectedLayerEffectivelyVisible else { return nil }
        // Moving part of a layer is a pixel edit, so a photo or text layer
        // rasterizes first and the pixels move within it. Masking the original
        // and leaving them in a new layer surprised more than it saved.
        var layer = selected
        if Self.needsRasterize(layer) {
            guard let ready = autoRasterize(layer, because: "to move the selection") else { return nil }
            layer = ready
        }
        guard let index = document.layerIndex(of: layer.id) else { return nil }
        let rect = path.boundingBoxOfPath.intersection(layer.canvasBounds).integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        // Baked at full opacity with the layer's opacity carried on the float
        // instead — the same split Copy uses (`writeCopy`), so the pixels
        // stay exact rather than being multiplied down twice.
        let deep = layer.source.bitsPerComponent > 8
        let texture = MaskFactory.selectionTexture(rect: rect, selection: selection,
                                                   featherCanvasPx: CGFloat(featherAmount))
        var bakeLayer = layer
        bakeLayer.opacity = 1
        guard let baked = RenderEngine.shared.renderLayerRegion(bakeLayer, croppedTo: rect,
                                                                selection: texture,
                                                                sixteenBit: deep) else { return nil }
        var floatLayer = Layer(name: "\(layer.name) selection", source: baked,
                               transform: CGAffineTransform(translationX: rect.minX, y: rect.minY),
                               opacity: layer.opacity, isPaintable: true,
                               blendMode: layer.blendMode)
        floatLayer.groupID = layer.groupID

        // The hole is always pixels: after the rasterize above, every layer
        // that reaches here has its own. ⌥-drag skips it, so the duplicate
        // lands in the pixels it came from.
        var holed = layer
        if cutting {
            guard layer.isPaintable,
                  let cut = Self.pixelsFilled(layer, path: path, color: nil,
                                              coverage: selectionCoverage(for: layer))
            else { return nil }
            holed = cut
        }

        var doc = document.replacingLayer(holed)
        doc.layers.insert(floatLayer, at: index + 1)
        let float = SelectionFloat(baseDocument: document, baseSelection: selection,
                                   sourceLayerID: layer.id, floatLayerID: floatLayer.id,
                                   initialTransform: floatLayer.transform,
                                   actionName: cutting ? "Move Selection" : "Duplicate Selection")
        selectionFloat = float
        setLiveDocument(doc)
        // The layer the pixels came from stays selected: the float is
        // scaffolding, and `panelRows` keeps it out of the panel entirely.
        return float
    }

    /// Lands a live float as exactly ONE history entry, the selection
    /// travelling with the pixels (Photoshop).
    ///
    /// The float stays alive across drags — releasing the mouse does not land
    /// it — so repeated moves and nudges push the same pixels around instead
    /// of re-cutting whatever they were dropped onto. It lands when its life
    /// ends: a new selection or deselect (hooked in `commit`), switching
    /// layers or tools, ⌘T's Return, saving, or any other document operation
    /// (`commitPendingSessions`).
    func landSelectionFloat(actionName: String? = nil) {
        guard let float = selectionFloat else { return }
        selectionFloat = nil
        guard let floatLayer = document[layerID: float.floatLayerID] else { return }
        // Canvas-space motion of the float: undo its lift position, apply
        // where it ended up.
        let moved = float.initialTransform.inverted().concatenating(floatLayer.transform)
        guard moved != .identity else {
            // Lifted but never moved: unwind rather than record a no-op.
            selectedLayerID = float.sourceLayerID
            setLiveDocument(float.baseDocument)
            return
        }
        var doc = document
        if let target = doc[layerID: float.sourceLayerID],
           let stamped = Self.stamping(floatLayer, into: target,
                                       canvasRect: document.canvasRect) {
            doc = doc.removingLayer(id: float.floatLayerID).replacingLayer(stamped)
            selectedLayerID = float.sourceLayerID
        }
        commit(actionName ?? float.actionName, document: doc,
               selection: float.baseSelection.transformed(by: moved))
    }

    /// Rows for the Layers panel. A floating selection is scaffolding the user
    /// never asked for — it lives in the document so the renderer and the move
    /// tool can see it — so it gets no row of its own, and the layer its
    /// pixels came from stays the selected one.
    var panelRows: [Document.PanelRow] {
        let rows = document.panelRows()
        guard let floatID = selectionFloat?.floatLayerID else { return rows }
        return rows.filter { $0.id != floatID }
    }

    /// The float layer's transform right now — the anchor a fresh drag or
    /// nudge starts from.
    var selectionFloatTransform: CGAffineTransform? {
        selectionFloat.flatMap { document[layerID: $0.floatLayerID]?.transform }
    }

    /// The selection outline to draw: while pixels float, the marching ants
    /// ride with them even though the committed selection hasn't moved yet.
    var liveSelectionPath: CGPath? {
        guard let float = selectionFloat, let path = float.baseSelection.path,
              let current = selectionFloatTransform else { return selection.path }
        var moved = float.initialTransform.inverted().concatenating(current)
        return path.copy(using: &moved) ?? path
    }

    /// Drops a float and restores the document from before the lift: Esc, and
    /// gestures that never moved (which must leave no history behind).
    func cancelSelectionFloat() {
        guard let float = selectionFloat else { return }
        selectionFloat = nil
        selectedLayerID = float.sourceLayerID
        setLiveDocument(float.baseDocument)
    }

    /// Draws a float's pixels into `layer`'s own grid — the paint-layer
    /// landing. Fresh sourceID: new pixels never reuse the old identity
    /// (invariant 4). Every non-pixel field is carried over explicitly, so a
    /// grouped, clipped or styled layer survives the stamp.
    /// Grows `layer`'s pixel grid so it covers `canvasRegion`, capped at the
    /// canvas, leaving every existing pixel exactly where it was.
    ///
    /// A layer's pixels live on a grid the size of its source image — a chunk
    /// pasted from somewhere else is only as big as the chunk — so painting,
    /// filling or dropping pixels past that edge would clip at it. Photoshop
    /// grows a layer to take them; so does this. The cap matters: nothing
    /// beyond the canvas is visible, and a grid that only ever grew would
    /// balloon with every edit.
    ///
    /// Returns the layer and the grid's new origin in the OLD source space
    /// (zero when nothing grew) — callers holding source-space coordinates,
    /// like a brush stroke, must shift them by it.
    static func grown(_ layer: Layer, toCover canvasRegion: CGRect,
                      canvasRect: CGRect) -> (layer: Layer, gridOrigin: CGPoint) {
        let unchanged = (layer: layer, gridOrigin: CGPoint.zero)
        guard layer.transform.isInvertible, layer.isPaintable else { return unchanged }
        let toSource = layer.transform.inverted()
        let wanted = canvasRegion.intersection(canvasRect)
        guard !wanted.isNull, !wanted.isEmpty else { return unchanged }
        let grid = layer.sourceRect.union(wanted.applying(toSource)).integral
        guard grid != layer.sourceRect, grid.width >= 1, grid.height >= 1,
              let ctx = CGContext(data: nil,
                                  width: Int(grid.width), height: Int(grid.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: BrushyColorSpace.displayP3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return unchanged
        }
        ctx.translateBy(x: -grid.minX, y: -grid.minY)
        ctx.draw(layer.source, in: layer.sourceRect)
        guard let image = ctx.makeImage() else { return unchanged }
        // The grid's origin moved; the transform absorbs the shift so every
        // existing pixel stays where it was on the canvas.
        let transform = CGAffineTransform(translationX: grid.minX, y: grid.minY)
            .concatenating(layer.transform)
        let grownLayer = Layer(id: layer.id, sourceID: UUID(), name: layer.name,
                               source: image, transform: transform,
                               opacity: layer.opacity, isVisible: layer.isVisible,
                               mask: layer.mask.map { maskShifted($0, from: layer.sourceRect, to: grid) },
                               isPaintable: true, kind: .raster,
                               blendMode: layer.blendMode, isClippedToBelow: layer.isClippedToBelow,
                               groupID: layer.groupID, effects: layer.effects)
        return (grownLayer, grid.origin)
    }

    private static func stamping(_ float: Layer, into layer: Layer,
                                 canvasRect: CGRect) -> Layer? {
        // Grow first, so pixels landing past the layer's edge are taken rather
        // than clipped there.
        let host = grown(layer, toCover: float.canvasBounds, canvasRect: canvasRect).layer
        guard host.transform.isInvertible,
              let ctx = CGContext(data: nil,
                                  width: host.source.width, height: host.source.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: BrushyColorSpace.displayP3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(host.source, in: host.sourceRect)
        ctx.saveGState()
        // float source → canvas → this layer's source grid.
        ctx.concatenate(float.transform.concatenating(host.transform.inverted()))
        ctx.setAlpha(CGFloat(float.opacity))
        ctx.draw(float.source, in: float.sourceRect)
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { return nil }
        return Layer(id: host.id, sourceID: UUID(), name: host.name,
                     source: image, transform: host.transform,
                     opacity: host.opacity, isVisible: host.isVisible, mask: host.mask,
                     isPaintable: true, kind: .raster,
                     blendMode: host.blendMode, isClippedToBelow: host.isClippedToBelow,
                     groupID: host.groupID, effects: host.effects)
    }

    /// Re-frames a mask onto a grown pixel grid, revealing (255) the strip
    /// that did not exist before. Mask rows are top-down while the source grid
    /// is y-up, so the row index flips (the classic place to get this wrong).
    private static func maskShifted(_ mask: Mask, from oldGrid: CGRect, to grid: CGRect) -> Mask {
        guard grid != oldGrid else { return mask }
        let old = mask.texture
        let width = Int(grid.width), height = Int(grid.height)
        let dx = Int(oldGrid.minX - grid.minX), dy = Int(oldGrid.minY - grid.minY)
        guard dx >= 0, dy >= 0, dx + old.width <= width, dy + old.height <= height else {
            return mask
        }
        var texture = MaskTexture(width: width, height: height, fill: 255)
        texture.mutate { data in
            data.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                old.data.withUnsafeBytes { source in
                    guard let from = source.bindMemory(to: UInt8.self).baseAddress else { return }
                    for row in 0..<old.height {
                        // Row → y-up in the old grid → y-up in the new → row.
                        let newRow = height - 1 - (old.height - 1 - row + dy)
                        (base + newRow * width + dx).update(from: from + row * old.width,
                                                            count: old.width)
                    }
                }
            }
        }
        var grown = mask
        grown.texture = texture
        return grown
    }

    // MARK: - Crop tool

    private func toolDidChange(from oldTool: Tool) {
        guard oldTool != activeTool else { return }
        commitPendingSessions()
        previewSelectionPath = nil
        previewGradientLine = nil
        activeGuides = []
        if activeTool == .crop {
            cropSession = CropSession(rect: document.canvasRect)
        } else if oldTool == .crop {
            cropSession = nil
        }
    }

    var cropAspectRatio: CGSize? {
        guard cropAspectLocked,
              let w = Double(cropAspectW), let h = Double(cropAspectH),
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    func updateCropSession(_ session: CropSession) {
        cropSession = session
    }

    func resetCropSession() {
        guard activeTool == .crop else { return }
        cropSession = CropSession(rect: document.canvasRect)
    }

    func commitCropSession() {
        guard let session = cropSession else { return }
        endQuickMaskBeforeCanvasChange()
        var rect = session.rect.standardized
        rect = CGRect(x: rect.origin.x.rounded(), y: rect.origin.y.rounded(),
                      width: max(1, rect.width.rounded()), height: max(1, rect.height.rounded()))
        guard rect != document.canvasRect else { return }
        commit("Crop", document: document.cropped(to: rect))
        cropSession = CropSession(rect: document.canvasRect)
    }

    var canCropToSelection: Bool { selection.cropRect(in: document.canvasRect) != nil }

    /// Image > Crop (⌘K): crops the canvas to the selection's bounds without
    /// switching tools. Same non-destructive `Document.cropped(to:)` as the
    /// crop tool; the selection survives, shifted with the content, so it
    /// still outlines the same pixels (Photoshop keeps it too).
    func cropToSelection() {
        guard !blockedByQuickMask else { return }
        commitPendingSessions()
        guard let rect = selection.cropRect(in: document.canvasRect),
              rect != document.canvasRect else { return }
        let shift = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        commit("Crop", document: document.cropped(to: rect),
               selection: selection.transformed(by: shift))
        if activeTool == .crop {
            cropSession = CropSession(rect: document.canvasRect)
        }
    }

    // MARK: - Selection (Stage A)

    /// Commits a new selection, saying so when the change could not carry the
    /// selection's coverage channel with it (Select ▸ Modify, a boolean, a
    /// scaled Transform Selection). Dropping it is the deliberate
    /// simplification — rebuilding a soft edge through path morphology is not
    /// worth what it costs — but it must never happen silently.
    private func commitSelection(_ actionName: String, _ newSelection: SelectionState) {
        let losesAlpha = selection.hasAlpha && !newSelection.hasAlpha && !newSelection.isEmpty
        commit(actionName, document: document, selection: newSelection)
        if losesAlpha {
            showToast("\(actionName) made the selection's soft edges hard")
        }
    }

    /// True (with a hint) for the few commands that cannot mean anything while
    /// the selection is being painted: the ones that would take pixels out of
    /// the document or resize the canvas underneath a canvas-sized channel.
    /// Ordinary selecting is NOT blocked — a selection made in Quick Mask
    /// limits where painting the channel lands, exactly as in Photoshop.
    private var blockedByQuickMask: Bool {
        guard quickMaskActive else { return false }
        brushHint = "Quick Mask is on — press Q to turn it back into a selection"
        return true
    }

    func combineSelection(_ path: CGPath, mode: SelectionState.CombineMode) {
        // A new selection ends a float's life: it lands first, as its own
        // history entry (Photoshop).
        landSelectionFloat()
        commitAnySelectionTransformSession()
        previewSelectionPath = nil
        let newSelection = selection.combining(path, mode: mode)
        guard newSelection != selection else { return }
        let name: String
        switch mode {
        case .replace: name = "Select"
        case .add: name = "Add to Selection"
        case .subtract: name = "Subtract from Selection"
        }
        commitSelection(name, newSelection)
    }

    /// A selection that arrived as pixels (⌘-clicked layer alpha, Quick Mask):
    /// it replaces whatever was selected, coverage and all.
    func replaceSelection(_ newSelection: SelectionState, actionName: String) {
        landSelectionFloat()
        commitAnySelectionTransformSession()
        previewSelectionPath = nil
        guard newSelection != selection else { return }
        commit(actionName, document: document, selection: newSelection)
    }

    func deselect() {
        landSelectionFloat()
        commitAnySelectionTransformSession()
        previewSelectionPath = nil
        guard !selection.isEmpty else { return }
        commit("Deselect", document: document, selection: .empty)
    }

    func invertSelection() {
        // In Quick Mask with nothing selected, Inverse inverts the channel —
        // the mask IS the selection then. With a selection up it means what it
        // always means, and inverts that instead.
        if let texture = quickMask, selection.isEmpty {
            var inverted = texture
            inverted.mutate { data in
                data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    for index in 0..<raw.count { bytes[index] = 255 &- bytes[index] }
                }
            }
            quickMask = inverted
            commit("Inverse", document: document)
            return
        }
        landSelectionFloat()
        commitAnySelectionTransformSession()
        guard !selection.isEmpty else { return }
        commitSelection("Inverse", selection.inverted(in: document.canvasRect))
    }

    func selectAll() {
        landSelectionFloat()
        commitAnySelectionTransformSession()
        let path = CGPath(rect: document.canvasRect, transform: nil)
        commit("Select All", document: document,
               selection: SelectionState.empty.combining(path, mode: .replace))
    }

    // MARK: - Quick Mask (Q)

    var quickMaskActive: Bool { quickMask != nil }

    /// Q: into the mode and back out again.
    func toggleQuickMask() {
        if quickMaskActive { exitQuickMask() } else { enterQuickMask() }
    }

    /// The channel is canvas-sized and canvas-aligned, so a canvas that
    /// changes size underneath it would leave it misaligned: the mode ends
    /// first, handing back an ordinary selection that crops and scales with
    /// the document like any other.
    private func endQuickMaskBeforeCanvasChange() {
        guard quickMaskActive else { return }
        exitQuickMask()
    }

    /// Turns the selection into a channel to paint. With nothing selected the
    /// channel starts fully selected (255) — "no selection" already means
    /// "the whole layer" everywhere else, and Photoshop opens Quick Mask with
    /// no red for the same reason.
    func enterQuickMask() {
        commitPendingSessions()
        guard quickMask == nil else { return }
        let rect = document.canvasRect.integral
        let width = rect.width.rounded().saturatingInt
        let height = rect.height.rounded().saturatingInt
        guard width >= 1, height >= 1 else { return }
        quickMask = selection.isEmpty ? MaskTexture(width: width, height: height, fill: 255)
                                      : selection.coverageTexture(over: rect)
        // The selection lives in the channel now; the ants come back on exit.
        commit("Quick Mask", document: document, selection: .empty)
        showToast("Quick Mask — paint with black to mask, white to select. Q to finish")
    }

    /// Traces the channel back into a selection: the 50% contour becomes the
    /// ants and the channel itself stays on as the selection's coverage, so a
    /// soft-painted edge survives into Fill, Copy and Add Layer Mask.
    func exitQuickMask() {
        guard quickMask != nil else { return }
        commitPendingSessions()
        // A stroke landed by `commitPendingSessions` may have replaced it.
        guard let texture = quickMask else { return }
        let rect = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let restored = SelectionState.coverage(texture, rect: rect)
        quickMask = nil
        commit("Quick Mask Selection", document: document, selection: restored)
    }

    // MARK: - Adjustment layers

    /// Non-nil while the adjustment editor is open (RootView presents it).
    struct AdjustmentRequest: Identifiable {
        /// The layer being edited.
        let id: UUID
    }

    @Published var adjustmentRequest: AdjustmentRequest?

    /// Layer ▸ New Adjustment Layer: lands above the selected layer, so it
    /// corrects everything below it within its group (Photoshop), and opens
    /// its editor straight away.
    func addAdjustmentLayer(_ spec: AdjustmentSpec) {
        commitPendingSessions()
        guard let source = AdjustmentSpec.placeholderSource() else { return }
        let layer = Layer(name: spec.displayName, source: source, kind: .adjustment(spec))
        insertLayerAboveSelection(layer)
        commit("New \(spec.displayName) Layer", document: document)
        adjustmentRequest = AdjustmentRequest(id: layer.id)
    }

    /// Live while a slider moves (`transient`), one history entry when it is
    /// let go — the same contract the shape and opacity editors follow.
    func updateAdjustment(_ layerID: UUID, spec: AdjustmentSpec, transient: Bool) {
        guard var layer = document[layerID: layerID], layer.kind.adjustmentSpec != nil else { return }
        layer.kind = .adjustment(spec)
        let updated = document.replacingLayer(layer)
        if transient {
            setLiveDocument(updated)
        } else {
            commit(spec.displayName, document: updated)
        }
    }

    var editableAdjustmentLayerID: UUID? {
        guard let layer = selectedLayer, layer.kind.adjustmentSpec != nil else { return nil }
        return layer.id
    }

    func requestAdjustmentEdit() {
        guard let id = editableAdjustmentLayerID else { return }
        commitPendingSessions()
        adjustmentRequest = AdjustmentRequest(id: id)
    }

    // MARK: - Layer via Copy / Cut, and loading a layer as a selection

    /// Photoshop's ⌘J / ⇧⌘J: the selected pixels become a layer of their own,
    /// left in place (copy) or taken out of the source (cut). With nothing
    /// selected, ⌘J duplicates the whole layer, exactly as Photoshop does.
    func layerViaCopy() { layerFromSelection(cutting: false) }
    func layerViaCut() { layerFromSelection(cutting: true) }

    var canMakeLayerFromSelection: Bool {
        selectedLayerEffectivelyVisible && !selection.isEmpty
    }

    private func layerFromSelection(cutting: Bool) {
        guard !blockedByQuickMask else { return }
        commitPendingSessions()
        guard let path = selection.path else {
            // Photoshop's ⌘J with no selection: duplicate the layer.
            if !cutting { duplicateSelectedLayer() }
            return
        }
        guard var layer = selectedLayer, selectedLayerEffectivelyVisible,
              layer.kind.adjustmentSpec == nil else { return }
        // Copying only READS the pixels, so a smart layer stays smart. Cutting
        // takes them out of it, which needs its own pixels first.
        if cutting, Self.needsRasterize(layer) {
            guard let ready = autoRasterize(layer, because: "to cut the selection out of it") else {
                return
            }
            layer = ready
        }
        guard let index = document.layerIndex(of: layer.id) else { return }
        let rect = path.boundingBoxOfPath.intersection(layer.canvasBounds).integral
        guard rect.width >= 1, rect.height >= 1 else { return }

        // Baked at full opacity with the layer's opacity carried across, the
        // same split Copy and the floating selection use.
        let deep = layer.source.bitsPerComponent > 8
        let texture = MaskFactory.selectionTexture(rect: rect, selection: selection,
                                                   featherCanvasPx: CGFloat(featherAmount))
        var bakeLayer = layer
        bakeLayer.opacity = 1
        guard let baked = RenderEngine.shared.renderLayerRegion(bakeLayer, croppedTo: rect,
                                                                selection: texture,
                                                                sixteenBit: deep) else { return }
        var lifted = Layer(name: cutting ? "Layer via Cut" : "Layer via Copy", source: baked,
                           transform: CGAffineTransform(translationX: rect.minX, y: rect.minY),
                           opacity: layer.opacity, isPaintable: true, blendMode: layer.blendMode)
        lifted.groupID = layer.groupID

        var doc = document
        if cutting {
            guard let holed = Self.pixelsFilled(layer, path: path, color: nil,
                                                coverage: selectionCoverage(for: layer))
            else { return }
            doc = doc.replacingLayer(holed)
        }
        doc.layers.insert(lifted, at: index + 1)
        selectedLayerID = lifted.id
        maskTargeted = false
        // The pixels are a layer now, so the selection has done its job —
        // Photoshop drops it too.
        commit(cutting ? "Layer via Cut" : "Layer via Copy", document: doc, selection: .empty)
    }

    /// ⌘-click a layer's thumbnail: select its pixels (Photoshop's "load as
    /// selection"). The layer's alpha becomes the selection's coverage, so a
    /// feathered or antialiased layer comes back exactly as soft as it is; the
    /// traced 50% contour is what the ants draw.
    func selectPixels(of layerID: UUID) {
        guard !blockedByQuickMask else { return }
        commitPendingSessions()
        guard let layer = document[layerID: layerID], layer.kind.adjustmentSpec == nil,
              let pixels = pixelBuffer(RenderEngine.shared.layerImage(layer,
                                                                      outputTransform: .identity))
        else { return }
        var coverage = Data(count: pixels.width * pixels.height)
        for index in 0..<(pixels.width * pixels.height) {
            coverage[index] = pixels.data[index * 4 + 3]
        }
        let texture = MaskTexture(width: pixels.width, height: pixels.height, data: coverage)
        let rect = document.canvasRect.integral
        let loaded = SelectionState.coverage(texture, rect: rect)
        guard !loaded.isEmpty else {
            brushHint = "“\(layer.name)” has no pixels inside the canvas to select"
            return
        }
        replaceSelection(loaded, actionName: "Select")
    }

    // MARK: - Magic Wand

    /// One wand click: find the matching region and combine it into the
    /// selection, as one history entry like any other selection gesture.
    func selectByWand(at canvasPoint: CGPoint, mode: SelectionState.CombineMode) {
        commitPendingSessions()
        brushHint = nil
        guard let pixels = wandPixels() else {
            brushHint = "Select a layer to use the wand on"
            return
        }
        // Canvas space is y-up, the buffer is row-0-at-top (§4).
        let x = Int(canvasPoint.x.rounded(.down))
        let row = pixels.height - 1 - Int(canvasPoint.y.rounded(.down))
        guard x >= 0, row >= 0, x < pixels.width, row < pixels.height else { return }

        let region = MagicWand.region(in: pixels, seedX: x, seedY: row,
                                      tolerance: Int(wandTolerance.rounded()),
                                      contiguous: wandContiguous)
        let path = MagicWand.path(from: region, width: pixels.width, height: pixels.height)
        guard !path.isEmpty else { return }
        combineSelection(path, mode: mode)
    }

    /// The canvas as RGBA8 for the wand to search: the selected layer alone,
    /// or the whole composite with Sample All Layers on (Photoshop's option).
    private func wandPixels() -> MagicWand.Pixels? {
        let image: CIImage
        if wandSamplesAllLayers {
            image = RenderEngine.shared.compositeImage(for: document)
        } else {
            guard let layer = selectedLayer, selectedLayerEffectivelyVisible,
                  layer.kind.adjustmentSpec == nil else { return nil }
            image = RenderEngine.shared.layerImage(layer, outputTransform: .identity)
        }
        return pixelBuffer(image)
    }

    /// `image` rasterized over the canvas rect as RGBA8, row 0 at top — what
    /// the wand searches and what "load as selection" thresholds.
    private func pixelBuffer(_ image: CIImage) -> MagicWand.Pixels? {
        let rect = document.canvasRect.integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        guard let cgImage = RenderEngine.shared.context.createCGImage(
            image, from: rect, format: .RGBA8, colorSpace: BrushyColorSpace.sRGB) else { return nil }
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: BrushyColorSpace.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return MagicWand.Pixels(data: data, width: width, height: height)
    }

    // MARK: - Select > Modify

    // Selection-only commits, like `invertSelection()`: the document rides
    // along unchanged, empty selections are no-ops with no history entry, and
    // each command is exactly one undo step. The geometry lives on
    // `SelectionState` (Selection.swift), which also clamps radii to the
    // feather field's 1...250 px range.

    func growSelection(by radius: CGFloat) {
        landSelectionFloat()
        commitAnySelectionTransformSession()
        guard !selection.isEmpty else { return }
        commitSelection("Grow Selection", selection.grown(by: radius))
    }

    /// Contracting past the shape's half-width legitimately commits `.empty` —
    /// the user asked for it, so it *is* a history entry.
    func contractSelection(by radius: CGFloat) {
        landSelectionFloat()
        commitAnySelectionTransformSession()
        guard !selection.isEmpty else { return }
        commitSelection("Contract Selection", selection.contracted(by: radius))
    }

    func borderSelection(width: CGFloat) {
        landSelectionFloat()
        commitAnySelectionTransformSession()
        guard !selection.isEmpty else { return }
        commitSelection("Border Selection", selection.bordered(width: width))
    }

    // MARK: - Transform Selection (Select menu; gestures on the selection)

    /// Select > Transform Selection: a lightweight parallel of Cmd+T. The
    /// document is never touched — the overlay previews the transformed
    /// outline from the session, and only commit changes the selection.
    func enterSelectionTransformMode() {
        commitPendingSessions()
        guard let session = SelectionTransformSession(selection: selection) else { return }
        selectionTransformSession = session
    }

    func updateSelectionTransformSession(_ transform: CGAffineTransform) {
        guard var session = selectionTransformSession else { return }
        session.currentTransform = transform
        selectionTransformSession = session
    }

    /// Return / double-click. One history entry; an untouched box commits
    /// nothing.
    func commitSelectionTransformSession() {
        guard let session = selectionTransformSession else { return }
        selectionTransformSession = nil
        guard session.hasChanges else { return }
        commitSelection("Transform Selection",
                        selection.transformed(by: session.currentTransform))
    }

    /// Esc. The committed selection was never changed mid-session, so
    /// dropping the session is the whole cancel.
    func cancelSelectionTransformSession() {
        selectionTransformSession = nil
    }

    /// Selection-changing ops (and `commitPendingSessions()`) land a live
    /// selection transform first, exactly like tool switches land Cmd+T.
    func commitAnySelectionTransformSession() {
        if selectionTransformSession != nil { commitSelectionTransformSession() }
    }

    // MARK: - Dragging the outline (marquee/lasso tools)

    /// Photoshop: with a selection tool active, a drag that starts INSIDE the
    /// selection moves the outline, not the pixels — the ants slide over the
    /// image and nothing in the document changes.
    ///
    /// Live like a layer drag: `previewSelectionPath` shows the moved outline
    /// mid-drag and `moveSelectionOutline` commits the whole gesture as one
    /// history entry. A whole-pixel translation, so a coverage channel rides
    /// along untouched.
    func selectionContains(_ canvasPoint: CGPoint) -> Bool {
        guard let path = selection.path, selectionFloat == nil,
              selectionTransformSession == nil else { return false }
        return path.contains(canvasPoint, using: .winding)
    }

    /// True while the ants themselves are being dragged — the overlay then
    /// draws the preview outline only, not the one it came from.
    @Published private(set) var movingSelectionOutline = false

    func previewSelectionOutline(movedBy delta: CGPoint) {
        guard let path = selection.path else { return }
        var shift = CGAffineTransform(translationX: delta.x.rounded(), y: delta.y.rounded())
        previewSelectionPath = path.copy(using: &shift)
        movingSelectionOutline = true
    }

    func moveSelectionOutline(by delta: CGPoint) {
        previewSelectionPath = nil
        movingSelectionOutline = false
        let shift = CGAffineTransform(translationX: delta.x.rounded(), y: delta.y.rounded())
        guard !selection.isEmpty, shift != .identity else { return }
        commit("Move Selection Outline", document: document,
               selection: selection.transformed(by: shift))
    }

    // MARK: - Select Subject (Select menu; owner-requested exception)

    /// Superseding token for the in-flight Select Subject request: a
    /// completion only lands while it is still the newest request.
    private var subjectRequestGeneration = 0

    /// Select → Select Subject: Vision's foreground-instance mask on the
    /// *selected layer's own source* (not the flattened composite),
    /// vectorized by `SubjectMask` into an ordinary selection so the
    /// result composes with feather, Add Layer Mask, Cut, Paste Into, and
    /// Select → Modify. The request runs off the main thread — `brushHint`
    /// carries the in-progress affordance — and the result is committed back
    /// on the main thread as one "Select Subject" history entry, or dropped
    /// if the document moved on underneath it.
    func selectSubject() {
        commitPendingSessions()
        guard let layer = selectedLayer, selectedLayerEffectivelyVisible else { return }
        subjectRequestGeneration += 1
        let generation = subjectRequestGeneration
        let layerID = layer.id
        let sourceID = layer.sourceID
        let source = layer.source
        brushHint = "Finding subject…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SubjectMask.subjectPath(in: source) }
            DispatchQueue.main.async {
                self?.finishSelectSubject(result, generation: generation,
                                          layerID: layerID, sourceID: sourceID)
            }
        }
    }

    private func finishSelectSubject(_ result: Result<CGPath, Error>,
                                     generation: Int, layerID: UUID,
                                     sourceID: UUID) {
        // Superseded by a newer request: that one owns the hint/error surfaces.
        guard generation == subjectRequestGeneration else { return }
        brushHint = nil
        // Stale guards: the layer must still be the selected, visible layer
        // with the pixels it had at kickoff, and no modal session may have
        // started meanwhile — dropping the result beats committing into a
        // document the user has moved past (or force-landing a session they
        // opened while Vision was thinking). The layer's *transform* is
        // deliberately re-read fresh: moving the layer mid-request lands the
        // selection where the layer is now.
        guard transformSession == nil, selectionTransformSession == nil,
              textSession == nil,
              selectedLayerID == layerID,
              let layer = document[layerID: layerID],
              layer.sourceID == sourceID,
              document.isEffectivelyVisible(layerID: layerID) else { return }
        switch result {
        case .success(let sourcePath):
            let canvasPath = CGMutablePath()
            canvasPath.addPath(sourcePath, transform: layer.transform)
            let newSelection = SelectionState.empty.combining(canvasPath, mode: .replace)
            guard !newSelection.isEmpty else {
                lastErrorMessage = "No subject was found on “\(layer.name)”."
                return
            }
            previewSelectionPath = nil
            guard newSelection != selection else { return }
            commit("Select Subject", document: document, selection: newSelection)
        case .failure(let error as SubjectMask.Failure) where error == .noSubject:
            lastErrorMessage = "No subject was found on “\(layer.name)”."
        case .failure(let error):
            lastErrorMessage = "Select Subject failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Modal-session undo (defect D)

    /// ⌘Z / ⇧⌘Z while a modal canvas gesture is live applies to the gesture,
    /// never to committed history behind it:
    /// - Free Transform: a changed box reverts to its initial transform (and
    ///   stays up); an unchanged one cancels.
    /// - Transform Selection: the same, with identity as "initial".
    /// - Crop: an adjusted rect resets to the canvas rect, like Esc; an
    ///   untouched rect falls through to normal history undo.
    /// Redo during a live session is consumed as a no-op — redoing a document
    /// step behind an uncommitted gesture would be the same bug in reverse.
    /// Returns false when no session claims the key, so the caller lets the
    /// Edit menu's normal undo/redo proceed.
    func handleUndoKeyDuringModalSession(redo: Bool) -> Bool {
        if let session = transformSession {
            if !redo {
                if session.hasChanges {
                    revertTransformSessionToInitial()
                } else {
                    cancelTransformSession()
                }
            }
            return true
        }
        if let session = selectionTransformSession {
            if !redo {
                if session.hasChanges {
                    updateSelectionTransformSession(.identity)
                } else {
                    cancelSelectionTransformSession()
                }
            }
            return true
        }
        // Floating pixels: ⌘Z drops the float back where it came from, the
        // same "the gesture first, then history" rule the sessions above use.
        if selectionFloat != nil {
            if !redo { cancelSelectionFloat() }
            return true
        }
        if activeTool == .crop, let session = cropSession,
           session.rect.standardized != document.canvasRect {
            if !redo { resetCropSession() }
            return true
        }
        return false
    }

    // MARK: - Masks (Stage A)

    func addLayerMask() {
        guard var layer = selectedLayer, layer.mask == nil else { return }
        commitPendingSessions()
        let texture = MaskFactory.maskTexture(for: layer,
                                              selection: selection,
                                              featherCanvasPx: CGFloat(featherAmount))
        layer.mask = Mask(texture: texture, isEnabled: true)
        maskTargeted = true
        // Photoshop consumes the selection when it becomes a mask.
        commit("Add Layer Mask", document: document.replacingLayer(layer), selection: .empty)
    }

    func deleteLayerMask() {
        commitPendingSessions()
        guard var layer = selectedLayer, layer.mask != nil else { return }
        layer.mask = nil
        maskTargeted = false
        commit("Delete Layer Mask", document: document.replacingLayer(layer))
    }

    func toggleMaskEnabled(_ id: UUID) {
        commitPendingSessions()
        guard var layer = document[layerID: id], var mask = layer.mask else { return }
        mask.isEnabled.toggle()
        layer.mask = mask
        commit(mask.isEnabled ? "Enable Layer Mask" : "Disable Layer Mask",
               document: document.replacingLayer(layer))
    }

    // MARK: - View

    func zoomIn() { viewport.stepZoom(1, canvasSize: document.canvasSize) }
    func zoomOut() { viewport.stepZoom(-1, canvasSize: document.canvasSize) }
    func zoomToFit() { viewport.fit(canvasSize: document.canvasSize) }
    func zoomToActualSize() { viewport.actualSize(canvasSize: document.canvasSize) }

    // MARK: - Guides & grid

    /// The guides snapping may target: hidden guides never snap (Photoshop
    /// parity — ⌘; turns them fully off, not just invisible).
    var snapGuides: [Guide] {
        guidesVisible ? document.guides : []
    }

    /// The grid lattice snapping may target — only while the grid is shown
    /// (Photoshop greys out Snap To Grid when the grid is hidden). Snapping
    /// targets the subdivision lines, like Photoshop. Anchored at the canvas
    /// top-left (origin.y = canvas height), matching the top-down rulers.
    var snapGrid: SmartGuides.Grid? {
        guard gridVisible, gridSpacing > 0 else { return nil }
        let step = CGFloat(gridSpacing) / CGFloat(max(1, gridSubdivisions))
        guard step >= 0.01 else { return nil }
        return SmartGuides.Grid(step: step,
                                origin: CGPoint(x: 0, y: document.canvasSize.height))
    }

    /// Mouse-up half of a guide drag (add / move / remove / ⌥ axis flip): the
    /// controller live-drags through `setLiveDocument` and lands the whole
    /// gesture here as one history entry. Cancelled or unchanged gestures pass
    /// a document equal to the drag's base, which `commit` dissolves without
    /// touching history.
    func commitGuideDrag(_ doc: Document, actionName: String) {
        commit(actionName, document: doc)
    }

    /// View → Clear Guides. Works while guides are locked, like Photoshop —
    /// the lock protects against accidental *drags*, not an explicit command.
    func clearGuides() {
        commitPendingSessions()
        guard !document.guides.isEmpty else { return }
        commit("Clear Guides", document: document.clearingGuides())
    }

    // MARK: - Brush & eraser (Stage B)

    /// Where a stroke would land right now: the targeted mask, a paint
    /// layer's pixels, or a layer that has to be rasterized to take them.
    private enum StrokeTargetResolution {
        case mask(Layer)
        case paint(Layer)
        /// A photo or a text/shape layer: the edit rasterizes it first.
        case needsRasterize(Layer)
        /// Quick Mask is on: the stroke paints the selection, not the document.
        case quickMask(MaskTexture)
        case blocked(String)
    }

    private func resolveStrokeTarget(eraser: Bool) -> StrokeTargetResolution {
        // Quick Mask outranks everything: in that mode the canvas is the
        // channel, whatever layer happens to be selected.
        if let texture = quickMask { return .quickMask(texture) }
        guard let layer = selectedLayer else {
            return .blocked("Select a layer to paint on")
        }
        guard selectedLayerEffectivelyVisible else {
            return .blocked("The selected layer is hidden")
        }
        guard layer.kind.adjustmentSpec == nil else {
            return .blocked("“\(layer.name)” is an adjustment — it has no pixels to paint on")
        }
        // Only an explicitly targeted mask takes paint — clicking the mask
        // thumbnail in the panel is what targets it. Otherwise pixels are
        // what the user is aiming at, and the layer rasterizes to take them:
        // routing the stroke into a mask instead is the kind of quiet
        // substitution that surprises more than it saves. `eraser` no longer
        // changes where a stroke lands.
        if maskTargeted, layer.mask != nil {
            return .mask(layer)
        }
        if layer.isPaintable {
            return .paint(layer)
        }
        return .needsRasterize(layer)
    }

    var brushTargetDescription: String? {
        if let hint = brushHint { return hint }
        guard activeTool == .brush || activeTool == .eraser else { return nil }
        // A selection is a stencil for paint, so say so — a stroke that lands
        // nowhere because the selection is off-screen is otherwise a mystery.
        let within = selection.isEmpty ? "" : ", inside the selection"
        switch resolveStrokeTarget(eraser: activeTool == .eraser) {
        case .mask(let layer):
            return "Painting mask of “\(layer.name)” — black hides, white reveals\(within)"
        case .paint(let layer): return "Painting “\(layer.name)”\(within)"
        case .needsRasterize(let layer): return "Painting will rasterize “\(layer.name)”"
        case .quickMask: return "Painting the Quick Mask — black masks, white selects\(within)"
        case .blocked(let reason): return reason
        }
    }

    /// The layer a stroke will paint into, with its pixel grid grown to the
    /// canvas first. The stroke's coverage buffer is sized from this grid, so
    /// the growth has to happen before the stroke starts — otherwise a layer
    /// the size of a pasted chunk is a window you cannot paint outside of.
    /// Growth rides along in the stroke's own history entry.
    private func paintable(_ layer: Layer) -> Layer {
        let grown = Self.grown(layer, toCover: document.canvasRect,
                               canvasRect: document.canvasRect).layer
        guard grown.sourceID != layer.sourceID else { return layer }
        setLiveDocument(document.replacingLayer(grown))
        return grown
    }

    /// The active selection as coverage over a layer's own grid: a selection
    /// is a mask, so the brush and eraser paint inside it and nowhere else
    /// (Photoshop). nil with no selection — the overwhelmingly common case,
    /// which then costs nothing. Same `MaskFactory` call Add Layer Mask makes,
    /// so feather and a coverage channel arrive here already accounted for.
    private func strokeSelectionClip(for layer: Layer) -> [UInt8]? {
        guard !selection.isEmpty else { return nil }
        return [UInt8](MaskFactory.maskTexture(for: layer, selection: selection,
                                               featherCanvasPx: CGFloat(featherAmount)).data)
    }

    /// The same coverage for the canvas-aligned Quick Mask channel: a
    /// selection made while the mask is up limits where painting, filling and
    /// gradients land on it, exactly as it limits painting a layer.
    private func quickMaskSelectionCoverage(width: Int, height: Int) -> MaskTexture? {
        guard !selection.isEmpty else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        return MaskFactory.selectionTexture(rect: rect, selection: selection,
                                            featherCanvasPx: CGFloat(featherAmount))
    }

    func beginBrushStroke(at canvasPoint: CGPoint, eraser: Bool) {
        commitPendingSessions()
        brushHint = nil
        let layer: Layer
        let targetsMask: Bool
        switch resolveStrokeTarget(eraser: eraser) {
        case .blocked(let reason):
            brushHint = reason
            return
        case .quickMask(let texture):
            // The channel is canvas-sized and canvas-aligned, so there is no
            // layer transform to go through. The eraser removes mask (white)
            // here rather than adding it: in Quick Mask the red IS the paint.
            quickMaskStrokeBase = texture
            strokeCanvasToLocal = .identity
            activeStroke = BrushStroke(
                target: .quickMask,
                isEraser: eraser,
                color: foregroundColor,
                maskValue: eraser ? 255 : Self.luminance255(of: foregroundColor),
                opacityCeiling: brushOpacity / 100,
                radius: CGFloat(brushSize) / 2,
                hardness: brushHardness / 100,
                targetWidth: texture.width,
                targetHeight: texture.height,
                selectionClip: quickMaskSelectionCoverage(width: texture.width,
                                                          height: texture.height)
                    .map { [UInt8]($0.data) })
            continueBrushStroke(to: canvasPoint)
            return
        case .needsRasterize(let target):
            // The stroke lands on this very click: rasterize, say so, paint.
            guard let ready = autoRasterize(target, because: eraser ? "to erase it"
                                                                   : "to paint on it") else { return }
            layer = paintable(ready)
            targetsMask = false
        case .mask(let target):
            layer = target
            targetsMask = true
            maskTargeted = true
        case .paint(let target):
            layer = paintable(target)
            targetsMask = false
        }
        guard layer.transform.isInvertible else { return }
        strokeCanvasToLocal = layer.transform.inverted()
        let (sx, sy) = layer.transform.scaleComponents
        let localRadius = (CGFloat(brushSize) / 2) / max((sx + sy) / 2, 1e-4)

        let target: BrushStroke.Target = targetsMask ? .mask(layerID: layer.id)
                                                     : .paintLayer(layerID: layer.id)
        activeStroke = BrushStroke(
            target: target,
            isEraser: eraser,
            color: foregroundColor,
            maskValue: eraser ? 0 : Self.luminance255(of: foregroundColor),
            opacityCeiling: brushOpacity / 100,
            radius: localRadius,
            hardness: brushHardness / 100,
            targetWidth: layer.source.width,
            targetHeight: layer.source.height,
            selectionClip: strokeSelectionClip(for: layer))
        continueBrushStroke(to: canvasPoint)
    }

    private var lastStrokePreviewTime: CFAbsoluteTime = 0
    /// The Quick Mask channel as it was when the current stroke began. Each
    /// frame re-composites the whole accumulated stroke from it (dirty rect
    /// only, on the CPU — `StrokePreview.applied(to:)`), so the live channel IS
    /// the preview: no second preview path to keep in step, and the red overlay
    /// shows exactly what will be committed.
    private var quickMaskStrokeBase: MaskTexture?

    func continueBrushStroke(to canvasPoint: CGPoint) {
        guard activeStroke != nil else { return }
        activeStroke?.extend(toLocal: canvasPoint.applying(strokeCanvasToLocal))
        // Mouse events arrive at 60–120Hz; building the preview image is the
        // expensive part, so cap it near display rate. The bake at stroke end
        // always uses the complete coverage.
        let now = CFAbsoluteTimeGetCurrent()
        // Deliberately NOT `let stroke = activeStroke`: that copy keeps the
        // stroke's canvas-sized coverage buffer referenced, so the mutation
        // below would copy it on write — a canvas-sized memcpy per event.
        if let base = quickMaskStrokeBase, activeStroke?.targetsQuickMask == true {
            guard quickMask == nil || now - lastStrokePreviewTime >= 0.012 else { return }
            lastStrokePreviewTime = now
            // Only what the last events actually touched, composited from the
            // pre-stroke channel — so the cost of a frame follows the pointer's
            // movement, not the length of the stroke so far.
            if let preview = activeStroke?.pendingPreview() {
                quickMask = preview.applied(to: quickMask ?? base, from: base)
            }
            return
        }
        if strokePreview == nil || now - lastStrokePreviewTime >= 0.012 {
            lastStrokePreviewTime = now
            strokePreview = activeStroke?.preview()
        }
    }

    /// Bakes the stroke and pushes exactly one undo step (: a full stroke,
    /// mouse-down to mouse-up, is one step — including any auto-created mask).
    func endBrushStroke() {
        guard let stroke = activeStroke else { return }
        activeStroke = nil
        strokePreview = nil
        guard let preview = stroke.preview() else {
            quickMaskStrokeBase = nil
            return
        }
        if case .quickMask = stroke.target {
            guard let base = quickMaskStrokeBase else { return }
            quickMaskStrokeBase = nil
            quickMask = preview.applied(to: base)
            commit(stroke.isEraser ? "Eraser Stroke" : "Brush Stroke", document: document)
            return
        }
        guard let id = stroke.layerID, var layer = document[layerID: id] else { return }
        switch stroke.target {
        case .quickMask:
            return // handled above; `layerID` is nil for it
        case .mask:
            guard let mask = layer.mask else { return }
            layer.mask?.texture = RenderEngine.shared.bakeMaskStroke(into: mask.texture,
                                                                     stroke: preview)
        case .paintLayer:
            // The grid was grown to the canvas when the stroke began
            // (`paintable`), so the coverage buffer already spans everywhere
            // this stroke could reach.
            guard let baked = RenderEngine.shared.bakePaintStroke(into: layer.source,
                                                                  stroke: preview) else { return }
            layer = Layer(id: layer.id, sourceID: UUID(), name: layer.name, source: baked,
                          transform: layer.transform, opacity: layer.opacity,
                          isVisible: layer.isVisible, mask: layer.mask, isPaintable: true,
                          kind: .raster, blendMode: layer.blendMode,
                          isClippedToBelow: layer.isClippedToBelow, groupID: layer.groupID,
                          effects: layer.effects)
        }
        commit(stroke.isEraser ? "Eraser Stroke" : "Brush Stroke",
               document: document.replacingLayer(layer))
    }

    // Brush keys: X swaps colours, D resets, [ ] size, ⇧[ ⇧] hardness.
    /// Which chip the colour picker is editing.
    enum ColorTarget: String, Identifiable {
        case foreground, background
        var id: String { rawValue }
    }

    /// Non-nil while the colour picker sheet is up (RootView presents it).
    @Published var colorPickerRequest: ColorTarget?

    func color(for target: ColorTarget) -> CGColor {
        target == .foreground ? foregroundColor : backgroundColor
    }

    func setColor(_ color: CGColor, for target: ColorTarget) {
        if target == .foreground { foregroundColor = color } else { backgroundColor = color }
    }

    func swapBrushColors() {
        let fg = foregroundColor
        foregroundColor = backgroundColor
        backgroundColor = fg
    }

    func resetBrushColors() {
        foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }

    func adjustBrushSize(increase: Bool) {
        let factor = increase ? 1.25 : 0.8
        brushSize = min(max((brushSize * factor).rounded(), 1), 1000)
    }

    func adjustBrushHardness(increase: Bool) {
        brushHardness = min(max(brushHardness + (increase ? 25 : -25), 0), 100)
    }

    /// Eyedropper: samples the on-screen composite at a canvas-space
    /// point into an sRGB colour — the space the colour wells hold —
    /// averaging over `eyedropperSampleSize`² canvas pixels. Reads the live
    /// document, so sampling mid-transform sees what is on screen (the same
    /// rule as Copy). Colours are UI state, not document state: sampling
    /// deliberately does not commit, does not land pending sessions, and
    /// creates no history entry. That is intentional — do not "fix" it.
    func sampleColor(at canvasPoint: CGPoint) -> CGColor? {
        RenderEngine.shared.sampleColor(document: document, at: canvasPoint,
                                        size: eyedropperSampleSize)
    }

    static func luminance255(of color: CGColor) -> UInt8 {
        let srgb = color.converted(to: BrushyColorSpace.sRGB,
                                   intent: .defaultIntent, options: nil) ?? color
        let c = srgb.components ?? [0, 0, 0, 1]
        let (r, g, b) = c.count >= 3 ? (c[0], c[1], c[2]) : (c[0], c[0], c[0])
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return UInt8((min(max(luminance, 0), 1) * 255).rounded())
    }

    /// A transparent, canvas-sized paint layer: what ⇧⌘N inserts, and what
    /// every new document starts with (Photoshop's fresh-canvas behaviour).
    static func blankPaintLayer(canvasSize: CGSize, name: String) -> Layer? {
        let width = max(1, Int(canvasSize.width))
        let height = max(1, Int(canvasSize.height))
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: BrushyColorSpace.displayP3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return nil }
        return Layer(name: name, source: image, isPaintable: true)
    }

    /// True while the document is still the untouched auto-created blank of a
    /// fresh window: exactly one transparent paint layer and no edits in
    /// either history direction. Content arrivals (place, paste, drop,
    /// cross-document transfer) REPLACE such a blank instead of stacking
    /// above it, preserving the open-into-a-fresh-window adoption semantics
    /// that predate the auto layer. Any committed edit — a stroke, a rename,
    /// a gradient — makes the layer user content and ends pristineness.
    var isPristineBlankDocument: Bool {
        guard !canUndo, !canRedo, document.groups.isEmpty,
              document.layers.count == 1 else { return false }
        let layer = document.layers[0]
        return layer.isPaintable && layer.mask == nil && layer.kind == .raster
            && layer.isVisible && layer.opacity == 1
            && layer.blendMode == .normal && layer.transform == .identity
            && layer.groupID == nil && !layer.isClippedToBelow
    }

    /// Strips the pristine blank ahead of an adoption-style arrival so the
    /// existing empty-document adoption logic fires unchanged. Explicitly
    /// sized documents (⌘N dialog) keep their Layer 1, like Photoshop.
    private func stripPristineBlank(from doc: inout Document) {
        guard !canvasSizeChosenExplicitly, isPristineBlankDocument else { return }
        doc.layers.removeAll()
        selectedLayerID = nil
        maskTargeted = false
    }

    /// Layer → New Paint Layer (⇧⌘N): a transparent, canvas-sized raster
    /// layer that accepts the brush.
    func addPaintLayer() {
        commitPendingSessions()
        let count = document.layers.filter(\.isPaintable).count + 1
        guard var layer = Self.blankPaintLayer(canvasSize: document.canvasSize,
                                               name: "Layer \(count)") else {
            lastErrorMessage = "Could not create a paint layer."
            return
        }
        var doc = document
        let index: Int
        if let selectedIndex = selectedLayerID.flatMap({ doc.layerIndex(of: $0) }) {
            index = selectedIndex + 1
            // Same adoption rule as `insertLayerAboveSelection`: a new layer
            // beside a grouped selection joins the group.
            layer.groupID = doc.layers[selectedIndex].groupID
        } else {
            index = doc.layers.count
        }
        doc.layers.insert(layer, at: index)
        selectedLayerID = layer.id
        selectedGroupID = nil
        maskTargeted = false
        commit("New Layer", document: doc)
    }

    // MARK: - Flip / rotate 90° (transform-only, non-destructive)

    private func composeOnSelectedLayer(_ local: CGAffineTransform, actionName: String) {
        guard let layer = selectedLayer else { return }
        commitPendingSessions()
        let center = layer.sourceRect.center.applying(layer.transform)
        let about = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(local)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        var updated = layer
        updated.transform = layer.transform.concatenating(about)
        commit(actionName, document: document.replacingLayer(updated))
    }

    func flipSelectedLayer(vertical: Bool) {
        composeOnSelectedLayer(CGAffineTransform(scaleX: vertical ? 1 : -1,
                                                 y: vertical ? -1 : 1),
                               actionName: vertical ? "Flip Vertical" : "Flip Horizontal")
    }

    /// Canvas space is y-up: counterclockwise ("left") is +90°.
    func rotateSelectedLayer90(clockwise: Bool) {
        composeOnSelectedLayer(CGAffineTransform(rotationAngle: clockwise ? -.pi / 2 : .pi / 2),
                               actionName: "Rotate 90°")
    }

    // MARK: - Fill selection

    private enum FillTarget {
        case mask(Layer)
        case pixels(Layer)
    }

    /// Same routing as the brush: the targeted mask, a paint layer's pixels,
    /// or an imported layer's existing mask. Imported pixels stay untouchable.
    private func resolveFillTarget() -> FillTarget? {
        guard let layer = selectedLayer, selectedLayerEffectivelyVisible,
              layer.kind.adjustmentSpec == nil else { return nil }
        if maskTargeted, layer.mask != nil { return .mask(layer) }
        if layer.isPaintable { return .pixels(layer) }
        if layer.mask != nil { return .mask(layer) }
        return nil
    }

    var canFillSelection: Bool { quickMaskActive || resolveFillTarget() != nil }

    /// Shown in the Fill dialog so it's unambiguous what will be filled.
    var fillTargetDescription: String {
        if quickMaskActive {
            return "Fills the Quick Mask with the colour's luminance — black masks, white selects."
        }
        guard let layer = selectedLayer else { return "Select a layer first." }
        switch resolveFillTarget() {
        case .mask:
            return "Fills the mask of “\(layer.name)” with the colour's luminance — black hides, white reveals."
        case .pixels:
            return "Fills “\(layer.name)”."
        case nil:
            return "“\(layer.name)” is an imported image — add a mask or use a paint layer."
        }
    }

    func fillSelection(withBackgroundColor useBackground: Bool = false) {
        fillSelection(using: useBackground ? backgroundColor : foregroundColor)
    }

    /// Source-space coverage of the current selection for `layer`, or nil when
    /// the selection is plain geometry — then the callers' path clip is both
    /// exact and cheaper, and behaviour is unchanged from before coverage
    /// existed.
    private func selectionCoverage(for layer: Layer) -> MaskTexture? {
        guard selection.hasAlpha else { return nil }
        return MaskFactory.maskTexture(for: layer, selection: selection,
                                       featherCanvasPx: CGFloat(featherAmount))
    }

    /// Fills the selection (or the whole layer when nothing is selected) with
    /// `color` — on masks, with its luminance.
    func fillSelection(using color: CGColor) {
        commitPendingSessions()
        // In Quick Mask the fill paints the channel: ⌥⌫ floods it with the
        // foreground's luminance, ⌘⌫ with the background's.
        if let texture = quickMask {
            let path = selection.path ?? CGPath(rect: document.canvasRect, transform: nil)
            let coverage = selection.hasAlpha
                ? quickMaskSelectionCoverage(width: texture.width, height: texture.height) : nil
            guard let filled = Self.maskFilled(texture, gridToCanvas: .identity, path: path,
                                               gray: CGFloat(Self.luminance255(of: color)) / 255,
                                               coverage: coverage) else { return }
            quickMask = filled
            commit("Fill Quick Mask", document: document)
            return
        }
        guard let target = resolveFillTarget() else {
            // Rasterize and carry straight on with the fill that asked for it.
            if let layer = selectedLayer, selectedLayerEffectivelyVisible,
               Self.needsRasterize(layer), autoRasterize(layer, because: "to fill it") != nil {
                fillSelection(using: color)
            } else {
                brushHint = "Fill needs a paint layer or a mask — add one first"
            }
            return
        }
        let path = selection.path ?? CGPath(rect: document.canvasRect, transform: nil)
        let updated: Layer?
        switch target {
        case .mask(let layer):
            updated = Self.maskFilled(layer, path: path,
                                      gray: CGFloat(Self.luminance255(of: color)) / 255,
                                      coverage: selectionCoverage(for: layer))
        case .pixels(let layer):
            // Fill what was asked for, even where the layer has no pixels yet.
            let host = Self.grown(layer, toCover: path.boundingBoxOfPath,
                                  canvasRect: document.canvasRect).layer
            // Coverage is source-space, so it has to be built against the
            // GROWN grid — the one the fill actually draws into.
            updated = Self.pixelsFilled(host, path: path, color: color,
                                        coverage: selectionCoverage(for: host))
        }
        guard let updated else { return }
        commit("Fill Selection", document: document.replacingLayer(updated))
    }

    /// Paints `gray` over `path` (canvas space) in the layer's mask.
    /// Shared by Fill Selection and Cut (which fills black).
    private static func maskFilled(_ layer: Layer, path: CGPath, gray: CGFloat,
                                   coverage: MaskTexture?) -> Layer? {
        guard var mask = layer.mask, layer.transform.isInvertible,
              let texture = maskFilled(mask.texture, gridToCanvas: maskGridTransform(of: layer),
                                       path: path, gray: gray, coverage: coverage) else {
            return nil
        }
        mask.texture = texture
        var updated = layer
        updated.mask = mask
        return updated
    }

    /// The same fill against a bare channel. `gridToCanvas` maps the texture's
    /// own grid into canvas space — a layer mask goes through its layer's
    /// transform, the Quick Mask is already canvas-aligned (identity) — which
    /// is what lets one implementation serve both.
    ///
    /// `coverage` (grid-sized) modulates the fill where the selection carries
    /// partial alpha; with none the path clip alone decides, exactly as before.
    private static func maskFilled(_ texture: MaskTexture, gridToCanvas: CGAffineTransform,
                                   path: CGPath, gray: CGFloat,
                                   coverage: MaskTexture?) -> MaskTexture? {
        guard gridToCanvas.isInvertible else { return nil }
        var texture = texture
        let width = texture.width
        let height = texture.height
        let inverse = gridToCanvas.inverted()
        texture.mutate { data in
            data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                guard let base = buffer.baseAddress,
                      let ctx = CGContext(data: base,
                                          width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: BrushyColorSpace.gray,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                    return
                }
                // Grid space, so the clip goes on before the transform.
                if let image = coverageImage(coverage, width: width, height: height) {
                    ctx.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: image)
                }
                ctx.setFillColor(gray: gray, alpha: 1)
                ctx.concatenate(inverse)
                ctx.addPath(path)
                ctx.fillPath(using: .winding)
            }
        }
        return texture
    }

    /// A mask texture's own grid → canvas. Masks are stored at source
    /// resolution, so this is the layer transform in every real document; the
    /// scale term is defensive, matching `maskGradiented`'s.
    private static func maskGridTransform(of layer: Layer) -> CGAffineTransform {
        guard let texture = layer.mask?.texture, texture.width > 0, texture.height > 0 else {
            return layer.transform
        }
        let sx = layer.sourceSize.width / CGFloat(texture.width)
        let sy = layer.sourceSize.height / CGFloat(texture.height)
        return CGAffineTransform(scaleX: sx, y: sy).concatenating(layer.transform)
    }

    /// Coverage as a clip mask, only when it matches the grid it is about to
    /// clip (a mismatch means something resized underneath it — then the path
    /// clip alone is the safe answer, not a stretched channel).
    private static func coverageImage(_ coverage: MaskTexture?,
                                      width: Int, height: Int) -> CGImage? {
        guard let coverage, coverage.width == width, coverage.height == height else { return nil }
        return coverage.cgImage
    }

    /// Draws over `path` (canvas space) in the layer's pixels — a colour fill,
    /// or clearing to transparent when `color` is nil (Cut). The result gets a
    /// fresh sourceID: new pixels never reuse the old identity.
    ///
    /// `coverage` (source-space) is the selection's alpha channel where it has
    /// one: the fill then blends by coverage and the clear takes alpha out in
    /// proportion, so a soft-edged selection cuts a soft-edged hole.
    private static func pixelsFilled(_ layer: Layer, path: CGPath, color: CGColor?,
                                     coverage: MaskTexture? = nil) -> Layer? {
        guard layer.transform.isInvertible,
              let ctx = CGContext(data: nil,
                                  width: layer.source.width, height: layer.source.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: BrushyColorSpace.displayP3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(layer.source, in: layer.sourceRect)
        ctx.saveGState()
        let region: CGRect
        if let image = coverageImage(coverage, width: layer.source.width,
                                     height: layer.source.height) {
            ctx.clip(to: layer.sourceRect, mask: image)
            region = layer.sourceRect
        } else {
            ctx.concatenate(layer.transform.inverted())
            ctx.addPath(path)
            ctx.clip()
            region = ctx.boundingBoxOfClipPath
        }
        if let color {
            ctx.setFillColor(color)
            ctx.fill(region)
        } else if coverage != nil {
            // Soft erase: destination-out with an opaque source takes the
            // clip's coverage straight out of the existing alpha. (`clear`
            // ignores a mask clip's fractional coverage, so the hard-edged
            // path below keeps using it and this branch does not.)
            ctx.setBlendMode(.destinationOut)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(region)
        } else {
            ctx.clear(region)
        }
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { return nil }
        return Layer(id: layer.id, sourceID: UUID(), name: layer.name,
                     source: image, transform: layer.transform,
                     opacity: layer.opacity, isVisible: layer.isVisible,
                     mask: layer.mask, isPaintable: true, kind: .raster)
    }

    // MARK: - Gradient tool (G)

    /// Mirrors `brushTargetDescription` for the gradient options bar: a sticky
    /// hint (e.g. the blocked-target message) wins, then a live description of
    /// where the next drag will land.
    var gradientTargetDescription: String? {
        if let hint = brushHint { return hint }
        guard activeTool == .gradient else { return nil }
        if quickMaskActive {
            return "Gradient fades the Quick Mask — a soft-edged selection"
        }
        guard let layer = selectedLayer else { return "Select a layer first" }
        switch resolveFillTarget() {
        case .mask:
            return "Gradient fills the mask of “\(layer.name)” with the colours' luminance — black hides, white reveals"
        case .pixels:
            return "Gradient fills “\(layer.name)”"
        case nil:
            return "“\(layer.name)” is an imported image — add a mask or use a paint layer"
        }
    }

    /// Bakes one gradient drag (canvas-space start→end). Routing mirrors
    /// Edit → Fill (`resolveFillTarget()`): the targeted mask (or an imported
    /// layer's existing mask) takes the two colours' luminance ramp; a paint
    /// layer takes a foreground→background pixel ramp with a fresh sourceID
    ///; imported pixels stay untouchable, with a hint saying
    /// why. An active selection clips the bake; with none the ENTIRE target
    /// is covered, clamped to the end colours beyond the dragged span.
    /// Exactly one history entry per drag ("Gradient"); zero-length drags are
    /// a no-op with no history.
    func applyGradient(from start: CGPoint, to end: CGPoint) {
        guard start != end else { return }
        commitPendingSessions()
        brushHint = nil
        // A gradient across the Quick Mask is the reason to have both: it is
        // how a selection gets a long soft fade.
        if let texture = quickMask {
            guard let ramped = Self.maskGradiented(
                texture, gridToCanvas: .identity,
                line: GradientLine(start: start, end: end),
                shape: gradientShape, reversed: gradientReversed,
                toTransparent: gradientToTransparent,
                startGray: Self.luminance255(of: foregroundColor),
                endGray: Self.luminance255(of: backgroundColor),
                selectionPath: selection.path,
                selectionCoverage: selection.hasAlpha
                    ? quickMaskSelectionCoverage(width: texture.width, height: texture.height)
                    : nil) else { return }
            quickMask = ramped
            commit("Gradient", document: document)
            return
        }
        guard let target = resolveFillTarget() else {
            if let layer = selectedLayer, selectedLayerEffectivelyVisible,
               Self.needsRasterize(layer),
               autoRasterize(layer, because: "to run a gradient over it") != nil {
                applyGradient(from: start, to: end)
            } else {
                brushHint = "Gradient needs a paint layer or a mask — add one first"
            }
            return
        }
        let line = GradientLine(start: start, end: end)
        let updated: Layer?
        switch target {
        case .mask(let layer):
            updated = Self.maskGradiented(layer, line: line, shape: gradientShape,
                                          reversed: gradientReversed,
                                          toTransparent: gradientToTransparent,
                                          startGray: Self.luminance255(of: foregroundColor),
                                          endGray: Self.luminance255(of: backgroundColor),
                                          selectionPath: selection.path,
                                          selectionCoverage: selectionCoverage(for: layer))
        case .pixels(let layer):
            // A gradient covers the selection, or the whole layer when there
            // is none — which for a small layer means growing it first.
            let region = selection.path?.boundingBoxOfPath ?? document.canvasRect
            let layer = Self.grown(layer, toCover: region,
                                   canvasRect: document.canvasRect).layer
            updated = Self.pixelsGradiented(layer, line: line, shape: gradientShape,
                                            reversed: gradientReversed,
                                            toTransparent: gradientToTransparent,
                                            startColor: foregroundColor,
                                            endColor: backgroundColor,
                                            selectionPath: selection.path,
                                            selectionCoverage: selectionCoverage(for: layer))
        }
        guard let updated else { return }
        commit("Gradient", document: document.replacingLayer(updated))
    }

    /// Bakes the ramp into the mask on the CPU, pixel by pixel: each mask byte
    /// maps through the layer transform into canvas space and evaluates
    /// `GradientMath` there, so gradients stay straight/circular on the canvas
    /// however the layer is transformed. Row 0 of the buffer is the TOP row
    /// — `sourceY` counts down from the top accordingly.
    /// `toTransparent` blends the start luminance over the existing texture
    /// with the ramp as its coverage, so the transparent end leaves the mask
    /// untouched. A selection clips via a coverage buffer rasterised with the
    /// same context setup as `maskFilled` (antialiased edges included).
    private static func maskGradiented(_ layer: Layer, line: GradientLine,
                                       shape: GradientShape, reversed: Bool,
                                       toTransparent: Bool,
                                       startGray: UInt8, endGray: UInt8,
                                       selectionPath: CGPath?,
                                       selectionCoverage: MaskTexture?) -> Layer? {
        guard var mask = layer.mask, layer.transform.isInvertible,
              let texture = maskGradiented(mask.texture,
                                           gridToCanvas: maskGridTransform(of: layer),
                                           line: line, shape: shape, reversed: reversed,
                                           toTransparent: toTransparent,
                                           startGray: startGray, endGray: endGray,
                                           selectionPath: selectionPath,
                                           selectionCoverage: selectionCoverage) else {
            return nil
        }
        mask.texture = texture
        var updated = layer
        updated.mask = mask
        return updated
    }

    /// The same ramp against a bare channel — a layer mask through its layer's
    /// transform, or the canvas-aligned Quick Mask (identity). See
    /// `maskFilled(_:gridToCanvas:…)` for why the grid transform is the seam.
    private static func maskGradiented(_ texture: MaskTexture,
                                       gridToCanvas transform: CGAffineTransform,
                                       line: GradientLine,
                                       shape: GradientShape, reversed: Bool,
                                       toTransparent: Bool,
                                       startGray: UInt8, endGray: UInt8,
                                       selectionPath: CGPath?,
                                       selectionCoverage: MaskTexture?) -> MaskTexture? {
        guard transform.isInvertible else { return nil }
        var texture = texture
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0 else { return nil }

        // Selection coverage over the mask grid, 255 = fully affected; no
        // selection means the whole target is covered. A selection with its own
        // alpha channel hands it over ready-made.
        var coverage: Data?
        if let ready = selectionCoverage, ready.width == width, ready.height == height {
            coverage = ready.data
        } else if let path = selectionPath {
            var buffer = Data(repeating: 0, count: width * height)
            buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let base = raw.baseAddress,
                      let ctx = CGContext(data: base,
                                          width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: BrushyColorSpace.gray,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                    return
                }
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.concatenate(transform.inverted())
                ctx.addPath(path)
                ctx.fillPath(using: .winding)
            }
            coverage = buffer
        }

        let g0 = CGFloat(startGray)
        let g1 = CGFloat(endGray)
        texture.mutate { data in
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let bake: (UnsafePointer<UInt8>?) -> Void = { coverageBytes in
                    for row in 0..<height {
                        // buffer row 0 is the top; the y-up grid
                        // counts down from height as rows increase.
                        let gridY = CGFloat(height - row) - 0.5
                        let rowBase = row * width
                        for col in 0..<width {
                            let index = rowBase + col
                            var cov: CGFloat = 1
                            if let coverageBytes {
                                cov = CGFloat(coverageBytes[index]) / 255
                                if cov == 0 { continue }
                            }
                            let gridPoint = CGPoint(x: CGFloat(col) + 0.5, y: gridY)
                            let t = GradientMath.parameter(of: gridPoint.applying(transform),
                                                           start: line.start, end: line.end,
                                                           shape: shape, reversed: reversed)
                            let gray = toTransparent ? g0 : g0 + (g1 - g0) * t
                            let alpha = (toTransparent ? 1 - t : 1) * cov
                            let old = CGFloat(bytes[index])
                            let value = old + (gray - old) * alpha
                            bytes[index] = UInt8(min(max(value, 0), 255).rounded())
                        }
                    }
                }
                if let coverage {
                    coverage.withUnsafeBytes { covRaw in
                        bake(covRaw.baseAddress?.assumingMemoryBound(to: UInt8.self))
                    }
                } else {
                    bake(nil)
                }
            }
        }
        return texture
    }

    /// Draws the gradient over the layer's pixels (the whole layer, or the
    /// selection when one exists) via CGGradient into a source copy, mirroring
    /// `pixelsFilled` — fresh sourceID. Stops interpolate in
    /// sRGB (the colour wells' space); Core Graphics converts into the P3
    /// source copy. `toTransparent` ramps the foreground's alpha to 0, so the
    /// far end leaves existing pixels showing through.
    private static func pixelsGradiented(_ layer: Layer, line: GradientLine,
                                         shape: GradientShape, reversed: Bool,
                                         toTransparent: Bool,
                                         startColor: CGColor, endColor: CGColor,
                                         selectionPath: CGPath?,
                                         selectionCoverage: MaskTexture? = nil) -> Layer? {
        guard layer.transform.isInvertible,
              let ctx = CGContext(data: nil,
                                  width: layer.source.width, height: layer.source.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: BrushyColorSpace.displayP3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(layer.source, in: layer.sourceRect)
        ctx.saveGState()
        // Coverage clips in source space, so it goes on before the transform.
        if let image = coverageImage(selectionCoverage, width: layer.source.width,
                                     height: layer.source.height) {
            ctx.clip(to: layer.sourceRect, mask: image)
            ctx.concatenate(layer.transform.inverted())
        } else {
            ctx.concatenate(layer.transform.inverted())
            if let selectionPath {
                ctx.addPath(selectionPath)
                ctx.clip()
            }
        }
        var start = startColor
        var end = toTransparent ? (startColor.copy(alpha: 0) ?? startColor) : endColor
        if reversed { swap(&start, &end) }
        guard let gradient = CGGradient(colorsSpace: BrushyColorSpace.sRGB,
                                        colors: [start, end] as CFArray,
                                        locations: [0, 1]) else {
            ctx.restoreGState()
            return nil
        }
        // §-Photoshop fill geometry: clamp to the end colours outside the span.
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation,
                                                 .drawsAfterEndLocation]
        switch shape {
        case .linear:
            ctx.drawLinearGradient(gradient, start: line.start, end: line.end,
                                   options: options)
        case .radial:
            ctx.drawRadialGradient(gradient, startCenter: line.start, startRadius: 0,
                                   endCenter: line.start,
                                   endRadius: (line.end - line.start).length,
                                   options: options)
        }
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { return nil }
        return Layer(id: layer.id, sourceID: UUID(), name: layer.name,
                     source: image, transform: layer.transform,
                     opacity: layer.opacity, isVisible: layer.isVisible,
                     mask: layer.mask, isPaintable: true, kind: .raster)
    }

    // MARK: - Clipboard

    /// What Copy means (Photoshop semantics): the selected layer, restricted
    /// to the current selection.
    /// - Selection → the layer's rendered contribution cropped to the
    ///   selection bounds, with the (feathered) selection applied as a mask —
    ///   a baked canvas-space raster.
    /// - No selection → the whole layer: source pixels, transform and mask
    ///   travel intact.
    /// Copy never touches the document or history; it reads the live document,
    /// so copying mid-gesture captures what is on screen.
    func copySelection(to pasteboard: NSPasteboard = .general) {
        guard let layer = selectedLayer, selectedLayerEffectivelyVisible else { return }
        writeCopy(of: layer, to: pasteboard)
    }

    /// Copy Merged (⇧⌘C): all visible layers flattened over the same region,
    /// clipped to the canvas frame like any flattened output. Visibility is
    /// effective — members of hidden groups are excluded like hidden layers.
    func copyMerged(to pasteboard: NSPasteboard = .general) {
        guard document.layers.contains(where: { document.isEffectivelyVisible(layerID: $0.id) }) else { return }
        var rect = document.canvasRect
        if let path = selection.path {
            rect = path.boundingBoxOfPath.intersection(rect)
        }
        rect = rect.integral
        guard rect.width >= 1, rect.height >= 1 else { return }
        let selectionTexture = selection.isEmpty ? nil
            : MaskFactory.selectionTexture(rect: rect, selection: selection,
                                           featherCanvasPx: CGFloat(featherAmount))
        let deep = document.layers.contains {
            document.isEffectivelyVisible(layerID: $0.id) && $0.source.bitsPerComponent > 8
        }
        guard let image = RenderEngine.shared.renderFlattenedRegion(
            document: document, croppedTo: rect,
            selection: selectionTexture, sixteenBit: deep) else { return }
        let merged = Layer(name: "Merged", source: image,
                           transform: CGAffineTransform(translationX: rect.minX, y: rect.minY),
                           isPaintable: true)
        LayerPasteboard.write(layer: merged, canvasSize: document.canvasSize,
                              renderedImage: image, to: pasteboard)
    }

    /// Cut (⌘X) = Copy, then remove the selected region non-destructively
    ///. The removal routing mirrors the eraser: a targeted or
    /// existing mask is filled black, a paint layer's pixels clear to
    /// transparent, and an imported layer with no mask gets an auto-created
    /// hide-mask first. Copy + removal lands as one undo step.
    func cutSelection(to pasteboard: NSPasteboard = .general) {
        commitPendingSessions()
        guard let layer = selectedLayer, selectedLayerEffectivelyVisible else { return }
        guard writeCopy(of: layer, to: pasteboard) else { return }
        let path = selection.path ?? CGPath(rect: layer.canvasBounds, transform: nil)
        let updated: Layer?
        switch resolveStrokeTarget(eraser: true) {
        case .blocked:
            return
        case .quickMask:
            return // Quick Mask has no pixels to cut
        case .mask(let target):
            updated = Self.maskFilled(target, path: path, gray: 0,
                                      coverage: selectionCoverage(for: target))
            maskTargeted = true
        case .paint(let target):
            updated = Self.pixelsFilled(target, path: path, color: nil,
                                        coverage: selectionCoverage(for: target))
        case .needsRasterize(let target):
            guard let ready = autoRasterize(target, because: "to cut from it") else { return }
            updated = Self.pixelsFilled(ready, path: path, color: nil,
                                        coverage: selectionCoverage(for: ready))
        }
        guard let updated else { return }
        commit("Cut", document: document.replacingLayer(updated))
    }

    /// ⌫ with a selection up clears the selected pixels (Photoshop) instead of
    /// deleting the layer. Routing mirrors Cut exactly.
    func clearSelection() {
        // In Quick Mask there are no pixels to clear: ⌫ fills the channel with
        // the background colour, as it fills a channel in Photoshop.
        if quickMaskActive {
            fillSelection(withBackgroundColor: true)
            return
        }
        commitPendingSessions()
        guard selectedLayerEffectivelyVisible, let path = selection.path else { return }
        let updated: Layer?
        switch resolveStrokeTarget(eraser: true) {
        case .blocked:
            return
        case .quickMask:
            return // in Quick Mask the canvas is the channel; ⌫ leaves it alone
        case .mask(let target):
            updated = Self.maskFilled(target, path: path, gray: 0,
                                      coverage: selectionCoverage(for: target))
            maskTargeted = true
        case .paint(let target):
            updated = Self.pixelsFilled(target, path: path, color: nil,
                                        coverage: selectionCoverage(for: target))
        case .needsRasterize(let target):
            guard let ready = autoRasterize(target, because: "to clear part of it") else { return }
            updated = Self.pixelsFilled(ready, path: path, color: nil,
                                        coverage: selectionCoverage(for: ready))
        }
        guard let updated else { return }
        commit("Clear", document: document.replacingLayer(updated))
    }

    /// Writes `layer` to the pasteboard in both flavours. Returns false when
    /// there is nothing to copy (selection entirely outside the layer) or
    /// encoding failed — callers treat that as a complete no-op.
    @discardableResult
    private func writeCopy(of layer: Layer, to pasteboard: NSPasteboard) -> Bool {
        let deep = layer.source.bitsPerComponent > 8
        if let path = selection.path {
            let rect = path.boundingBoxOfPath.intersection(layer.canvasBounds).integral
            guard rect.width >= 1, rect.height >= 1 else { return false }
            let selectionTexture = MaskFactory.selectionTexture(
                rect: rect, selection: selection, featherCanvasPx: CGFloat(featherAmount))
            // Bake at full opacity — the envelope carries opacity as metadata,
            // so the pasted layer keeps it editable.
            var bakeLayer = layer
            bakeLayer.opacity = 1
            guard let baked = RenderEngine.shared.renderLayerRegion(
                bakeLayer, croppedTo: rect,
                selection: selectionTexture, sixteenBit: deep) else { return false }
            let rendered = layer.opacity < 1
                ? RenderEngine.shared.renderLayerRegion(layer, croppedTo: rect,
                                                        selection: selectionTexture,
                                                        sixteenBit: deep) ?? baked
                : baked
            let copied = Layer(name: layer.name, source: baked,
                               transform: CGAffineTransform(translationX: rect.minX,
                                                            y: rect.minY),
                               opacity: layer.opacity, isPaintable: true)
            return LayerPasteboard.write(layer: copied, canvasSize: document.canvasSize,
                                         renderedImage: rendered, to: pasteboard)
        }
        let rect = layer.canvasBounds.integral
        guard rect.width >= 1, rect.height >= 1 else { return false }
        let rendered = RenderEngine.shared.renderLayerRegion(layer, croppedTo: rect,
                                                             sixteenBit: deep)
        return LayerPasteboard.write(layer: layer, canvasSize: document.canvasSize,
                                     renderedImage: rendered, to: pasteboard)
    }

    /// Paste (⌘V): inserts the clipboard as a new layer above the selected
    /// one. A Brushy layer whose source canvas matches the target's pastes
    /// in place; anything else centres via the placement rule. Content arrives
    /// with Free Transform armed.
    func paste(from pasteboard: NSPasteboard = .general) {
        commitPendingSessions()
        performPaste(from: pasteboard, into: false)
    }

    /// Paste Into (⌥⌘V): Paste plus a mask built from the current selection,
    /// which is consumed the way Add Layer Mask consumes it.
    func pasteInto(from pasteboard: NSPasteboard = .general) {
        commitPendingSessions()
        guard !selection.isEmpty else { return }
        performPaste(from: pasteboard, into: true)
    }

    private func performPaste(from pasteboard: NSPasteboard, into: Bool) {
        switch LayerPasteboard.read(from: pasteboard) {
        case .none:
            return
        case .urls(let urls):
            // placeImages owns naming, placement, commit and transform arming.
            placeImages(from: urls)
        case .image(let image):
            var doc = document
            if !into { stripPristineBlank(from: &doc) }
            let adopted = doc.layers.isEmpty && !into && !canvasSizeChosenExplicitly
            if adopted {
                // An empty document adopts the pasted image's size, mirroring
                // placeImages' open-as-document semantics.
                doc.canvasSize = Self.clampedSize(CGSize(width: image.width,
                                                         height: image.height))
            }
            let layer = Self.placedLayer(image, named: "Pasted Layer",
                                         canvasSize: doc.canvasSize)
            finishPaste(layer, document: doc, adopted: adopted, into: into)
        case .layer(let envelope):
            guard var layer = LayerPasteboard.layer(from: envelope) else {
                lastErrorMessage = "The layer on the clipboard could not be read."
                return
            }
            var doc = document
            let sourceCanvas = CGSize(width: envelope.canvasWidth,
                                      height: envelope.canvasHeight)
            if !into { stripPristineBlank(from: &doc) }
            let adopted = doc.layers.isEmpty && !into && !canvasSizeChosenExplicitly
            if adopted {
                // An empty document adopts the source document's frame, so a
                // cross-document paste of a whole layer round-trips in place.
                doc.canvasSize = Self.clampedSize(sourceCanvas)
            }
            if doc.canvasSize != sourceCanvas {
                layer = Self.recentered(layer, canvasSize: doc.canvasSize)
            }
            finishPaste(layer, document: doc, adopted: adopted, into: into)
        }
    }

    private func finishPaste(_ incoming: Layer, document doc: Document,
                             adopted: Bool, into: Bool) {
        var layer = incoming
        layer.isVisible = true
        if into, !selection.isEmpty {
            // The selection becomes the pasted layer's mask, built against its
            // final transform. It replaces any mask that travelled with the
            // layer — the selection is what Paste Into means.
            layer.mask = Mask(texture: MaskFactory.maskTexture(
                                  for: layer, selection: selection,
                                  featherCanvasPx: CGFloat(featherAmount)),
                              isEnabled: true)
        }
        setLiveDocument(doc)
        insertLayerAboveSelection(layer, consumingBlankTarget: true)
        commit(into ? "Paste Into" : "Paste", document: document, selection: .empty)
        if adopted {
            zoomToFit()
        }
        armTransformForArrivedLayer(layer.id, adoptedCanvas: adopted)
    }

    /// `placedLayer`'s rule generalised to a layer that already has a
    /// transform: keep its scale/rotation, centre its bounds on the canvas,
    /// and shrink proportionally only if larger than the canvas.
    static func recentered(_ layer: Layer, canvasSize: CGSize) -> Layer {
        let bounds = layer.canvasBounds
        guard bounds.width > 0, bounds.height > 0 else { return layer }
        var scale: CGFloat = 1
        if bounds.width > canvasSize.width || bounds.height > canvasSize.height {
            scale = min(canvasSize.width / bounds.width,
                        canvasSize.height / bounds.height)
        }
        var center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        if scale == 1 {
            // Whole-pixel landing, as in `placedLayer`.
            center = CGPoint(x: ((canvasSize.width - bounds.width) / 2).rounded() + bounds.width / 2,
                             y: ((canvasSize.height - bounds.height) / 2).rounded() + bounds.height / 2)
        }
        var updated = layer
        updated.transform = layer.transform
            .concatenating(CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return updated
    }

    // MARK: - Cross-document transfer (Layer → Duplicate Layer to)

    /// Lands a layer duplicated out of another open document. The copy gets a
    /// fresh `id` **and** a fresh `sourceID`: two documents must never share a
    /// source identity, because each document's serializer caches source PNG
    /// bytes keyed on `sourceID`. The pixels themselves are shared by
    /// reference — `source` is immutable, so the copy is identity-deep,
    /// not byte-deep.
    ///
    /// Placement mirrors Paste: an empty document adopts the source
    /// document's frame so the layer lands in place; matching canvases
    /// preserve the transform exactly; anything else re-places the layer like
    /// a newly placed image. Like every arrival path, the copy lands with
    /// Free Transform armed unless the document adopted its frame (—
    /// `armTransformForArrivedLayer`). Exactly one history entry lands here
    ///; the source document is never touched.
    func receiveLayer(_ layer: Layer, from sourceCanvasSize: CGSize) {
        commitPendingSessions()
        var doc = document
        stripPristineBlank(from: &doc)
        let adopted = doc.layers.isEmpty && !canvasSizeChosenExplicitly
        if adopted {
            doc.canvasSize = Self.clampedSize(sourceCanvasSize)
        }
        // Blend mode and layer style travel with the layer — they are
        // properties OF it. The clipping flag and group membership do not:
        // both are relationships with the stack the layer is leaving (same
        // rule as the clipboard path), and insertion beside the target's
        // selection decides any new membership. `effects` was omitted here
        // rather than excluded on purpose, which silently dropped the style.
        var incoming = Layer(id: UUID(), sourceID: UUID(), name: layer.name,
                             source: layer.source, transform: layer.transform,
                             opacity: layer.opacity, isVisible: layer.isVisible,
                             mask: nil, isPaintable: layer.isPaintable,
                             kind: layer.kind, blendMode: layer.blendMode,
                             isClippedToBelow: false, groupID: nil,
                             effects: layer.effects)
        if doc.canvasSize != sourceCanvasSize {
            incoming.transform = Self.placedLayer(layer.source, named: layer.name,
                                                  canvasSize: doc.canvasSize).transform
        }
        // Masks don't survive a mismatch with the underlying raster; carry
        // one only when its dimensions match the source — the same rule
        // updateVectorLayer and the clipboard path apply.
        if let mask = layer.mask,
           mask.texture.width == layer.source.width,
           mask.texture.height == layer.source.height {
            incoming.mask = mask
        }
        setLiveDocument(doc)
        insertLayerAboveSelection(incoming, consumingBlankTarget: true)
        commit("Duplicate Layer", document: document)
        if adopted { zoomToFit() }
        armTransformForArrivedLayer(incoming.id, adoptedCanvas: adopted)
    }

    // MARK: - Text & shape layers

    /// The topmost visible text layer under a canvas point (text-tool clicks
    /// edit existing text instead of stacking new layers). Effective
    /// visibility — text hidden through its group is not click-editable.
    func textLayer(at canvasPoint: CGPoint) -> Layer? {
        document.layers.reversed().first { layer in
            layer.kind.textSpec != nil
                && document.isEffectivelyVisible(layerID: layer.id)
                && layer.canvasBounds.contains(canvasPoint)
        }
    }

    // MARK: In-place text sessions

    /// Seeded into new sessions and shown fully selected, so the first
    /// keystroke replaces it. Accepting it as-is makes a layer that says
    /// "Text" — see `commitTextSession`.
    static let textPlaceholder = "Text"

    func beginTextSession(creatingAt canvasPoint: CGPoint) {
        commitPendingSessions()
        var spec = textStyle
        // nil caretHint ⇒ the editor selects all, so the placeholder previews
        // the current style and typing replaces it in one stroke.
        spec.text = Self.textPlaceholder
        spec.color = ColorSpec(cgColor: foregroundColor)
        textSession = TextEditSession(layerID: nil, spec: spec, initialSpec: nil,
                                      anchorTopLeft: canvasPoint,
                                      rotation: 0, scaleX: 1, scaleY: 1,
                                      isDecomposable: true, caretHint: nil)
    }

    func beginTextSession(editing layerID: UUID, caretAt canvasPoint: CGPoint?) {
        commitPendingSessions()
        guard let layer = document[layerID: layerID],
              let spec = layer.kind.textSpec else { return }
        activeTool = .text
        selectLayer(layerID)
        let t = layer.transform
        let determinant = t.a * t.d - t.b * t.c
        let (sx, sy) = t.scaleComponents
        let session: TextEditSession
        if determinant > 0 {
            session = TextEditSession(
                layerID: layerID, spec: spec, initialSpec: spec,
                anchorTopLeft: CGPoint(x: 0, y: layer.sourceSize.height).applying(t),
                rotation: t.rotationAngle, scaleX: sx, scaleY: sy,
                isDecomposable: true, caretHint: canvasPoint)
        } else {
            // Mirrored transform: upright fallback box at the AABB top-left.
            let bounds = layer.canvasBounds
            session = TextEditSession(
                layerID: layerID, spec: spec, initialSpec: spec,
                anchorTopLeft: CGPoint(x: bounds.minX, y: bounds.maxY),
                rotation: 0, scaleX: sx, scaleY: sy,
                isDecomposable: false, caretHint: canvasPoint)
        }
        textSession = session
    }

    /// From the editor's textDidChange — no document mutation.
    func updateTextSessionText(_ text: String) {
        textSession?.spec.text = text
    }

    /// Options-bar style changes apply to the live session AND become the
    /// creation defaults.
    func updateTextSessionStyle(_ mutate: (inout TextSpec) -> Void) {
        if var session = textSession {
            mutate(&session.spec)
            textSession = session
            var defaults = textStyle
            defaults.fontName = session.spec.fontName
            defaults.fontSize = session.spec.fontSize
            defaults.color = session.spec.color
            textStyle = defaults
        } else {
            var defaults = textStyle
            mutate(&defaults)
            textStyle = defaults
        }
    }

    /// At most one undo step: create / edit / delete-when-emptied / no-op.
    func commitTextSession() {
        guard let session = textSession else { return }
        textSession = nil
        let trimmed = session.spec.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let layerID = session.layerID {
            if trimmed.isEmpty {
                // Photoshop parity: committing an emptied text layer deletes it.
                guard let index = document.layerIndex(of: layerID) else { return }
                var doc = document.removingLayer(id: layerID)
                if selectedLayerID == layerID {
                    selectedLayerID = doc.layers.indices.contains(index - 1)
                        ? doc.layers[index - 1].id : doc.layers.first?.id
                }
                commit("Delete Layer", document: doc)
            } else if let initial = session.initialSpec, session.spec == initial {
                // Unchanged: no history entry.
            } else {
                updateVectorLayer(layerID, kind: .text(session.spec), actionName: "Edit Text")
            }
        } else if !trimmed.isEmpty {
            // Whatever is in the box when you accept it becomes the layer, the
            // untouched placeholder included. Dropping it silently instead
            // reads as the app ignoring you; clearing the text (or ⌘Z) is how
            // you say you didn't want it.
            insertTextLayer(session.spec, topLeftAt: session.anchorTopLeft)
        }
    }

    /// The document was never touched — nothing to restore.
    func cancelTextSession() {
        textSession = nil
    }

    func commitAnyTextSession() {
        if textSession != nil { commitTextSession() }
    }

    /// Creates a text layer with the click point as its top-left.
    func insertTextLayer(_ spec: TextSpec, topLeftAt point: CGPoint) {
        guard let image = VectorRasterizer.render(text: spec) else {
            lastErrorMessage = "Could not render the text."
            return
        }
        let transform = CGAffineTransform(translationX: point.x,
                                          y: point.y - CGFloat(image.height))
        let layer = Layer(name: Self.layerName(forText: spec.text), source: image,
                          transform: transform, kind: .text(spec))
        insertLayerAboveSelection(layer)
        commit("New Text Layer", document: document)
    }

    func addShapeLayer(dragRect: CGRect, lineFrom: CGPoint?, lineTo: CGPoint?) {
        let (spec, origin) = VectorRasterizer.shapeSpec(from: dragRect,
                                                       lineFrom: lineFrom, lineTo: lineTo,
                                                       style: shapeStyle)
        guard let image = VectorRasterizer.render(shape: spec) else {
            lastErrorMessage = "Could not render the shape."
            return
        }
        let layer = Layer(name: spec.kind.displayName,
                          source: image,
                          transform: CGAffineTransform(translationX: origin.x, y: origin.y),
                          kind: .shape(spec))
        insertLayerAboveSelection(layer)
        commit("New Shape Layer", document: document)
    }

    /// Re-renders a vector layer from an updated spec, preserving its anchor:
    /// text keeps its top-left (text grows downward), shapes keep their centre
    /// (padding growth stays symmetric). The layer's transform (scale/rotation)
    /// is untouched.
    func updateVectorLayer(_ layerID: UUID, kind: LayerKind, actionName: String,
                           transient: Bool = false) {
        guard var layer = document[layerID: layerID] else { return }
        let oldWidth = CGFloat(layer.source.width)
        let oldHeight = CGFloat(layer.source.height)
        let image: CGImage?
        switch kind {
        case .text(let spec): image = VectorRasterizer.render(text: spec)
        case .shape(let spec): image = VectorRasterizer.render(shape: spec)
        // Neither has a rasterisation to refresh: an adjustment has no pixels
        // at all, and a raster layer's pixels are already the truth.
        case .raster, .adjustment: image = nil
        }
        guard let image else { return }
        let anchorShift: CGAffineTransform
        if case .text = kind {
            anchorShift = CGAffineTransform(translationX: 0,
                                            y: oldHeight - CGFloat(image.height))
        } else {
            anchorShift = CGAffineTransform(translationX: (oldWidth - CGFloat(image.width)) / 2,
                                            y: (oldHeight - CGFloat(image.height)) / 2)
        }
        // Only the PIXELS change here — this is a re-rasterisation of the same
        // layer, so everything that isn't pixels has to survive it. Listing
        // the fields explicitly (rather than mutating a copy) is what let
        // blendMode, isClippedToBelow, groupID and effects silently reset to
        // their defaults: editing the text of a grouped layer dropped it out
        // of its group, released its clipping mask and cleared its style.
        // A fresh sourceID is still required.
        layer = Layer(id: layer.id, sourceID: UUID(), name: layer.name, source: image,
                      transform: anchorShift.concatenating(layer.transform),
                      opacity: layer.opacity, isVisible: layer.isVisible,
                      mask: nil, // mask resolution is tied to the old raster
                      isPaintable: false, kind: kind,
                      blendMode: layer.blendMode,
                      isClippedToBelow: layer.isClippedToBelow,
                      groupID: layer.groupID,
                      effects: layer.effects)
        // Masks don't survive a resize of the underlying raster; keep them
        // only when dimensions are unchanged.
        if let mask = document[layerID: layerID]?.mask,
           mask.texture.width == image.width, mask.texture.height == image.height {
            layer.mask = mask
        }
        if transient {
            setLiveDocument(document.replacingLayer(layer))
        } else {
            commit(actionName, document: document.replacingLayer(layer))
        }
    }

    /// The selected layer's shape spec, if it is a shape layer.
    var selectedShapeSpec: ShapeSpec? {
        selectedLayer?.kind.shapeSpec
    }

    func updateSelectedShape(_ mutate: (inout ShapeSpec) -> Void, transient: Bool = false) {
        guard let layer = selectedLayer, var spec = layer.kind.shapeSpec else { return }
        let oldPadding = spec.padding
        mutate(&spec)
        // Padding changes move geometry relative to the content box; shift
        // line endpoints so the drawn line stays put in canvas space.
        let paddingDelta = CGFloat(spec.padding - oldPadding)
        if spec.kind == .line, paddingDelta != 0 {
            spec.size.width += paddingDelta * 2
            spec.size.height += paddingDelta * 2
            spec.lineStart = spec.lineStart + CGPoint(x: paddingDelta, y: paddingDelta)
            spec.lineEnd = spec.lineEnd + CGPoint(x: paddingDelta, y: paddingDelta)
        }
        updateVectorLayer(layer.id, kind: .shape(spec), actionName: "Edit Shape",
                          transient: transient)
    }

    func commitShapeEdit() {
        guard let layer = selectedLayer, let spec = layer.kind.shapeSpec else { return }
        updateVectorLayer(layer.id, kind: .shape(spec), actionName: "Edit Shape")
    }

    /// A transparent, unstyled paint layer: scaffolding with nothing on it to
    /// lose. Arriving content takes its place rather than stacking on top of
    /// it — "I made a layer to paste into" should mean exactly that.
    static func isBlankPaintLayer(_ layer: Layer) -> Bool {
        guard layer.isPaintable, layer.kind == .raster, layer.mask == nil,
              layer.effects.isEmpty, !layer.isClippedToBelow,
              layer.opacity == 1, layer.blendMode == .normal else { return false }
        return layer.source.isFullyTransparent
    }

    /// `consumingBlankTarget` — for content ARRIVING from outside (paste,
    /// place, a layer from another document): an empty layer the user made to
    /// receive it is used rather than stacked under. New text, shapes and
    /// adjustments never consume one; they are their own content.
    ///
    /// A document's only layer is never consumed either: a fresh ⌘N window is
    /// one empty layer, and Photoshop keeps its Background there too.
    private func insertLayerAboveSelection(_ layer: Layer,
                                           consumingBlankTarget: Bool = false) {
        var doc = document
        var incoming = layer
        let index: Int
        if let selectedIndex = selectedLayerID.flatMap({ doc.layerIndex(of: $0) }) {
            index = selectedIndex + 1
            // Arrivals (paste, transfer, new text/shape) land directly above
            // the selected layer and ADOPT its group, keeping the group's run
            // contiguous — Photoshop's paste-into-a-group behaviour. No
            // membership travels from the source; the landing spot decides.
            incoming.groupID = doc.layers[selectedIndex].groupID
            if consumingBlankTarget, doc.layers.count > 1,
               Self.isBlankPaintLayer(doc.layers[selectedIndex]) {
                doc.layers.remove(at: selectedIndex)
                doc.layers.insert(incoming, at: selectedIndex)
                selectedLayerID = incoming.id
                selectedGroupID = nil
                maskTargeted = false
                setLiveDocument(doc)
                return
            }
        } else {
            index = doc.layers.count
            incoming.groupID = nil
        }
        doc.layers.insert(incoming, at: index)
        selectedLayerID = incoming.id
        selectedGroupID = nil
        maskTargeted = false
        setLiveDocument(doc)
    }

    private static func layerName(forText text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? "Text"
        return firstLine.count > 24 ? String(firstLine.prefix(24)) + "…" : firstLine
    }

    // MARK: - Image Size / Canvas Size

    /// Sizes are clamped to Metal-friendly bounds. The bound and the clamp
    /// both live on `Document` now — the file readers need the same rule, and
    /// a canvas size read from a document is no more trustworthy than one
    /// typed into a dialog.
    static var sizeLimits: ClosedRange<CGFloat> { Document.canvasSizeLimits }

    static func clampedSize(_ size: CGSize) -> CGSize { Document.clampedCanvasSize(size) }

    func resizeImage(to newSize: CGSize) {
        commitPendingSessions()
        endQuickMaskBeforeCanvasChange()
        let size = Self.clampedSize(newSize)
        guard size != document.canvasSize else { return }
        commit("Image Size", document: document.scaled(to: size))
        canvasSizeChosenExplicitly = true
    }

    func resizeCanvas(to newSize: CGSize, anchor: CGPoint) {
        commitPendingSessions()
        endQuickMaskBeforeCanvasChange()
        let size = Self.clampedSize(newSize)
        guard size != document.canvasSize else { return }
        commit("Canvas Size", document: document.resizingCanvas(to: size, anchor: anchor))
        canvasSizeChosenExplicitly = true
    }

    // MARK: - Export

    func requestExport() {
        commitPendingSessions()
        exportRequested = true
    }
}

import Combine
import Foundation

/// The **live** half of the preference split: app-scoped settings
/// that open documents must follow immediately, not on next launch.
///
/// Everything else is seed-only — read once from `Defaults` when the thing it
/// configures is created — and deliberately does *not* live here. See the
/// per-key LIVE / SEED-ONLY tags in `Defaults.Keys`; that split is the thing
/// this task exists to make explicit, and the reason a Settings change must
/// never blindly reach into every open `DocumentStore`.
///
/// Only these belong: grid spacing and subdivisions, the guide and grid
/// colours, snapping, and the two history caps. Photoshop applies them live,
/// and a grid-spacing change the user can't see until they reopen the window
/// reads as a bug.
///
/// Mechanism: each property persists through `Defaults` on write and republishes;
/// `DocumentStore` mirrors the ones it needs onto its own `@Published`
/// properties (so the canvas overlay's existing "redraw on store change" path
/// keeps working unchanged) and pushes local changes — the View menu's ⇧⌘;
/// Snap toggle, say — back up here. Both directions guard on equality, which
/// is what stops the round trip from looping.
///
/// **Never in the undo history**, like every other preference: nothing here
/// goes through `DocumentStore.commit`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// True while `reload()` is re-reading, so the write-back in each `didSet`
    /// doesn't immediately re-create the keys a pane just reset.
    private var isReloading = false

    @Published var gridSpacing: Double = Defaults.value(Defaults.Keys.gridSpacing) {
        didSet { persist(gridSpacing, Defaults.Keys.gridSpacing) }
    }
    @Published var gridSubdivisions: Int = Defaults.value(Defaults.Keys.gridSubdivisions) {
        didSet { persist(gridSubdivisions, Defaults.Keys.gridSubdivisions) }
    }
    @Published var snappingEnabled: Bool = Defaults.value(Defaults.Keys.snappingEnabled) {
        didSet { persist(snappingEnabled, Defaults.Keys.snappingEnabled) }
    }
    @Published var guideColor: ColorSpec = Defaults.value(Defaults.Keys.guideColor) {
        didSet { persist(guideColor, Defaults.Keys.guideColor) }
    }
    @Published var gridColor: ColorSpec = Defaults.value(Defaults.Keys.gridColor) {
        didSet { persist(gridColor, Defaults.Keys.gridColor) }
    }
    /// history cap. Clamped on the way in: a depth of 0 would mean no undo
    /// at all, and `commit` indexes `history[historyIndex]` unconditionally.
    @Published var undoDepth: Int = AppSettings.clampedUndoDepth(
        Defaults.value(Defaults.Keys.undoDepth)) {
        didSet {
            let clamped = Self.clampedUndoDepth(undoDepth)
            if clamped != undoDepth {
                undoDepth = clamped // re-enters; the second pass persists
                return
            }
            persist(undoDepth, Defaults.Keys.undoDepth)
        }
    }
    /// The other half of the history cap: the depth cap alone does
    /// not bound memory, because one brush stroke's snapshot can be tens of
    /// MB. Held in MB — the pane's unit — and exposed to `DocumentStore` in
    /// bytes through `undoByteBudget`.
    @Published var undoByteBudgetMB: Int = AppSettings.clampedUndoByteBudgetMB(
        Defaults.value(Defaults.Keys.undoByteBudgetMB)) {
        didSet {
            let clamped = Self.clampedUndoByteBudgetMB(undoByteBudgetMB)
            if clamped != undoByteBudgetMB {
                undoByteBudgetMB = clamped // re-enters; the second pass persists
                return
            }
            persist(undoByteBudgetMB, Defaults.Keys.undoByteBudgetMB)
        }
    }

    /// What `DocumentStore.undoByteBudget` mirrors. Capped at a quarter of
    /// physical memory however high the preference goes: a budget larger than
    /// the machine can hold is not a budget.
    var undoByteBudget: Int {
        min(undoByteBudgetMB * 1_048_576,
            Int(ProcessInfo.processInfo.physicalMemory / 4))
    }

    static let undoDepthRange = 10...500
    /// 250 MB is roughly ten 6000×4000 strokes — below that a paint session
    /// can barely undo at all; the top end is for large-memory machines.
    static let undoByteBudgetMBRange = 250...16_000

    static func clampedUndoDepth(_ value: Int) -> Int {
        min(max(value, undoDepthRange.lowerBound), undoDepthRange.upperBound)
    }

    static func clampedUndoByteBudgetMB(_ value: Int) -> Int {
        min(max(value, undoByteBudgetMBRange.lowerBound), undoByteBudgetMBRange.upperBound)
    }

    private func persist<Value>(_ value: Value, _ key: DefaultsKey<Value>) {
        guard !isReloading else { return }
        Defaults.set(value, for: key)
    }

    /// Re-reads every live setting from `Defaults`. Called after a pane's
    /// "Reset to Defaults" (which removes the keys, so this picks up the
    /// documented fallbacks) and by tests after swapping `Defaults.store`.
    func reload() {
        isReloading = true
        gridSpacing = Defaults.value(Defaults.Keys.gridSpacing)
        gridSubdivisions = Defaults.value(Defaults.Keys.gridSubdivisions)
        snappingEnabled = Defaults.value(Defaults.Keys.snappingEnabled)
        guideColor = Defaults.value(Defaults.Keys.guideColor)
        gridColor = Defaults.value(Defaults.Keys.gridColor)
        undoDepth = Self.clampedUndoDepth(Defaults.value(Defaults.Keys.undoDepth))
        undoByteBudgetMB = Self.clampedUndoByteBudgetMB(
            Defaults.value(Defaults.Keys.undoByteBudgetMB))
        isReloading = false
    }
}

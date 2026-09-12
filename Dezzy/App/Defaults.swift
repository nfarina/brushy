import CoreGraphics
import Foundation

/// The app's single `UserDefaults` path. Everything preference-like
/// goes through here — before this, view furniture went through a private
/// `ViewDefaults` enum inside `DocumentStore` and the New Document dialog
/// reached into `UserDefaults.standard` with its own ad-hoc keys, so nothing
/// could enumerate, reset or test the preference surface.
///
/// These are preference-like (Photoshop keeps ruler/grid setup in
/// Preferences), so they are deliberately not in the document and **never in
/// the undo history** — the rule the old `ViewDefaults` stated, carried over
/// verbatim. Nothing in this file touches `DocumentStore.commit`.
///
/// Keys are namespaced by domain (`view.*`, `tools.*`, `newDoc.*`, `color.*`,
/// `perf.*`) but the raw name is stated explicitly per key rather than derived,
/// so the pre-existing `view.*` and `new.*` keys keep working untouched: a user
/// upgrading into this build loses no settings.
enum Defaults {
    /// Injectable so tests can point at a throwaway `UserDefaults(suiteName:)`
    /// — the old `ViewDefaults` hit `.standard` directly, which meant any test
    /// exercising it wrote to the developer's real preferences.
    static var store: UserDefaults = .standard

    static func value<Value>(_ key: DefaultsKey<Value>) -> Value {
        guard let object = store.object(forKey: key.name),
              let decoded = Value.fromDefaultsObject(object) else { return key.fallback }
        return decoded
    }

    static func set<Value>(_ value: Value, for key: DefaultsKey<Value>) {
        store.set(value.defaultsObject, forKey: key.name)
    }

    /// Clears one pane's worth of settings, so the next read returns each
    /// key's documented fallback. Scoped by domain, never a blanket wipe: a
    /// "Reset to Defaults" button in the Tools pane must not undo the user's
    /// colour-management choices.
    static func reset(_ domain: SettingsDomain) {
        for key in Keys.all where key.domain == domain {
            store.removeObject(forKey: key.name)
        }
    }
}

/// Pane-sized grouping. One case per Settings tab, which is what makes a
/// pane-scoped "Reset to Defaults" a one-liner.
enum SettingsDomain: String, CaseIterable {
    /// Rulers, guides, grid, snapping — the Guides & Grid pane.
    case view
    /// Tool option-bar defaults — the Tools pane.
    case tools
    /// New-document size and structure — the General pane.
    case newDoc
    /// Export colour management — the Color pane.
    case color
    /// Undo depth (and, from, the history byte budget).
    case perf
    /// The AI chat sidebar: model choice and thinking level — the AI pane.
    /// The API key itself lives in the Keychain (`APIKeys`), never here.
    case chat
}

/// A typed preference key: name, fallback and owning pane in one value, so
/// `Defaults.value(_:)` can't be handed the wrong type and no call site has to
/// repeat the fallback.
struct DefaultsKey<Value: DefaultsValue> {
    let name: String
    let fallback: Value
    let domain: SettingsDomain

    init(_ name: String, default fallback: Value, domain: SettingsDomain) {
        self.name = name
        self.fallback = fallback
        self.domain = domain
    }

    var erased: AnyDefaultsKey { AnyDefaultsKey(name: name, domain: domain) }
}

/// Type-erased key, for the registry `reset(_:)` walks.
struct AnyDefaultsKey {
    let name: String
    let domain: SettingsDomain
}

// MARK: - Storable values

/// What a `DefaultsKey` can hold. `UserDefaults` only stores property-list
/// objects, so richer values (colours, text/shape styles) round-trip through
/// JSON `Data` rather than being flattened into a pile of scalar keys.
protocol DefaultsValue {
    static func fromDefaultsObject(_ object: Any) -> Self?
    var defaultsObject: Any { get }
}

extension Bool: DefaultsValue {
    static func fromDefaultsObject(_ object: Any) -> Bool? { (object as? NSNumber)?.boolValue }
    var defaultsObject: Any { self }
}

extension Int: DefaultsValue {
    static func fromDefaultsObject(_ object: Any) -> Int? { (object as? NSNumber)?.intValue }
    var defaultsObject: Any { self }
}

extension Double: DefaultsValue {
    /// Reads through `NSNumber` on purpose: a key written as an Int (a legacy
    /// `view.gridSpacing` of 100, or a plist edited by hand) must still read
    /// back as a Double instead of silently falling back.
    static func fromDefaultsObject(_ object: Any) -> Double? { (object as? NSNumber)?.doubleValue }
    var defaultsObject: Any { self }
}

extension String: DefaultsValue {
    static func fromDefaultsObject(_ object: Any) -> String? { object as? String }
    var defaultsObject: Any { self }
}

/// String-backed enums (export profile, gradient shape) store their raw value,
/// so an unknown future case degrades to the fallback rather than crashing.
extension DefaultsValue where Self: RawRepresentable, Self.RawValue == String {
    static func fromDefaultsObject(_ object: Any) -> Self? {
        (object as? String).flatMap(Self.init(rawValue:))
    }
    var defaultsObject: Any { rawValue }
}

extension ExportProfile: DefaultsValue {}

/// Codable structs stored as JSON `Data`. Adding a field to `TextSpec` /
/// `ShapeSpec` keeps old stored values readable as long as the new field has a
/// default, which is how those specs are already written for.
protocol JSONDefaultsValue: DefaultsValue, Codable {}

extension JSONDefaultsValue {
    static func fromDefaultsObject(_ object: Any) -> Self? {
        guard let data = object as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    var defaultsObject: Any { (try? JSONEncoder().encode(self)) ?? Data() }
}

extension ColorSpec: JSONDefaultsValue {}
extension TextSpec: JSONDefaultsValue {}
extension ShapeSpec: JSONDefaultsValue {}

// MARK: - The keys

extension Defaults {
    /// Every preference the app has, in one place.
    ///
    /// Each key is tagged **LIVE** or **SEED-ONLY**; the distinction is the
    /// thing most likely to drift, so it is stated per key rather than only in
    /// the plan:
    ///
    /// - **LIVE** — mirrored on `AppSettings` and pushed into every open
    ///   `DocumentStore` the moment it changes. Photoshop applies grid spacing
    ///   and snapping live, and users expect a grid change to be visible
    ///   without reopening the window.
    /// - **SEED-ONLY** — read once, when the thing it configures is created
    ///   (`DocumentStore.init`, `DezzyDocument.init`, the Export sheet's
    ///   `@State`). Changing it affects the *next* document/sheet, never an
    ///   open one.
    ///
    /// Adding a key means adding it to `all` below as well — that array is
    /// what pane-scoped `reset(_:)` walks.
    enum Keys {
        // MARK: view — Guides & Grid pane
        // The five toggles below are SEED-ONLY: they are per-window View-menu
        // state (⌘R, ⌘;, ⌘'), and the menu writes them back so a new window
        // adopts the last-used setup. The Settings pane edits the same key as
        // the "show on open" default.
        /// SEED-ONLY.
        static let rulersVisible = DefaultsKey("view.rulersVisible", default: false, domain: .view)
        /// SEED-ONLY.
        static let guidesVisible = DefaultsKey("view.guidesVisible", default: true, domain: .view)
        /// SEED-ONLY.
        static let guidesLocked = DefaultsKey("view.guidesLocked", default: false, domain: .view)
        /// SEED-ONLY.
        static let gridVisible = DefaultsKey("view.gridVisible", default: false, domain: .view)
        /// SEED-ONLY — View → Show Pixel Grid. On by default, like Photoshop's;
        /// it only draws above 500% zoom anyway.
        static let pixelGridVisible = DefaultsKey("view.pixelGridVisible", default: true, domain: .view)
        /// LIVE — View → Snap is the master switch over all snapping; changing
        /// the default mid-session should not leave open windows disagreeing.
        static let snappingEnabled = DefaultsKey("view.snappingEnabled", default: true, domain: .view)
        /// LIVE — major gridline spacing, canvas px.
        static let gridSpacing = DefaultsKey("view.gridSpacing", default: 100.0, domain: .view)
        /// LIVE.
        static let gridSubdivisions = DefaultsKey("view.gridSubdivisions", default: 4, domain: .view)
        /// LIVE — cyan, the Photoshop convention, so user guides read apart
        /// from the magenta smart guides (`CanvasOverlayView`).
        static let guideColor = DefaultsKey("view.guideColor",
                                            default: ColorSpec(r: 0, g: 1, b: 1),
                                            domain: .view)
        /// LIVE — the grid's neutral grey; alpha is scaled per line class
        /// (minor lines draw at 45% of the major alpha) in the overlay.
        static let gridColor = DefaultsKey("view.gridColor",
                                           default: ColorSpec(r: 0.6, g: 0.6, b: 0.6, a: 0.55),
                                           domain: .view)

        // MARK: tools — Tools pane (all SEED-ONLY)
        // Read once in `DocumentStore.init`. Changing a brush default must not
        // yank the size out from under a window the user is painting in.
        /// SEED-ONLY — canvas px, diameter.
        static let brushSize = DefaultsKey("tools.brushSize", default: 60.0, domain: .tools)
        /// SEED-ONLY — %.
        static let brushHardness = DefaultsKey("tools.brushHardness", default: 50.0, domain: .tools)
        /// SEED-ONLY — %.
        static let brushOpacity = DefaultsKey("tools.brushOpacity", default: 100.0, domain: .tools)
        /// SEED-ONLY — box edge in canvas px: 1 = point sample, 3 = 3×3, 5 = 5×5.
        static let eyedropperSampleSize = DefaultsKey("tools.eyedropperSampleSize",
                                                      default: 1, domain: .tools)
        /// SEED-ONLY — Move tool Auto-Select. Off by default, like
        /// Photoshop's: a click that silently retargets the layer is a
        /// surprise until you ask for it.
        static let autoSelectLayer = DefaultsKey("tools.autoSelectLayer", default: false, domain: .tools)
        /// SEED-ONLY — feather field, canvas px.
        static let featherAmount = DefaultsKey("tools.featherAmount", default: 0.0, domain: .tools)
        /// SEED-ONLY — style applied to the next created text layer.
        static let textStyle = DefaultsKey("tools.textStyle", default: TextSpec(), domain: .tools)
        /// SEED-ONLY — style applied to the next created shape.
        static let shapeStyle = DefaultsKey("tools.shapeStyle",
                                            default: ShapeSpec(kind: .rectangle, fill: nil,
                                                               stroke: .black, strokeWidth: 4),
                                            domain: .tools)
        // Deliberately NOT persisted, though they also reset on relaunch:
        // the foreground/background colour wells and the gradient options.
        // They read as transient tool state rather than preferences (they have
        // no Settings control, and X / D reset the colours by design), and
        // writing every eyedropper sample or gradient flip into UserDefaults
        // would make one document's tool state leak into the next window.

        // MARK: newDoc — General pane (all SEED-ONLY, by definition)
        /// SEED-ONLY. Raw name kept as `new.width`: it predates this file
        /// (`NewDocumentDialog`), and renaming it would drop the user's
        /// last-used size on upgrade.
        static let newDocumentWidth = DefaultsKey("new.width", default: 1920, domain: .newDoc)
        /// SEED-ONLY — see `newDocumentWidth` on the raw name.
        static let newDocumentHeight = DefaultsKey("new.height", default: 1080, domain: .newDoc)
        /// SEED-ONLY — every new document starts with a transparent "Layer 1"
        /// so the canvas is immediately brushable (Photoshop parity). Was
        /// hardcoded in `DezzyDocument.init`; now a preference.
        static let startWithBlankLayer = DefaultsKey("newDoc.startWithBlankLayer",
                                                     default: true, domain: .newDoc)
        /// SEED-ONLY — gates AppKit's window/document state restoration at
        /// launch (`AppDelegate.applicationShouldRestoreApplicationState`).
        static let reopenDocumentsOnLaunch = DefaultsKey("newDoc.reopenOnLaunch",
                                                         default: true, domain: .newDoc)

        // MARK: color — Color pane (all SEED-ONLY: the Export sheet reads them
        // into its `@State` when it opens, and per-export overrides stay
        // per-export — they don't write back.)
        /// SEED-ONLY — output profile.
        static let exportProfile = DefaultsKey("color.exportProfile",
                                               default: ExportProfile.sRGB, domain: .color)
        /// SEED-ONLY — embed the ICC profile in the exported file.
        static let embedProfile = DefaultsKey("color.embedProfile", default: true, domain: .color)
        /// SEED-ONLY — 16 bits per channel where the format supports it.
        static let exportSixteenBit = DefaultsKey("color.sixteenBit", default: false, domain: .color)
        /// SEED-ONLY — 0…1, JPEG only.
        static let jpegQuality = DefaultsKey("color.jpegQuality", default: 0.9, domain: .color)

        // MARK: perf — Performance pane
        /// LIVE — snapshot history cap. Lowering it with a deep history
        /// open evicts from the front immediately (see
        /// `DocumentStore.evictOverBudgetHistory`), not at the next commit.
        static let undoDepth = DefaultsKey("perf.undoDepth", default: 100, domain: .perf)
        /// LIVE — the other half of the history cap, in MB. A depth
        /// cap alone does not bound memory: most snapshots are nearly free
        /// (shared `CGImage` sources, copy-on-write masks) but each brush
        /// stroke bakes a new full-size bitmap, and 100 strokes on a 6000×4000
        /// layer were measured retaining 9.6 GB. Stored in MB rather than
        /// bytes so the pane's control and the stored value are the same unit.
        static let undoByteBudgetMB = DefaultsKey("perf.undoByteBudgetMB",
                                                  default: 2_000, domain: .perf)

        // MARK: chat — AI pane
        /// LIVE — read when each turn is sent (`ChatStore.makeProvider`).
        static let chatModel = DefaultsKey("chat.model", default: "gemini-3.8-flash", domain: .chat)
        /// LIVE — Gemini `thinking_level`; "default" sends none.
        static let chatThinkingLevel = DefaultsKey("chat.thinkingLevel", default: "low", domain: .chat)
        /// LIVE — the model behind the `generate_image` tool.
        static let imageModel = DefaultsKey("chat.imageModel", default: "gemini-3.1-flash-image",
                                            domain: .chat)
        /// App-level sidebar visibility (`ChatStore.isSidebarVisible`), so
        /// the next launch opens the way the last one closed.
        static let chatSidebarVisible = DefaultsKey("chat.sidebarVisible", default: false, domain: .chat)

        /// The registry `Defaults.reset(_:)` walks. Every key above appears
        /// here exactly once — `DefaultsTests` checks the names are unique and
        /// that no domain is empty.
        static let all: [AnyDefaultsKey] = [
            rulersVisible.erased, guidesVisible.erased, guidesLocked.erased,
            gridVisible.erased, pixelGridVisible.erased, snappingEnabled.erased, gridSpacing.erased,
            gridSubdivisions.erased, guideColor.erased, gridColor.erased,
            brushSize.erased, brushHardness.erased, brushOpacity.erased,
            eyedropperSampleSize.erased, autoSelectLayer.erased, featherAmount.erased,
            textStyle.erased, shapeStyle.erased,
            newDocumentWidth.erased, newDocumentHeight.erased,
            startWithBlankLayer.erased, reopenDocumentsOnLaunch.erased,
            exportProfile.erased, embedProfile.erased, exportSixteenBit.erased,
            jpegQuality.erased,
            undoDepth.erased, undoByteBudgetMB.erased,
            chatModel.erased, chatThinkingLevel.erased, imageModel.erased, chatSidebarVisible.erased,
        ]
    }
}

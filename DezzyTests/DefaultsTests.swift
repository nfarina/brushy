import AppKit
import CoreGraphics
import XCTest

// No `@testable import Dezzy` — see the note atop ClipboardTests.swift.

/// — the one persistence path, and the app-scoped/document-scoped
/// split that hangs off it.
///
/// Every test runs against an injected `UserDefaults(suiteName:)`: the old
/// `ViewDefaults` hit `.standard`, so exercising it wrote to the developer's
/// real preferences. `tearDown` puts `Defaults.store` back and re-reads
/// `AppSettings` from it — the singleton is process-wide, and `StoreTests`
/// asserts the shipped undo depth of 100.
///
/// Deliberately windowless: this tests the settings *model*, never the
/// Settings window (a Metal-backed canvas window in the test process
/// measurably slows the performance test — see `NewDocumentTests`).
final class DefaultsTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "dezzy.defaults.tests.\(UUID().uuidString)"
        Defaults.store = UserDefaults(suiteName: suiteName)!
        AppSettings.shared.reload()
    }

    override func tearDown() {
        let name = suiteName
        Defaults.store.removePersistentDomain(forName: name)
        Defaults.store = .standard
        AppSettings.shared.reload()
        super.tearDown()
    }

    // MARK: - Typed keys

    /// Missing → documented fallback; set → reads back; removed → fallback
    /// again. Run over every key so a new one can't quietly land with a
    /// non-round-tripping value type.
    private func roundTrip<Value: DefaultsValue & Equatable>(
        _ key: DefaultsKey<Value>, _ value: Value,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Defaults.value(key), key.fallback,
                       "\(key.name): a missing key must return its fallback",
                       file: file, line: line)
        XCTAssertNotEqual(value, key.fallback,
                          "\(key.name): the probe value must differ from the fallback, "
                          + "or the round trip proves nothing",
                          file: file, line: line)
        Defaults.set(value, for: key)
        XCTAssertEqual(Defaults.value(key), value, "\(key.name): round trip",
                       file: file, line: line)
        Defaults.store.removeObject(forKey: key.name)
        XCTAssertEqual(Defaults.value(key), key.fallback,
                       "\(key.name): back to the fallback once cleared",
                       file: file, line: line)
    }

    func testEveryKeyRoundTrips() {
        let K = Defaults.Keys.self
        // view
        roundTrip(K.rulersVisible, true)
        roundTrip(K.guidesVisible, false)
        roundTrip(K.guidesLocked, true)
        roundTrip(K.gridVisible, true)
        roundTrip(K.snappingEnabled, false)
        roundTrip(K.gridSpacing, 37.5)
        roundTrip(K.gridSubdivisions, 7)
        roundTrip(K.guideColor, ColorSpec(r: 1, g: 0.25, b: 0, a: 0.8))
        roundTrip(K.gridColor, ColorSpec(r: 0.1, g: 0.2, b: 0.3, a: 0.4))
        // tools
        roundTrip(K.brushSize, 17.5)
        roundTrip(K.brushHardness, 12)
        roundTrip(K.brushOpacity, 33)
        roundTrip(K.eyedropperSampleSize, 5)
        roundTrip(K.autoSelectLayer, false)
        roundTrip(K.featherAmount, 4.25)
        roundTrip(K.textStyle, TextSpec(text: "T", fontName: "Menlo", fontSize: 21,
                                        color: ColorSpec(r: 0, g: 0.5, b: 1)))
        roundTrip(K.shapeStyle, ShapeSpec(kind: .ellipse, fill: .white,
                                          stroke: nil, strokeWidth: 9))
        // newDoc
        roundTrip(K.newDocumentWidth, 640)
        roundTrip(K.newDocumentHeight, 480)
        roundTrip(K.startWithBlankLayer, false)
        roundTrip(K.reopenDocumentsOnLaunch, false)
        // color
        roundTrip(K.exportProfile, .displayP3)
        roundTrip(K.embedProfile, false)
        roundTrip(K.exportSixteenBit, true)
        roundTrip(K.jpegQuality, 0.42)
        // perf
        roundTrip(K.undoDepth, 25)
        roundTrip(K.undoByteBudgetMB, 750)
    }

    /// `Keys.all` is what `reset(_:)` walks, so a key missing from it would
    /// silently survive a Reset to Defaults.
    func testKeyRegistryIsCompleteAndUnique() {
        let all = Defaults.Keys.all
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "duplicate raw key name")
        for domain in SettingsDomain.allCases {
            XCTAssertFalse(all.filter { $0.domain == domain }.isEmpty,
                           "\(domain) has no keys — a pane with nothing to reset")
        }
        // Spot-check the count against the declared keys above: bumping one
        // without the other is the drift this guards.
        XCTAssertEqual(all.count, 28)
    }

    /// A garbage value of the wrong type must not crash or leak through.
    func testWrongTypeFallsBack() {
        Defaults.store.set("not a number", forKey: Defaults.Keys.gridSpacing.name)
        XCTAssertEqual(Defaults.value(Defaults.Keys.gridSpacing), 100)
        Defaults.store.set(Data([0x00, 0x01]), forKey: Defaults.Keys.guideColor.name)
        XCTAssertEqual(Defaults.value(Defaults.Keys.guideColor),
                       Defaults.Keys.guideColor.fallback)
        Defaults.store.set("mauve", forKey: Defaults.Keys.exportProfile.name)
        XCTAssertEqual(Defaults.value(Defaults.Keys.exportProfile), .sRGB,
                       "an unknown enum raw value degrades to the fallback")
    }

    // MARK: - Domain-scoped reset

    func testResetClearsOnlyItsOwnDomain() {
        Defaults.set(9.5, for: Defaults.Keys.gridSpacing)          // view
        Defaults.set(11.5, for: Defaults.Keys.brushSize)           // tools
        Defaults.set(321, for: Defaults.Keys.newDocumentWidth)     // newDoc
        Defaults.set(false, for: Defaults.Keys.embedProfile)       // color
        Defaults.set(42, for: Defaults.Keys.undoDepth)             // perf

        Defaults.reset(.tools)

        XCTAssertEqual(Defaults.value(Defaults.Keys.brushSize), 60, "cleared")
        XCTAssertEqual(Defaults.value(Defaults.Keys.gridSpacing), 9.5)
        XCTAssertEqual(Defaults.value(Defaults.Keys.newDocumentWidth), 321)
        XCTAssertEqual(Defaults.value(Defaults.Keys.embedProfile), false)
        XCTAssertEqual(Defaults.value(Defaults.Keys.undoDepth), 42)

        for domain in SettingsDomain.allCases { Defaults.reset(domain) }
        XCTAssertEqual(Defaults.value(Defaults.Keys.gridSpacing), 100)
        XCTAssertEqual(Defaults.value(Defaults.Keys.newDocumentWidth), 1920)
        XCTAssertEqual(Defaults.value(Defaults.Keys.embedProfile), true)
        XCTAssertEqual(Defaults.value(Defaults.Keys.undoDepth), 100)
    }

    // MARK: - Legacy keys survive the move

    /// The whole point of naming the keys explicitly rather than deriving them
    /// from the domain: someone upgrading into this build keeps the settings
    /// the old `ViewDefaults` / `NewDocumentDialog` wrote. Written here through
    /// the RAW key, exactly as the old code wrote it, and read through the new
    /// typed accessor.
    func testLegacyRawKeysStillRead() {
        Defaults.store.set(true, forKey: "view.rulersVisible")
        Defaults.store.set(false, forKey: "view.guidesVisible")
        Defaults.store.set(true, forKey: "view.guidesLocked")
        Defaults.store.set(false, forKey: "view.snappingEnabled")
        Defaults.store.set(true, forKey: "view.gridVisible")
        Defaults.store.set(64.0, forKey: "view.gridSpacing")
        Defaults.store.set(3, forKey: "view.gridSubdivisions")
        Defaults.store.set(2400, forKey: "new.width")
        Defaults.store.set(1600, forKey: "new.height")

        XCTAssertEqual(Defaults.value(Defaults.Keys.rulersVisible), true)
        XCTAssertEqual(Defaults.value(Defaults.Keys.guidesVisible), false)
        XCTAssertEqual(Defaults.value(Defaults.Keys.guidesLocked), true)
        XCTAssertEqual(Defaults.value(Defaults.Keys.snappingEnabled), false)
        XCTAssertEqual(Defaults.value(Defaults.Keys.gridVisible), true)
        XCTAssertEqual(Defaults.value(Defaults.Keys.gridSpacing), 64)
        XCTAssertEqual(Defaults.value(Defaults.Keys.gridSubdivisions), 3)
        XCTAssertEqual(Defaults.value(Defaults.Keys.newDocumentWidth), 2400)
        XCTAssertEqual(Defaults.value(Defaults.Keys.newDocumentHeight), 1600)
    }

    /// `view.gridSpacing` written as an integer by an older build (or by hand)
    /// must still read as a Double rather than silently falling back to 100.
    func testLegacyIntegerReadsAsDouble() {
        Defaults.store.set(75, forKey: "view.gridSpacing")
        XCTAssertEqual(Defaults.value(Defaults.Keys.gridSpacing), 75)
    }

    // MARK: - Seeding a new store

    private func makeDocument() -> Document {
        var document = Document(canvasSize: CGSize(width: 300, height: 200))
        document.layers = [Layer(name: "L",
                                 source: GeneratedImages.solid(
                                     width: 100, height: 80, r: 10, g: 20, b: 30,
                                     colorSpace: DezzyColorSpace.displayP3))]
        return document
    }

    func testNewStoreSeedsToolDefaults() {
        Defaults.set(23.0, for: Defaults.Keys.brushSize)
        Defaults.set(88.0, for: Defaults.Keys.brushHardness)
        Defaults.set(44.0, for: Defaults.Keys.brushOpacity)
        Defaults.set(5, for: Defaults.Keys.eyedropperSampleSize)
        Defaults.set(false, for: Defaults.Keys.autoSelectLayer)
        Defaults.set(6.5, for: Defaults.Keys.featherAmount)
        Defaults.set(TextSpec(text: "Text", fontName: "Menlo", fontSize: 30, color: .black),
                     for: Defaults.Keys.textStyle)
        Defaults.set(ShapeSpec(kind: .ellipse, fill: .white, stroke: .black, strokeWidth: 7),
                     for: Defaults.Keys.shapeStyle)

        let store = DocumentStore(document: makeDocument())
        XCTAssertEqual(store.brushSize, 23)
        XCTAssertEqual(store.brushHardness, 88)
        XCTAssertEqual(store.brushOpacity, 44)
        XCTAssertEqual(store.eyedropperSampleSize, 5)
        XCTAssertFalse(store.autoSelectLayer)
        XCTAssertEqual(store.featherAmount, 6.5)
        XCTAssertEqual(store.textStyle.fontName, "Menlo")
        XCTAssertEqual(store.shapeStyle.strokeWidth, 7)
    }

    /// The View-menu toggles write back so the NEXT window adopts the
    /// last-used setup — the behaviour the old `ViewDefaults` had, unchanged.
    func testSeedOnlySettingsPersistOnChange() {
        let store = DocumentStore(document: makeDocument())
        store.rulersVisible = true
        store.gridVisible = true
        store.guidesLocked = true

        XCTAssertEqual(Defaults.value(Defaults.Keys.rulersVisible), true)
        XCTAssertEqual(Defaults.value(Defaults.Keys.gridVisible), true)
        XCTAssertEqual(Defaults.value(Defaults.Keys.guidesLocked), true)
    }

    // MARK: - Live vs seed-only

    func testLiveSettingsReachOpenDocumentsAndSeedOnlyOnesDoNot() {
        let store = DocumentStore(document: makeDocument())
        let seededBrushSize = store.brushSize

        AppSettings.shared.gridSpacing = 42
        AppSettings.shared.gridSubdivisions = 8
        AppSettings.shared.snappingEnabled = false
        AppSettings.shared.guideColor = ColorSpec(r: 1, g: 0, b: 1)
        AppSettings.shared.gridColor = ColorSpec(r: 0, g: 0, b: 1, a: 0.5)

        XCTAssertEqual(store.gridSpacing, 42, "grid spacing is LIVE")
        XCTAssertEqual(store.gridSubdivisions, 8)
        XCTAssertFalse(store.snappingEnabled)
        XCTAssertEqual(store.guideColor, ColorSpec(r: 1, g: 0, b: 1))
        XCTAssertEqual(store.gridColor, ColorSpec(r: 0, g: 0, b: 1, a: 0.5))
        XCTAssertEqual(Defaults.value(Defaults.Keys.gridSpacing), 42,
                       "a live change persists through the same one path")

        Defaults.set(seededBrushSize + 100, for: Defaults.Keys.brushSize)
        XCTAssertEqual(store.brushSize, seededBrushSize,
                       "brush size is SEED-ONLY — it must not move under an open window")
        XCTAssertEqual(DocumentStore(document: makeDocument()).brushSize,
                       seededBrushSize + 100,
                       "…but the next window picks it up")
    }

    /// The View menu's ⇧⌘; Snap toggle is per-window state on the store; it has
    /// to push back up so a second window and the Settings pane agree.
    func testStoreChangeToALiveSettingPropagatesBack() {
        let first = DocumentStore(document: makeDocument())
        let second = DocumentStore(document: makeDocument())

        first.snappingEnabled = false
        XCTAssertFalse(AppSettings.shared.snappingEnabled)
        XCTAssertFalse(second.snappingEnabled, "open windows never disagree about Snap")
        XCTAssertEqual(Defaults.value(Defaults.Keys.snappingEnabled), false)
    }

    /// Nothing here may reach `commit` — preferences are outside the document
    /// and outside history, the rule the old `ViewDefaults` stated.
    func testSettingsNeverEnterUndoHistory() {
        let store = DocumentStore(document: makeDocument())
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager

        store.rulersVisible = true
        store.brushSize = 99
        AppSettings.shared.gridSpacing = 12
        AppSettings.shared.guideColor = ColorSpec(r: 1, g: 1, b: 0)
        AppSettings.shared.undoDepth = 40

        XCTAssertFalse(store.canUndo, "no setting creates an undo step")
        XCTAssertFalse(undoManager.canUndo)
    }

    // MARK: - Undo depth (Performance pane)

    /// Lowering the depth with a deep history open truncates from the front
    /// straight away, rather than waiting for the next commit — otherwise the
    /// memory the user was trying to reclaim stays held.
    func testLoweringUndoDepthTruncatesExistingHistoryImmediately() {
        let store = DocumentStore(document: makeDocument())
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 500
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        let id = store.document.layers[0].id
        for i in 1...60 {
            undoManager.beginUndoGrouping()
            store.renameLayer(id, to: "N\(i)")
            undoManager.endUndoGrouping()
        }
        XCTAssertEqual(store.document[layerID: id]?.name, "N60")

        // 61 snapshots (the initial one plus 60 commits) capped to 10 keeps the
        // last 10 — "N51"…"N60" — so the oldest reachable state is N51 and the
        // current state is untouched.
        AppSettings.shared.undoDepth = 10
        XCTAssertEqual(store.document[layerID: id]?.name, "N60",
                       "trimming the front never disturbs where the user is")

        var undos = 0
        while store.canUndo && undos < 200 {
            undoManager.undo()
            undos += 1
        }
        XCTAssertEqual(undos, 9, "10 snapshots ⇒ 9 undo steps")
        XCTAssertEqual(store.document[layerID: id]?.name, "N51")
    }

    /// The depth is clamped on the way in: 0 would leave `commit` indexing an
    /// empty history.
    func testUndoDepthIsClamped() {
        AppSettings.shared.undoDepth = 0
        XCTAssertEqual(AppSettings.shared.undoDepth, AppSettings.undoDepthRange.lowerBound)
        AppSettings.shared.undoDepth = 100_000
        XCTAssertEqual(AppSettings.shared.undoDepth, AppSettings.undoDepthRange.upperBound)
    }

    /// The byte budget ('s cap, surfaced in the same pane) clamps the
    /// same way, and never exceeds a quarter of physical memory however high
    /// the stored preference goes — a budget the machine can't hold is not a
    /// budget.
    func testUndoByteBudgetIsClampedAndBoundedByPhysicalMemory() {
        AppSettings.shared.undoByteBudgetMB = 1
        XCTAssertEqual(AppSettings.shared.undoByteBudgetMB,
                       AppSettings.undoByteBudgetMBRange.lowerBound)
        AppSettings.shared.undoByteBudgetMB = 10_000_000
        XCTAssertEqual(AppSettings.shared.undoByteBudgetMB,
                       AppSettings.undoByteBudgetMBRange.upperBound)
        XCTAssertLessThanOrEqual(AppSettings.shared.undoByteBudget,
                                 Int(ProcessInfo.processInfo.physicalMemory / 4))
    }

    /// LIVE, like the depth: lowering the budget with a big history open
    /// evicts right away rather than at the next commit. Uses renames over one
    /// shared bitmap, so the whole history costs about one image — dropping
    /// the budget under that forces eviction without allocating gigabytes.
    func testLoweringUndoByteBudgetEvictsOpenHistoriesImmediately() {
        let side = 300
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        document.layers = [Layer(name: "big",
                                 source: GeneratedImages.solid(width: side, height: side,
                                                               r: 1, g: 2, b: 3,
                                                               colorSpace: DezzyColorSpace.displayP3))]
        let store = DocumentStore(document: document)
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 500
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        let id = document.layers[0].id
        for i in 1...20 {
            undoManager.beginUndoGrouping()
            store.renameLayer(id, to: "N\(i)")
            undoManager.endUndoGrouping()
        }
        XCTAssertEqual(store.historyEntries.count, 21)

        // Below one image's worth: everything but the state on screen goes.
        AppSettings.shared.undoByteBudgetMB = AppSettings.undoByteBudgetMBRange.lowerBound
        store.undoByteBudget = 1
        XCTAssertEqual(store.historyEntries.count, 1,
                       "the newest state is never evicted, however small the budget")
        XCTAssertEqual(store.document[layerID: id]?.name, "N20",
                       "evicting from the front never disturbs where the user is")
        XCTAssertEqual(store.historyPosition, 0, "the index follows the eviction")
        XCTAssertFalse(store.canUndo)
    }

    // MARK: - New documents

    /// The blank "Layer 1" (commit e986bcd) was hardcoded; the General pane
    /// makes it a preference, and both creation paths honour it.
    func testBlankLayerPreferenceGatesNewDocuments() {
        Defaults.set(false, for: Defaults.Keys.startWithBlankLayer)
        let bare = DezzyDocument()
        defer { bare.close() }
        XCTAssertTrue(bare.store.document.layers.isEmpty)

        let sized = AppDelegate.sizedUntitledDocument(size: CGSize(width: 320, height: 240))
        defer { sized.close() }
        XCTAssertTrue(sized.store.document.layers.isEmpty)

        Defaults.set(true, for: Defaults.Keys.startWithBlankLayer)
        let withLayer = DezzyDocument()
        defer { withLayer.close() }
        XCTAssertEqual(withLayer.store.document.layers.map(\.name), ["Layer 1"])
    }

    // MARK: - The ⌘, menu item

    /// ⌘, has to work with **no document open**, which almost no other command
    /// here does — nearly everything targets `DezzyDocument` and reaches
    /// it through the responder chain. This checks the mechanism that makes it
    /// so (the item targets the app delegate, which is in the chain whether or
    /// not a document exists) rather than the window, which stays out of the
    /// test process. Position is checked too: About, separator, Settings…, the
    /// standard macOS layout.
    func testSettingsMenuItemIsAppScopedAndOnCommandComma() {
        // Note `MainMenuBuilder` tolerates a nil NSApp: instantiating
        // NSApplication.shared here to satisfy it measurably slowed the
        // frame-budget tests that run later in the same process.
        let appMenu = try? XCTUnwrap(MainMenuBuilder.build().items.first?.submenu)
        guard let appMenu else { return XCTFail("no App menu") }
        guard let index = appMenu.items.firstIndex(where: { $0.title == "Settings…" }) else {
            return XCTFail("no Settings… item")
        }
        let item = appMenu.items[index]
        XCTAssertEqual(item.keyEquivalent, ",")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertEqual(item.action, #selector(AppDelegate.showSettings(_:)))
        XCTAssertTrue(appMenu.items[index - 1].isSeparatorItem)
        XCTAssertTrue(appMenu.items[index - 2].title.hasPrefix("About"))

        let action = try? XCTUnwrap(item.action)
        guard let action else { return }
        XCTAssertTrue(AppDelegate.instancesRespond(to: action),
                      "the app delegate handles it, so ⌘, works with zero documents")
        XCTAssertFalse(DezzyDocument.instancesRespond(to: action),
                       "and it deliberately does NOT depend on a document being open")
    }
}

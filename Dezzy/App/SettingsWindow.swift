import AppKit
import SwiftUI

/// The Settings window (⌘,). One shared controller for the whole app:
/// re-invoking ⌘, brings the existing window forward rather than stacking a
/// second one.
///
/// Deliberately **not** parented to a document window and not held by any
/// `DezzyDocument`: preferences are app-scoped, so the window has to
/// survive every document closing, and ⌘, has to work with none open.
///
/// AppKit's `NSTabViewController` in toolbar style, with one SwiftUI pane
/// per tab: that is what every native Settings window is (the tabs ARE the
/// window's toolbar, in `.preference` style). A SwiftUI `TabView` inside a
/// plain `NSWindow` only imitates it, and shoved every tab into an overflow
/// menu once there were six.
final class SettingsWindowController: NSWindowController {
    /// Held while the window is open; dropped on close so the next ⌘, builds
    /// fresh panes, which re-read their values on creation.
    private static var shared: SettingsWindowController?
    private let tabs: SettingsTabViewController

    /// The open Settings window, for `DebugSnapshot`.
    static var currentWindow: NSWindow? { shared?.window }

    static func showWindow(pane: SettingsView.Pane? = nil) {
        let controller = shared ?? {
            let created = SettingsWindowController()
            shared = created
            return created
        }()
        if let pane, let index = SettingsView.Pane.allCases.firstIndex(of: pane) {
            controller.tabs.selectedTabViewItemIndex = index
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        for pane in SettingsView.Pane.allCases {
            // Fixed pane size (`SettingsView` frames it), not SwiftUI's
            // ideal size: a grouped Form reports a size that depends on its
            // content, and the window would jump between tabs.
            let host = NSHostingController(rootView: SettingsView(pane: pane))
            host.sizingOptions = []
            host.preferredContentSize = SettingsView.preferredSize
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.title = SettingsView.Pane.general.title
        window.toolbarStyle = .preference
        // No resize/minimise: a preferences window sizes to its panes, like
        // every other macOS Settings window.
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // Not .darkAqua like the document windows — Settings follows the
        // system appearance, which is what "native-looking" means here.
        self.tabs = tabs
        super.init(window: window)
        window.setFrameAutosaveName("DezzySettings")
        window.setContentSize(SettingsView.preferredSize)
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { _ in Self.shared = nil }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Titles the window after the selected tab, as System Settings and Xcode do.
private final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? "Settings"
    }
}

/// The panes, and a SwiftUI view of one of them. `SettingsView` itself is
/// only used by `DebugSnapshot`, which embeds a pane in the main window
/// (the Settings window is a secondary window and can't be captured).
struct SettingsView: View {
    /// Sized to fit the panes without scrolling, except Tools — which has
    /// four sections and scrolls inside its Form rather than making every
    /// other pane tall and empty.
    static let preferredSize = CGSize(width: 560, height: 520)

    enum Pane: String, CaseIterable {
        case general, guides, tools, performance, color, ai

        var title: String {
            switch self {
            case .general: return "General"
            case .guides: return "Guides & Grid"
            case .tools: return "Tools"
            case .performance: return "Performance"
            case .color: return "Color"
            case .ai: return "AI"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .guides: return "square.grid.3x3"
            case .tools: return "paintbrush"
            case .performance: return "speedometer"
            case .color: return "paintpalette"
            case .ai: return "sparkles"
            }
        }

        @ViewBuilder var view: some View {
            switch self {
            case .general: GeneralSettingsPane()
            case .guides: GuidesGridSettingsPane()
            case .tools: ToolsSettingsPane()
            case .performance: PerformanceSettingsPane()
            case .color: ColorSettingsPane()
            case .ai: AISettingsPane()
            }
        }
    }

    var pane: Pane = .general

    var body: some View {
        pane.view
            .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
    }
}

// MARK: - Shared pane furniture

/// Every pane is Form + a pane-scoped Reset. The reset is scoped to one
/// `SettingsDomain` on purpose: resetting the Tools pane must not throw away
/// the user's colour-management choices.
struct SettingsPane<Content: View>: View {
    /// The only domain this pane's Reset clears — the button can't be wired to
    /// the wrong one, because clearing IS `Defaults.reset(domain)` here.
    let domain: SettingsDomain
    /// Re-reads the pane's state after the keys are gone, so the controls show
    /// the documented fallbacks instead of the values just deleted.
    let reload: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    Defaults.reset(domain)
                    reload()
                }
            }
            // The grouped Form brings its own insets; only this trailing row
            // needs them.
            .padding([.horizontal, .bottom], 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// sRGB round-trip for a settings colour well, matching
/// `ToolOptionsBar.colorBinding(_:)` —: colour wells hold sRGB even though
/// the working space is linear Display P3.
private func colorWellBinding(_ spec: @escaping () -> ColorSpec,
                              set: @escaping (ColorSpec) -> Void) -> Binding<Color> {
    Binding(get: { Color(cgColor: spec().cgColor) },
            set: { newValue in
                let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                set(ColorSpec(cgColor: ns.cgColor))
            })
}

// MARK: - General

/// New-document defaults. Everything here is SEED-ONLY by definition — it
/// describes documents that don't exist yet.
///
/// No units control, deliberately: the app is pixel-only end to end (rulers,
/// Image Size, Canvas Size, export) because `Document` carries no resolution,
/// so an inches/cm picker here would be a control that can't mean anything
/// until documents grow a DPI. The label states the unit instead.
private struct GeneralSettingsPane: View {
    private struct Values: Equatable {
        var width = Defaults.value(Defaults.Keys.newDocumentWidth)
        var height = Defaults.value(Defaults.Keys.newDocumentHeight)
        var startWithBlankLayer = Defaults.value(Defaults.Keys.startWithBlankLayer)
        var reopenOnLaunch = Defaults.value(Defaults.Keys.reopenDocumentsOnLaunch)
    }

    @State private var values = Values()
    @State private var isLoading = false

    var body: some View {
        SettingsPane(domain: .newDoc, reload: {
            isLoading = true
            values = Values()
            isLoading = false
        }) {
            Section("New Document") {
                LabeledContent("Width") {
                    numberField($values.width, width: 80)
                    Text("px").foregroundStyle(.secondary)
                }
                LabeledContent("Height") {
                    numberField($values.height, width: 80)
                    Text("px").foregroundStyle(.secondary)
                }
                Toggle("Start with a blank Layer 1", isOn: $values.startWithBlankLayer)
                Text("A transparent layer so the canvas is immediately brushable, like Photoshop. Turn it off to start with an empty layer stack.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Launch") {
                Toggle("Reopen documents on launch", isOn: $values.reopenOnLaunch)
            }
        }
        .onChange(of: values) { _, new in save(new) }
    }

    private func numberField(_ binding: Binding<Int>, width: CGFloat) -> some View {
        TextField("", value: binding, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(.trailing)
    }

    private func save(_ new: Values) {
        guard !isLoading else { return }
        // Clamped the same way the New Document dialog clamps on Create, so a
        // nonsense preference can't produce an unopenable document.
        let size = DocumentStore.clampedSize(CGSize(width: new.width, height: new.height))
        Defaults.set(Int(size.width), for: Defaults.Keys.newDocumentWidth)
        Defaults.set(Int(size.height), for: Defaults.Keys.newDocumentHeight)
        Defaults.set(new.startWithBlankLayer, for: Defaults.Keys.startWithBlankLayer)
        Defaults.set(new.reopenOnLaunch, for: Defaults.Keys.reopenDocumentsOnLaunch)
    }
}

// MARK: - Guides & Grid

/// Mirrors Photoshop's pane of the same name, and is where the LIVE / SEED-ONLY
/// split is most visible: the top group applies to open windows immediately
/// (it binds `AppSettings`), the bottom group is what a *new* window adopts.
private struct GuidesGridSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    private struct Values: Equatable {
        var rulersVisible = Defaults.value(Defaults.Keys.rulersVisible)
        var guidesVisible = Defaults.value(Defaults.Keys.guidesVisible)
        var guidesLocked = Defaults.value(Defaults.Keys.guidesLocked)
        var gridVisible = Defaults.value(Defaults.Keys.gridVisible)
    }

    @State private var values = Values()
    @State private var isLoading = false

    var body: some View {
        SettingsPane(domain: .view, reload: {
            isLoading = true
            values = Values()
            settings.reload()
            isLoading = false
        }) {
            Section("Appearance") {
                LabeledContent("Guide colour") {
                    ColorPicker("", selection: colorWellBinding({ settings.guideColor },
                                                                set: { settings.guideColor = $0 }),
                                supportsOpacity: true)
                        .labelsHidden()
                }
                LabeledContent("Grid colour") {
                    ColorPicker("", selection: colorWellBinding({ settings.gridColor },
                                                                set: { settings.gridColor = $0 }),
                                supportsOpacity: true)
                        .labelsHidden()
                }
            }
            Section("Grid") {
                LabeledContent("Gridline every") {
                    TextField("", value: $settings.gridSpacing, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("px").foregroundStyle(.secondary)
                }
                LabeledContent("Subdivisions") {
                    Stepper(value: $settings.gridSubdivisions, in: 1...20) {
                        Text("\(settings.gridSubdivisions)").monospacedDigit()
                    }
                    .frame(width: 90)
                }
                Toggle("Snap (guides, grid and smart guides)", isOn: $settings.snappingEnabled)
                Text("These apply to open documents immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Show in new windows") {
                Toggle("Rulers", isOn: $values.rulersVisible)
                Toggle("Guides", isOn: $values.guidesVisible)
                Toggle("Lock guides", isOn: $values.guidesLocked)
                Toggle("Grid", isOn: $values.gridVisible)
            }
        }
        .onChange(of: values) { _, new in save(new) }
    }

    private func save(_ new: Values) {
        guard !isLoading else { return }
        Defaults.set(new.rulersVisible, for: Defaults.Keys.rulersVisible)
        Defaults.set(new.guidesVisible, for: Defaults.Keys.guidesVisible)
        Defaults.set(new.guidesLocked, for: Defaults.Keys.guidesLocked)
        Defaults.set(new.gridVisible, for: Defaults.Keys.gridVisible)
    }
}

// MARK: - Tools

/// Tool option-bar defaults. All SEED-ONLY: `DocumentStore.init` reads them, so
/// they take effect in the next window — changing the brush size here must not
/// yank it out from under a stroke in progress.
private struct ToolsSettingsPane: View {
    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    private struct Values: Equatable {
        var brushSize = Defaults.value(Defaults.Keys.brushSize)
        var brushHardness = Defaults.value(Defaults.Keys.brushHardness)
        var brushOpacity = Defaults.value(Defaults.Keys.brushOpacity)
        var eyedropperSampleSize = Defaults.value(Defaults.Keys.eyedropperSampleSize)
        var autoSelectLayer = Defaults.value(Defaults.Keys.autoSelectLayer)
        var featherAmount = Defaults.value(Defaults.Keys.featherAmount)
        var textStyle = Defaults.value(Defaults.Keys.textStyle)
        var shapeStyle = Defaults.value(Defaults.Keys.shapeStyle)
    }

    @State private var values = Values()
    @State private var isLoading = false

    var body: some View {
        SettingsPane(domain: .tools, reload: {
            isLoading = true
            values = Values()
            isLoading = false
        }) {
            Section("Brush") {
                slider("Size", $values.brushSize, 1...500, unit: "px")
                slider("Hardness", $values.brushHardness, 0...100, unit: "%")
                slider("Opacity", $values.brushOpacity, 1...100, unit: "%")
            }
            Section("Selection & Move") {
                LabeledContent("Feather") {
                    TextField("", value: $values.featherAmount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("px").foregroundStyle(.secondary)
                }
                Picker("Eyedropper sample", selection: $values.eyedropperSampleSize) {
                    Text("Point sample").tag(1)
                    Text("3 × 3 average").tag(3)
                    Text("5 × 5 average").tag(5)
                }
                Toggle("Move tool auto-selects the layer under the cursor",
                       isOn: $values.autoSelectLayer)
            }
            Section("Text") {
                Picker("Font", selection: $values.textStyle.fontName) {
                    if !Self.fontFamilies.contains(values.textStyle.fontName) {
                        Text(values.textStyle.fontName).tag(values.textStyle.fontName)
                    }
                    ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    TextField("", value: $values.textStyle.fontSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("pt").foregroundStyle(.secondary)
                    ColorPicker("", selection: colorWellBinding({ values.textStyle.color },
                                                                set: { values.textStyle.color = $0 }),
                                supportsOpacity: true)
                        .labelsHidden()
                }
            }
            Section("Shape") {
                Picker("Shape", selection: $values.shapeStyle.kind) {
                    ForEach(ShapeSpec.Kind.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Stroke") {
                    TextField("", value: $values.shapeStyle.strokeWidth, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("px").foregroundStyle(.secondary)
                    ColorPicker("", selection: optionalColorWell(\.stroke, fallback: .black),
                                supportsOpacity: true)
                        .labelsHidden()
                }
                Toggle("Filled", isOn: Binding(
                    get: { values.shapeStyle.fill != nil },
                    set: { values.shapeStyle.fill = $0 ? (values.shapeStyle.fill ?? .white) : nil }))
                if values.shapeStyle.fill != nil {
                    LabeledContent("Fill colour") {
                        ColorPicker("", selection: optionalColorWell(\.fill, fallback: .white),
                                    supportsOpacity: true)
                            .labelsHidden()
                    }
                }
            }
        }
        .onChange(of: values) { _, new in save(new) }
    }

    /// `ShapeSpec.fill` / `.stroke` are optional (nil = no fill / no stroke);
    /// the well edits the colour and leaves the nil-ness to the Filled toggle.
    private func optionalColorWell(_ keyPath: WritableKeyPath<ShapeSpec, ColorSpec?>,
                                   fallback: ColorSpec) -> Binding<Color> {
        colorWellBinding({ values.shapeStyle[keyPath: keyPath] ?? fallback },
                         set: { values.shapeStyle[keyPath: keyPath] = $0 })
    }

    private func slider(_ label: String, _ binding: Binding<Double>,
                        _ range: ClosedRange<Double>, unit: String) -> some View {
        LabeledContent(label) {
            Slider(value: binding, in: range)
            Text("\(Int(binding.wrappedValue.rounded()))\(unit)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private func save(_ new: Values) {
        guard !isLoading else { return }
        Defaults.set(new.brushSize, for: Defaults.Keys.brushSize)
        Defaults.set(new.brushHardness, for: Defaults.Keys.brushHardness)
        Defaults.set(new.brushOpacity, for: Defaults.Keys.brushOpacity)
        Defaults.set(new.eyedropperSampleSize, for: Defaults.Keys.eyedropperSampleSize)
        Defaults.set(new.autoSelectLayer, for: Defaults.Keys.autoSelectLayer)
        Defaults.set(new.featherAmount, for: Defaults.Keys.featherAmount)
        Defaults.set(new.textStyle, for: Defaults.Keys.textStyle)
        Defaults.set(new.shapeStyle, for: Defaults.Keys.shapeStyle)
    }
}

// MARK: - Performance

/// undo history. Undo depth is LIVE: lowering it trims every open
/// document's history from the front straight away (`DocumentStore.trimHistory`).
///
///'s **history byte budget** belongs in this pane, beside the depth —
/// the depth cap alone doesn't bound memory, because a single brush-stroke
/// snapshot can be tens of megabytes. Adding it means one more `AppSettings`
/// property mirrored into `DocumentStore` exactly like `undoDepth`, plus a row
/// here; no restructuring.
private struct PerformanceSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let depthRange = Double(AppSettings.undoDepthRange.lowerBound)
        ... Double(AppSettings.undoDepthRange.upperBound)
    private static let budgetRange = Double(AppSettings.undoByteBudgetMBRange.lowerBound)
        ... Double(AppSettings.undoByteBudgetMBRange.upperBound)

    var body: some View {
        SettingsPane(domain: .perf, reload: { settings.reload() }) {
            Section("History") {
                LabeledContent("Undo steps") {
                    Slider(value: Binding(get: { Double(settings.undoDepth) },
                                          set: { settings.undoDepth = Int($0.rounded()) }),
                           in: Self.depthRange)
                    Text("\(settings.undoDepth)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                LabeledContent("Memory limit") {
                    Slider(value: Binding(get: { Double(settings.undoByteBudgetMB) },
                                          set: { settings.undoByteBudgetMB = Int($0.rounded()) }),
                           in: Self.budgetRange)
                    Text("\(settings.undoByteBudgetMB) MB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
                // Both caps, and why there are two: the step count alone does
                // not bound memory, because a brush stroke snapshots a whole
                // new full-size bitmap while a transform or rename shares one.
                Text("The step count alone doesn't bound memory — painting snapshots a full-size bitmap per stroke, while transforms and renames share one. Whichever limit is reached first discards the oldest steps, immediately rather than at the next edit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Color

/// Export colour management. SEED-ONLY: the Export sheet reads these into
/// its own state when it opens, so a per-export override stays per-export.
private struct ColorSettingsPane: View {
    private struct Values: Equatable {
        var profile = Defaults.value(Defaults.Keys.exportProfile)
        var embedProfile = Defaults.value(Defaults.Keys.embedProfile)
        var sixteenBit = Defaults.value(Defaults.Keys.exportSixteenBit)
        var jpegQuality = Defaults.value(Defaults.Keys.jpegQuality)
    }

    @State private var values = Values()
    @State private var isLoading = false

    var body: some View {
        SettingsPane(domain: .color, reload: {
            isLoading = true
            values = Values()
            isLoading = false
        }) {
            Section("Export Defaults") {
                Picker("Profile", selection: $values.profile) {
                    ForEach(ExportProfile.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Embed the profile in exported files", isOn: $values.embedProfile)
                Toggle("16 bits per channel where supported", isOn: $values.sixteenBit)
                LabeledContent("JPEG quality") {
                    Slider(value: $values.jpegQuality, in: 0.05...1)
                    Text("\(Int((values.jpegQuality * 100).rounded()))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                Text("The working space stays linear Display P3; these choose what leaves the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: values) { _, new in save(new) }
    }

    private func save(_ new: Values) {
        guard !isLoading else { return }
        Defaults.set(new.profile, for: Defaults.Keys.exportProfile)
        Defaults.set(new.embedProfile, for: Defaults.Keys.embedProfile)
        Defaults.set(new.sixteenBit, for: Defaults.Keys.exportSixteenBit)
        Defaults.set(new.jpegQuality, for: Defaults.Keys.jpegQuality)
    }
}

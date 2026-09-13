import AppKit
import SwiftUI

/// Layer → Layer Style… / the panel's "Blending Options…".
/// Photoshop's dialog shape: the effect list with checkboxes down the left,
/// the selected effect's parameters on the right, and a live canvas preview
/// while you drag.
///
/// Preview and commit follow the store's two-tier rule: every
/// control edits through `setLiveLayerEffects`, which never touches history,
/// and OK lands exactly one `setLayerEffects` commit — so the whole session
/// reads as a single "Undo Layer Style". Cancel puts the layer's original
/// effects back live and commits nothing.
struct LayerStyleSheet: View {
    @ObservedObject var store: DocumentStore
    let request: DocumentStore.LayerStyleRequest
    @Environment(\.dismiss) private var dismiss

    @State private var effects = LayerEffects()
    @State private var original = LayerEffects()
    @State private var selectedKind: LayerEffects.Kind = .dropShadow
    @State private var loaded = false

    private var layer: Layer? { store.document[layerID: request.layerID] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                effectList
                    .frame(width: 190)
                Divider()
                ScrollView {
                    parameters
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 480)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Layer Style")
                    .font(.title3.weight(.semibold))
                Text(layer?.name ?? "—")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Preview", isOn: .constant(true))
                .toggleStyle(.checkbox)
                .disabled(true)
                .help("Changes preview on the canvas as you make them")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var effectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LayerEffects.Kind.allCases) { kind in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { effects.isOn(kind) },
                        set: { on in
                            effects.setOn(kind, on)
                            if on { selectedKind = kind }
                            pushLive()
                        }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Text(kind.displayName)
                        .font(.callout)
                        .foregroundStyle(effects.isOn(kind) ? Color.primary : Color.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selectedKind == kind ? Color.accentColor.opacity(0.25) : .clear)
                .contentShape(Rectangle())
                // Clicking the row selects the pane; the checkbox above still
                // owns the on/off, like Photoshop's list.
                .onTapGesture { selectedKind = kind }
            }
            Divider()
                .padding(.vertical, 6)
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { effects.isEnabled },
                    set: { effects.isEnabled = $0; pushLive() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Text("Effects enabled")
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 12)
            .help("The master fx switch — off keeps every setting but renders nothing")
            Spacer()
        }
        .padding(.top, 8)
        .background(.background.opacity(0.35))
    }

    private var footer: some View {
        HStack {
            Button("Clear Style") {
                effects = .none
                pushLive()
            }
            .disabled(effects.isEmpty)
            Spacer()
            Button("Cancel") {
                store.setLiveLayerEffects(request.layerID, original)
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("OK") {
                // The live document already holds `effects`; committing it
                // turns the whole session into one undoable step.
                store.setLayerEffects(request.layerID, effects)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Parameter panes

    @ViewBuilder
    private var parameters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(selectedKind.displayName)
                .font(.headline)
            if !effects.isOn(selectedKind) {
                Text("Switch \(selectedKind.displayName) on to edit it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Group {
                switch selectedKind {
                case .dropShadow: dropShadowPane(bind(\.dropShadow, DropShadowEffect()))
                case .innerShadow: innerShadowPane(bind(\.innerShadow, InnerShadowEffect()))
                case .outerGlow: outerGlowPane(bind(\.outerGlow, OuterGlowEffect()))
                case .innerGlow: innerGlowPane(bind(\.innerGlow, InnerGlowEffect()))
                case .stroke: strokePane(bind(\.stroke, StrokeEffect()))
                case .colorOverlay: colorOverlayPane(bind(\.colorOverlay, ColorOverlayEffect()))
                case .gradientOverlay:
                    gradientOverlayPane(bind(\.gradientOverlay, GradientOverlayEffect()))
                }
            }
            .disabled(!effects.isOn(selectedKind))
        }
    }

    private func dropShadowPane(_ shadow: Binding<DropShadowEffect>) -> some View {
        pane {
            blendRow(shadow.blendMode)
            colorRow("Color", shadow.color)
            percentRow("Opacity", shadow.opacity)
            angleRow(shadow.angle, global: shadow.usesGlobalLight)
            pointRow("Distance", shadow.distance, max: 250)
            percentRow("Spread", shadow.spread)
            pointRow("Size", shadow.size, max: 250)
            Toggle("Layer knocks out drop shadow", isOn: shadow.knocksOut)
                .toggleStyle(.checkbox)
                .padding(.leading, 110)
        }
    }

    private func innerShadowPane(_ shadow: Binding<InnerShadowEffect>) -> some View {
        pane {
            blendRow(shadow.blendMode)
            colorRow("Color", shadow.color)
            percentRow("Opacity", shadow.opacity)
            angleRow(shadow.angle, global: shadow.usesGlobalLight)
            pointRow("Distance", shadow.distance, max: 250)
            percentRow("Choke", shadow.choke)
            pointRow("Size", shadow.size, max: 250)
        }
    }

    private func outerGlowPane(_ glow: Binding<OuterGlowEffect>) -> some View {
        pane {
            blendRow(glow.blendMode)
            colorRow("Color", glow.color)
            percentRow("Opacity", glow.opacity)
            percentRow("Spread", glow.spread)
            pointRow("Size", glow.size, max: 250)
        }
    }

    private func innerGlowPane(_ glow: Binding<InnerGlowEffect>) -> some View {
        pane {
            blendRow(glow.blendMode)
            colorRow("Color", glow.color)
            percentRow("Opacity", glow.opacity)
            percentRow("Choke", glow.choke)
            pointRow("Size", glow.size, max: 250)
        }
    }

    private func strokePane(_ stroke: Binding<StrokeEffect>) -> some View {
        pane {
            pointRow("Size", stroke.size, max: 250, min: 1)
            HStack(spacing: 10) {
                label("Position")
                Picker("", selection: stroke.position) {
                    ForEach(StrokeEffect.Position.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                Spacer()
            }
            blendRow(stroke.blendMode)
            percentRow("Opacity", stroke.opacity)
            colorRow("Color", stroke.color)
        }
    }

    private func colorOverlayPane(_ overlay: Binding<ColorOverlayEffect>) -> some View {
        pane {
            blendRow(overlay.blendMode)
            colorRow("Color", overlay.color)
            percentRow("Opacity", overlay.opacity)
        }
    }

    private func gradientOverlayPane(_ overlay: Binding<GradientOverlayEffect>) -> some View {
        pane {
            blendRow(overlay.blendMode)
            percentRow("Opacity", overlay.opacity)
            colorRow("Start", overlay.startColor)
            colorRow("End", overlay.endColor)
            HStack(spacing: 10) {
                label("Style")
                Picker("", selection: overlay.style) {
                    ForEach(GradientOverlayEffect.Style.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                Toggle("Reverse", isOn: overlay.reversed)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            degreeRow("Angle", overlay.angle)
            percentRow("Scale", overlay.scale, range: 0.1...3)
        }
    }

    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
    }

    // MARK: - Rows

    private func blendRow(_ value: Binding<BlendMode>) -> some View {
        HStack(spacing: 10) {
            label("Blend Mode")
            Picker("", selection: value) {
                ForEach(Array(BlendMode.uiGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 160)
            Spacer()
        }
    }

    private func colorRow(_ title: String, _ value: Binding<EffectColor>) -> some View {
        HStack(spacing: 10) {
            label(title)
            ColorPicker("", selection: Binding(
                get: { Color(cgColor: value.wrappedValue.cgColor) },
                set: { newValue in
                    let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                    value.wrappedValue = EffectColor(ns.cgColor)
                }), supportsOpacity: false)
                .labelsHidden()
            Spacer()
        }
    }

    /// A 0…1 parameter shown as a percentage, Photoshop-style.
    private func percentRow(_ title: String, _ value: Binding<Double>,
                            range: ClosedRange<Double> = 0...1) -> some View {
        HStack(spacing: 10) {
            label(title)
            Slider(value: value, in: range)
                .frame(width: 220)
            numberField(Binding(get: { (value.wrappedValue * 100).rounded() },
                                set: { value.wrappedValue = min(max($0 / 100, range.lowerBound),
                                                                range.upperBound) }),
                        suffix: "%")
            Spacer()
        }
    }

    /// A canvas-point parameter (distance, size).
    private func pointRow(_ title: String, _ value: Binding<Double>,
                          max upper: Double, min lower: Double = 0) -> some View {
        HStack(spacing: 10) {
            label(title)
            Slider(value: value, in: lower...upper)
                .frame(width: 220)
            numberField(Binding(get: { value.wrappedValue.rounded() },
                                set: { value.wrappedValue = Swift.min(Swift.max($0, lower), upper) }),
                        suffix: "px")
            Spacer()
        }
    }

    private func degreeRow(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            label(title)
            Slider(value: value, in: -180...180)
                .frame(width: 220)
            numberField(Binding(get: { value.wrappedValue.rounded() },
                                set: { value.wrappedValue = $0 }), suffix: "°")
            Spacer()
        }
    }

    /// The light angle plus Photoshop's "Use Global Light" tie — with it on,
    /// the effect follows the layer's shared angle instead of its own.
    private func angleRow(_ value: Binding<Double>, global: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            degreeRow("Angle", global.wrappedValue
                      ? Binding(get: { effects.globalLightAngle },
                                set: { effects.globalLightAngle = $0; pushLive() })
                      : value)
            Toggle("Use global light", isOn: global)
                .toggleStyle(.checkbox)
                .padding(.leading, 110)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 100, alignment: .trailing)
    }

    private func numberField(_ value: Binding<Double>, suffix: String) -> some View {
        HStack(spacing: 3) {
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
            Text(suffix)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - State plumbing

    private func load() {
        guard !loaded, let layer else { return }
        loaded = true
        original = layer.effects
        effects = layer.effects
        if let focus = request.focus {
            selectedKind = focus
            if !effects.isOn(focus) {
                effects.setOn(focus, true)
                pushLive()
            }
        } else if let first = effects.activeKinds.first {
            selectedKind = first
        }
    }

    /// Every control change funnels through here, so the canvas tracks the
    /// dialog without a single history entry until OK.
    private func pushLive() {
        store.setLiveLayerEffects(request.layerID, effects)
    }

    /// A binding to one whole effect struct, materialising it at Photoshop's
    /// defaults if it doesn't exist yet. The panes reach individual fields
    /// through `Binding`'s dynamic member lookup, which writes the struct back
    /// through this setter — so every field edit funnels into `pushLive`.
    /// (A key path with optional chaining, `\.dropShadow?.size`, can't do the
    /// job: those are read-only.)
    private func bind<E>(_ path: WritableKeyPath<LayerEffects, E?>, _ fallback: E) -> Binding<E> {
        Binding(get: { effects[keyPath: path] ?? fallback },
                set: { newValue in
                    effects[keyPath: path] = newValue
                    pushLive()
                })
    }
}

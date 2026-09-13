import AppKit
import SwiftUI

/// Layer effects (Photoshop's Layer Style), edited in place under the Layers
/// list rather than in a modal dialog, so the canvas stays visible and
/// navigable while you tune them.
///
/// Each present effect is a disclosure row: checkbox (on/off, parameters
/// kept), name, remove. History follows the opacity slider's two-tier rule
/// (§6): a drag previews through `setLiveLayerEffects` and lands one commit
/// when it ends; typed values, pickers and checkboxes commit at once; colour
/// changes, which arrive continuously from the colour panel, commit after
/// they settle.
struct LayerEffectsPanel: View {
    @ObservedObject var store: DocumentStore
    /// The most the panel may take from the right column; past it, it scrolls.
    let maxHeight: CGFloat

    @State private var expanded: Set<LayerEffects.Kind> = []
    @State private var contentHeight: CGFloat = 0
    @State private var pendingColorCommit: DispatchWorkItem?

    private typealias Kind = LayerEffects.Kind
    private static let headerHeight: CGFloat = 32

    /// Effects belong to one layer; groups and adjustment layers have none.
    private var layer: Layer? {
        guard store.selectedGroupID == nil, let layer = store.selectedLayer,
              layer.kind.adjustmentSpec == nil else { return nil }
        return layer
    }

    var body: some View {
        if let layer {
            VStack(spacing: 0) {
                header(layer)
                if !layer.effects.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Kind.allCases.filter { layer.effects.isPresent($0) }) { kind in
                                    section(kind, layer: layer)
                                        .id(kind)
                                }
                            }
                            .padding(.bottom, 6)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                contentHeight = $0
                            }
                        }
                        .frame(height: min(contentHeight, max(maxHeight - Self.headerHeight, 0)))
                        .opacity(layer.effects.isEnabled ? 1 : 0.5)
                        .onAppear { consumeFocus(proxy) }
                        .onChange(of: store.effectsFocus) { consumeFocus(proxy) }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private func header(_ layer: Layer) -> some View {
        HStack(spacing: 8) {
            Text("Effects")
                .font(.callout.weight(.semibold))
            Spacer()
            if !layer.effects.isEmpty {
                Button {
                    store.toggleLayerEffectsEnabled(layer.id)
                } label: {
                    Image(systemName: layer.effects.isEnabled ? "eye" : "eye.slash")
                        .foregroundStyle(layer.effects.isEnabled ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(layer.effects.isEnabled ? "Hide all effects (keeps their settings)"
                                              : "Show effects")
            }
            Menu {
                ForEach(Kind.allCases.filter { !layer.effects.isOn($0) }) { kind in
                    Button(kind.displayName) {
                        store.addLayerEffect(layer.id, kind)
                        expanded.insert(kind)
                    }
                }
                if !layer.effects.isEmpty {
                    Divider()
                    Button("Clear Layer Style") { store.clearLayerStyle(layer.id) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add an effect")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.headerHeight)
    }

    // MARK: - Sections

    private func section(_ kind: Kind, layer: Layer) -> some View {
        let isOpen = expanded.contains(kind)
        let isOn = layer.effects.isOn(kind)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Toggle("", isOn: Binding(get: { isOn },
                                         set: { store.setLayerEffectOn(layer.id, kind, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Text(kind.displayName)
                    .font(.callout)
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                Spacer()
                Button {
                    store.removeLayerEffect(layer.id, kind)
                    expanded.remove(kind)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(kind.displayName)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpanded(kind) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isOpen ? "Collapses the settings" : "Shows the settings")

            if isOpen {
                controls(kind, layerID: layer.id)
                    .padding(.leading, 28)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                    .disabled(!isOn)
            }
        }
    }

    @ViewBuilder
    private func controls(_ kind: Kind, layerID id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            switch kind {
            case .dropShadow:
                blendAndColorRow(id, kind, \.dropShadow, DropShadowEffect.self)
                percentRow("Opacity", id, kind, \.dropShadow, \DropShadowEffect.opacity)
                angleRow(id, kind, \.dropShadow, \DropShadowEffect.angle,
                         global: \DropShadowEffect.usesGlobalLight)
                pointRow("Distance", id, kind, \.dropShadow, \DropShadowEffect.distance)
                pointRow("Size", id, kind, \.dropShadow, \DropShadowEffect.size)
                percentRow("Spread", id, kind, \.dropShadow, \DropShadowEffect.spread)
                Toggle("Layer knocks out shadow",
                       isOn: value(id, kind, \.dropShadow, \DropShadowEffect.knocksOut, .commit))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Hides the shadow behind the layer where the layer is translucent. "
                          + "No visible change at 100% layer opacity.")
            case .innerShadow:
                blendAndColorRow(id, kind, \.innerShadow, InnerShadowEffect.self)
                percentRow("Opacity", id, kind, \.innerShadow, \InnerShadowEffect.opacity)
                angleRow(id, kind, \.innerShadow, \InnerShadowEffect.angle,
                         global: \InnerShadowEffect.usesGlobalLight, inward: true)
                pointRow("Distance", id, kind, \.innerShadow, \InnerShadowEffect.distance)
                pointRow("Size", id, kind, \.innerShadow, \InnerShadowEffect.size)
                percentRow("Choke", id, kind, \.innerShadow, \InnerShadowEffect.choke)
            case .outerGlow:
                blendAndColorRow(id, kind, \.outerGlow, OuterGlowEffect.self)
                percentRow("Opacity", id, kind, \.outerGlow, \OuterGlowEffect.opacity)
                pointRow("Size", id, kind, \.outerGlow, \OuterGlowEffect.size)
                percentRow("Spread", id, kind, \.outerGlow, \OuterGlowEffect.spread)
            case .innerGlow:
                blendAndColorRow(id, kind, \.innerGlow, InnerGlowEffect.self)
                percentRow("Opacity", id, kind, \.innerGlow, \InnerGlowEffect.opacity)
                pointRow("Size", id, kind, \.innerGlow, \InnerGlowEffect.size)
                percentRow("Choke", id, kind, \.innerGlow, \InnerGlowEffect.choke)
            case .stroke:
                blendAndColorRow(id, kind, \.stroke, StrokeEffect.self)
                percentRow("Opacity", id, kind, \.stroke, \StrokeEffect.opacity)
                pointRow("Size", id, kind, \.stroke, \StrokeEffect.size, lower: 1)
                HStack(spacing: 6) {
                    label("Position")
                    Picker("", selection: value(id, kind, \.stroke, \StrokeEffect.position, .commit)) {
                        ForEach(StrokeEffect.Position.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            case .colorOverlay:
                blendAndColorRow(id, kind, \.colorOverlay, ColorOverlayEffect.self)
                percentRow("Opacity", id, kind, \.colorOverlay, \ColorOverlayEffect.opacity)
            case .gradientOverlay:
                HStack(spacing: 6) {
                    label("Blend")
                    blendPicker(value(id, kind, \.gradientOverlay, \GradientOverlayEffect.blendMode, .commit))
                }
                percentRow("Opacity", id, kind, \.gradientOverlay, \GradientOverlayEffect.opacity)
                HStack(spacing: 6) {
                    label("Colors")
                    colorWell(id, kind, \.gradientOverlay, \GradientOverlayEffect.startColor)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    colorWell(id, kind, \.gradientOverlay, \GradientOverlayEffect.endColor)
                    Toggle("Reverse",
                           isOn: value(id, kind, \.gradientOverlay, \GradientOverlayEffect.reversed, .commit))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                HStack(spacing: 6) {
                    label("Style")
                    Picker("", selection: value(id, kind, \.gradientOverlay,
                                                \GradientOverlayEffect.style, .commit)) {
                        ForEach(GradientOverlayEffect.Style.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                sliderRow("Angle", id, kind,
                          slider: value(id, kind, \.gradientOverlay, \GradientOverlayEffect.angle, .live),
                          field: value(id, kind, \.gradientOverlay, \GradientOverlayEffect.angle, .commit),
                          range: LayerEffects.Bounds.degrees, suffix: "°")
                percentRow("Scale", id, kind, \.gradientOverlay, \GradientOverlayEffect.scale,
                           range: LayerEffects.Bounds.gradientScale)
            }
        }
    }

    // MARK: - Rows

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    private func blendPicker(_ selection: Binding<BlendMode>) -> some View {
        Picker("", selection: selection) {
            ForEach(Array(BlendMode.uiGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
        .labelsHidden()
        .controlSize(.small)
    }

    private func blendAndColorRow<E: ColoredLayerEffect>(_ id: UUID, _ kind: Kind,
                                                         _ effect: WritableKeyPath<LayerEffects, E?>,
                                                         _: E.Type) -> some View {
        HStack(spacing: 6) {
            label("Blend")
            blendPicker(value(id, kind, effect, \E.blendMode, .commit))
            colorWell(id, kind, effect, \E.color)
        }
    }

    private func colorWell<E: LayerEffect>(_ id: UUID, _ kind: Kind,
                                           _ effect: WritableKeyPath<LayerEffects, E?>,
                                           _ field: WritableKeyPath<E, EffectColor>) -> some View {
        let color = value(id, kind, effect, field, .settle)
        return ColorPicker("", selection: Binding(
            get: { Color(cgColor: color.wrappedValue.cgColor) },
            set: { newValue in
                let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                color.wrappedValue = EffectColor(ns.cgColor)
            }), supportsOpacity: false)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
    }

    /// Slider + typed field. The slider previews live and commits when the
    /// drag ends; the field commits on Return.
    private func sliderRow(_ title: String, _ id: UUID, _ kind: Kind,
                           slider: Binding<Double>, field: Binding<Double>,
                           range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 6) {
            label(title)
            Slider(value: slider, in: range) { editing in
                if !editing { store.endLayerEffectsEdit(actionName(kind)) }
            }
            .controlSize(.small)
            numberField(field, suffix: suffix)
        }
    }

    private func percentRow<E: LayerEffect>(_ title: String, _ id: UUID, _ kind: Kind,
                                            _ effect: WritableKeyPath<LayerEffects, E?>,
                                            _ field: WritableKeyPath<E, Double>,
                                            range: ClosedRange<Double> = LayerEffects.Bounds.percent) -> some View {
        let live = value(id, kind, effect, field, .live)
        let committed = value(id, kind, effect, field, .commit)
        return sliderRow(title, id, kind, slider: live,
                         field: Binding(get: { (committed.wrappedValue * 100).rounded() },
                                        set: { committed.wrappedValue = min(max($0 / 100, range.lowerBound),
                                                                            range.upperBound) }),
                         range: range, suffix: "%")
    }

    /// Canvas-point sizes. The slider runs on a squared scale — most useful
    /// values are small, but the range reaches 250 — and the field is linear.
    private func pointRow<E: LayerEffect>(_ title: String, _ id: UUID, _ kind: Kind,
                                          _ effect: WritableKeyPath<LayerEffects, E?>,
                                          _ field: WritableKeyPath<E, Double>,
                                          lower: Double = 0) -> some View {
        let upper = LayerEffects.Bounds.point.upperBound
        let live = value(id, kind, effect, field, .live)
        let committed = value(id, kind, effect, field, .commit)
        return sliderRow(title, id, kind,
                         slider: Binding(get: { sqrt(max(live.wrappedValue, 0) / upper) },
                                         set: { live.wrappedValue = max((upper * $0 * $0).rounded(), lower) }),
                         field: Binding(get: { committed.wrappedValue.rounded() },
                                        set: { committed.wrappedValue = min(max($0, lower), upper) }),
                         range: 0...1, suffix: "px")
    }

    /// The light angle as a dial, with the typed value beside it. With
    /// "use global light" on the angle is the layer's shared one, which drop
    /// and inner shadow move together; the checkbox only appears when the
    /// layer has both, the one case where the link is visible.
    private func angleRow<E: LayerEffect>(_ id: UUID, _ kind: Kind,
                                          _ effect: WritableKeyPath<LayerEffects, E?>,
                                          _ ownAngle: WritableKeyPath<E, Double>,
                                          global: WritableKeyPath<E, Bool>,
                                          inward: Bool = false) -> some View {
        let usesGlobal = value(id, kind, effect, global, .commit)
        func angle(_ mode: EditMode) -> Binding<Double> {
            usesGlobal.wrappedValue
                ? binding(id, kind, mode, get: { $0.globalLightAngle },
                          set: { $0.globalLightAngle = AngleDialMath.normalized($1) })
                : value(id, kind, effect, ownAngle, mode)
        }
        let live = angle(.live)
        let committed = angle(.commit)
        let effects = store.document[layerID: id]?.effects
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                label("Angle")
                AngleDial(angle: live.wrappedValue,
                          onChange: { live.wrappedValue = $0 },
                          onEnd: { store.endLayerEffectsEdit(actionName(kind)) },
                          castsInward: inward)
                Spacer(minLength: 0)
                numberField(Binding(get: { committed.wrappedValue.rounded() },
                                    set: { committed.wrappedValue = AngleDialMath.normalized($0) }),
                            suffix: "°")
            }
            if effects?.dropShadow != nil && effects?.innerShadow != nil {
                Toggle("Same angle for both shadows", isOn: usesGlobal)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .padding(.leading, 58)
            }
        }
    }

    private func numberField(_ value: Binding<Double>, suffix: String) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
            Text(suffix)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
        }
    }

    // MARK: - Editing

    private enum EditMode {
        /// Preview only; the gesture's end commits.
        case live
        /// Preview and commit now.
        case commit
        /// Preview now, commit once changes stop arriving (the colour panel).
        case settle
    }

    private func actionName(_ kind: Kind) -> String { "Change \(kind.displayName)" }

    /// A binding to one field of one effect, read fresh from the document on
    /// every access so a stale view can never write an old style back.
    private func value<E: LayerEffect, V>(_ id: UUID, _ kind: Kind,
                                          _ effect: WritableKeyPath<LayerEffects, E?>,
                                          _ field: WritableKeyPath<E, V>,
                                          _ mode: EditMode) -> Binding<V> {
        binding(id, kind, mode,
                get: { ($0[keyPath: effect] ?? E())[keyPath: field] },
                set: { effects, newValue in effects[keyPath: effect]?[keyPath: field] = newValue })
    }

    private func binding<V>(_ id: UUID, _ kind: Kind, _ mode: EditMode,
                            get: @escaping (LayerEffects) -> V,
                            set: @escaping (inout LayerEffects, V) -> Void) -> Binding<V> {
        Binding(
            get: { get(store.document[layerID: id]?.effects ?? .none) },
            set: { newValue in
                guard var effects = store.document[layerID: id]?.effects else { return }
                set(&effects, newValue)
                store.setLiveLayerEffects(id, effects)
                switch mode {
                case .live:
                    break
                case .commit:
                    store.endLayerEffectsEdit(actionName(kind))
                case .settle:
                    pendingColorCommit?.cancel()
                    let name = actionName(kind)
                    let work = DispatchWorkItem { [store] in store.endLayerEffectsEdit(name) }
                    pendingColorCommit = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
                }
            })
    }

    // MARK: - Focus

    private func toggleExpanded(_ kind: Kind) {
        if expanded.contains(kind) { expanded.remove(kind) } else { expanded.insert(kind) }
    }

    /// Expands and scrolls to the effect a menu item or fx badge asked for.
    private func consumeFocus(_ proxy: ScrollViewProxy) {
        guard let focus = store.effectsFocus, focus.layerID == layer?.id else { return }
        expanded.insert(focus.kind)
        store.effectsFocus = nil
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(focus.kind, anchor: .top) }
        }
    }
}

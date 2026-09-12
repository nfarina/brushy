import SwiftUI

/// The editor behind Layer ▸ New Adjustment Layer. Every control previews
/// live on the canvas and commits one history entry when the sheet is
/// accepted, like Photoshop's adjustment dialogs.
struct AdjustmentSheet: View {
    @ObservedObject var store: DocumentStore
    let layerID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var spec: AdjustmentSpec
    /// Restored on Cancel — the layer itself already exists by then.
    private let original: AdjustmentSpec

    init(store: DocumentStore, layerID: UUID) {
        self.store = store
        self.layerID = layerID
        let current = store.document[layerID: layerID]?.kind.adjustmentSpec
            ?? .levels(AdjustmentSpec.Levels())
        original = current
        _spec = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(spec.displayName, systemImage: spec.systemImage)
                .font(.headline)
            editor
            HStack {
                Button("Reset") { spec = defaultSpec }
                Spacer()
                Button("Cancel", role: .cancel) {
                    store.updateAdjustment(layerID, spec: original, transient: true)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("OK") {
                    store.updateAdjustment(layerID, spec: spec, transient: false)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 430)
        .onChange(of: spec) { _, updated in
            store.updateAdjustment(layerID, spec: updated, transient: true)
        }
    }

    private var defaultSpec: AdjustmentSpec {
        switch spec {
        case .levels: return .levels(AdjustmentSpec.Levels())
        case .curves: return .curves(AdjustmentSpec.Curves())
        case .hueSaturation: return .hueSaturation(AdjustmentSpec.HueSaturation())
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch spec {
        case .levels(let levels):
            levelsEditor(levels)
        case .curves(let curves):
            curvesEditor(curves)
        case .hueSaturation(let hueSaturation):
            hueSaturationEditor(hueSaturation)
        }
    }

    // MARK: Levels

    private func levelsEditor(_ levels: AdjustmentSpec.Levels) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Input").font(.caption).foregroundStyle(.secondary)
            level255("Black", value: levels.inputBlack) { new in
                setLevels(levels) { $0.inputBlack = min(new, $0.inputWhite - 0.01) }
            }
            HStack(spacing: 8) {
                Text("Gamma").font(.callout).frame(width: 74, alignment: .leading)
                Slider(value: Binding(get: { levels.gamma },
                                      set: { new in setLevels(levels) { $0.gamma = new } }),
                       in: 0.1...3)
                Text(String(format: "%.2f", levels.gamma))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            level255("White", value: levels.inputWhite) { new in
                setLevels(levels) { $0.inputWhite = max(new, $0.inputBlack + 0.01) }
            }
            Divider()
            Text("Output").font(.caption).foregroundStyle(.secondary)
            level255("Black", value: levels.outputBlack) { new in
                setLevels(levels) { $0.outputBlack = new }
            }
            level255("White", value: levels.outputWhite) { new in
                setLevels(levels) { $0.outputWhite = new }
            }
        }
    }

    /// Photoshop shows levels as 0–255 even though the maths is 0–1.
    private func level255(_ title: String, value: Double,
                          set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set($0) }), in: 0...1)
            Text("\(Int((value * 255).rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// The input black and white points can't cross, so each setter clamps
    /// against the other before the spec is replaced.
    private func setLevels(_ levels: AdjustmentSpec.Levels,
                           _ change: (inout AdjustmentSpec.Levels) -> Void) {
        var copy = levels
        change(&copy)
        spec = .levels(copy)
    }

    // MARK: Curves

    private func curvesEditor(_ curves: AdjustmentSpec.Curves) -> some View {
        let size: CGFloat = 240
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.15))
                CurveGrid().stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                CurveDiagonal().stroke(Color.gray.opacity(0.4),
                                       style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                CurveLine(curves: curves).stroke(Color.accentColor, lineWidth: 1.5)
                // Screen y runs down while the curve's output runs up.
                ForEach(Array(curves.points.enumerated()), id: \.offset) { _, point in
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(.black, lineWidth: 1))
                        .frame(width: 7, height: 7)
                        .position(x: point.x * size, y: (1 - point.y) * size)
                }
            }
            .frame(width: size, height: size)
            .border(Color.black.opacity(0.4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                // The nearest of the five stops follows the pointer.
                let x = min(max(value.location.x / size, 0), 1)
                let index = Int((x * 4).rounded())
                var outputs = curves.outputs
                outputs[min(max(index, 0), 4)] = min(max(1 - value.location.y / size, 0), 1)
                spec = .curves(AdjustmentSpec.Curves(outputs: outputs))
            })
            Text("Drag the five points: left is shadows, right is highlights.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Curve chrome

    /// Quarter grid.
    private struct CurveGrid: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            for step in 0...4 {
                let x = rect.minX + rect.width * CGFloat(step) / 4
                let y = rect.minY + rect.height * CGFloat(step) / 4
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            return path
        }
    }

    /// The untouched curve, for reference: bottom-left to top-right.
    private struct CurveDiagonal: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return path
        }
    }

    /// The curve itself, sampled from the same spline the renderer hands to
    /// Core Image, so the graph is what the pixels get.
    private struct CurveLine: Shape {
        let curves: AdjustmentSpec.Curves

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for step in 0...64 {
                let x = Double(step) / 64
                let point = CGPoint(x: rect.minX + x * rect.width,
                                    y: rect.minY + (1 - curves.apply(x)) * rect.height)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
    }

    // MARK: Hue/Saturation

    private func hueSaturationEditor(_ values: AdjustmentSpec.HueSaturation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            hueSlider("Hue", value: values.hue, range: -180...180, suffix: "°") { new in
                var copy = values; copy.hue = new; spec = .hueSaturation(copy)
            }
            hueSlider("Saturation", value: values.saturation, range: -100...100, suffix: "") { new in
                var copy = values; copy.saturation = new; spec = .hueSaturation(copy)
            }
            hueSlider("Lightness", value: values.lightness, range: -100...100, suffix: "") { new in
                var copy = values; copy.lightness = new; spec = .hueSaturation(copy)
            }
        }
    }

    private func hueSlider(_ title: String, value: Double, range: ClosedRange<Double>,
                           suffix: String, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range)
            Text("\(Int(value.rounded()))\(suffix)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

import SwiftUI

/// Photoshop-style vertical tool strip. Single-key shortcuts (V M L C) are
/// handled by the canvas view.
struct ToolStrip: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Tool.allCases) { tool in
                Button {
                    store.activeTool = tool
                } label: {
                    Image(systemName: tool == .shape ? store.shapeStyle.kind.systemImage
                                                     : tool.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.activeTool == tool ? Color.accentColor : Color.primary)
                .background(store.activeTool == tool ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .help("\(tool.displayName) (\(tool.shortcutKey))")
            }
            ColorSwatches(store: store)
                .padding(.top, 8)
            Spacer()
        }
        .padding(.top, 10)
        .frame(maxHeight: .infinity)
    }
}

/// Photoshop's foreground/background chips under the tools: foreground over
/// background, swap arrow top-right, default-colours icon bottom-left. X and D
/// do the same from the canvas. Colours are sRGB like every UI well (§7).
private struct ColorSwatches: View {
    @ObservedObject var store: DocumentStore

    private let chip: CGFloat = 22
    private let offset: CGFloat = 12
    private let icon: CGFloat = 11

    var body: some View {
        ZStack(alignment: .topLeading) {
            swatch(\.backgroundColor, help: "Background colour")
                .offset(x: offset, y: offset)
            swatch(\.foregroundColor, help: "Foreground colour")
            Button { store.swapBrushColors() } label: {
                SwapArrow()
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.2, lineCap: .round,
                                                              lineJoin: .round))
                    .frame(width: icon, height: icon)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: chip + 1, y: 0)
            .help("Swap foreground and background colours (X)")
            Button { store.resetBrushColors() } label: {
                DefaultColorsIcon()
                    .frame(width: icon, height: icon)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 0, y: chip + 1)
            .help("Default foreground and background colours (D)")
        }
        .frame(width: chip + offset, height: chip + offset, alignment: .topLeading)
    }

    private func swatch(_ keyPath: ReferenceWritableKeyPath<DocumentStore, CGColor>,
                        help: String) -> some View {
        ColorChip(color: store[keyPath: keyPath])
            .frame(width: chip, height: chip)
            .overlay(PanelColorWell(color: store[keyPath: keyPath], toolTip: help) {
                store[keyPath: keyPath] = $0
            })
    }
}

private struct ColorChip: View {
    let color: CGColor

    var body: some View {
        ZStack {
            if color.alpha < 1 {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                    let cell: CGFloat = 5
                    for row in 0..<Int((size.height / cell).rounded(.up)) {
                        for col in 0..<Int((size.width / cell).rounded(.up)) where (row + col) % 2 == 1 {
                            context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                                     width: cell, height: cell)),
                                         with: .color(Color(white: 0.8)))
                        }
                    }
                }
            }
            Rectangle().fill(Color(cgColor: color))
        }
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1).padding(1))
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.75), lineWidth: 1))
    }
}

/// Two-headed quarter arc, pointing left at the top and down at the right.
private struct SwapArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 11
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var path = Path()
        path.addArc(center: p(2, 9), radius: 6.5 * s,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.move(to: p(4, 0.5)); path.addLine(to: p(2, 2.5)); path.addLine(to: p(4, 4.5))
        path.move(to: p(6.5, 7)); path.addLine(to: p(8.5, 9)); path.addLine(to: p(10.5, 7))
        return path
    }
}

/// Miniature black-over-white chips.
private struct DefaultColorsIcon: View {
    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width * 0.6
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.white)
                    .overlay(Rectangle().strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5))
                    .frame(width: side, height: side)
                    .offset(x: geo.size.width - side, y: geo.size.height - side)
                Rectangle().fill(.black)
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.7), lineWidth: 0.5))
                    .frame(width: side, height: side)
            }
        }
    }
}

/// An invisible NSColorWell laid over a chip. The well supplies the colour
/// panel plumbing — `activate(true)` detaches whichever well (including the
/// options bar's ColorPickers) was driving the shared panel, so only one colour
/// edits at a time — while the chip above does the drawing.
private struct PanelColorWell: NSViewRepresentable {
    let color: CGColor
    let toolTip: String
    let onChange: (CGColor) -> Void

    func makeNSView(context: Context) -> ChipColorWell {
        let well = ChipColorWell()
        well.alphaValue = 0
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ well: ChipColorWell, context: Context) {
        context.coordinator.onChange = onChange
        well.toolTip = toolTip
        // Compare in sRGB: the panel hands back colours in its own space, and
        // re-assigning an equal colour would bounce through the panel again.
        if well.color.usingColorSpace(.sRGB)?.cgColor != color {
            well.color = NSColor(cgColor: color) ?? .black
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        var onChange: (CGColor) -> Void
        init(onChange: @escaping (CGColor) -> Void) { self.onChange = onChange }

        @objc func colorChanged(_ sender: NSColorWell) {
            onChange((sender.color.usingColorSpace(.sRGB) ?? .black).cgColor)
        }
    }

    final class ChipColorWell: NSColorWell {
        /// Straight to the full colour panel, skipping the macOS 13+ well's
        /// swatch popover — a Photoshop chip opens the picker on click.
        override func mouseDown(with event: NSEvent) {
            NSColorPanel.shared.showsAlpha = true
            activate(true)
            NSColorPanel.shared.orderFront(nil)
        }

        /// The well's own subviews (the popover arrow) must not take the click.
        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }
    }
}

/// Context-sensitive options above the canvas.
struct ToolOptionsBar: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        HStack(spacing: 12) {
            if store.transformSession != nil {
                transformOptions
            } else {
                switch store.activeTool {
                case .move:
                    if store.selectedShapeSpec != nil {
                        shapeStyleOptions
                    } else {
                        moveOptions
                    }
                case .marquee, .lasso: selectionOptions
                case .crop: cropOptions
                case .eyedropper: eyedropperOptions
                case .brush, .eraser: brushOptions
                case .gradient: gradientOptions
                case .text: textOptions
                case .shape: shapeOptions
                }
            }
            Spacer()
            Text("\(store.document.canvasSize.width.saturatingInt) × \(store.document.canvasSize.height.saturatingInt) px   \((store.viewport.zoom * 100).rounded().saturatingInt)%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
    }

    private var transformOptions: some View {
        HStack(spacing: 10) {
            Label("Free Transform", systemImage: "square.dashed")
                .font(.callout.weight(.medium))
            Text("Return commits · Esc cancels · ⇧ unconstrained · ⌥ from centre · drag outside corner to rotate")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var moveOptions: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $store.autoSelectLayer) { Text("Auto-Select") }
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Clicking the canvas selects the topmost layer under the cursor")
            Divider().frame(height: 18)
            alignOptions
            Divider().frame(height: 18)
            Text("⇧-click adds to the selection · ⌥-drag duplicates · ⌘T to transform")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Align & Distribute — Photoshop puts these on the Move tool's
    /// options bar, which is where they are actually reached; the Layer menu
    /// carries the same commands for discoverability.
    private var alignOptions: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { store.effectiveAlignReference },
                                          set: { store.alignReference = $0 })) {
                Text("Selection").tag(AlignReference.selectionBounds)
                Text("Canvas").tag(AlignReference.canvas)
            }
            .labelsHidden()
            .frame(width: 110)
            // With one object the selection bounds ARE the object, so every
            // align would be a no-op: the picker is forced to Canvas.
            .disabled(store.alignObjects.count < 2)
            .help("Align To: the selection's bounds, or the canvas")

            HStack(spacing: 2) {
                ForEach(AlignEdge.allCases) { edge in
                    Button {
                        store.alignSelection(to: edge)
                    } label: {
                        Image(systemName: edge.systemImage)
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canAlignSelection)
                    .help("Align \(edge.displayName)")
                }
            }
            HStack(spacing: 2) {
                // The two people actually want: equal GAPS. Equal centres live
                // in the Layer ▸ Distribute menu.
                ForEach([DistributeCommand.horizontalSpacing,
                         DistributeCommand.verticalSpacing]) { command in
                    Button {
                        store.distributeSelection(command)
                    } label: {
                        Image(systemName: command.systemImage)
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canDistributeSelection)
                    .help("Distribute \(command.displayName) — equal gaps between three or more objects")
                }
            }
        }
    }

    private var selectionOptions: some View {
        HStack(spacing: 8) {
            Text("Feather")
                .font(.callout)
            TextField("0", value: Binding(
                get: { store.featherAmount },
                set: { store.featherAmount = min(max($0, 0), 250) }),
                format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
            Text("px")
                .foregroundStyle(.secondary)
                .font(.callout)
            Divider().frame(height: 18)
            Text("⇧ adds · ⌥ subtracts · ⌘D deselects")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var brushOptions: some View {
        HStack(spacing: 10) {
            brushSlider("Size", value: $store.brushSize, range: 1...500, width: 90,
                        label: "\(Int(store.brushSize))px")
            brushSlider("Hardness", value: $store.brushHardness, range: 0...100, width: 70,
                        label: "\(Int(store.brushHardness))%")
            brushSlider("Opacity", value: $store.brushOpacity, range: 1...100, width: 70,
                        label: "\(Int(store.brushOpacity))%")
            if store.activeTool == .brush {
                Divider().frame(height: 18)
                ColorPicker("", selection: colorBinding(\.foregroundColor), supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 34)
                    .help("Foreground colour (painted; X swaps, D resets)")
                Button {
                    store.swapBrushColors()
                } label: {
                    Image(systemName: "arrow.2.squarepath")
                }
                .buttonStyle(.plain)
                .help("Swap foreground/background (X)")
                ColorPicker("", selection: colorBinding(\.backgroundColor), supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 34)
                    .help("Background colour")
            }
            if let hint = store.brushTargetDescription {
                Divider().frame(height: 18)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var gradientOptions: some View {
        HStack(spacing: 10) {
            Picker("", selection: $store.gradientShape) {
                ForEach(GradientShape.allCases) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .help("Gradient shape: linear ramps along the drag, radial rings out from its start")
            Divider().frame(height: 18)
            ColorPicker("", selection: colorBinding(\.foregroundColor), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 34)
                .help("Start colour (foreground — X swaps, D resets)")
            Button {
                store.swapBrushColors()
            } label: {
                Image(systemName: "arrow.2.squarepath")
            }
            .buttonStyle(.plain)
            .help("Swap foreground/background (X)")
            ColorPicker("", selection: colorBinding(\.backgroundColor), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 34)
                .help("End colour (background)")
            Divider().frame(height: 18)
            Toggle(isOn: $store.gradientToTransparent) { Text("To Transparent") }
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Ramp the foreground to transparent — on masks the transparent end leaves the mask untouched")
            Toggle(isOn: $store.gradientReversed) { Text("Reverse") }
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Swap the ends of the gradient")
            if let hint = store.gradientTargetDescription {
                Divider().frame(height: 18)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var eyedropperOptions: some View {
        HStack(spacing: 10) {
            Text("Sample Size").font(.caption)
            Picker("", selection: $store.eyedropperSampleSize) {
                Text("Point Sample").tag(1)
                Text("3×3").tag(3)
                Text("5×5").tag(5)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .help("Average over an N×N box of canvas pixels (zoom-independent)")
            Divider().frame(height: 18)
            ColorPicker("", selection: colorBinding(\.foregroundColor), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 34)
                .help("Foreground colour — click samples into it (X swaps, D resets)")
            ColorPicker("", selection: colorBinding(\.backgroundColor), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 34)
                .help("Background colour — ⌥-click samples into it")
            Text("Click sets foreground · ⌥-click sets background")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func brushSlider(_ title: String, value: Binding<Double>,
                             range: ClosedRange<Double>, width: CGFloat,
                             label: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption)
            Slider(value: value, in: range).frame(width: width)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
        }
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<DocumentStore, CGColor>) -> Binding<Color> {
        Binding(get: { Color(cgColor: store[keyPath: keyPath]) },
                set: { newValue in
                    let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                    store[keyPath: keyPath] = ns.cgColor
                })
    }

    // MARK: Text tool

    @ViewBuilder
    private var textOptions: some View {
        if store.textSession != nil {
            textSessionOptions
        } else {
            HStack(spacing: 10) {
                TextStyleControls(store: store)
                Divider().frame(height: 18)
                Text("Click the canvas to type · click existing text to edit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let layer = store.selectedLayer, layer.kind.textSpec != nil {
                    Button("Edit “\(layer.name)”") {
                        store.beginTextSession(editing: layer.id, caretAt: nil)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// Live styling while typing on the canvas.
    private var textSessionOptions: some View {
        HStack(spacing: 10) {
            TextStyleControls(store: store)
            Divider().frame(height: 18)
            Text("Enter commits · Esc cancels · Return adds a line")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Shape tool

    private var shapeOptions: some View {
        HStack(spacing: 10) {
            Picker("", selection: shapeBinding(\.kind, transientSlider: false)) {
                ForEach(ShapeSpec.Kind.allCases) { kind in
                    Image(systemName: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .help("Shape: rectangle, ellipse, line")
            shapeStyleControls
        }
    }

    /// Style controls shown while creating (shape tool) or editing (a shape
    /// layer selected with the move tool).
    private var shapeStyleOptions: some View {
        HStack(spacing: 10) {
            Label(store.selectedLayer?.name ?? "Shape", systemImage: "square.on.circle")
                .font(.callout)
            shapeStyleControls
        }
    }

    private var editingSelectedShape: Bool {
        store.selectedShapeSpec != nil && (store.activeTool == .move || store.activeTool == .shape)
    }

    /// Reads/writes either the creation defaults or the selected shape layer.
    private func shapeBinding<T>(_ keyPath: WritableKeyPath<ShapeSpec, T>,
                                 transientSlider: Bool) -> Binding<T> {
        Binding(
            get: {
                if editingSelectedShape, let spec = store.selectedShapeSpec {
                    return spec[keyPath: keyPath]
                }
                return store.shapeStyle[keyPath: keyPath]
            },
            set: { newValue in
                store.shapeStyle[keyPath: keyPath] = newValue
                if editingSelectedShape {
                    store.updateSelectedShape({ $0[keyPath: keyPath] = newValue },
                                              transient: transientSlider)
                }
            })
    }

    private func shapeColorBinding(_ keyPath: WritableKeyPath<ShapeSpec, ColorSpec?>) -> Binding<Color> {
        Binding(
            get: {
                let spec = editingSelectedShape ? (store.selectedShapeSpec ?? store.shapeStyle)
                                                : store.shapeStyle
                return Color(cgColor: (spec[keyPath: keyPath] ?? .black).cgColor)
            },
            set: { newValue in
                let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                let colorSpec = ColorSpec(cgColor: ns.cgColor)
                store.shapeStyle[keyPath: keyPath] = colorSpec
                if editingSelectedShape {
                    store.updateSelectedShape { $0[keyPath: keyPath] = colorSpec }
                }
            })
    }

    private func shapeEnabledBinding(_ keyPath: WritableKeyPath<ShapeSpec, ColorSpec?>,
                                     defaultColor: ColorSpec) -> Binding<Bool> {
        Binding(
            get: {
                let spec = editingSelectedShape ? (store.selectedShapeSpec ?? store.shapeStyle)
                                                : store.shapeStyle
                return spec[keyPath: keyPath] != nil
            },
            set: { enabled in
                let value: ColorSpec? = enabled ? defaultColor : nil
                store.shapeStyle[keyPath: keyPath] = value
                if editingSelectedShape {
                    store.updateSelectedShape { $0[keyPath: keyPath] = value }
                }
            })
    }

    @ViewBuilder
    private var shapeStyleControls: some View {
        let spec = editingSelectedShape ? (store.selectedShapeSpec ?? store.shapeStyle)
                                        : store.shapeStyle
        let isLine = spec.kind == .line
        HStack(spacing: 8) {
            if !isLine {
                Toggle(isOn: shapeEnabledBinding(\.fill, defaultColor: .white)) { Text("Fill") }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                if spec.fill != nil {
                    ColorPicker("", selection: shapeColorBinding(\.fill), supportsOpacity: true)
                        .labelsHidden()
                        .frame(width: 30)
                }
            }
            Toggle(isOn: shapeEnabledBinding(\.stroke, defaultColor: .black)) { Text("Stroke") }
                .toggleStyle(.checkbox)
                .font(.caption)
            if spec.stroke != nil {
                ColorPicker("", selection: shapeColorBinding(\.stroke), supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 30)
                Slider(value: shapeBinding(\.strokeWidth, transientSlider: true),
                       in: 1...40) { editing in
                    if !editing && editingSelectedShape { store.commitShapeEdit() }
                }
                .frame(width: 70)
                Text("\(Int(spec.strokeWidth))px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                Picker("", selection: shapeBinding(\.strokeStyle, transientSlider: false)) {
                    ForEach(ShapeSpec.StrokeStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            if isLine {
                Divider().frame(height: 18)
                Toggle(isOn: shapeBinding(\.arrowStart, transientSlider: false)) {
                    Image(systemName: "arrow.left")
                }
                .toggleStyle(.button)
                .help("Arrowhead at start")
                Toggle(isOn: shapeBinding(\.arrowEnd, transientSlider: false)) {
                    Image(systemName: "arrow.right")
                }
                .toggleStyle(.button)
                .help("Arrowhead at end")
            }
        }
    }

    private var cropOptions: some View {
        HStack(spacing: 8) {
            Text("Aspect")
                .font(.callout)
            TextField("W", text: $store.cropAspectW)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.center)
            Text(":").foregroundStyle(.secondary)
            TextField("H", text: $store.cropAspectH)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.center)
            Toggle(isOn: $store.cropAspectLocked) {
                Image(systemName: store.cropAspectLocked ? "lock.fill" : "lock.open")
            }
            .toggleStyle(.button)
            .help("Lock aspect ratio")
            Divider().frame(height: 18)
            Text("Return commits · Esc resets")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

import AppKit
import SwiftUI

/// HSB ↔ sRGB, kept pure so the picker's maths is testable on its own.
/// Hue is carried explicitly rather than recomputed from RGB: at zero
/// saturation or brightness the hue is undefined, and recomputing it would
/// snap the picker's slider to red whenever the user dragged into a corner.
struct HSBColor: Equatable {
    /// 0..<1, wrapping.
    var hue: Double
    /// 0...1.
    var saturation: Double
    /// 0...1.
    var brightness: Double
    var alpha: Double = 1

    /// sRGB components, 0...1.
    var rgb: (r: Double, g: Double, b: Double) {
        let sector = (hue.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1) * 6
        let chroma = brightness * saturation
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = brightness - chroma
        let rgb: (Double, Double, Double)
        switch Int(sector) {
        case 0: rgb = (chroma, second, 0)
        case 1: rgb = (second, chroma, 0)
        case 2: rgb = (0, chroma, second)
        case 3: rgb = (0, second, chroma)
        case 4: rgb = (second, 0, chroma)
        default: rgb = (chroma, 0, second)
        }
        return (rgb.0 + base, rgb.1 + base, rgb.2 + base)
    }

    init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.alpha = alpha
    }

    init(r: Double, g: Double, b: Double, alpha: Double = 1) {
        let high = max(r, g, b), low = min(r, g, b)
        let chroma = high - low
        var hue: Double = 0
        if chroma > 0 {
            switch high {
            case r: hue = ((g - b) / chroma).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / chroma + 2
            default: hue = (r - g) / chroma + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        self.init(hue: hue, saturation: high > 0 ? chroma / high : 0,
                  brightness: high, alpha: alpha)
    }

    /// UI colour wells hold sRGB (§7).
    init(cgColor: CGColor) {
        let ns = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                  b: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }

    var cgColor: CGColor {
        let (r, g, b) = rgb
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    var hex: String {
        let (r, g, b) = rgb
        let byte = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// Accepts `RGB`, `RRGGBB`, with or without a leading `#`.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(r: Double((value >> 16) & 0xFF) / 255,
                  g: Double((value >> 8) & 0xFF) / 255,
                  b: Double(value & 0xFF) / 255)
    }
}

/// Photoshop's colour picker: the saturation/brightness square for the chosen
/// hue, the hue slider beside it, the new colour over the old one, and hex/RGB
/// fields. Colours are sRGB; the document's working space stays linear P3 (§7).
struct ColorPickerSheet: View {
    @ObservedObject var store: DocumentStore
    let target: DocumentStore.ColorTarget
    @Environment(\.dismiss) private var dismiss

    @State private var hsb = HSBColor(hue: 0, saturation: 1, brightness: 1)
    @State private var hexField = ""
    private let previous: CGColor

    init(store: DocumentStore, target: DocumentStore.ColorTarget) {
        self.store = store
        self.target = target
        previous = store.color(for: target)
        _hsb = State(initialValue: HSBColor(cgColor: previous))
        _hexField = State(initialValue: HSBColor(cgColor: previous).hex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target == .foreground ? "Foreground Colour" : "Background Colour")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                saturationBrightnessSquare
                hueSlider
                VStack(alignment: .leading, spacing: 12) {
                    comparison
                    fields
                }
                .frame(width: 150)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    store.setColor(hsb.cgColor, for: target)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    // MARK: Square

    private var saturationBrightnessSquare: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(cgColor: HSBColor(hue: hsb.hue, saturation: 1,
                                                         brightness: 1).cgColor))
                LinearGradient(colors: [.white, .white.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black],
                               startPoint: .top, endPoint: .bottom)
                marker
                    .position(x: hsb.saturation * geo.size.width,
                              y: (1 - hsb.brightness) * geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                hsb.saturation = clamped(value.location.x / geo.size.width)
                hsb.brightness = 1 - clamped(value.location.y / geo.size.height)
                hexField = hsb.hex
            })
        }
        .frame(width: 240, height: 200)
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
    }

    /// White ring with a dark halo, so it stays visible on any colour.
    private var marker: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 1.5)
            .background(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 3))
            .frame(width: 12, height: 12)
    }

    private var hueSlider: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12)
                    .map { Color(cgColor: HSBColor(hue: $0, saturation: 1, brightness: 1).cgColor) },
                               startPoint: .top, endPoint: .bottom)
                Rectangle()
                    .fill(.white)
                    .frame(height: 2)
                    .overlay(Rectangle().strokeBorder(.black.opacity(0.6), lineWidth: 0.5))
                    .offset(y: hsb.hue * geo.size.height - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                hsb.hue = clamped(value.location.y / geo.size.height)
                hexField = hsb.hex
            })
        }
        .frame(width: 22, height: 200)
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
    }

    // MARK: Readouts

    /// New over old, Photoshop's stacked pair — click the old half to go back.
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("new").font(.caption2).foregroundStyle(.secondary)
            Rectangle().fill(Color(cgColor: hsb.cgColor)).frame(height: 26)
            Rectangle().fill(Color(cgColor: previous)).frame(height: 26)
                .onTapGesture {
                    hsb = HSBColor(cgColor: previous)
                    hexField = hsb.hex
                }
            Text("current").font(.caption2).foregroundStyle(.secondary)
        }
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
            .padding(.vertical, 14))
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("#").foregroundStyle(.secondary)
                TextField("", text: $hexField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit(applyHex)
                    .onChange(of: hexField) { _, _ in applyHex() }
            }
            component("R", \.r)
            component("G", \.g)
            component("B", \.b)
            HStack(spacing: 6) {
                Text("Opacity").font(.caption)
                Slider(value: $hsb.alpha, in: 0...1).frame(width: 70)
                Text("\(Int((hsb.alpha * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One 0–255 field, editing the colour through RGB.
    private func component(_ label: String, _ keyPath: KeyPath<(r: Double, g: Double, b: Double), Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 12, alignment: .leading)
            TextField("", value: Binding(
                get: { Int((hsb.rgb[keyPath: keyPath] * 255).rounded()) },
                set: { newValue in
                    var (r, g, b) = hsb.rgb
                    let value = Double(min(max(newValue, 0), 255)) / 255
                    switch label {
                    case "R": r = value
                    case "G": g = value
                    default: b = value
                    }
                    let alpha = hsb.alpha
                    var updated = HSBColor(r: r, g: g, b: b, alpha: alpha)
                    // Keep the slider where the user left it when the new
                    // colour has no hue of its own (grey, black, white).
                    if updated.saturation == 0 || updated.brightness == 0 {
                        updated.hue = hsb.hue
                    }
                    hsb = updated
                    hexField = hsb.hex
                }), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
        }
    }

    private func applyHex() {
        guard var parsed = HSBColor(hex: hexField) else { return }
        parsed.alpha = hsb.alpha
        if parsed.saturation == 0 || parsed.brightness == 0 { parsed.hue = hsb.hue }
        guard parsed != hsb else { return }
        hsb = parsed
    }

    private func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}

import SwiftUI

/// Font/size/colour bound to the live session when one exists, else to the
/// creation defaults. Shared by the options bar and the floating task bar.
struct TextStyleControls: View {
    @ObservedObject var store: DocumentStore

    private static let fontFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.sorted()
    }()

    var body: some View {
        let current = store.textSession?.spec ?? store.textStyle
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { current.fontName },
                set: { name in store.updateTextSessionStyle { $0.fontName = name } })) {
                if !Self.fontFamilies.contains(current.fontName) {
                    Text(current.fontName).tag(current.fontName)
                }
                ForEach(Self.fontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .labelsHidden()
            .frame(width: 160)
            TextField("Size", value: Binding(
                get: { current.fontSize },
                set: { size in
                    store.updateTextSessionStyle { $0.fontSize = min(max(size, 4), 800) }
                }), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
            ColorPicker("", selection: Binding(
                get: { Color(cgColor: current.color.cgColor) },
                set: { newValue in
                    let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                    store.updateTextSessionStyle { $0.color = ColorSpec(cgColor: ns.cgColor) }
                }), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 30)
        }
    }
}

/// The floating contextual bar under an active text session (Photoshop's
/// task bar): live style controls plus explicit cancel/commit. The
/// TextEditingCoordinator positions it against the editing box's AABB —
/// it tracks the box but never rotates with it.
struct TextTaskBar: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        HStack(spacing: 8) {
            TextStyleControls(store: store)
            Divider().frame(height: 16)
            Button {
                store.cancelTextSession()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Cancel (Esc)")
            Button {
                store.commitTextSession()
            } label: {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
            .help("Commit (Enter)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Color.primary.opacity(0.15)))
    }
}

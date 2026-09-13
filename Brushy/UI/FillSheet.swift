import AppKit
import SwiftUI

/// Edit → Fill… (⇧F5), Photoshop-shaped: pick the contents, fill the selection
/// (or the whole layer when nothing is selected). Masks fill with the chosen
/// colour's luminance.
struct FillSheet: View {
    @ObservedObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    enum Contents: String, CaseIterable, Identifiable {
        case foreground, background, black, white, gray, custom

        var id: String { rawValue }
        var label: String {
            switch self {
            case .foreground: return "Foreground Color"
            case .background: return "Background Color"
            case .black: return "Black"
            case .white: return "White"
            case .gray: return "50% Gray"
            case .custom: return "Custom Color"
            }
        }
    }

    @State private var contents: Contents = .foreground
    @State private var customColor: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fill")
                .font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                Text("Contents")
                Picker("", selection: $contents) {
                    ForEach(Contents.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                if contents == .custom {
                    ColorPicker("", selection: $customColor, supportsOpacity: true)
                        .labelsHidden()
                        .frame(width: 34)
                }
            }

            Text(store.fillTargetDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Fill") {
                    store.fillSelection(using: fillColor)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!store.canFillSelection)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private var fillColor: CGColor {
        switch contents {
        case .foreground: return store.foregroundColor
        case .background: return store.backgroundColor
        case .black: return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .white: return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .gray: return CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        case .custom:
            return (NSColor(customColor).usingColorSpace(.sRGB) ?? .white).cgColor
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

///.5 / export: PNG (16-bit option), JPEG (quality slider), TIFF —
/// converted to the chosen output profile (default sRGB) with the profile
/// embedded.
struct ExportSheet: View {
    @ObservedObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFileFormat = .png
    // Seeded from the Color pane — SEED-ONLY: an override here is a
    // per-export choice and deliberately doesn't write back to the preference.
    @State private var sixteenBit = Defaults.value(Defaults.Keys.exportSixteenBit)
    @State private var jpegQuality = Defaults.value(Defaults.Keys.jpegQuality)
    @State private var profile = Defaults.value(Defaults.Keys.exportProfile)
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export")
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Format")
                    Picker("", selection: $format) {
                        ForEach(ExportFileFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                if format.supportsSixteenBit {
                    GridRow {
                        Text("Depth")
                        Toggle("16-bit per channel", isOn: $sixteenBit)
                    }
                }
                if format == .jpeg {
                    GridRow {
                        Text("Quality")
                        HStack {
                            Slider(value: $jpegQuality, in: 0.05...1)
                                .frame(width: 140)
                            Text("\(Int((jpegQuality * 100).rounded()))")
                                .monospacedDigit()
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
                GridRow {
                    Text("Profile")
                    Picker("", selection: $profile) {
                        ForEach(ExportProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                GridRow {
                    Text("Size")
                    Text("\(store.document.canvasSize.width.saturatingInt) × \(store.document.canvasSize.height.saturatingInt) px")
                        .foregroundStyle(.secondary)
                }
            }

            if format.isLayered {
                Text("Layers, masks, names, visibility and opacity are preserved. Transforms, text and shapes are baked into each layer's pixels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Exports the flattened composite.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isExporting ? "Exporting…" : "Export…") { runSavePanel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExporting)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func runSavePanel() {
        let settings = ExportSettings(format: format, sixteenBit: sixteenBit,
                                      jpegQuality: jpegQuality, profile: profile,
                                      embedProfile: Defaults.value(Defaults.Keys.embedProfile))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        let base = NSDocumentController.shared.currentDocument?.displayName ?? "Untitled"
        panel.nameFieldStringValue = "\(base).\(settings.format.fileExtension)"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            isExporting = true
            let document = store.document
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Exporter.export(document: document, settings: settings, to: url)
                    DispatchQueue.main.async {
                        isExporting = false
                        dismiss()
                    }
                } catch {
                    DispatchQueue.main.async {
                        isExporting = false
                        store.lastErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

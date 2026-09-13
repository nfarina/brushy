import AppKit
import SwiftUI

/// File → New… (⌘N): Photoshop-style New Document dialog — width and height
/// with a few pixel presets, remembering the last-used size. App-modal rather
/// than a sheet: it must work with zero document windows open.
enum NewDocumentDialog {
    /// Persistence goes through `Defaults` — this dialog used to
    /// reach into `UserDefaults.standard` with its own keys, which was the
    /// second of the two divergent paths. The raw key names are unchanged, so
    /// an upgrading user keeps their last-used size; the General pane edits
    /// the same two keys.

    /// Runs the modal dialog; calls `onCreate` only when the user confirms.
    static func present(onCreate: @escaping (CGSize) -> Void) {
        var chosen: CGSize?
        let host = NSHostingController(rootView: NewDocumentForm(
            clipboardSize: LayerPasteboard.contentPixelSize(on: .general),
            create: { size in
                chosen = size
                NSApp.stopModal()
            },
            cancel: { NSApp.stopModal() }))
        let window = NSWindow(contentViewController: host)
        window.title = "New Document"
        window.styleMask = [.titled] // no close button: runModal owns dismissal
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
        if let chosen { onCreate(chosen) }
    }
}

struct NewDocumentForm: View {
    let clipboardSize: CGSize?
    let create: (CGSize) -> Void
    let cancel: () -> Void

    @State private var width: Int
    @State private var height: Int
    /// The visible preset state (Photoshop shows a selected "Clipboard" card;
    /// our pop-up reads the active source the same way). Tracks the fields in
    /// both directions: picking fills them, editing them re-matches it.
    @State private var choice: PresetChoice
    @State private var suppressSync = false

    init(clipboardSize: CGSize? = nil,
         create: @escaping (CGSize) -> Void, cancel: @escaping () -> Void) {
        self.clipboardSize = clipboardSize
        self.create = create
        self.cancel = cancel
        // Clipboard content seeds the fields when present (its size is what a
        // paste needs); otherwise the last-used size — Photoshop's order.
        let seededWidth = clipboardSize.map { Int($0.width) }
            ?? Defaults.value(Defaults.Keys.newDocumentWidth)
        let seededHeight = clipboardSize.map { Int($0.height) }
            ?? Defaults.value(Defaults.Keys.newDocumentHeight)
        _width = State(initialValue: seededWidth)
        _height = State(initialValue: seededHeight)
        _choice = State(initialValue: Self.matchingChoice(width: seededWidth,
                                                          height: seededHeight,
                                                          clipboardSize: clipboardSize))
    }

    private enum PresetChoice: Hashable {
        case clipboard
        case fixed(Int) // index into `presets`
        case custom
    }

    private struct Preset {
        let name: String
        let width: Int
        let height: Int
    }

    private static let presets: [Preset] = [
        Preset(name: "HD", width: 1920, height: 1080),
        Preset(name: "4K UHD", width: 3840, height: 2160),
        Preset(name: "Square", width: 2048, height: 2048),
        Preset(name: "Photo 3∶2", width: 3000, height: 2000),
        Preset(name: "Portrait 4∶5", width: 1080, height: 1350),
    ]

    private static func matchingChoice(width: Int, height: Int,
                                       clipboardSize: CGSize?) -> PresetChoice {
        if let clipboardSize, Int(clipboardSize.width) == width,
           Int(clipboardSize.height) == height {
            return .clipboard
        }
        if let index = presets.firstIndex(where: { $0.width == width && $0.height == height }) {
            return .fixed(index)
        }
        return .custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Document")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text("Preset").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $choice) {
                    if let clipboardSize {
                        Text("Clipboard · \(Int(clipboardSize.width)) × \(Int(clipboardSize.height))")
                            .tag(PresetChoice.clipboard)
                    }
                    ForEach(Array(Self.presets.enumerated()), id: \.offset) { index, preset in
                        Text("\(preset.name) · \(preset.width) × \(preset.height)")
                            .tag(PresetChoice.fixed(index))
                    }
                    Text("Custom").tag(PresetChoice.custom)
                }
                .labelsHidden()
                .frame(width: 230)
            }

            HStack(alignment: .bottom, spacing: 8) {
                sizeField("Width", $width)
                sizeField("Height", $height)
                Text("px")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }

            if choice == .clipboard {
                Label("Sized to the clipboard image — paste after creating to land exactly.",
                      systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("1–16384 px per side. The size is remembered for the next new document.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let size = DocumentStore.clampedSize(CGSize(width: width, height: height))
                    Defaults.set(Int(size.width), for: Defaults.Keys.newDocumentWidth)
                    Defaults.set(Int(size.height), for: Defaults.Keys.newDocumentHeight)
                    create(size)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width < 1 || height < 1)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onChange(of: choice) { _, newValue in
            guard !suppressSync else { return }
            suppressSync = true
            switch newValue {
            case .clipboard:
                if let clipboardSize {
                    width = Int(clipboardSize.width)
                    height = Int(clipboardSize.height)
                }
            case .fixed(let index):
                width = Self.presets[index].width
                height = Self.presets[index].height
            case .custom:
                break
            }
            suppressSync = false
        }
        .onChange(of: width) { _, _ in rematchChoice() }
        .onChange(of: height) { _, _ in rematchChoice() }
    }

    /// Manual edits re-match the visible preset (back to Clipboard when the
    /// numbers agree again, Custom otherwise) — the pop-up always tells the
    /// truth about where the size came from.
    private func rematchChoice() {
        guard !suppressSync else { return }
        suppressSync = true
        choice = Self.matchingChoice(width: width, height: height,
                                     clipboardSize: clipboardSize)
        suppressSync = false
    }

    private func sizeField(_ label: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
        }
    }
}

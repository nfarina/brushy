import SwiftUI

/// Image → Image Size… (⌥⌘I). Resizes the whole document; the proportional
/// lock links the fields like Photoshop's chain icon. Implemented by scaling
/// layer transforms, so no quality is ever baked away.
struct ImageSizeSheet: View {
    @ObservedObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var width: Int = 0
    @State private var height: Int = 0
    @State private var proportional = true

    private var currentSize: CGSize { store.document.canvasSize }
    private var aspect: Double {
        currentSize.height > 0 ? Double(currentSize.width) / Double(currentSize.height) : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Image Size")
                .font(.title3.weight(.semibold))
            Text("Current: \(Int(currentSize.width)) × \(Int(currentSize.height)) px")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Captions get their own row so the link toggle and unit centre
            // on the input boxes, not on caption + input.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    fieldCaption("Width")
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    fieldCaption("Height")
                }
                GridRow {
                    sizeField(widthBinding)
                    Toggle(isOn: $proportional) {
                        Image(systemName: proportional ? "link" : "link.badge.plus")
                    }
                    .toggleStyle(.button)
                    .help("Constrain proportions")
                    sizeField(heightBinding)
                    Text("px").foregroundStyle(.secondary)
                }
            }

            Text("Layers are rescaled through their transforms and re-rendered from the original pixels — repeated resizes lose no quality.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Resize") {
                    store.resizeImage(to: CGSize(width: width, height: height))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width < 1 || height < 1)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            width = Int(currentSize.width)
            height = Int(currentSize.height)
        }
    }

    // Linking lives in the bindings so only the user's edit drives the other
    // field. An onChange pair ran after any suppress flag was reset, so each
    // keystroke's rounded result fed back into the field being typed in
    // (typing 3000 could land on 3100).
    private var widthBinding: Binding<Int> {
        Binding(get: { width }, set: { newValue in
            width = newValue
            if proportional { height = max(1, Int((Double(newValue) / aspect).rounded())) }
        })
    }

    private var heightBinding: Binding<Int> {
        Binding(get: { height }, set: { newValue in
            height = newValue
            if proportional { width = max(1, Int((Double(newValue) * aspect).rounded())) }
        })
    }

    private func fieldCaption(_ label: String) -> some View {
        Text(label).font(.caption).foregroundStyle(.secondary)
    }

    private func sizeField(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            .multilineTextAlignment(.trailing)
    }
}

/// Image → Canvas Size… (⌥⌘C). Changes the canvas frame around a 9-way
/// anchor. Non-destructive like crop: content outside the frame survives.
struct CanvasSizeSheet: View {
    @ObservedObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var width: Int = 0
    @State private var height: Int = 0
    /// Anchor in UI terms, row 0 = top. Converted to y-up on commit.
    @State private var anchorRow = 1
    @State private var anchorCol = 1

    private var currentSize: CGSize { store.document.canvasSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Canvas Size")
                .font(.title3.weight(.semibold))
            Text("Current: \(Int(currentSize.width)) × \(Int(currentSize.height)) px")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Width").frame(width: 46, alignment: .leading)
                        TextField("", value: $width, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text("px").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("Height").frame(width: 46, alignment: .leading)
                        TextField("", value: $height, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Anchor").font(.caption).foregroundStyle(.secondary)
                    anchorGrid
                }
            }

            Text("Content outside the new canvas is kept, not deleted — drag it back any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Resize") {
                    // UI rows are top-down; canvas anchors are y-up.
                    let anchor = CGPoint(x: Double(anchorCol) / 2,
                                         y: Double(2 - anchorRow) / 2)
                    store.resizeCanvas(to: CGSize(width: width, height: height), anchor: anchor)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width < 1 || height < 1)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            width = Int(currentSize.width)
            height = Int(currentSize.height)
        }
    }

    private var anchorGrid: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        Button {
                            anchorRow = row
                            anchorCol = col
                        } label: {
                            Image(systemName: anchorRow == row && anchorCol == col
                                  ? "circle.fill" : "circle")
                                .font(.system(size: 8))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .help("Existing content pins to this point of the new canvas")
    }
}

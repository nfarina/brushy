import SwiftUI

/// Which panel the fixed 280pt right column shows. A segmented
/// switch rather than a second pane or a floating window: it needs no window
/// lifecycle and no layout change, and both panels stay independent views if
/// this later becomes a `VSplitView`.
enum RightPanel: String, CaseIterable, Identifiable {
    case layers = "Layers"
    case history = "History"
    var id: String { rawValue }
}

struct RootView: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        VStack(spacing: 0) {
            ToolOptionsBar(store: store)
                .frame(height: 38)
            Divider()
            HStack(spacing: 0) {
                ToolStrip(store: store)
                    .frame(width: 44)
                Divider()
                CanvasRepresentable(store: store)
                    .frame(minWidth: 480, maxWidth: .infinity,
                           minHeight: 320, maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) {
                    Picker("", selection: $store.rightPanel) {
                        ForEach(RightPanel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    Divider()
                    switch store.rightPanel {
                    case .layers: LayersPanel(store: store)
                    case .history: HistoryPanel(store: store)
                    }
                }
                .frame(width: 280)
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .sheet(isPresented: $store.exportRequested) {
            ExportSheet(store: store)
        }
        .sheet(isPresented: $store.imageSizeRequested) {
            ImageSizeSheet(store: store)
        }
        .sheet(isPresented: $store.canvasSizeRequested) {
            CanvasSizeSheet(store: store)
        }
        .sheet(isPresented: $store.fillRequested) {
            FillSheet(store: store)
        }
        .sheet(item: $store.adjustmentRequest) { request in
            AdjustmentSheet(store: store, layerID: request.id)
        }
        .sheet(item: $store.colorPickerRequest) { target in
            ColorPickerSheet(store: store, target: target)
        }
        .sheet(item: $store.selectionModifyRequested) { kind in
            SelectionModifySheet(store: store, kind: kind)
        }
        .sheet(item: $store.layerStyleRequested) { request in
            LayerStyleSheet(store: store, request: request)
        }
        // Photoshop's rasterize prompt. "Add Layer Mask" is offered alongside
        // it because on a photo that is usually the better answer here.
        .alert("Rasterize “\(store.rasterizePrompt?.layerName ?? "")”?",
               isPresented: Binding(
                get: { store.rasterizePrompt != nil },
                set: { if !$0 { store.resolveRasterizePrompt(.cancel) } }),
               presenting: store.rasterizePrompt) { _ in
            Button("Rasterize") { store.resolveRasterizePrompt(.rasterize) }
            Button("Add Layer Mask") { store.resolveRasterizePrompt(.addMask) }
            Button("Cancel", role: .cancel) { store.resolveRasterizePrompt(.cancel) }
        } message: { prompt in
            Text("“\(prompt.layerName)” is an imported image, so its pixels are never changed. "
                 + "Rasterize it to \(prompt.intent) directly — its mask, if any, is applied into "
                 + "the pixels — or add a layer mask to keep working non-destructively.")
        }
        .alert("Dezzy", isPresented: Binding(
            get: { store.lastErrorMessage != nil },
            set: { if !$0 { store.lastErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let store: DocumentStore

    func makeNSView(context: Context) -> CanvasHostView {
        CanvasHostView(store: store)
    }

    func updateNSView(_ nsView: CanvasHostView, context: Context) {}
}

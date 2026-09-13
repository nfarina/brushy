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
    /// App-level: the same chats in every window (`ChatStore`).
    @ObservedObject var chats: ChatStore = .shared

    var body: some View {
        VStack(spacing: 0) {
            if !store.panelsHidden {
                ToolOptionsBar(store: store)
                    .frame(height: 38)
                Divider()
            }
            HStack(spacing: 0) {
                if !store.panelsHidden {
                    ToolStrip(store: store)
                        .frame(width: 44)
                    Divider()
                }
                CanvasRepresentable(store: store)
                    .frame(minWidth: 480, maxWidth: .infinity,
                           minHeight: 320, maxHeight: .infinity)
                    // Says what the app did on its own (rasterizing a layer so
                    // an edit could land) without standing in the way.
                    .overlay(alignment: .bottom) {
                        if let toast = store.toast {
                            ToastView(message: toast.message) { store.dismissToast() }
                                .padding(.bottom, 20)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: store.toast)
                if !store.panelsHidden {
                    Divider()
                    rightColumn
                    if chats.isSidebarVisible {
                        Divider()
                        ChatSidebar(chats: chats)
                    }
                }
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
        .alert("Brushy", isPresented: Binding(
            get: { store.lastErrorMessage != nil },
            set: { if !$0 { store.lastErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
    }
}

private extension RootView {
    var rightColumn: some View {
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

/// The toast itself: what happened, and the reminder that ⌘Z undoes it.
/// Click to dismiss; it fades on its own after a few seconds.
private struct ToastView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.callout)
                .lineLimit(1)
            Text("⌘Z to undo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // A solid fill rather than a material: this floats over the Metal
        // canvas, where vibrancy has nothing dependable to sample.
        .background(Color(white: 0.13).opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .onTapGesture(perform: dismiss)
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let store: DocumentStore

    func makeNSView(context: Context) -> CanvasHostView {
        CanvasHostView(store: store)
    }

    func updateNSView(_ nsView: CanvasHostView, context: Context) {}
}

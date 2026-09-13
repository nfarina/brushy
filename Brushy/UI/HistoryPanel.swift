import SwiftUI

/// — Photoshop's History palette: every state of the document's
/// snapshot history oldest-first, the current position highlighted,
/// click any row to jump there.
///
/// Row 0 is the opening state ("New" or "Open"), never an edit. Rows AFTER the
/// current position are the redo tail: they are dimmed because the next commit
/// discards them, which is exactly the affordance Photoshop provides.
///
/// No thumbnails — Photoshop renders one composite per state, which costs a
/// full render per row for very little; the action name carries the meaning.
struct HistoryPanel: View {
    @ObservedObject var store: DocumentStore

    /// The projection is rebuilt on every read because eviction shifts every
    /// index; nothing here may cache a row id across commits.
    private var entries: [DocumentStore.HistoryEntry] { store.historyEntries }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: selectionBinding) {
                    ForEach(entries) { entry in
                        row(entry)
                            .tag(entry.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    }
                }
                .listStyle(.plain)
                // Undo/redo from the keyboard moves the position without
                // touching this list; follow it so the highlight stays visible.
                .onChange(of: store.historyPosition) { _, newValue in
                    proxy.scrollTo(newValue)
                }
            }
            Divider()
            footer
        }
        .background(.background.opacity(0.4))
    }

    /// List selection IS the history position: setting it jumps. Reading it
    /// from the store (rather than `@State`) keeps the highlight correct after
    /// ⌘Z, a commit that truncates the tail, or eviction.
    private var selectionBinding: Binding<Int?> {
        Binding(get: { store.historyPosition },
                set: { if let index = $0 { store.jumpToHistory(index: index) } })
    }

    private func row(_ entry: DocumentStore.HistoryEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.actionName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.callout)
        // The redo tail reads as provisional, like Photoshop's greyed states.
        .foregroundStyle(entry.isRedoTail ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .fontWeight(entry.isCurrent ? .semibold : .regular)
        .contentShape(Rectangle())
        .help(entry.isRedoTail
              ? "\(entry.actionName) — will be discarded by the next edit"
              : entry.actionName)
    }

    /// The history's real depth, plus an explicit note when states have been
    /// dropped: paint steps retain a full-size bitmap each, so a long brush
    /// session hits the byte budget well before the 100-step count cap. Saying
    /// so makes the behaviour legible rather than mysterious.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(entries.count) of \(store.undoDepth) steps")
            if let note = store.historyLimitNote {
                Text(note).foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

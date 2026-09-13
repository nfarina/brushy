import AppKit
import SwiftUI

/// The AI chat sidebar: app-level (every window shows the same chats), a
/// list of conversations, and inside one a transcript with tool calls the
/// user can expand to read the script that ran. Styled like the Layers and
/// History panels so it reads as part of the same chrome.
struct ChatSidebar: View {
    @ObservedObject var chats: ChatStore
    static let width: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let id = chats.activeChatID, let session = chats.session(for: id) {
                ChatConversationView(session: session, chats: chats)
            } else {
                ChatListView(chats: chats)
            }
        }
        .frame(width: Self.width)
        .background(.background.opacity(0.4))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let id = chats.activeChatID, let session = chats.session(for: id) {
                Button { chats.activeChatID = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .help("All chats")
                Text(session.chat.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let cost = session.chat.totalCost {
                    Text(AIPricing.format(cost))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                        .fixedSize()
                        .help(String(format: "About $%.4f at Gemini list prices, image generation included",
                                     cost))
                        .accessibilityLabel("Chat cost \(AIPricing.format(cost))")
                }
            } else {
                Text("Chats")
                    .font(.callout.weight(.semibold))
            }
            Spacer()
            Button { chats.newChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.plain)
                .help("New Chat")
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// The show/hide button that lives in every document window's title bar
/// (`BrushyDocument.makeWindowControllers`), so the sidebar can be brought
/// back after hiding it. Tinted while the sidebar is open.
struct ChatSidebarToggle: View {
    @ObservedObject var chats: ChatStore = .shared

    var body: some View {
        Button { chats.isSidebarVisible.toggle() } label: {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(chats.isSidebarVisible ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chats.isSidebarVisible ? "Hide AI Chat (⌘L)" : "Show AI Chat (⌘L)")
        .padding(.trailing, 8)
    }
}

// MARK: - Chat list

private struct ChatListView: View {
    @ObservedObject var chats: ChatStore

    var body: some View {
        if chats.chats.filter({ !$0.isEmpty }).isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Text("Ask for changes to the open documents in plain language.\n\nTry: “arrange the screenshots in a row with 24px gaps and fit the canvas”")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.horizontal, 24)
                Button("New Chat") { chats.newChat() }
                    .keyboardShortcut(.defaultAction)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(chats.chats.filter { !$0.isEmpty }) { chat in
                    Button { chats.activeChatID = chat.id } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title)
                                .font(.callout)
                                .lineLimit(1)
                            Text(chat.updatedAt, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .contextMenu {
                        Button("Delete", role: .destructive) { chats.delete(chat.id) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Conversation

private struct ChatConversationView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var chats: ChatStore
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(session.chat.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                        if session.isBusy, session.chat.messages.last?.isStreaming != true {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                            .id("busy")
                        }
                    }
                    .padding(10)
                }
                .onChange(of: session.chat.messages) { _, messages in
                    withAnimation(.easeOut(duration: 0.15)) {
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: session.isBusy) { _, busy in
                    if busy { proxy.scrollTo("busy", anchor: .bottom) }
                }
            }
            Divider()
            if !chats.hasGeminiKey {
                HStack(spacing: 8) {
                    Image(systemName: "key").foregroundStyle(.secondary)
                    Text("Add a Gemini API key to chat.")
                        .font(.caption)
                    Spacer()
                    Button("Settings…") { SettingsWindowController.showWindow(pane: .ai) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            inputBar
        }
        .onAppear {
            inputFocused = true
            chats.refreshAPIKey()
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask for a change…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .font(.callout)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
            if session.isBusy {
                Button { session.cancel() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .help("Send (Return; ⌥Return for a new line)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !session.isBusy else { return }
        draft = ""
        session.send(text)
    }
}

// MARK: - Rows

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.25)))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 0) {
                markdown(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                Spacer(minLength: 0)
            }
        case .tool:
            if let tool = message.tool { ToolCallRow(record: tool) }
        case .error:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 4)
        }
    }

    private func markdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}

private struct ToolCallRow: View {
    let record: ToolCallRecord
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    statusIcon
                        .frame(width: 14)
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                    Text(record.description)
                        .font(.callout)
                        .lineLimit(expanded ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                if let code = record.code, !code.isEmpty {
                    codeBlock(code, title: "Script")
                }
                if let arguments = record.arguments, !arguments.isEmpty {
                    codeBlock(arguments, title: "Arguments")
                }
                if let data = record.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if !record.result.isEmpty {
                    codeBlock(record.result, title: record.status == .failed ? "Error" : "Result")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))
    }

    private var icon: String {
        switch record.name {
        case ChatTools.lookName: return "eye"
        case ChatTools.generateImageName: return "sparkles"
        default: return "curlybraces"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.status {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func codeBlock(_ text: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.25)))
        }
    }
}

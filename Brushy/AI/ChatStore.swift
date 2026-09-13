import Foundation

/// The app's chats: the list the sidebar shows, one `ChatSession` per open
/// chat, and JSON persistence under Application Support. App-scoped, like
/// `AppSettings` — every window's sidebar shows the same list.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    /// Newest first.
    @Published private(set) var chats: [Chat] = []
    @Published var isSidebarVisible: Bool {
        didSet { Defaults.set(isSidebarVisible, for: Defaults.Keys.chatSidebarVisible) }
    }
    @Published var activeChatID: UUID?
    /// Whether a Gemini key is available — Keychain or environment. Starts
    /// optimistic and is refreshed when a conversation appears and whenever
    /// `APIKeys.didChange` fires (typing a key into Settings clears the
    /// sidebar's hint without a new chat). Deliberately not read at init:
    /// an ad-hoc-signed build gets a keychain permission prompt on its first
    /// read after every rebuild, and that belongs at the moment the user
    /// opens a chat, not at app launch — and never inside the unit tests.
    @Published private(set) var hasGeminiKey = true
    /// Where the key comes from; tests substitute a stub.
    var keyLookup: () -> String? = { APIKeys.gemini }

    let registry: DocumentRegistry
    let runner: ScriptRunner
    let tools: ChatTools
    let directory: URL
    private var sessions: [UUID: ChatSession] = [:]

    init(directory: URL? = nil, registry: DocumentRegistry = .shared) {
        self.registry = registry
        self.runner = ScriptRunner(registry: registry)
        self.tools = ChatTools(registry: registry, runner: runner)
        self.directory = directory ?? Self.defaultDirectory
        self.isSidebarVisible = Defaults.value(Defaults.Keys.chatSidebarVisible)
        NotificationCenter.default.addObserver(forName: APIKeys.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAPIKey() }
        }
        tools.imageClient = { APIKeys.gemini.map { GeminiClient(apiKey: $0) } }
        tools.imageModel = { Defaults.value(Defaults.Keys.imageModel) }
        load()
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Brushy/Chats", isDirectory: true)
    }

    func refreshAPIKey() {
        let available = keyLookup() != nil
        if available != hasGeminiKey { hasGeminiKey = available }
    }

    // MARK: - Persistence

    private func load() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        chats = urls.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Chat.self, from: $0) } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    func save(_ chat: Chat) {
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
        } else {
            chats.insert(chat, at: 0)
        }
        chats.sort { $0.updatedAt > $1.updatedAt }
        // Empty chats are not worth a file; they are recreated on demand.
        guard !chat.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(chat).write(to: url(for: chat.id), options: .atomic)
        } catch {
            NSLog("Brushy: could not save chat: \(error)")
        }
    }

    // MARK: - Sessions

    /// A fresh chat — or the current one, if it is still empty.
    @discardableResult
    func newChat() -> ChatSession {
        if let id = activeChatID, let session = sessions[id], session.chat.isEmpty {
            return session
        }
        if let empty = chats.first(where: \.isEmpty), let session = session(for: empty.id) {
            activeChatID = empty.id
            return session
        }
        let chat = Chat()
        chats.insert(chat, at: 0)
        activeChatID = chat.id
        return session(for: chat.id)!
    }

    func session(for id: UUID) -> ChatSession? {
        if let session = sessions[id] { return session }
        guard let chat = chats.first(where: { $0.id == id }) else { return nil }
        let registry = self.registry
        let session = ChatSession(chat: chat, tools: tools,
                                  providerFactory: { try Self.makeProvider() },
                                  contextProvider: { ChatPrompt.contextPrefix(registry: registry) })
        session.onChange = { [weak self] chat in self?.save(chat) }
        sessions[id] = session
        return session
    }

    func delete(_ id: UUID) {
        sessions[id]?.cancel()
        sessions[id] = nil
        chats.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: url(for: id))
        if activeChatID == id { activeChatID = nil }
    }

    static func makeProvider() throws -> ChatProvider {
        guard let key = APIKeys.gemini else { throw GeminiError.missingKey }
        let thinking = Defaults.value(Defaults.Keys.chatThinkingLevel)
        return GeminiChatProvider(client: GeminiClient(apiKey: key),
                                  model: Defaults.value(Defaults.Keys.chatModel),
                                  thinkingLevel: thinking == "default" ? nil : thinking)
    }
}

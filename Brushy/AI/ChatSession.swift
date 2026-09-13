import Foundation

/// One model turn, provider-neutral enough that a second provider is a
/// second conformance. The history is the provider's own step format.
protocol ChatProvider {
    /// The model id, for pricing a turn (`AIPricing`).
    var model: String { get }
    func interact(systemInstruction: String, tools: [ToolDeclaration], input: [JSONValue],
                  onEvent: @escaping (GeminiStreamEvent) -> Void) async throws -> Interaction
}

struct GeminiChatProvider: ChatProvider {
    let client: GeminiClient
    let model: String
    let thinkingLevel: String?

    func interact(systemInstruction: String, tools: [ToolDeclaration], input: [JSONValue],
                  onEvent: @escaping (GeminiStreamEvent) -> Void) async throws -> Interaction {
        try await client.interact(model: model, systemInstruction: systemInstruction, tools: tools,
                                  input: input, thinkingLevel: thinkingLevel, onEvent: onEvent)
    }
}

/// The agent loop for one chat: send the user's message with the document
/// context, run whatever tools the model asks for, feed the results back,
/// repeat until the model answers in words. Main-actor; the sidebar observes
/// `chat` and `isBusy`.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var chat: Chat
    @Published private(set) var isBusy = false

    let tools: ChatTools
    /// Built per turn so a key or model changed in Settings applies at once.
    var providerFactory: () throws -> ChatProvider
    /// The [Context] block for the next message.
    var contextProvider: () -> String
    var onChange: ((Chat) -> Void)?

    /// A backstop for a model stuck in a loop, not a budget: the sidebar's
    /// stop button is the real control.
    static let maxToolRounds = 50

    private var task: Task<Void, Never>?

    init(chat: Chat, tools: ChatTools, providerFactory: @escaping () throws -> ChatProvider,
         contextProvider: @escaping () -> String) {
        self.chat = chat
        self.tools = tools
        self.providerFactory = providerFactory
        self.contextProvider = contextProvider
    }

    /// Replaces the transcript wholesale (seeding a snapshot state, or a
    /// chat reloaded from disk); never while a turn is in flight.
    func load(_ chat: Chat) {
        guard !isBusy else { return }
        self.chat = chat
        onChange?(chat)
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        if chat.messages.isEmpty {
            let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
            chat.title = firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
        }
        chat.messages.append(ChatMessage(role: .user, text: trimmed))
        chat.history.append(ChatPrompt.userInput(text: trimmed, context: contextProvider()))
        touch()
        isBusy = true
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func touch() {
        chat.updatedAt = Date()
        onChange?(chat)
    }

    private func runLoop() async {
        defer {
            isBusy = false
            task = nil
            touch()
        }
        let system = ChatPrompt.systemInstruction()
        for _ in 0..<Self.maxToolRounds {
            let provider: ChatProvider
            do {
                provider = try providerFactory()
            } catch {
                chat.messages.append(ChatMessage(role: .error, text: error.localizedDescription))
                return
            }
            // The round's model cost goes on the first message it produces.
            let roundStart = chat.messages.count
            var streamingIndex: Int?
            let interaction: Interaction
            do {
                interaction = try await provider.interact(systemInstruction: system,
                                                          tools: ChatTools.declarations,
                                                          input: chat.history) { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard let self, case .text(let delta) = event else { return }
                        if let index = streamingIndex {
                            self.chat.messages[index].text += delta
                        } else {
                            self.chat.messages.append(ChatMessage(role: .assistant, text: delta, isStreaming: true))
                            streamingIndex = self.chat.messages.count - 1
                        }
                    }
                }
            } catch is CancellationError {
                finishStreaming(at: streamingIndex, text: nil)
                chat.messages.append(ChatMessage(role: .error, text: "Stopped."))
                return
            } catch {
                finishStreaming(at: streamingIndex, text: nil)
                chat.messages.append(ChatMessage(role: .error, text: error.localizedDescription))
                return
            }
            chat.history.append(contentsOf: interaction.steps)
            var pendingCost: Double?
            if let usage = interaction.usage {
                chat.usage.add(usage)
                pendingCost = AIPricing.cost(model: provider.model, usage: usage)
            }
            finishStreaming(at: streamingIndex, text: interaction.text)
            addCost(&pendingCost, toMessageAt: roundStart)
            let calls = interaction.functionCalls
            if calls.isEmpty {
                // A turn with nothing to show still cost something.
                addCost(&pendingCost, toMessageAt: chat.messages.count - 1)
                touch()
                return
            }
            for call in calls {
                if Task.isCancelled {
                    // Every call the model made needs a result in the
                    // history, or the next request is malformed.
                    chat.history.append(ChatPrompt.functionResult(callID: call.id, name: call.name,
                                                                  text: "Cancelled by the user before it ran.",
                                                                  image: nil))
                    continue
                }
                let record = ToolCallRecord(name: call.name,
                                            description: call.string("description") ?? Self.summary(of: call),
                                            code: call.string("code"),
                                            arguments: Self.arguments(of: call))
                chat.messages.append(ChatMessage(role: .tool, tool: record))
                let index = chat.messages.count - 1
                addCost(&pendingCost, toMessageAt: roundStart)
                touch()
                let started = Date()
                let outcome = await tools.run(call)
                chat.messages[index].tool?.status = outcome.status
                chat.messages[index].tool?.result = outcome.text
                chat.messages[index].tool?.imageData = outcome.displayImage
                chat.messages[index].tool?.duration = Date().timeIntervalSince(started)
                var toolCost = outcome.cost
                addCost(&toolCost, toMessageAt: index)
                chat.history.append(ChatPrompt.functionResult(callID: call.id, name: call.name,
                                                              text: outcome.text, image: outcome.image))
                touch()
            }
            // Every call was cancelled before it ran.
            addCost(&pendingCost, toMessageAt: chat.messages.count - 1)
            if Task.isCancelled {
                chat.messages.append(ChatMessage(role: .error, text: "Stopped."))
                return
            }
        }
        chat.messages.append(ChatMessage(role: .error, text: "Stopped after \(Self.maxToolRounds) tool calls without a final answer."))
    }

    /// Adds `cost` to the message at `index` and clears it; leaves it pending
    /// when that message doesn't exist yet.
    private func addCost(_ cost: inout Double?, toMessageAt index: Int) {
        guard let amount = cost, chat.messages.indices.contains(index) else { return }
        chat.messages[index].cost = (chat.messages[index].cost ?? 0) + amount
        cost = nil
    }

    private func finishStreaming(at index: Int?, text: String?) {
        guard let index, chat.messages.indices.contains(index) else {
            if let text, !text.isEmpty {
                chat.messages.append(ChatMessage(role: .assistant, text: text))
            }
            return
        }
        chat.messages[index].isStreaming = false
        if let text {
            if text.isEmpty {
                chat.messages.remove(at: index)
            } else {
                chat.messages[index].text = text
            }
        }
    }

    private static func summary(of call: FunctionCall) -> String {
        switch call.name {
        case ChatTools.lookName:
            if let layer = call.string("layer") { return "Look at layer \"\(layer)\"" }
            return "Look at \(call.string("document") ?? "the document")"
        case ChatTools.generateImageName:
            return "Generate: " + String((call.string("prompt") ?? "").prefix(60))
        default:
            return call.name
        }
    }

    private static func arguments(of call: FunctionCall) -> String? {
        guard call.name != ChatTools.executeName else { return nil }
        let args = call.arguments.filter { $0.key != "code" }
        guard !args.isEmpty else { return nil }
        return JSONValue.object(args).prettyString
    }
}

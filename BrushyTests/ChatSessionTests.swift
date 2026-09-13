import CoreGraphics
import XCTest

/// The agent loop against a scripted provider: tool calls run for real
/// (scripts commit to real stores), the history stays well-formed, and the
/// sidebar's message list ends up in the right shape.
@MainActor
final class ChatSessionTests: XCTestCase {
    /// Answers each turn from a queue; records what it was sent.
    final class FakeProvider: ChatProvider {
        var turns: [Interaction]
        var inputs: [[JSONValue]] = []
        var systemInstructions: [String] = []
        init(turns: [Interaction]) { self.turns = turns }

        func interact(systemInstruction: String, tools: [ToolDeclaration], input: [JSONValue],
                      onEvent: @escaping (GeminiStreamEvent) -> Void) async throws -> Interaction {
            inputs.append(input)
            systemInstructions.append(systemInstruction)
            guard !turns.isEmpty else { throw GeminiError.api("no more turns") }
            let turn = turns.removeFirst()
            for step in turn.steps where step["type"]?.stringValue == "model_output" {
                for part in step["content"]?.arrayValue ?? [] {
                    if let text = part["text"]?.stringValue { onEvent(.text(text)) }
                }
            }
            return turn
        }
    }

    private static func text(_ string: String) -> JSONValue {
        .object(["type": .string("model_output"), "content": .array([.object(["type": .string("text"), "text": .string(string)])])])
    }

    private static func call(_ id: String, _ name: String, _ args: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("function_call"), "id": .string(id), "name": .string(name), "arguments": .object(args)])
    }

    private static let thought: JSONValue = .object(["type": .string("thought"), "signature": .string("sig")])

    private func makeStore() -> DocumentStore {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        for (i, name) in ["A", "B"].enumerated() {
            var layer = Layer(name: name, source: GeneratedImages.solid(width: 100, height: 80, r: 200, g: 80, b: 120,
                                                                         colorSpace: BrushyColorSpace.displayP3))
            layer.transform = CGAffineTransform(translationX: CGFloat(10 + i * 140), y: 20)
            document.layers.append(layer)
        }
        return DocumentStore(document: document)
    }

    private func makeSession(store: DocumentStore, provider: FakeProvider) -> ChatSession {
        let registry = DocumentRegistry()
        registry.enumerate = { [(store, "Untitled")] }
        registry.active = { store }
        let tools = ChatTools(registry: registry, runner: ScriptRunner(registry: registry))
        return ChatSession(chat: Chat(), tools: tools, providerFactory: { provider },
                           contextProvider: { ChatPrompt.contextPrefix(registry: registry) })
    }

    private func waitUntilIdle(_ session: ChatSession) async {
        for _ in 0..<200 where session.isBusy {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(session.isBusy)
    }

    func testToolRoundTripCommitsAndFeedsResultBack() async {
        let store = makeStore()
        let provider = FakeProvider(turns: [
            Interaction(id: nil, status: "requires_action",
                        steps: [Self.thought, Self.call("c1", "execute", ["code": .string("doc.layer('A').move(0, 50); return doc.layers.length;"),
                                                                            "description": .string("Nudge A down")])],
                        usage: InteractionUsage(inputTokens: 100, outputTokens: 10)),
            Interaction(id: nil, status: "completed", steps: [Self.text("Moved A down by 50.")],
                        usage: InteractionUsage(inputTokens: 200, outputTokens: 8)),
        ])
        let session = makeSession(store: store, provider: provider)
        var saved: [Chat] = []
        session.onChange = { saved.append($0) }
        session.send("move A down 50")
        await waitUntilIdle(session)

        // The document changed, as one named history entry.
        let a = store.document.layers[0]
        XCTAssertEqual(ScriptGeometry.topLeft(a.canvasBounds, canvasHeight: 300).minY, 250)
        XCTAssertEqual(store.historyEntries.last?.actionName, "AI: Nudge A down")

        // Messages: user, tool, assistant.
        let roles = session.chat.messages.map(\.role)
        XCTAssertEqual(roles, [.user, .tool, .assistant])
        XCTAssertEqual(session.chat.messages[1].tool?.status, .succeeded)
        XCTAssertTrue(session.chat.messages[1].tool?.result.contains("changed \"A\"") == true)
        XCTAssertTrue(session.chat.messages[1].tool?.result.contains("Returned: 2") == true)
        XCTAssertEqual(session.chat.messages[2].text, "Moved A down by 50.")
        XCTAssertFalse(session.chat.messages[2].isStreaming)
        XCTAssertEqual(session.chat.title, "move A down 50")

        // History: user_input, thought, function_call, function_result, model_output.
        let types = session.chat.history.map { $0["type"]?.stringValue ?? "?" }
        XCTAssertEqual(types, ["user_input", "thought", "function_call", "function_result", "model_output"])
        XCTAssertEqual(session.chat.history[3]["call_id"]?.stringValue, "c1")
        // The second request carried the whole history so far.
        XCTAssertEqual(provider.inputs.count, 2)
        XCTAssertEqual(provider.inputs[1].count, 4)
        XCTAssertTrue(provider.systemInstructions[0].contains("declare class Doc"))
        // The context block described the document.
        let first = provider.inputs[0][0]["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(first.hasPrefix("[Context]\nActive document:\ndoc1 \"Untitled\" 400×300 px, 2 layers"), first)
        XCTAssertTrue(first.hasSuffix("[Message]\nmove A down 50"))
        XCTAssertEqual(session.chat.usage.inputTokens, 300)
        XCTAssertFalse(saved.isEmpty)
    }

    func testScriptErrorIsReportedAndNothingCommits() async {
        let store = makeStore()
        let provider = FakeProvider(turns: [
            Interaction(id: nil, status: "requires_action",
                        steps: [Self.call("c1", "execute", ["code": .string("doc.layer('A').move(0, 50);\ndoc.arrange(['nope']);"),
                                                              "description": .string("Broken")])], usage: nil),
            Interaction(id: nil, status: "completed", steps: [Self.text("That failed.")], usage: nil),
        ])
        let session = makeSession(store: store, provider: provider)
        session.send("do a thing")
        await waitUntilIdle(session)
        XCTAssertFalse(store.canUndo)
        XCTAssertEqual(session.chat.messages[1].tool?.status, .failed)
        XCTAssertTrue(session.chat.messages[1].tool?.result.hasPrefix("Error on line 2: No layer \"nope\"") == true,
                      session.chat.messages[1].tool?.result ?? "")
        let fed = session.chat.history[2]["result"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(fed.contains("Nothing was applied."))
    }

    func testProviderErrorBecomesErrorMessage() async {
        let store = makeStore()
        let session = makeSession(store: store, provider: FakeProvider(turns: []))
        session.send("hello")
        await waitUntilIdle(session)
        XCTAssertEqual(session.chat.messages.last?.role, .error)
        XCTAssertEqual(session.chat.messages.last?.text, "no more turns")
    }

    func testMissingKeyIsExplained() async {
        let store = makeStore()
        let registry = DocumentRegistry()
        registry.enumerate = { [(store, "Untitled")] }
        let tools = ChatTools(registry: registry, runner: ScriptRunner(registry: registry))
        let session = ChatSession(chat: Chat(), tools: tools, providerFactory: { throw GeminiError.missingKey },
                                  contextProvider: { "" })
        session.send("hello")
        await waitUntilIdle(session)
        XCTAssertEqual(session.chat.messages.last?.text, GeminiError.missingKey.localizedDescription)
    }

    func testLookToolReturnsAnImage() async {
        let store = makeStore()
        let provider = FakeProvider(turns: [
            Interaction(id: nil, status: "requires_action",
                        steps: [Self.call("c1", "look", ["layer": .string("A"), "max_size": .number(80)])], usage: nil),
            Interaction(id: nil, status: "completed", steps: [Self.text("It's pink.")], usage: nil),
        ])
        let session = makeSession(store: store, provider: provider)
        session.send("what colour is A?")
        await waitUntilIdle(session)
        let tool = session.chat.messages[1].tool
        XCTAssertEqual(tool?.status, .succeeded)
        XCTAssertNotNil(tool?.imageData)
        XCTAssertTrue(tool?.result.contains("rendered at 80×64") == true, tool?.result ?? "")
        let parts = session.chat.history[2]["result"]?.arrayValue ?? []
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1]["mime_type"]?.stringValue, "image/png")
    }

    func testChatStorePersistsAndReloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrushyChatTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = DocumentRegistry()
        let store = ChatStore(directory: directory, registry: registry)
        let session = store.newChat()
        XCTAssertTrue(store.newChat() === session, "an empty chat is reused")
        var chat = session.chat
        chat.messages = [ChatMessage(role: .user, text: "hi")]
        chat.history = [.object(["type": .string("user_input"), "content": .string("hi")])]
        chat.title = "hi"
        store.save(chat)
        let reloaded = ChatStore(directory: directory, registry: registry)
        XCTAssertEqual(reloaded.chats.map(\.title), ["hi"])
        XCTAssertEqual(reloaded.chats.first?.history.first?["type"]?.stringValue, "user_input")
        reloaded.delete(chat.id)
        XCTAssertTrue(reloaded.chats.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(chat.id.uuidString).json").path))
    }
}

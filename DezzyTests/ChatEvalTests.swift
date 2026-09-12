import CoreGraphics
import XCTest
@testable import Dezzy

/// Live evaluation against the real Gemini API: does the configured model,
/// given the system prompt and API, turn plain-language requests into the
/// right document changes? Skipped unless a key is available (the
/// `GEMINI_API_KEY` environment variable, or `~/.config/imagegen/secrets.env`).
/// Costs a few cents per run. Override the model with `DEZZY_EVAL_MODEL`.
///
///     TEST_RUNNER_DEZZY_EVAL=1 xcodebuild -project Dezzy.xcodeproj -scheme Dezzy test -only-testing:DezzyTests/ChatEvalTests
@MainActor
final class ChatEvalTests: XCTestCase {
    private static func apiKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty { return key }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/imagegen/secrets.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("GEMINI_API_KEY=") {
            return String(line.dropFirst("GEMINI_API_KEY=".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private var model: String {
        ProcessInfo.processInfo.environment["DEZZY_EVAL_MODEL"] ?? Defaults.Keys.chatModel.fallback
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEZZY_EVAL"] == "1",
                          "Set DEZZY_EVAL=1 to run live model evaluations")
        try XCTSkipUnless(Self.apiKey() != nil, "No Gemini API key available")
    }

    /// 400×300; A, B, C are 100×80 at top-left (10,200), (150,200), (290,200).
    private func makeStore() -> DocumentStore {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        for (i, name) in ["A", "B", "C"].enumerated() {
            var layer = Layer(name: name, source: GeneratedImages.solid(width: 100, height: 80,
                                                                         r: UInt8(60 * i + 40), g: 80, b: 120,
                                                                         colorSpace: DezzyColorSpace.displayP3))
            layer.transform = CGAffineTransform(translationX: CGFloat(10 + i * 140), y: 20)
            document.layers.append(layer)
        }
        return DocumentStore(document: document)
    }

    private struct Run {
        let session: ChatSession
        let store: DocumentStore
        let seconds: TimeInterval
        let messages: [ChatMessage]
        var transcript: String {
            messages.map { message -> String in
                switch message.role {
                case .user: return "USER: \(message.text)"
                case .assistant: return "ASSISTANT: \(message.text)"
                case .error: return "ERROR: \(message.text)"
                case .tool:
                    let tool = message.tool!
                    return "TOOL \(tool.name) [\(tool.status.rawValue)] \(tool.description)\n\(tool.code ?? tool.arguments ?? "")\n→ \(tool.result.prefix(400))"
                }
            }.joined(separator: "\n")
        }
    }

    private func ask(_ text: String, store: DocumentStore? = nil) async -> Run {
        let store = store ?? makeStore()
        let registry = DocumentRegistry()
        registry.enumerate = { [(store, "Untitled")] }
        registry.active = { store }
        let tools = ChatTools(registry: registry, runner: ScriptRunner(registry: registry))
        let client = GeminiClient(apiKey: Self.apiKey()!)
        let provider = GeminiChatProvider(client: client, model: model, thinkingLevel: "low")
        let session = ChatSession(chat: Chat(), tools: tools, providerFactory: { provider },
                                  contextProvider: { ChatPrompt.contextPrefix(registry: registry) })
        let started = Date()
        session.send(text)
        for _ in 0..<600 where session.isBusy {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let run = Run(session: session, store: store, seconds: Date().timeIntervalSince(started),
                      messages: session.chat.messages)
        let usage = session.chat.usage
        print("""
            ===== EVAL (\(model), \(String(format: "%.1f", run.seconds)) s, \(usage.inputTokens) in / \(usage.outputTokens) out / \(usage.thoughtTokens) thought)
            \(run.transcript)
            """)
        return run
    }

    private func frames(_ store: DocumentStore) -> [String: CGRect] {
        let height = store.document.canvasSize.height
        return Dictionary(store.document.layers.map { ($0.name, ScriptGeometry.topLeft($0.canvasBounds, canvasHeight: height)) },
                          uniquingKeysWith: { a, _ in a })
    }

    func testArrangeInRowAndFitCanvas() async {
        let run = await ask("Arrange the three layers in a horizontal row with 20px gaps starting at the top-left corner, then fit the canvas to the content with no padding.")
        let f = frames(run.store)
        XCTAssertEqual(run.store.document.canvasSize, CGSize(width: 340, height: 80), run.transcript)
        XCTAssertEqual(f["A"]?.origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(f["B"]?.origin, CGPoint(x: 120, y: 0))
        XCTAssertEqual(f["C"]?.origin, CGPoint(x: 240, y: 0))
        XCTAssertEqual(run.session.chat.messages.last?.role, .assistant)
    }

    func testWhiteBackgroundLayer() async throws {
        let run = await ask("Add a white background behind everything.")
        let bottom = try XCTUnwrap(run.store.document.layers.first, run.transcript)
        XCTAssertTrue(bottom.isPaintable, run.transcript)
        XCTAssertEqual(bottom.canvasBounds, run.store.document.canvasRect, run.transcript)
        let pixels = try rawRGBA8(bottom.source)
        let p = pixels[5, 5]
        XCTAssertEqual([p.r, p.g, p.b, p.a], [255, 255, 255, 255])
        XCTAssertEqual(run.store.document.layers.count, 4)
    }

    func testGridOfText() async {
        let run = await ask("Make a 3 by 3 grid of the letter X in red at 40px, with the cells 60px apart starting at (10, 10).")
        let texts = run.store.document.layers.filter { $0.kind.textSpec?.text == "X" }
        XCTAssertEqual(texts.count, 9, run.transcript)
        let height = run.store.document.canvasSize.height
        let origins = Set(texts.map { layer -> String in
            let f = ScriptGeometry.topLeft(layer.canvasBounds, canvasHeight: height)
            return "\(Int(f.minX.rounded())),\(Int(f.minY.rounded()))"
        })
        XCTAssertEqual(origins.count, 9, "cells overlap: \(origins)")
        XCTAssertEqual(texts.first?.kind.textSpec?.color, ColorSpec(r: 1, g: 0, b: 0))
    }

    func testDeleteAndRename() async {
        let run = await ask("Delete layer B and rename A to Hero.")
        XCTAssertEqual(run.store.document.layers.map(\.name), ["Hero", "C"], run.transcript)
        XCTAssertEqual(run.store.historyEntries.filter { $0.actionName.hasPrefix("AI:") }.count, 1,
                       "expected one undo step")
    }

    func testCenteredTitle() async throws {
        let run = await ask("Put a title that says Hello at the top of the canvas, horizontally centred, 48px, 10px from the top edge.")
        let title = try XCTUnwrap(run.store.document.layers.first { $0.kind.textSpec?.text == "Hello" }, run.transcript)
        let f = ScriptGeometry.topLeft(title.canvasBounds, canvasHeight: run.store.document.canvasSize.height)
        XCTAssertEqual(f.midX, 200, accuracy: 4, run.transcript)
        XCTAssertEqual(f.minY, 10, accuracy: 4, run.transcript)
        XCTAssertEqual(title.kind.textSpec?.fontSize, 48)
    }

    /// The request that produced 108 one-row shape layers before `draw` and
    /// `fillGradient` existed: now it must be one paint layer.
    func testMultistopGradientIsOneLayer() async throws {
        let run = await ask("Fill the canvas with a very pretty multistop gradient.")
        let document = run.store.document
        XCTAssertEqual(document.layers.count, 4, run.transcript)
        let added = try XCTUnwrap(document.layers.first { !["A", "B", "C"].contains($0.name) }, run.transcript)
        XCTAssertTrue(added.isPaintable, run.transcript)
        XCTAssertNil(added.kind.shapeSpec, "a shape layer, not pixels: \(run.transcript)")
        XCTAssertEqual(added.canvasBounds, document.canvasRect, run.transcript)
        let px = try rawRGBA8(added.source)
        let top = px[200, 5], bottom = px[200, 294], middle = px[200, 150]
        XCTAssertNotEqual([top.r, top.g, top.b], [bottom.r, bottom.g, bottom.b], "no ramp: \(run.transcript)")
        XCTAssertNotEqual([top.r, top.g, top.b], [middle.r, middle.g, middle.b], "no ramp: \(run.transcript)")
    }

    func testCheckerboardIsDrawnOnOneLayer() async throws {
        let run = await ask("Add a new layer with an 8 by 6 checkerboard covering the whole canvas, alternating navy and cream, starting with navy in the top-left cell.")
        let document = run.store.document
        XCTAssertEqual(document.layers.count, 4, run.transcript)
        let added = try XCTUnwrap(document.layers.first { !["A", "B", "C"].contains($0.name) }, run.transcript)
        XCTAssertTrue(added.isPaintable, run.transcript)
        let px = try rawRGBA8(added.source, in: DezzyColorSpace.sRGB)
        // 50×50 cells on 400×300: (25,25) navy, (75,25) cream, (25,75) cream.
        let navy = px[25, 25], cream = px[75, 25], below = px[25, 75]
        XCTAssertLessThan(navy.r, 100, "top-left should be navy: \(navy) — \(run.transcript)")
        XCTAssertGreaterThan(cream.r, 180, "second cell should be cream: \(cream) — \(run.transcript)")
        XCTAssertGreaterThan(below.r, 180, "cell below should be cream: \(below) — \(run.transcript)")
    }

    func testQuestionUsesContextWithoutTools() async {
        let run = await ask("How many layers are there and what size is the canvas? Don't change anything.")
        XCTAssertFalse(run.store.canUndo, run.transcript)
        let reply = run.session.chat.messages.last?.text ?? ""
        XCTAssertTrue(reply.contains("3") || reply.lowercased().contains("three"), reply)
        XCTAssertTrue(reply.contains("400"), reply)
    }
}

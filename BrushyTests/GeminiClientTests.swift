import XCTest

/// The Interactions API plumbing that never touches the network: stream
/// reassembly from captured SSE frames, and the request/response shapes.
final class GeminiClientTests: XCTestCase {
    /// Frames captured from a live `gemini-3.5-flash-lite` call on
    /// 2026-09-12 (signature shortened).
    private let textFrames: [(String, String)] = [
        ("interaction.created", #"{"interaction":{"id":"","status":"in_progress","object":"interaction","model":"gemini-3.5-flash-lite"},"event_type":"interaction.created"}"#),
        ("interaction.status_update", #"{"interaction_id":"","status":"in_progress","event_type":"interaction.status_update"}"#),
        ("step.start", #"{"index":0,"step":{"type":"thought"},"event_type":"step.start"}"#),
        ("step.delta", #"{"index":0,"delta":{"signature":"El4KXAERTTIP","type":"thought_signature"},"event_type":"step.delta"}"#),
        ("step.stop", #"{"index":0,"event_type":"step.stop"}"#),
        ("step.start", #"{"index":1,"step":{"type":"model_output"},"event_type":"step.start"}"#),
        ("step.delta", #"{"index":1,"delta":{"text":"It'","type":"text"},"event_type":"step.delta"}"#),
        ("step.delta", #"{"index":1,"delta":{"text":"s blue.","type":"text"},"event_type":"step.delta"}"#),
        ("step.stop", #"{"index":1,"event_type":"step.stop"}"#),
        ("interaction.completed", #"{"interaction":{"id":"","status":"completed","usage":{"total_tokens":119,"total_input_tokens":114,"total_cached_tokens":0,"total_output_tokens":5,"total_thought_tokens":0}},"event_type":"interaction.completed"}"#),
        ("done", "[DONE]"),
    ]

    func testAssemblesTextTurn() {
        var assembler = InteractionStreamAssembler()
        var events: [GeminiStreamEvent] = []
        for (event, data) in textFrames { events += assembler.consume(event: event, data: data) }
        let interaction = assembler.interaction
        XCTAssertEqual(interaction.status, "completed")
        XCTAssertEqual(interaction.text, "It's blue.")
        XCTAssertEqual(interaction.functionCalls, [])
        XCTAssertEqual(interaction.usage?.inputTokens, 114)
        XCTAssertEqual(interaction.usage?.outputTokens, 5)
        XCTAssertEqual(events, [.thinking, .text("It'"), .text("s blue.")])
        // The steps echo back in the non-streamed shape.
        XCTAssertEqual(interaction.steps.count, 2)
        XCTAssertEqual(interaction.steps[0], .object(["type": .string("thought"), "signature": .string("El4KXAERTTIP")]))
        XCTAssertEqual(interaction.steps[1]["type"]?.stringValue, "model_output")
        XCTAssertEqual(interaction.steps[1]["content"]?.arrayValue?.count, 1)
    }

    func testAssemblesFunctionCallWithStreamedArguments() {
        var assembler = InteractionStreamAssembler()
        var events: [GeminiStreamEvent] = []
        let frames: [(String, String)] = [
            ("step.start", #"{"index":0,"step":{"type":"thought"},"event_type":"step.start"}"#),
            ("step.delta", #"{"index":0,"delta":{"signature":"abc","type":"thought_signature"},"event_type":"step.delta"}"#),
            ("step.stop", #"{"index":0,"event_type":"step.stop"}"#),
            ("step.start", #"{"index":1,"step":{"id":"call_1","type":"function_call","name":"execute","arguments":{}},"event_type":"step.start"}"#),
            ("step.delta", #"{"index":1,"delta":{"type":"arguments_delta","arguments":"{\"code\": \"doc.layer"},"event_type":"step.delta"}"#),
            ("step.delta", #"{"index":1,"delta":{"type":"arguments","partial_arguments":"('A').move(1, 0)\", \"description\": \"Nudge\"}"},"event_type":"step.delta"}"#),
            ("step.stop", #"{"index":1,"event_type":"step.stop"}"#),
            ("interaction.completed", #"{"interaction":{"id":"v1_x","status":"requires_action"},"event_type":"interaction.completed"}"#),
        ]
        for (event, data) in frames { events += assembler.consume(event: event, data: data) }
        let interaction = assembler.interaction
        XCTAssertEqual(interaction.status, "requires_action")
        XCTAssertEqual(interaction.id, "v1_x")
        XCTAssertEqual(events, [.thinking, .functionCall("execute")])
        let calls = interaction.functionCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, "call_1")
        XCTAssertEqual(calls.first?.string("code"), "doc.layer('A').move(1, 0)")
        XCTAssertEqual(calls.first?.string("description"), "Nudge")
        // Arguments went back into the step as an object, as the non-streamed API returns them.
        XCTAssertEqual(interaction.steps[1]["arguments"]?["description"]?.stringValue, "Nudge")
    }

    func testFunctionCallWithInlineArguments() {
        var assembler = InteractionStreamAssembler()
        _ = assembler.consume(event: "step.start", data: #"{"index":0,"step":{"id":"call_2","type":"function_call","name":"look","arguments":{"document":"doc1"}},"event_type":"step.start"}"#)
        _ = assembler.consume(event: "step.stop", data: #"{"index":0,"event_type":"step.stop"}"#)
        XCTAssertEqual(assembler.interaction.functionCalls.first?.arguments["document"]?.stringValue, "doc1")
    }

    func testErrorFrame() {
        var assembler = InteractionStreamAssembler()
        _ = assembler.consume(event: "error", data: #"{"error":{"message":"Request contains an invalid argument.","code":"invalid_request"},"event_type":"error"}"#)
        XCTAssertEqual(assembler.error, "Request contains an invalid argument.")
        XCTAssertEqual(GeminiClient.error(fromBody: "event: error\ndata: {\"error\":{\"message\":\"Boom\"}}", status: 400), .api("Boom"))
        XCTAssertEqual(GeminiClient.error(fromBody: "<html>", status: 502), .http(502, "<html>"))
    }

    func testToolDeclarationShape() {
        let json = ChatTools.declarations[0].geminiJSON
        XCTAssertEqual(json["type"]?.stringValue, "function")
        XCTAssertEqual(json["name"]?.stringValue, "execute")
        XCTAssertEqual(json["parameters"]?["required"]?.arrayValue?.compactMap(\.stringValue), ["code", "description"])
    }

    func testPromptStepsShape() {
        let input = ChatPrompt.userInput(text: "hi", context: "[Context]\nnone")
        XCTAssertEqual(input["type"]?.stringValue, "user_input")
        XCTAssertEqual(input["content"]?.arrayValue?.first?["text"]?.stringValue, "[Context]\nnone\n\n[Message]\nhi")
        let result = ChatPrompt.functionResult(callID: "c1", name: "look", text: "rendered",
                                               image: ("image/png", Data([1, 2, 3])))
        XCTAssertEqual(result["type"]?.stringValue, "function_result")
        XCTAssertEqual(result["call_id"]?.stringValue, "c1")
        let parts = result["result"]?.arrayValue ?? []
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1]["mime_type"]?.stringValue, "image/png")
        XCTAssertEqual(parts[1]["data"]?.stringValue, Data([1, 2, 3]).base64EncodedString())
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object(["a": .number(1), "b": .bool(true), "c": .null,
                                        "d": .array([.string("x"), .number(2.5)])])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        let bridged = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        XCTAssertEqual(bridged, value)
        XCTAssertEqual(JSONValue(any: ["flag": true, "n": 3])["flag"], .bool(true))
        XCTAssertEqual(JSONValue(any: ["flag": true, "n": 3])["n"], .number(3))
    }

    func testAspectRatioAndSizeChoice() {
        XCTAssertEqual(ChatTools.nearestAspectRatio(1200.0 / 675), "16:9")
        XCTAssertEqual(ChatTools.nearestAspectRatio(1), "1:1")
        XCTAssertEqual(ChatTools.nearestAspectRatio(0.5), "9:16")
        XCTAssertEqual(ChatTools.imageSize(forLongestEdge: 300), "512")
        XCTAssertEqual(ChatTools.imageSize(forLongestEdge: 1000), "1K")
        XCTAssertEqual(ChatTools.imageSize(forLongestEdge: 3000), "2K")
    }
}

import Foundation

/// A function the model may call, in the provider-neutral shape the
/// Interactions API happens to use natively.
struct ToolDeclaration: Equatable {
    let name: String
    let description: String
    /// JSON Schema for the arguments object.
    let parameters: JSONValue

    var geminiJSON: JSONValue {
        .object(["type": .string("function"), "name": .string(name),
                 "description": .string(description), "parameters": parameters])
    }
}

struct FunctionCall: Equatable {
    let id: String
    let name: String
    let arguments: [String: JSONValue]

    func string(_ key: String) -> String? { arguments[key]?.stringValue }
    func double(_ key: String) -> Double? { arguments[key]?.doubleValue }
}

/// Token counts for a call — see `AIPricing` for how they bill.
struct InteractionUsage: Equatable, Codable {
    var inputTokens = 0
    /// Excludes thinking; includes `imageOutputTokens`.
    var outputTokens = 0
    var thoughtTokens = 0
    var cachedTokens = 0
    var imageOutputTokens = 0

    init(inputTokens: Int = 0, outputTokens: Int = 0, thoughtTokens: Int = 0, cachedTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cachedTokens = cachedTokens
    }

    init(json: JSONValue) {
        inputTokens = json["total_input_tokens"]?.intValue ?? 0
        outputTokens = json["total_output_tokens"]?.intValue ?? 0
        thoughtTokens = json["total_thought_tokens"]?.intValue ?? 0
        cachedTokens = json["total_cached_tokens"]?.intValue ?? 0
        imageOutputTokens = (json["output_tokens_by_modality"]?.arrayValue ?? [])
            .filter { $0["modality"]?.stringValue == "image" }
            .compactMap { $0["tokens"]?.intValue }
            .reduce(0, +)
    }

    /// Chats saved before a field existed decode it as 0.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        thoughtTokens = try container.decodeIfPresent(Int.self, forKey: .thoughtTokens) ?? 0
        cachedTokens = try container.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0
        imageOutputTokens = try container.decodeIfPresent(Int.self, forKey: .imageOutputTokens) ?? 0
    }

    mutating func add(_ other: InteractionUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        thoughtTokens += other.thoughtTokens
        cachedTokens += other.cachedTokens
        imageOutputTokens += other.imageOutputTokens
    }
}

/// One model turn: the steps to echo back verbatim (thought signatures
/// included — stateless mode requires it), plus the parts a caller acts on.
struct Interaction: Equatable {
    var id: String?
    var status: String
    var steps: [JSONValue]
    var usage: InteractionUsage?

    /// Concatenated `model_output` text.
    var text: String {
        steps.compactMap { step -> String? in
            guard step["type"]?.stringValue == "model_output",
                  let content = step["content"]?.arrayValue else { return nil }
            let texts = content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
            return texts.isEmpty ? nil : texts.joined()
        }.joined()
    }

    var functionCalls: [FunctionCall] {
        steps.compactMap { step in
            guard step["type"]?.stringValue == "function_call", let name = step["name"]?.stringValue else { return nil }
            return FunctionCall(id: step["id"]?.stringValue ?? "", name: name,
                                arguments: step["arguments"]?.objectValue ?? [:])
        }
    }
}

enum GeminiStreamEvent: Equatable {
    case thinking
    case text(String)
    case functionCall(String)
}

enum GeminiError: LocalizedError, Equatable {
    case missingKey
    case http(Int, String)
    case api(String)
    case malformed(String)
    case noImage

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No Gemini API key. Add one in Settings → AI."
        case .http(let code, let body): return "Gemini returned HTTP \(code): \(body)"
        case .api(let message): return message
        case .malformed(let what): return "Unexpected response from Gemini: \(what)"
        case .noImage: return "Gemini returned no image."
        }
    }
}

/// Google's Gemini "Interactions" REST API (`/v1beta/interactions`), used
/// stateless (`store: false`): the full history rides in every request and
/// the model's steps come back to be resent verbatim. Verified against the
/// live API in September 2026 — see the memory note if the shape drifts.
final class GeminiClient {
    let apiKey: String
    let session: URLSession
    let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private func request(body: JSONValue) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body.any)
        request.timeoutInterval = 300
        return request
    }

    /// One turn. `input` is the whole stateless history. Streams text as it
    /// arrives through `onEvent`; the returned steps are assembled from the
    /// same stream so what is echoed back equals what a non-streamed call
    /// would have returned.
    func interact(model: String, systemInstruction: String, tools: [ToolDeclaration],
                  input: [JSONValue], thinkingLevel: String?,
                  onEvent: ((GeminiStreamEvent) -> Void)? = nil) async throws -> Interaction {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "store": .bool(false),
            "stream": .bool(true),
            "system_instruction": .string(systemInstruction),
            "input": .array(input),
        ]
        if !tools.isEmpty { body["tools"] = .array(tools.map(\.geminiJSON)) }
        if let thinkingLevel { body["generation_config"] = .object(["thinking_level": .string(thinkingLevel)]) }
        let (bytes, response) = try await session.bytes(for: try request(body: .object(body)))
        guard let http = response as? HTTPURLResponse else { throw GeminiError.malformed("no HTTP response") }
        if http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line + "\n" }
            throw Self.error(fromBody: text, status: http.statusCode)
        }
        var assembler = InteractionStreamAssembler()
        var event = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let data = String(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                for streamEvent in assembler.consume(event: event, data: data) { onEvent?(streamEvent) }
                if let error = assembler.error { throw GeminiError.api(error) }
            }
            try Task.checkCancellation()
        }
        if let error = assembler.error { throw GeminiError.api(error) }
        return assembler.interaction
    }

    /// Text (and optional reference images) → one image, with the call's
    /// usage for pricing. `aspectRatio` like "16:9"; `imageSize` one of
    /// "512", "1K", "2K", "4K". Output is JPEG — the only format the API
    /// produces.
    func generateImage(model: String, prompt: String, references: [Data] = [],
                       aspectRatio: String, imageSize: String) async throws -> (data: Data, usage: InteractionUsage?) {
        var parts: [JSONValue] = [.object(["type": .string("text"), "text": .string(prompt)])]
        for reference in references {
            parts.append(.object(["type": .string("image"), "mime_type": .string("image/jpeg"),
                                  "data": .string(reference.base64EncodedString())]))
        }
        let body: JSONValue = .object([
            "model": .string(model),
            "input": .array(parts),
            "response_format": .object(["type": .string("image"), "aspect_ratio": .string(aspectRatio),
                                        "image_size": .string(imageSize)]),
        ])
        let (data, response) = try await session.data(for: try request(body: body))
        guard let http = response as? HTTPURLResponse else { throw GeminiError.malformed("no HTTP response") }
        if http.statusCode != 200 {
            throw Self.error(fromBody: String(data: data, encoding: .utf8) ?? "", status: http.statusCode)
        }
        let json = try JSONValue.parse(data)
        for step in json["steps"]?.arrayValue ?? [] where step["type"]?.stringValue == "model_output" {
            for part in step["content"]?.arrayValue ?? [] where part["type"]?.stringValue == "image" {
                if let base64 = part["data"]?.stringValue, let bytes = Data(base64Encoded: base64) {
                    return (bytes, json["usage"].map(InteractionUsage.init(json:)))
                }
            }
        }
        throw GeminiError.noImage
    }

    static func error(fromBody body: String, status: Int) -> GeminiError {
        // Errors arrive as JSON, or as an SSE `event: error` frame.
        let jsonText = body.split(separator: "\n").first { $0.hasPrefix("data:") }
            .map { String($0.dropFirst(5)) } ?? body
        if let data = jsonText.data(using: .utf8), let json = try? JSONValue.parse(data),
           let message = json["error"]?["message"]?.stringValue {
            return .api(message)
        }
        return .http(status, String(body.prefix(300)))
    }
}

/// Rebuilds the model's steps from the SSE frames (`step.start`,
/// `step.delta`, `step.stop`, `interaction.completed`) so the stateless
/// history can carry them verbatim. Pure; unit-tested against captured
/// frames.
struct InteractionStreamAssembler {
    private var steps: [Int: [String: JSONValue]] = [:]
    private var partialArguments: [Int: String] = [:]
    private(set) var id: String?
    private(set) var status = "in_progress"
    private(set) var usage: InteractionUsage?
    private(set) var error: String?

    var interaction: Interaction {
        Interaction(id: id, status: status,
                    steps: steps.keys.sorted().map { .object(steps[$0]!) }, usage: usage)
    }

    /// Feeds one frame; returns the user-visible events it implied.
    mutating func consume(event: String, data: String) -> [GeminiStreamEvent] {
        guard data != "[DONE]", let bytes = data.data(using: .utf8),
              let json = try? JSONValue.parse(bytes) else { return [] }
        let type = json["event_type"]?.stringValue ?? event
        switch type {
        case "interaction.created":
            id = json["interaction"]?["id"]?.stringValue
            return []
        case "step.start":
            guard let index = json["index"]?.intValue, var step = json["step"]?.objectValue else { return [] }
            if let arguments = step["arguments"]?.stringValue {
                // Arguments may stream as a JSON string; parse at stop.
                partialArguments[index] = arguments
                step["arguments"] = nil
            }
            steps[index] = step
            switch step["type"]?.stringValue {
            case "thought": return [.thinking]
            case "function_call": return step["name"]?.stringValue.map { [.functionCall($0)] } ?? []
            case "model_output":
                let text = Interaction(id: nil, status: "", steps: [.object(step)], usage: nil).text
                return text.isEmpty ? [] : [.text(text)]
            default: return []
            }
        case "step.delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"] else { return [] }
            var step = steps[index] ?? [:]
            switch delta["type"]?.stringValue {
            case "text":
                let text = delta["text"]?.stringValue ?? ""
                var content = step["content"]?.arrayValue ?? []
                if let last = content.last, last["type"]?.stringValue == "text",
                   let existing = last["text"]?.stringValue {
                    content[content.count - 1] = .object(["type": .string("text"), "text": .string(existing + text)])
                } else {
                    content.append(.object(["type": .string("text"), "text": .string(text)]))
                }
                step["content"] = .array(content)
                steps[index] = step
                return text.isEmpty ? [] : [.text(text)]
            case "thought_signature":
                let signature = (step["signature"]?.stringValue ?? "") + (delta["signature"]?.stringValue ?? "")
                step["signature"] = .string(signature)
                steps[index] = step
                return []
            case "arguments", "arguments_delta":
                // Live frames (Sept 2026): `{"type":"arguments_delta","arguments":"{…json…}"}`
                // on top of a `step.start` whose `arguments` is `{}`; the
                // documented shape names the field `partial_arguments`.
                let chunk = delta["arguments"]?.stringValue ?? delta["partial_arguments"]?.stringValue ?? ""
                partialArguments[index, default: ""] += chunk
                return []
            default:
                // Unknown delta kinds (thought summaries, tool results): keep
                // any signature they carry, ignore the rest.
                if let signature = delta["signature"]?.stringValue {
                    step["signature"] = .string((step["signature"]?.stringValue ?? "") + signature)
                    steps[index] = step
                }
                return []
            }
        case "step.stop":
            guard let index = json["index"]?.intValue else { return [] }
            if let raw = partialArguments.removeValue(forKey: index), var step = steps[index] {
                if let data = raw.data(using: .utf8), let parsed = try? JSONValue.parse(data) {
                    step["arguments"] = parsed
                } else {
                    step["arguments"] = .object([:])
                }
                steps[index] = step
            }
            return []
        case "interaction.completed":
            if let interaction = json["interaction"] {
                id = interaction["id"]?.stringValue ?? id
                status = interaction["status"]?.stringValue ?? "completed"
                if let usageJSON = interaction["usage"] { usage = InteractionUsage(json: usageJSON) }
            } else {
                status = "completed"
            }
            return []
        case "error":
            error = json["error"]?["message"]?.stringValue ?? "Unknown error"
            return []
        default:
            return []
        }
    }
}

import Foundation

/// A conversation with the assistant. App-level, not part of any document:
/// chats can reach every open document, and a `.brushy` file never carries
/// conversation history. Persisted as JSON by `ChatStore`.
struct Chat: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New Chat"
    var createdAt = Date()
    var updatedAt = Date()
    /// What the sidebar shows.
    var messages: [ChatMessage] = []
    /// The provider's stateless history, verbatim (user inputs, model steps
    /// with their thought signatures, function results). Never edited.
    var history: [JSONValue] = []
    var provider = "gemini"
    var usage = InteractionUsage()

    var isEmpty: Bool { messages.isEmpty }
}

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user, assistant, tool, error
    }

    var id = UUID()
    var role: Role
    var text = ""
    var tool: ToolCallRecord?
    var createdAt = Date()
    /// True while the model is still producing this message.
    var isStreaming = false
}

/// A tool call as the sidebar shows it: what was asked, what happened.
struct ToolCallRecord: Codable, Equatable {
    enum Status: String, Codable {
        case running, succeeded, failed
    }

    var name: String
    /// The model's one-line description of an `execute` call — doubles as
    /// the history entry's name.
    var description: String
    /// The script, for `execute`.
    var code: String?
    /// Other arguments, pretty-printed, for `look` and `generate_image`.
    var arguments: String?
    var status: Status = .running
    /// What the model was told back (text part).
    var result = ""
    /// A `look` result or generated image, PNG/JPEG bytes, for the sidebar.
    var imageData: Data?
    var duration: TimeInterval = 0
}

import SwiftUI

/// Settings → AI: the Gemini key (Keychain, not a preference — and so not
/// touched by the pane's Reset), the chat model and thinking level, and the
/// image model behind `generate_image`. All LIVE: `ChatStore.makeProvider`
/// reads them per turn.
struct AISettingsPane: View {
    static let chatModels = ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash",
                             "gemini-3.5-flash-lite", "gemini-3.1-pro-preview"]
    static let imageModels = ["gemini-3.1-flash-image", "gemini-3.1-flash-lite-image",
                              "gemini-3-pro-image", "gemini-2.5-flash-image"]
    static let thinkingLevels = ["default", "minimal", "low", "medium", "high"]

    private struct Values: Equatable {
        var chatModel = Defaults.value(Defaults.Keys.chatModel)
        var thinkingLevel = Defaults.value(Defaults.Keys.chatThinkingLevel)
        var imageModel = Defaults.value(Defaults.Keys.imageModel)
    }

    @State private var values = Values()
    @State private var isLoading = false
    @State private var apiKey = Keychain.string(account: APIKeys.geminiAccount) ?? ""

    private var keyFromEnvironment: Bool {
        !APIKeys.geminiIsStoredInKeychain && APIKeys.gemini != nil
    }

    var body: some View {
        SettingsPane(domain: .chat, reload: {
            isLoading = true
            values = Values()
            isLoading = false
        }) {
            Section("Gemini") {
                LabeledContent("API key") {
                    SecureField("", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .onChange(of: apiKey) { _, new in
                            APIKeys.gemini = new.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                }
                if keyFromEnvironment {
                    Text("Using the GEMINI_API_KEY environment variable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Stored in your login keychain. Get a key at aistudio.google.com/apikey.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Chat") {
                Picker("Model", selection: $values.chatModel) {
                    ForEach(Self.options(Self.chatModels, including: values.chatModel), id: \.self) { Text($0).tag($0) }
                }
                Picker("Thinking", selection: $values.thinkingLevel) {
                    ForEach(Self.options(Self.thinkingLevels, including: values.thinkingLevel), id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
                Text("Flash models handle the scripting well; higher thinking levels help with layout puzzles and cost more. A typical request is a few thousand tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Images") {
                Picker("Image model", selection: $values.imageModel) {
                    ForEach(Self.options(Self.imageModels, including: values.imageModel), id: \.self) { Text($0).tag($0) }
                }
                Text("Used by the generate_image tool. Each generation costs noticeably more than a chat turn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: values) { _, new in save(new) }
    }

    /// The picker must contain its selection, so a value typed into the
    /// defaults by hand (a preview model, say) still shows.
    private static func options(_ known: [String], including current: String) -> [String] {
        known.contains(current) ? known : [current] + known
    }

    private func save(_ new: Values) {
        guard !isLoading else { return }
        Defaults.set(new.chatModel, for: Defaults.Keys.chatModel)
        Defaults.set(new.thinkingLevel, for: Defaults.Keys.chatThinkingLevel)
        Defaults.set(new.imageModel, for: Defaults.Keys.imageModel)
    }
}

import Foundation

/// What a Gemini call costs at list prices, so the chat can show a running
/// total. Paid-tier standard rates per 1M tokens from
/// ai.google.dev/gemini-api/docs/pricing, read 2026-09-13; an unlisted model
/// has no price and its calls show no cost rather than a wrong one.
///
/// How the Interactions API's `usage` maps onto the bill (measured on live
/// calls, 2026-09-13):
/// - `total_output_tokens` does NOT include thinking; `total_thought_tokens`
///   is separate and billed at the output rate.
/// - An image model's `total_output_tokens` includes its image tokens, which
///   `output_tokens_by_modality` breaks out and which bill at the image
///   rate (1,120 tokens for a 1K image — $0.0336 on flash-lite-image, the
///   listed per-image price).
/// - Cached tokens are assumed to be a subset of `total_input_tokens`, as
///   in the older generateContent API (not observed: stateless chats don't
///   cache).
enum AIPricing {
    struct Rates: Equatable {
        var input: Double
        var output: Double
        /// Nil when caching isn't listed; cached tokens then bill as input.
        var cachedInput: Double?
        /// Nil for text-only models.
        var imageOutput: Double?
    }

    /// The Flash 3.6–3.8 introductory prices end with 2026.
    private static let flashPriceChange: Date = {
        var components = DateComponents()
        components.year = 2027
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    static func rates(for model: String, inputTokens: Int = 0, on date: Date = Date()) -> Rates? {
        switch model {
        case "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash":
            return date < flashPriceChange
                ? Rates(input: 0.75, output: 3.75, cachedInput: 0.075)
                : Rates(input: 1.50, output: 7.50, cachedInput: 0.15)
        case "gemini-3.5-flash-lite":
            return Rates(input: 0.30, output: 2.50)
        case "gemini-3.1-pro-preview":
            return inputTokens > 200_000
                ? Rates(input: 4.00, output: 18.00, cachedInput: 0.40)
                : Rates(input: 2.00, output: 12.00, cachedInput: 0.20)
        case "gemini-3.1-flash-image":
            return Rates(input: 0.50, output: 3.00, imageOutput: 60.00)
        case "gemini-3.1-flash-lite-image":
            return Rates(input: 0.25, output: 1.50, imageOutput: 30.00)
        case "gemini-3-pro-image":
            return Rates(input: 2.00, output: 12.00, imageOutput: 120.00)
        case "gemini-2.5-flash-image":
            // Listed only as $0.039 per image: 1,290 tokens at $30/M.
            return Rates(input: 0.30, output: 2.50, imageOutput: 30.00)
        default:
            return nil
        }
    }

    /// US dollars for one call, or nil when the model has no known price.
    static func cost(model: String, usage: InteractionUsage, on date: Date = Date()) -> Double? {
        guard let rates = rates(for: model, inputTokens: usage.inputTokens, on: date) else { return nil }
        let input = max(usage.inputTokens, 0)
        let cached = min(max(usage.cachedTokens, 0), input)
        let output = max(usage.outputTokens, 0)
        let image = min(max(usage.imageOutputTokens, 0), output)
        let textOutput = output - image + max(usage.thoughtTokens, 0)
        let dollars = Double(input - cached) * rates.input
            + Double(cached) * (rates.cachedInput ?? rates.input)
            + Double(textOutput) * rates.output
            + Double(image) * (rates.imageOutput ?? rates.output)
        return dollars / 1_000_000
    }

    /// The badge text: cents precision, with sub-cent totals shown as such
    /// rather than as a misleading "$0.00".
    static func format(_ dollars: Double) -> String {
        if dollars <= 0 { return "$0" }
        if dollars < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", dollars)
    }
}

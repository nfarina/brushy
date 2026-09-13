import Foundation
import XCTest

final class AIPricingTests: XCTestCase {
    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    /// Thinking bills at the output rate on top of `total_output_tokens`.
    /// Numbers from a live gemini-3.8-flash call (thinking "high").
    func testThoughtTokensBillAsOutput() throws {
        let usage = InteractionUsage(inputTokens: 16, outputTokens: 0, thoughtTokens: 731)
        let cost = try XCTUnwrap(AIPricing.cost(model: "gemini-3.8-flash", usage: usage,
                                                on: date("2026-09-13T12:00:00Z")))
        XCTAssertEqual(cost, (16 * 0.75 + 731 * 3.75) / 1_000_000, accuracy: 1e-12)
    }

    /// A live 1K flash-lite-image call: 1,496 output tokens of which 1,120
    /// are the image. The image part must land on the listed $0.0336.
    func testImageTokensBillAtTheImageRate() throws {
        var usage = InteractionUsage(inputTokens: 16, outputTokens: 1496)
        usage.imageOutputTokens = 1120
        let cost = try XCTUnwrap(AIPricing.cost(model: "gemini-3.1-flash-lite-image", usage: usage))
        let expected = (16 * 0.25 + 376 * 1.50 + 1120 * 30.0) / 1_000_000
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
        XCTAssertEqual(1120 * 30.0 / 1_000_000, 0.0336, accuracy: 1e-9)
    }

    func testCachedTokensBillAtTheCacheRate() throws {
        let usage = InteractionUsage(inputTokens: 10_000, outputTokens: 0, cachedTokens: 8_000)
        let cost = try XCTUnwrap(AIPricing.cost(model: "gemini-3.8-flash", usage: usage,
                                                on: date("2026-09-13T12:00:00Z")))
        XCTAssertEqual(cost, (2_000 * 0.75 + 8_000 * 0.075) / 1_000_000, accuracy: 1e-12)
    }

    func testFlashPricesDoubleIn2027() {
        XCTAssertEqual(AIPricing.rates(for: "gemini-3.8-flash", on: date("2026-12-31T12:00:00Z"))?.input, 0.75)
        XCTAssertEqual(AIPricing.rates(for: "gemini-3.8-flash", on: date("2027-01-01T12:00:00Z"))?.input, 1.50)
    }

    func testProTiersOnPromptSize() {
        XCTAssertEqual(AIPricing.rates(for: "gemini-3.1-pro-preview", inputTokens: 200_000)?.output, 12)
        XCTAssertEqual(AIPricing.rates(for: "gemini-3.1-pro-preview", inputTokens: 200_001)?.output, 18)
    }

    func testUnknownModelsHaveNoPrice() {
        XCTAssertNil(AIPricing.cost(model: "gemini-9-ultra", usage: InteractionUsage(inputTokens: 1)))
    }

    func testFormat() {
        XCTAssertEqual(AIPricing.format(0), "$0")
        XCTAssertEqual(AIPricing.format(0.004), "<$0.01")
        XCTAssertEqual(AIPricing.format(0.0351), "$0.04")
        XCTAssertEqual(AIPricing.format(12.3), "$12.30")
    }

    /// Chats saved before image tokens were tracked must still load.
    func testUsageDecodesWithoutImageTokens() throws {
        let json = #"{"inputTokens":5,"outputTokens":6,"thoughtTokens":7,"cachedTokens":0}"#
        let usage = try JSONDecoder().decode(InteractionUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.outputTokens, 6)
        XCTAssertEqual(usage.imageOutputTokens, 0)
    }

    func testUsageParsesImageTokensFromTheAPI() throws {
        let json = #"{"total_input_tokens":16,"total_output_tokens":1496,"output_tokens_by_modality":[{"modality":"image","tokens":1120}]}"#
        let usage = InteractionUsage(json: try JSONValue.parse(Data(json.utf8)))
        XCTAssertEqual(usage.outputTokens, 1496)
        XCTAssertEqual(usage.imageOutputTokens, 1120)
    }
}

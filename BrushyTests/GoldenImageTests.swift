import CoreGraphics
import Foundation
import XCTest

/// The golden-image harness: loads each fixture's JSON description, applies
/// the operations through the app's own document model and render pipeline, and
/// pixel-diffs the result against the reference. Failures write a visual diff
/// (deviating pixels in red) plus the actual render into test-output/.
final class GoldenImageTests: XCTestCase {
    func testGoldenFixtures() throws {
        if TestPaths.isRecording {
            try FixtureLibrary.recordAll()
        }
        let specURLs = (try FileManager.default.contentsOfDirectory(
            at: TestPaths.fixturesDir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(specURLs.isEmpty,
                       "No fixtures found — record them first with TEST_RUNNER_RECORD_FIXTURES=1")

        for url in specURLs {
            let spec = try JSONDecoder().decode(FixtureSpec.self, from: Data(contentsOf: url))
            XCTContext.runActivity(named: spec.name) { _ in
                do {
                    try runFixture(spec)
                } catch {
                    XCTFail("\(spec.name): \(error)")
                }
            }
        }
    }

    private func runFixture(_ spec: FixtureSpec) throws {
        let document = try spec.buildDocument(fixturesDir: TestPaths.fixturesDir)
        guard let rendered = RenderEngine.shared.renderFlattened(
            document: document, profile: spec.outputColorSpace, sixteenBit: false) else {
            XCTFail("\(spec.name): render failed")
            return
        }
        let referenceImage = try loadPNG(TestPaths.fixturesDir.appendingPathComponent(spec.reference))
        XCTAssertEqual(rendered.colorSpace?.name, referenceImage.colorSpace?.name,
                       "\(spec.name): colour space mismatch against reference")
        let actual = try rawRGBA8(rendered)
        let reference = try rawRGBA8(referenceImage)
        guard actual.width == reference.width, actual.height == reference.height else {
            XCTFail("\(spec.name): size mismatch \(actual.width)×\(actual.height) vs \(reference.width)×\(reference.height)")
            return
        }
        let (stats, deviations) = comparePixels(actual: actual, reference: reference,
                                                colorTolerance: spec.colorTolerance ?? 2,
                                                alphaTolerance: spec.alphaTolerance ?? 0)
        if stats.deviatingPixels > 0 {
            try? FileManager.default.createDirectory(at: TestPaths.outputDir,
                                                     withIntermediateDirectories: true)
            try? writePNG(rendered, to: TestPaths.outputDir.appendingPathComponent("\(spec.name)-actual.png"))
            try? writeDiffImage(reference: reference, deviations: deviations,
                                to: TestPaths.outputDir.appendingPathComponent("\(spec.name)-diff.png"))
            XCTFail("\(spec.name): \(stats.summary) — see test-output/\(spec.name)-diff.png")
        }
    }
}

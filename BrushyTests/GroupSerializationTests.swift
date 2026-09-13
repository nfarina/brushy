import CoreGraphics
import Foundation
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// Layer groups in the.brushy format: full round-trip through real
/// bytes, byte-shape compatibility for group-free documents, and load-time
/// repair of hand-edited files (the guides/blendMode precedent).
final class GroupSerializationTests: XCTestCase {
    private let p3 = BrushyColorSpace.displayP3

    private func layer(_ name: String, groupID: UUID? = nil) -> Layer {
        Layer(name: name,
              source: GeneratedImages.solid(width: 8, height: 8, r: 40, g: 80, b: 160,
                                            colorSpace: p3),
              groupID: groupID)
    }

    private func roundTrip(_ document: Document) throws -> Document {
        let wrapper = try DocumentSerializer().fileWrapper(for: document)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("groups-\(UUID().uuidString).brushy")
        try wrapper.write(to: temp, options: .atomic, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let readWrapper = try FileWrapper(url: temp)
        return try DocumentSerializer().document(from: readWrapper)
    }

    func testGroupsRoundTripThroughCompdoc() throws {
        var document = Document(canvasSize: CGSize(width: 64, height: 64))
        var outer = LayerGroup(name: "Outer")
        outer.opacity = 0.7
        outer.blendMode = .multiply
        outer.isExpanded = false
        var inner = LayerGroup(name: "Inner", parentID: outer.id)
        inner.isVisible = false
        document.groups = [outer, inner]
        document.layers = [layer("below"),
                           layer("a", groupID: outer.id),
                           layer("b", groupID: inner.id),
                           layer("top")]

        let restored = try roundTrip(document)
        XCTAssertEqual(restored.groups.count, 2)
        let restoredOuter = try XCTUnwrap(restored.group(withID: outer.id))
        XCTAssertEqual(restoredOuter.name, "Outer")
        XCTAssertEqual(restoredOuter.opacity, 0.7)
        XCTAssertEqual(restoredOuter.blendMode, .multiply)
        XCTAssertFalse(restoredOuter.isExpanded)
        XCTAssertNil(restoredOuter.parentID)
        let restoredInner = try XCTUnwrap(restored.group(withID: inner.id))
        XCTAssertNil(restoredInner.blendMode, "Pass Through round-trips as absent")
        XCTAssertFalse(restoredInner.isVisible)
        XCTAssertEqual(restoredInner.parentID, outer.id)
        XCTAssertEqual(restored.layers.map(\.groupID),
                       [nil, outer.id, inner.id, nil])
        XCTAssertEqual(restored.normalizingGroups(), restored,
                       "a well-formed file loads already-normalized")
    }

    /// A document that uses no groups must serialize byte-identically to what
    /// a pre-group build writes: no "groups" key, no "groupID" keys.
    func testGroupFreeDocumentOmitsGroupKeys() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        document.layers = [layer("only")]
        let wrapper = try DocumentSerializer().fileWrapper(for: document)
        let json = try XCTUnwrap(wrapper.fileWrappers?["document.json"]?.regularFileContents)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(text.contains("\"groups\""))
        XCTAssertFalse(text.contains("\"groupID\""))
    }

    /// Hand-edited or future-build files: a groupID naming no group is
    /// dropped, and an interleaved membership is truncated to keep runs
    /// contiguous — the model invariants hold whatever the bytes said.
    func testLoadRepairsDanglingAndInterleavedMembership() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        let g = LayerGroup(name: "G")
        document.groups = [g]
        document.layers = [layer("a", groupID: g.id),
                           layer("gap"),
                           layer("b", groupID: g.id)]

        // Write, then corrupt the JSON the way a hand edit would: point one
        // layer at a nonexistent group. (The interleave above is already
        // invalid as written — the writer serializes the model verbatim.)
        let wrapper = try DocumentSerializer().fileWrapper(for: document)
        var dto = try JSONDecoder().decode(
            DocumentDTO.self,
            from: XCTUnwrap(wrapper.fileWrappers?["document.json"]?.regularFileContents))
        dto.layers[2].groupID = UUID() // dangling
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var files = wrapper.fileWrappers ?? [:]
        files["document.json"].map { wrapper.removeFileWrapper($0) }
        let corrupted = FileWrapper(regularFileWithContents: try encoder.encode(dto))
        corrupted.preferredFilename = "document.json"
        wrapper.addFileWrapper(corrupted)
        _ = files

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("groups-repair-\(UUID().uuidString).brushy")
        try wrapper.write(to: temp, options: .atomic, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let restored = try DocumentSerializer().document(from: FileWrapper(url: temp))

        XCTAssertNil(restored.layers[2].groupID, "a dangling membership drops on load")
        XCTAssertEqual(restored.layers[0].groupID, g.id)
        XCTAssertEqual(restored.normalizingGroups(), restored)
        if let run = restored.memberRun(ofGroup: g.id) {
            XCTAssertEqual(run, 0...0, "the run stays contiguous after repair")
        }
    }
}

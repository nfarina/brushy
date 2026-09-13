import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// One pass over the whole product surface: place a real file, edit through
/// store operations, save the .brushy, reopen it, and verify the reopened
/// document renders identically; then exercise every export format.
final class EndToEndTests: XCTestCase {
    func testImportEditSaveReopenExport() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brushy-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A real image file on disk, sRGB-tagged.
        let imageURL = dir.appendingPathComponent("photo.png")
        try writePNG(GeneratedImages.gradientChecker(width: 300, height: 200, square: 20,
                                                     colorSpace: BrushyColorSpace.sRGB),
                     to: imageURL)

        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 1920, height: 1080)))
        store.placeImages(from: [imageURL])
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 300, height: 200))

        // Move the layer a little, as the move tool would.
        let layerID = store.document.layers[0].id
        store.setLiveLayerTransform(layerID,
                                    store.document.layers[0].transform
                                        .concatenating(CGAffineTransform(translationX: 14, y: -9)))
        store.commitMove()

        // Crop the document.
        store.activeTool = .crop
        var crop = store.cropSession!
        crop.rect = CGRect(x: 20, y: 10, width: 240, height: 160)
        store.updateCropSession(crop)
        store.commitCropSession()
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 240, height: 160))

        // Feathered selection mask.
        store.activeTool = .marquee
        store.combineSelection(CGPath(rect: CGRect(x: 40, y: 30, width: 120, height: 90),
                                      transform: nil), mode: .replace)
        store.featherAmount = 12
        store.addLayerMask()
        XCTAssertNotNil(store.document.layers[0].mask)

        // Duplicate, drop opacity, merge back down (the one destructive op).
        store.selectLayer(layerID)
        store.duplicateSelectedLayer()
        let copyID = store.selectedLayerID!
        store.setLiveOpacity(copyID, 0.6)
        store.endOpacityEdit()
        store.mergeDownSelectedLayer()
        XCTAssertEqual(store.document.layers.count, 1)

        // Save the package, then reopen it with a fresh serializer.
        let docURL = dir.appendingPathComponent("edit.brushy")
        let wrapper = try DocumentSerializer().fileWrapper(for: store.document)
        try wrapper.write(to: docURL, options: .atomic, originalContentsURL: nil)
        let reopened = try DocumentSerializer().document(from: FileWrapper(url: docURL))

        // The reopened document must render the same picture.
        let renderedA = try rawRGBA8(RenderEngine.shared.renderFlattened(
            document: store.document, profile: BrushyColorSpace.sRGB, sixteenBit: false)!)
        let renderedB = try rawRGBA8(RenderEngine.shared.renderFlattened(
            document: reopened, profile: BrushyColorSpace.sRGB, sixteenBit: false)!)
        let (stats, _) = comparePixels(actual: renderedB, reference: renderedA,
                                       colorTolerance: 2, alphaTolerance: 1)
        XCTAssertEqual(stats.deviatingPixels, 0,
                       "reopened document renders differently: \(stats.summary)")

        // Every export format produces a decodable file with the right
        // dimensions, depth and embedded profile.
        for (settings, name) in [
            (ExportSettings(format: .png, sixteenBit: true, jpegQuality: 0.9, profile: .displayP3), "out16.png"),
            (ExportSettings(format: .jpeg, sixteenBit: false, jpegQuality: 0.85, profile: .sRGB), "out.jpg"),
            (ExportSettings(format: .tiff, sixteenBit: false, jpegQuality: 0.9, profile: .sRGB), "out.tiff"),
        ] {
            let url = dir.appendingPathComponent(name)
            try Exporter.export(document: store.document, settings: settings, to: url)
            let decoded = try loadPNG(url) // CGImageSource decodes all three formats
            XCTAssertEqual(decoded.width, 240, "\(name) width")
            XCTAssertEqual(decoded.height, 160, "\(name) height")
            if settings.format == .png && settings.sixteenBit {
                XCTAssertEqual(decoded.bitsPerComponent, 16, "16-bit PNG depth")
                XCTAssertEqual(decoded.colorSpace?.name, BrushyColorSpace.displayP3.name,
                               "P3 profile must be embedded")
            }
            if settings.format == .jpeg {
                let opaque: [CGImageAlphaInfo] = [.none, .noneSkipLast, .noneSkipFirst]
                XCTAssertTrue(opaque.contains(decoded.alphaInfo), "JPEG must be flattened opaque")
                XCTAssertEqual(decoded.colorSpace?.name, BrushyColorSpace.sRGB.name)
            }
        }
    }

    /// (Open as Layer / Place): placing into a document that already
    /// has layers must append — never replace — and must not re-adopt the
    /// canvas size from the incoming image.
    func testPlaceIntoDocumentWithLayersAppends() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brushy-place-append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstURL = dir.appendingPathComponent("first.png")
        try writePNG(GeneratedImages.gradientChecker(width: 300, height: 200, square: 20,
                                                     colorSpace: BrushyColorSpace.sRGB),
                     to: firstURL)
        let secondURL = dir.appendingPathComponent("second.png")
        try writePNG(GeneratedImages.gradientChecker(width: 64, height: 48, square: 8,
                                                     colorSpace: BrushyColorSpace.sRGB),
                     to: secondURL)

        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 1920, height: 1080)))
        // First place into an empty document adopts the canvas
        // (open-as-document semantics).
        store.placeImages(from: [firstURL])
        XCTAssertEqual(store.document.layers.count, 1)
        let firstID = store.document.layers[0].id
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 300, height: 200))

        // Second place must append to the existing content.
        store.placeImages(from: [secondURL])
        XCTAssertEqual(store.document.layers.count, 2, "Place must append, not replace")
        XCTAssertEqual(store.document.layers[0].id, firstID,
                       "the existing layer must survive a Place")
        XCTAssertEqual(store.document.canvasSize, CGSize(width: 300, height: 200),
                       "Place into a non-empty document must not resize the canvas")
        XCTAssertEqual(store.selectedLayerID, store.document.layers[1].id,
                       "the placed layer should be selected")

        // Landing any session armed on arrival must leave the append intact.
        store.commitPendingSessions()
        XCTAssertEqual(store.document.layers.count, 2)
        XCTAssertEqual(store.document.layers[0].id, firstID)
    }
}

import CoreGraphics
import Foundation
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// Layer effects crossing file boundaries: the `.brushy` format and
/// Adobe's `lfx2` descriptor in both directions.
final class LayerEffectsInteropTests: XCTestCase {
    private let p3 = BrushyColorSpace.displayP3

    /// A style with every modelled effect on, at values distinct from the
    /// defaults, so a field the codec forgets can't pass by coincidence.
    private func fullyLoadedEffects() -> LayerEffects {
        var effects = LayerEffects()
        effects.globalLightAngle = 42

        var shadow = DropShadowEffect()
        shadow.blendMode = .colorBurn
        shadow.color = EffectColor(red: 0.2, green: 0.4, blue: 0.6)
        shadow.opacity = 0.61
        shadow.usesGlobalLight = false
        shadow.angle = -33
        shadow.distance = 17
        shadow.spread = 0.25
        shadow.size = 29
        shadow.knocksOut = false
        effects.dropShadow = shadow

        var innerShadow = InnerShadowEffect()
        innerShadow.blendMode = .overlay
        innerShadow.opacity = 0.4
        innerShadow.distance = 9
        innerShadow.choke = 0.3
        innerShadow.size = 12
        effects.innerShadow = innerShadow

        var outerGlow = OuterGlowEffect()
        outerGlow.blendMode = .lighten
        outerGlow.color = EffectColor(red: 1, green: 0.5, blue: 0)
        outerGlow.opacity = 0.9
        outerGlow.spread = 0.15
        outerGlow.size = 21
        effects.outerGlow = outerGlow

        var innerGlow = InnerGlowEffect()
        innerGlow.blendMode = .softLight
        innerGlow.opacity = 0.33
        innerGlow.choke = 0.5
        innerGlow.size = 7
        effects.innerGlow = innerGlow

        var stroke = StrokeEffect()
        stroke.blendMode = .difference
        stroke.color = EffectColor(red: 0, green: 0.75, blue: 0.25)
        stroke.opacity = 0.8
        stroke.size = 6
        stroke.position = .center
        effects.stroke = stroke

        var colorOverlay = ColorOverlayEffect()
        colorOverlay.blendMode = .hue
        colorOverlay.color = EffectColor(red: 0.9, green: 0.1, blue: 0.35)
        colorOverlay.opacity = 0.7
        effects.colorOverlay = colorOverlay

        var gradientOverlay = GradientOverlayEffect()
        gradientOverlay.blendMode = .luminosity
        gradientOverlay.opacity = 0.55
        gradientOverlay.startColor = EffectColor(red: 0.1, green: 0.2, blue: 0.3)
        gradientOverlay.endColor = EffectColor(red: 0.8, green: 0.7, blue: 0.6)
        gradientOverlay.angle = 135
        gradientOverlay.scale = 1.5
        gradientOverlay.reversed = true
        gradientOverlay.style = .radial
        effects.gradientOverlay = gradientOverlay

        return effects
    }

    /// Colours make the round trip through 0…255 doubles, so they come back
    /// within a level; everything else must be exact.
    private func assertEffectsMatch(_ actual: LayerEffects, _ expected: LayerEffects,
                                    file: StaticString = #filePath, line: UInt = #line) {
        func assertColor(_ a: EffectColor?, _ b: EffectColor?, _ label: String) {
            guard let a, let b else {
                return XCTAssertEqual(a == nil, b == nil, label, file: file, line: line)
            }
            XCTAssertEqual(a.red, b.red, accuracy: 0.005, "\(label).red", file: file, line: line)
            XCTAssertEqual(a.green, b.green, accuracy: 0.005, "\(label).green", file: file, line: line)
            XCTAssertEqual(a.blue, b.blue, accuracy: 0.005, "\(label).blue", file: file, line: line)
        }
        XCTAssertEqual(actual.isEnabled, expected.isEnabled, file: file, line: line)
        XCTAssertEqual(actual.globalLightAngle, expected.globalLightAngle, accuracy: 0.001,
                       file: file, line: line)

        XCTAssertEqual(actual.dropShadow?.blendMode, expected.dropShadow?.blendMode,
                       file: file, line: line)
        XCTAssertEqual(actual.dropShadow?.opacity ?? -1, expected.dropShadow?.opacity ?? -1,
                       accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(actual.dropShadow?.angle ?? -1, expected.dropShadow?.angle ?? -1,
                       accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.dropShadow?.usesGlobalLight, expected.dropShadow?.usesGlobalLight,
                       file: file, line: line)
        XCTAssertEqual(actual.dropShadow?.distance ?? -1, expected.dropShadow?.distance ?? -1,
                       accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.dropShadow?.spread ?? -1, expected.dropShadow?.spread ?? -1,
                       accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(actual.dropShadow?.size ?? -1, expected.dropShadow?.size ?? -1,
                       accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.dropShadow?.knocksOut, expected.dropShadow?.knocksOut,
                       file: file, line: line)
        assertColor(actual.dropShadow?.color, expected.dropShadow?.color, "dropShadow.color")

        XCTAssertEqual(actual.innerShadow?.blendMode, expected.innerShadow?.blendMode,
                       file: file, line: line)
        XCTAssertEqual(actual.innerShadow?.choke ?? -1, expected.innerShadow?.choke ?? -1,
                       accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(actual.innerShadow?.size ?? -1, expected.innerShadow?.size ?? -1,
                       accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.innerShadow?.distance ?? -1, expected.innerShadow?.distance ?? -1,
                       accuracy: 0.001, file: file, line: line)

        XCTAssertEqual(actual.outerGlow?.blendMode, expected.outerGlow?.blendMode,
                       file: file, line: line)
        XCTAssertEqual(actual.outerGlow?.spread ?? -1, expected.outerGlow?.spread ?? -1,
                       accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(actual.outerGlow?.size ?? -1, expected.outerGlow?.size ?? -1,
                       accuracy: 0.001, file: file, line: line)
        assertColor(actual.outerGlow?.color, expected.outerGlow?.color, "outerGlow.color")

        XCTAssertEqual(actual.innerGlow?.blendMode, expected.innerGlow?.blendMode,
                       file: file, line: line)
        XCTAssertEqual(actual.innerGlow?.choke ?? -1, expected.innerGlow?.choke ?? -1,
                       accuracy: 0.005, file: file, line: line)

        XCTAssertEqual(actual.stroke?.blendMode, expected.stroke?.blendMode, file: file, line: line)
        XCTAssertEqual(actual.stroke?.position, expected.stroke?.position, file: file, line: line)
        XCTAssertEqual(actual.stroke?.size ?? -1, expected.stroke?.size ?? -1,
                       accuracy: 0.001, file: file, line: line)
        assertColor(actual.stroke?.color, expected.stroke?.color, "stroke.color")

        XCTAssertEqual(actual.colorOverlay?.blendMode, expected.colorOverlay?.blendMode,
                       file: file, line: line)
        assertColor(actual.colorOverlay?.color, expected.colorOverlay?.color, "colorOverlay.color")

        XCTAssertEqual(actual.gradientOverlay?.blendMode, expected.gradientOverlay?.blendMode,
                       file: file, line: line)
        XCTAssertEqual(actual.gradientOverlay?.style, expected.gradientOverlay?.style,
                       file: file, line: line)
        XCTAssertEqual(actual.gradientOverlay?.angle ?? -1, expected.gradientOverlay?.angle ?? -1,
                       accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.gradientOverlay?.scale ?? -1, expected.gradientOverlay?.scale ?? -1,
                       accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(actual.gradientOverlay?.reversed, expected.gradientOverlay?.reversed,
                       file: file, line: line)
        assertColor(actual.gradientOverlay?.startColor, expected.gradientOverlay?.startColor,
                    "gradient.start")
        assertColor(actual.gradientOverlay?.endColor, expected.gradientOverlay?.endColor,
                    "gradient.end")
    }

    // MARK: - Descriptors

    /// Every OSType the effect codec emits, encoded and decoded back.
    func testDescriptorEncodingRoundTripsEveryValueKind() throws {
        var nested = PSDDescriptor(classID: "RGBC")
        nested["Rd  "] = .double(12.5)
        var descriptor = PSDDescriptor(name: "style", classID: "null")
        descriptor["Objc"] = .descriptor(nested)
        descriptor["VlLs"] = .list([.integer(1), .boolean(false), .text("two")])
        descriptor["doub"] = .double(-3.25)
        descriptor["UntF"] = .unitFloat(unit: "#Prc", value: 87.5)
        descriptor["TEXT"] = .text("Ünïcode ✻")
        descriptor["enum"] = .enumerated(type: "BlnM", value: "Mltp")
        descriptor["long"] = .integer(-4096)
        descriptor["comp"] = .largeInteger(1 << 40)
        descriptor["bool"] = .boolean(true)
        descriptor["tdta"] = .rawData(Data([1, 2, 3, 4]))
        // A key that isn't four characters exercises the length-prefixed form.
        descriptor["masterFXSwitch"] = .boolean(true)

        var reader = PSDByteReader(descriptor.encoded())
        let decoded = try PSDDescriptor(reading: &reader)
        XCTAssertEqual(decoded, descriptor)
        XCTAssertEqual(reader.remaining, 0, "the encoder must not leave trailing bytes")
    }

    // MARK: Descriptor nesting depth

    /// A descriptor body nested `depth` levels deep, written by hand rather
    /// than through `PSDDescriptor.encoded()` — building the value tree in
    /// memory would recurse just as hard as decoding it, so the test would
    /// crash before it could exercise the reader.
    ///
    /// One level is 28 bytes: empty Unicode name (4), classID as a
    /// zero-length + fourCC pair (8), item count (4), key (8), OSType (4).
    private func nestedDescriptorBytes(depth: Int) -> Data {
        var data = Data()
        for _ in 0..<depth {
            data.appendU32(0)                       // name: zero UTF-16 units
            data.appendU32(0)                       // classID: fourCC follows
            data.append(contentsOf: Array("null".utf8))
            data.appendU32(1)                       // one item
            data.appendU32(0)                       // key: fourCC follows
            data.append(contentsOf: Array("Objc".utf8))
            data.append(contentsOf: Array("Objc".utf8))  // value OSType
        }
        data.appendU32(0)                           // innermost: name
        data.appendU32(0)
        data.append(contentsOf: Array("null".utf8)) // innermost: classID
        data.appendU32(0)                           // innermost: no items
        return data
    }

    /// Nesting within reason still decodes — the cap must not reject real
    /// styles, which nest a handful of levels.
    func testModestDescriptorNestingStillDecodes() throws {
        var reader = PSDByteReader(nestedDescriptorBytes(depth: 8))
        XCTAssertNoThrow(try PSDDescriptor(reading: &reader))
    }

    /// Descriptors and their values are mutually recursive and each level
    /// costs only 28 file bytes, so an unbounded reader takes the process
    /// down on a crafted `lfx2` — a stack overflow no `try?` upstream can
    /// catch. Without `PSDDescriptor.maxNestingDepth` this test does not
    /// fail, it crashes the test runner.
    func testPathologicalDescriptorNestingThrowsRatherThanOverflowingTheStack() {
        var reader = PSDByteReader(nestedDescriptorBytes(depth: 20_000))
        XCTAssertThrowsError(try PSDDescriptor(reading: &reader)) { error in
            guard case PSDReadError.unsupportedLayout = error else {
                return XCTFail("expected unsupportedLayout, got \(error)")
            }
        }
    }

    /// The same bomb delivered as a real PSD effects block: `PSDReader` reads
    /// `lfx2` through a `try?`, so this is the path that actually reaches a
    /// user double-clicking a file.
    func testPathologicalNestingInLFX2IsRejected() {
        var payload = Data()
        payload.appendU32(0)            // lfx2 descriptor version
        payload.appendU32(16)           // descriptor version
        payload.append(nestedDescriptorBytes(depth: 20_000))
        XCTAssertThrowsError(try PSDEffects.effects(fromLFX2: payload))
    }

    func testEffectsSurviveTheDescriptorRoundTrip() throws {
        let effects = fullyLoadedEffects()
        let payload = try XCTUnwrap(PSDEffects.lfx2Payload(for: effects))
        assertEffectsMatch(try PSDEffects.effects(fromLFX2: payload), effects)
    }

    func testMasterSwitchOffSurvives() throws {
        var effects = LayerEffects()
        effects.setOn(.dropShadow, true)
        effects.isEnabled = false
        let payload = try XCTUnwrap(PSDEffects.lfx2Payload(for: effects))
        XCTAssertFalse(try PSDEffects.effects(fromLFX2: payload).isEnabled)
    }

    /// Photoshop's "Scale Effects" multiplies every distance in a style. The
    /// reader folds it into the numbers, since the model has no such dial.
    func testScaleEffectsIsFoldedIntoSizesOnRead() throws {
        var descriptor = PSDEffects.descriptor(for: {
            var effects = LayerEffects()
            var shadow = DropShadowEffect()
            shadow.distance = 10
            shadow.size = 20
            effects.dropShadow = shadow
            return effects
        }())
        descriptor["Scl "] = .unitFloat(unit: "#Prc", value: 200)

        let effects = PSDEffects.effects(from: descriptor)
        XCTAssertEqual(effects.dropShadow?.distance ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(effects.dropShadow?.size ?? 0, 40, accuracy: 0.001)
    }

    /// Effects this app doesn't model (Bevel & Emboss here) must be ignored
    /// without taking the rest of the style down with them.
    func testUnmodelledEffectsAreIgnoredNotFatal() throws {
        var descriptor = PSDEffects.descriptor(for: {
            var effects = LayerEffects()
            var overlay = ColorOverlayEffect()
            overlay.opacity = 0.5
            effects.colorOverlay = overlay
            return effects
        }())
        var bevel = PSDDescriptor(classID: "ebbl")
        bevel["enab"] = .boolean(true)
        bevel["Sftn"] = .unitFloat(unit: "#Pxl", value: 5)
        descriptor["ebbl"] = .descriptor(bevel)

        let effects = PSDEffects.effects(from: descriptor)
        XCTAssertEqual(effects.colorOverlay?.opacity ?? 0, 0.5, accuracy: 0.005)
        XCTAssertNil(effects.dropShadow)
    }

    /// Descriptor blend keys are NOT the layer-record four-character codes —
    /// 'Mltp' vs 'mul '. Mixing them up would silently normalise every
    /// effect's mode.
    func testDescriptorBlendKeysDifferFromLayerRecordKeys() {
        XCTAssertEqual(BlendMode.multiply.psdDescriptorKey, "Mltp")
        XCTAssertEqual(BlendMode.multiply.psdKey, "mul ")
        XCTAssertEqual(BlendMode(psdDescriptorKey: "CBrn"), .colorBurn)
        XCTAssertEqual(BlendMode(psdKey: "idiv"), .colorBurn)
        // An unmodelled Photoshop mode degrades to Normal rather than failing.
        XCTAssertNil(BlendMode(psdDescriptorKey: "vividLight"))
        XCTAssertEqual(BlendMode(psdKey: "vLit"), .normal)
    }

    // MARK: - Whole-file round trips

    func testStyledLayerRoundTripsThroughAPSDFile() throws {
        var document = Document(canvasSize: CGSize(width: 48, height: 32))
        var layer = Layer(name: "Styled",
                          source: GeneratedImages.solid(width: 24, height: 16,
                                                        r: 30, g: 140, b: 210, colorSpace: p3),
                          transform: CGAffineTransform(translationX: 12, y: 8))
        layer.effects = fullyLoadedEffects()
        document.layers = [layer]

        let data = try PSDWriter.data(for: document, profile: p3)
        let read = try PSDReader.document(from: data)
        let readLayer = try XCTUnwrap(read.layers.first)
        assertEffectsMatch(readLayer.effects, layer.effects)
    }

    /// The written PSD must keep style out of the pixels: Photoshop applies
    /// `lfx2` itself, so baking a shadow into the channels too would double
    /// it.
    func testPSDLayerPixelsExcludeTheStyle() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        var layer = Layer(name: "Styled",
                          source: GeneratedImages.solid(width: 8, height: 8,
                                                        r: 255, g: 255, b: 255, colorSpace: p3),
                          transform: CGAffineTransform(translationX: 12, y: 12))
        var stroke = StrokeEffect()
        stroke.size = 4
        stroke.position = .outside
        layer.effects.stroke = stroke
        document.layers = [layer]

        let read = try PSDReader.document(from: try PSDWriter.data(for: document, profile: p3))
        let readLayer = try XCTUnwrap(read.layers.first)
        XCTAssertEqual(readLayer.source.width, 8, "an outside stroke must not enlarge the layer")
        XCTAssertEqual(readLayer.source.height, 8)
        XCTAssertEqual(readLayer.effects.stroke?.size ?? 0, 4, accuracy: 0.001)
    }

    // MARK: -.brushy

    private func brushyRoundTrip(_ document: Document) throws -> Document {
        let wrapper = try DocumentSerializer().fileWrapper(for: document)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("effects-\(UUID().uuidString).brushy")
        try wrapper.write(to: temp, options: .atomic, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try DocumentSerializer().document(from: try FileWrapper(url: temp))
    }

    func testEffectsRoundTripThroughCompdoc() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        var layer = Layer(name: "Styled",
                          source: GeneratedImages.solid(width: 16, height: 16,
                                                        r: 10, g: 20, b: 30, colorSpace: p3))
        layer.effects = fullyLoadedEffects()
        document.layers = [layer]

        let read = try brushyRoundTrip(document)
        assertEffectsMatch(try XCTUnwrap(read.layers.first).effects, layer.effects)
    }

    /// A document with no style must serialise exactly as it did before
    /// effects existed — the guides/groups precedent for format additions.
    func testEffectFreeDocumentsOmitTheKey() throws {
        var document = Document(canvasSize: CGSize(width: 16, height: 16))
        document.layers = [Layer(name: "Plain",
                                 source: GeneratedImages.solid(width: 16, height: 16,
                                                               r: 1, g: 2, b: 3, colorSpace: p3))]
        let wrapper = try DocumentSerializer().fileWrapper(for: document)
        let json = try XCTUnwrap(wrapper.fileWrappers?["document.json"]?.regularFileContents)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(text.contains("effects"), "no style ⇒ no key:\n\(text)")
        XCTAssertTrue(try brushyRoundTrip(document).layers[0].effects.isEmpty)
    }
}

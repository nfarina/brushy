import CoreGraphics
import CoreImage
import Foundation
import Metal
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// Layer groups: render semantics.
///
/// The keystone is pass-through neutrality: a group with no explicit blend
/// mode and 100% opacity is organizational only, so a document composited
/// with pass-through groups must be BIT-IDENTICAL to the same document
/// ungrouped — the renderer builds node-for-node the same graph. Isolated
/// groups (opacity < 100% or an explicit mode) are verified analytically in
/// the style of BlendClippingTests: group opacity interpolates in linear
/// light (like layer opacity), group blend modes run the same encoded
/// gamma sandwich as layer modes.
final class GroupRenderTests: XCTestCase {
    private let p3 = BrushyColorSpace.displayP3

    private func solidLayer(_ name: String, r: UInt8, g: UInt8, b: UInt8,
                            width: Int = 32, height: Int = 32,
                            at origin: CGPoint = .zero) -> Layer {
        Layer(name: name,
              source: GeneratedImages.solid(width: width, height: height,
                                            r: r, g: g, b: b, colorSpace: p3),
              transform: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    private func flattenedBytes(_ document: Document) throws -> RawImage {
        guard let output = RenderEngine.shared.renderFlattened(
            document: document, profile: p3, sixteenBit: false) else {
            throw TestImageError.contextFailed
        }
        return try rawRGBA8(output)
    }

    // MARK: - Pass-through neutrality (the keystone)

    /// A busy document — masked layer, partial opacities, a multiply clip
    /// run, a screen layer — grouped into pass-through folders (one nested)
    /// WITHOUT splitting any clip run must composite byte-for-byte the same
    /// as the flat original. This is what keeps the golden pipeline
    /// safe under grouping.
    func testPassThroughGroupsCompositeBitIdentical() throws {
        var flat = Document(canvasSize: CGSize(width: 200, height: 150))
        let background = Layer(name: "bg",
                               source: GeneratedImages.gradientChecker(
                                   width: 200, height: 150, square: 16, colorSpace: p3))
        var masked = solidLayer("masked", r: 220, g: 40, b: 30,
                                width: 80, height: 60, at: CGPoint(x: 20, y: 15))
        var maskData = Data(repeating: 255, count: 80 * 60)
        for row in 30..<60 {
            for col in 0..<80 { maskData[row * 80 + col] = 64 }
        }
        masked.mask = Mask(texture: MaskTexture(width: 80, height: 60, data: maskData),
                           isEnabled: true)
        masked.opacity = 0.8
        var clipped = solidLayer("clip", r: 40, g: 200, b: 60,
                                 width: 70, height: 50, at: CGPoint(x: 45, y: 30))
        clipped.blendMode = .multiply
        clipped.isClippedToBelow = true
        var screen = solidLayer("screen", r: 40, g: 80, b: 230,
                                width: 90, height: 70, at: CGPoint(x: 95, y: 60))
        screen.blendMode = .screen
        screen.opacity = 0.6
        let top = solidLayer("top", r: 250, g: 250, b: 245,
                             width: 40, height: 30, at: CGPoint(x: 130, y: 30))
        flat.layers = [background, masked, clipped, screen, top]

        var grouped = flat
        let inner = LayerGroup(name: "Inner")
        let outer = LayerGroup(name: "Outer")
        let pair = LayerGroup(name: "Pair")
        grouped.groups = [pair, outer, LayerGroup(id: inner.id, name: inner.name,
                                                  parentID: outer.id)]
        grouped.layers[1].groupID = pair.id       // masked + its clip stay together
        grouped.layers[2].groupID = pair.id
        grouped.layers[3].groupID = outer.id
        grouped.layers[4].groupID = inner.id      // nested pass-through

        // Well-formed by construction — normalization must agree.
        XCTAssertEqual(grouped.normalizingGroups().normalizingClipping(), grouped,
                       "a well-formed grouped document must normalize to itself")

        let reference = try flattenedBytes(flat)
        let actual = try flattenedBytes(grouped)
        XCTAssertEqual(actual.rgba, reference.rgba,
                       "pass-through grouping changed the composite — it must be graph-neutral")
    }

    // MARK: - Isolated groups (analytic)

    /// Group opacity applies ONCE to the flattened members, interpolating in
    /// linear light like layer opacity. Members: white base + black at
    /// 60% layer opacity inside the group → linear 0.4 grey; the group at 50%
    /// over a red backdrop → 0.5·(0.4,0.4,0.4) + 0.5·(1,0,0) = (0.7,0.2,0.2)
    /// linear → encoded ≈ (218,124,124). Fading members individually instead
    /// (a pass-through-style mistake) would land far off.
    func testIsolatedGroupOpacityIsLinearLightOnFlattenedMembers() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        let backdrop = solidLayer("red", r: 255, g: 0, b: 0)
        let white = solidLayer("white", r: 255, g: 255, b: 255)
        var black = solidLayer("black", r: 0, g: 0, b: 0)
        black.opacity = 0.6
        var group = LayerGroup(name: "G")
        group.opacity = 0.5
        document.groups = [group]
        document.layers = [backdrop, white, black]
        document.layers[1].groupID = group.id
        document.layers[2].groupID = group.id

        let pixel = try flattenedBytes(document)[16, 16]
        XCTAssert((216...220).contains(Int(pixel.r)),
                  "expected linear-light group opacity r≈218, got \(pixel.r)")
        for channel in [pixel.g, pixel.b] {
            XCTAssert((122...126).contains(Int(channel)),
                      "expected linear-light group opacity g/b≈124, got \(channel)")
        }
        XCTAssertEqual(pixel.a, 255)
    }

    /// A group's blend mode runs the same encoded-space gamma sandwich as a
    /// layer's: Screen of mid-grey group content over mid-grey backdrop gives
    /// 1−(1−0.50196)² = 0.75196 → ≈192 (linear-space math would give ≈167,
    /// excluded by the range — same discriminator as BlendClippingTests).
    func testIsolatedGroupBlendModeUsesEncodedMath() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        let backdrop = solidLayer("grey", r: 128, g: 128, b: 128)
        let member = solidLayer("member", r: 128, g: 128, b: 128)
        var group = LayerGroup(name: "G")
        group.blendMode = .screen
        document.groups = [group]
        document.layers = [backdrop, member]
        document.layers[1].groupID = group.id

        let pixel = try flattenedBytes(document)[16, 16]
        for channel in [pixel.r, pixel.g, pixel.b] {
            XCTAssert((189...194).contains(Int(channel)),
                      "expected encoded-space group screen ≈192, got \(channel)")
        }
    }

    /// Nested isolation composes: 50% inside 50% over black is linear 0.25
    /// white → encoded ≈ 137.
    func testNestedIsolatedGroupsComposeOpacities() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        let backdrop = solidLayer("black", r: 0, g: 0, b: 0)
        let white = solidLayer("white", r: 255, g: 255, b: 255)
        var outer = LayerGroup(name: "Outer")
        outer.opacity = 0.5
        var inner = LayerGroup(name: "Inner")
        inner.opacity = 0.5
        inner.parentID = outer.id
        document.groups = [outer, inner]
        document.layers = [backdrop, white]
        document.layers[1].groupID = inner.id

        let pixel = try flattenedBytes(document)[16, 16]
        for channel in [pixel.r, pixel.g, pixel.b] {
            XCTAssert((135...139).contains(Int(channel)),
                      "expected 0.25 linear white ≈137, got \(channel)")
        }
    }

    /// An explicit Normal mode ISOLATES (unlike Pass Through): members
    /// flatten against transparency first, so a Multiply member at the bottom
    /// of the group stops multiplying the backdrop underneath the group.
    /// Pass-through: multiply(128,128) encoded = 0.50196² = 0.25196 → ≈64.
    /// Normal-isolated: the multiply member sees only in-group transparency,
    /// leaving its own grey → 128.
    func testNormalModeIsolatesWhereMembersBlendWithBackdrop() throws {
        var document = Document(canvasSize: CGSize(width: 32, height: 32))
        let backdrop = solidLayer("grey", r: 128, g: 128, b: 128)
        var member = solidLayer("member", r: 128, g: 128, b: 128)
        member.blendMode = .multiply
        var passDoc = document
        var group = LayerGroup(name: "G")
        passDoc.groups = [group]
        passDoc.layers = [backdrop, member]
        passDoc.layers[1].groupID = group.id
        let passPixel = try flattenedBytes(passDoc)[16, 16]
        XCTAssert((62...66).contains(Int(passPixel.r)),
                  "pass-through member multiply must reach the backdrop, got \(passPixel.r)")

        group.blendMode = .normal
        var isoDoc = document
        isoDoc.groups = [group]
        isoDoc.layers = [backdrop, member]
        isoDoc.layers[1].groupID = group.id
        let isoPixel = try flattenedBytes(isoDoc)[16, 16]
        XCTAssert((126...130).contains(Int(isoPixel.r)),
                  "Normal-isolated member multiply must see only in-group transparency, got \(isoPixel.r)")
    }

    // MARK: - Clip runs scoped to the group

    /// A clipped layer whose neighbour below sits outside its group has no
    /// base: it renders UNCLIPPED (matching the bottom-of-stack rule), and
    /// never confines to a layer across the boundary.
    func testClipRunBreaksAtGroupBoundary() throws {
        var document = Document(canvasSize: CGSize(width: 100, height: 100))
        let small = solidLayer("below", r: 255, g: 0, b: 0,
                               width: 10, height: 10, at: CGPoint(x: 0, y: 0))
        var clipped = solidLayer("clipped", r: 0, g: 0, b: 255,
                                 width: 20, height: 20, at: CGPoint(x: 30, y: 30))
        clipped.isClippedToBelow = true
        let group = LayerGroup(name: "G")
        document.groups = [group]
        document.layers = [small, clipped]
        document.layers[1].groupID = group.id

        let pixels = try flattenedBytes(document)
        // Canvas y-up → raster row flips: canvas (35,35) is row 100-1-35 = 64.
        let inside = pixels[35, 64]
        XCTAssertEqual(inside.a, 255, "the boundary-orphaned clipped layer must render")
        XCTAssertGreaterThan(inside.b, 200,
                             "the orphaned clipped layer renders unclipped, not confined to a base across the group boundary")
    }

    /// Inside a group the run works exactly as at top level: the clipped
    /// member confines to its in-group base's coverage.
    func testClipRunInsideGroupConfinesToBase() throws {
        var document = Document(canvasSize: CGSize(width: 100, height: 100))
        let backdrop = solidLayer("bg", r: 128, g: 128, b: 128,
                                  width: 100, height: 100)
        let base = solidLayer("base", r: 0, g: 200, b: 0,
                              width: 20, height: 20, at: CGPoint(x: 10, y: 10))
        var clip = solidLayer("clip", r: 255, g: 255, b: 255,
                              width: 60, height: 60, at: CGPoint(x: 0, y: 0))
        clip.isClippedToBelow = true
        let group = LayerGroup(name: "G")
        document.groups = [group]
        document.layers = [backdrop, base, clip]
        document.layers[1].groupID = group.id
        document.layers[2].groupID = group.id

        let pixels = try flattenedBytes(document)
        let insideBase = pixels[15, 100 - 1 - 15]     // canvas (15,15)
        let outsideBase = pixels[45, 100 - 1 - 45]    // canvas (45,45) — clip covers, base doesn't
        XCTAssertGreaterThan(insideBase.r, 200, "clip content shows over its base")
        XCTAssert((126...130).contains(Int(outsideBase.r)),
                  "clip content must vanish outside the base even though the clip layer covers this point — got \(outsideBase.r)")
    }

    // MARK: - Visibility cascade

    /// Hiding a group hides every member — render, and hit-testing alike.
    /// Nested members go with their outermost hidden ancestor.
    func testHiddenGroupHidesSubtreeEverywhere() throws {
        var document = Document(canvasSize: CGSize(width: 60, height: 60))
        let backdrop = solidLayer("bg", r: 10, g: 10, b: 10, width: 60, height: 60)
        let member = solidLayer("member", r: 255, g: 0, b: 0,
                                width: 20, height: 20, at: CGPoint(x: 20, y: 20))
        let nested = solidLayer("nested", r: 0, g: 255, b: 0,
                                width: 10, height: 10, at: CGPoint(x: 25, y: 25))
        var outer = LayerGroup(name: "Outer")
        outer.isVisible = false
        let inner = LayerGroup(name: "Inner", parentID: outer.id)
        document.groups = [outer, inner]
        document.layers = [backdrop, member, nested]
        document.layers[1].groupID = outer.id
        document.layers[2].groupID = inner.id

        let pixel = try flattenedBytes(document)[30, 60 - 1 - 30]
        XCTAssertLessThan(pixel.r, 30, "hidden group's member must not render")
        XCTAssertLessThan(pixel.g, 30, "hidden group's nested member must not render")

        let hit = document.topmostLayer(at: CGPoint(x: 30, y: 30))
        XCTAssertEqual(hit?.id, backdrop.id,
                       "auto-select must fall through members hidden via their group")
        XCTAssertFalse(document.isEffectivelyVisible(layerID: member.id))
        XCTAssertFalse(document.isEffectivelyVisible(layerID: nested.id))
        XCTAssertFalse(document.isEffectivelyVisible(groupID: inner.id))

        // Copy Merged region render flows through the same composite.
        let region = RenderEngine.shared.renderFlattenedRegion(
            document: document, croppedTo: CGRect(x: 20, y: 20, width: 20, height: 20))
        let regionPixels = try rawRGBA8(XCTUnwrap(region))
        XCTAssertLessThan(regionPixels[10, 10].r, 30,
                          "Copy Merged must exclude members hidden via their group")
    }

    /// A member's own eye still works inside a visible group.
    func testMemberVisibilityInsideVisibleGroup() throws {
        var document = Document(canvasSize: CGSize(width: 40, height: 40))
        let backdrop = solidLayer("bg", r: 10, g: 10, b: 10, width: 40, height: 40)
        var member = solidLayer("member", r: 255, g: 0, b: 0, width: 40, height: 40)
        member.isVisible = false
        let group = LayerGroup(name: "G")
        document.groups = [group]
        document.layers = [backdrop, member]
        document.layers[1].groupID = group.id

        let pixel = try flattenedBytes(document)[20, 20]
        XCTAssertLessThan(pixel.r, 30, "a hidden member stays hidden inside a visible group")
        XCTAssertFalse(document.isEffectivelyVisible(layerID: member.id))
        XCTAssertTrue(document.isEffectivelyVisible(groupID: group.id))
    }

    // The frame-time test with pass-through groups lives in
    // GroupPerformanceTests — perf suites are isolated from the functional
    // pass because frame measurements are order-fragile at full-suite scale.
}

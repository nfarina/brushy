import CoreGraphics
import Foundation
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// Layer effects(; the layer-style exclusion lifted by the
/// owner, as with blend modes).
///
/// Effects are verified structurally rather than against golden images: an
/// effect's job is to put the right colour in the right place, and CI's
/// Gaussian blur is an approximation (see MaskFactory's note), so the
/// assertions probe geometry — which side the shadow lands on, how far it
/// reaches, what the layer's own pixels do — on flat colours where the
/// arithmetic is analytic.
///
/// Scene: an 80×80 canvas, an opaque white backdrop, and a 32×32 blue square
/// centred at canvas (24…56, 24…56). Canvas space is y-up and `rawRGBA8`
/// rows count from the top, so canvas y maps to row 79 − y.
final class LayerEffectsTests: XCTestCase {
    private let p3 = BrushyColorSpace.displayP3
    private let canvas: CGFloat = 80
    private let square: CGFloat = 32

    private func row(forCanvasY y: Int) -> Int { Int(canvas) - 1 - y }

    private func scene(_ effects: LayerEffects,
                       squareOpacity: Float = 1) -> Document {
        var document = Document(canvasSize: CGSize(width: canvas, height: canvas))
        let backdrop = Layer(name: "white",
                             source: GeneratedImages.solid(width: Int(canvas), height: Int(canvas),
                                                           r: 255, g: 255, b: 255, colorSpace: p3))
        var layer = Layer(name: "square",
                          source: GeneratedImages.solid(width: Int(square), height: Int(square),
                                                        r: 0, g: 0, b: 255, colorSpace: p3))
        layer.transform = CGAffineTransform(translationX: (canvas - square) / 2,
                                            y: (canvas - square) / 2)
        layer.opacity = squareOpacity
        layer.effects = effects
        document.layers = [backdrop, layer]
        return document
    }

    private func render(_ document: Document) throws -> RawImage {
        guard let output = RenderEngine.shared.renderFlattened(document: document, profile: p3,
                                                               sixteenBit: false) else {
            throw TestImageError.contextFailed
        }
        return try rawRGBA8(output)
    }

    /// Pixel at a canvas coordinate (y-up), from a top-down raster.
    private func pixel(_ image: RawImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        image[x, row(forCanvasY: y)]
    }

    // MARK: - Fast path

    /// A layer with no effects, and a layer whose effects are all switched
    /// off, must render byte-identically to the pre-effects pipeline — the
    /// golden references depend on it and so does the frame budget.
    func testInactiveEffectsRenderIdenticallyToNoEffects() throws {
        let plain = try render(scene(.none))

        var switchedOff = LayerEffects()
        switchedOff.setOn(.dropShadow, true)
        switchedOff.setOn(.stroke, true)
        switchedOff.isEnabled = false          // the master fx switch
        XCTAssertFalse(switchedOff.isActive)
        let masterOff = try render(scene(switchedOff))
        XCTAssertEqual(plain.rgba, masterOff.rgba,
                       "the master fx switch off must cost nothing and change nothing")

        var unchecked = LayerEffects()
        unchecked.setOn(.dropShadow, true)
        unchecked.setOn(.dropShadow, false)    // keeps parameters, clears the checkbox
        XCTAssertNotNil(unchecked.dropShadow)
        XCTAssertFalse(unchecked.isActive)
        XCTAssertEqual(plain.rgba, try render(scene(unchecked)).rgba)
    }

    // MARK: - Drop shadow

    /// Photoshop's angle dial points at the light, so the default 120° casts
    /// down and to the right. The hard-edged case (size 0, spread 0) makes
    /// the offset exactly measurable.
    func testDropShadowFallsOppositeTheLightAngle() throws {
        var shadow = DropShadowEffect()
        shadow.angle = 120
        shadow.usesGlobalLight = false
        shadow.distance = 10
        shadow.size = 0
        shadow.opacity = 1
        var effects = LayerEffects()
        effects.dropShadow = shadow
        let image = try render(scene(effects))

        // Offset = (−cos120°, −sin120°)·10 = (+5, −8.66): right and down.
        // A point just inside the shadow's displaced rect but outside the
        // square must be darkened; its mirror image on the opposite side
        // must be untouched white.
        let shadowed = pixel(image, x: 59, y: 20)
        XCTAssertLessThan(Int(shadowed.r), 200, "expected the shadow down-right of the square")
        let opposite = pixel(image, x: 21, y: 59)
        XCTAssertEqual(Int(opposite.r), 255, "up-left of the square must stay clear")
    }

    /// Black at 35% Multiply over white is analytic: 255·(1−0.35) ≈ 166.
    func testDropShadowOpacityAndBlendModeAreExact() throws {
        var shadow = DropShadowEffect()
        shadow.usesGlobalLight = false
        shadow.angle = 120
        shadow.distance = 12
        shadow.size = 0
        shadow.opacity = 0.35
        shadow.blendMode = .multiply
        var effects = LayerEffects()
        effects.dropShadow = shadow
        let image = try render(scene(effects))
        let shadowed = pixel(image, x: 60, y: 18)
        XCTAssertEqual(Int(shadowed.r), 166, accuracy: 2)
        XCTAssertEqual(Int(shadowed.a), 255)
    }

    /// Size controls how far the blur reaches beyond the layer's edge. The
    /// `LayerEffectRenderer.blurRadiusPerSize` constant is calibrated so a
    /// size-N shadow fades out at roughly N canvas points — this pins it.
    func testShadowSizeControlsReach() throws {
        func reach(size: Double) throws -> Int {
            var shadow = DropShadowEffect()
            shadow.distance = 0
            shadow.size = size
            shadow.opacity = 1
            shadow.blendMode = .multiply
            var effects = LayerEffects()
            effects.dropShadow = shadow
            let image = try render(scene(effects))
            // Walk right from the square's edge (canvas x 56) along its
            // mid-height until the backdrop is clean again.
            var distance = 0
            for x in Int(canvas / 2 + square / 2)..<Int(canvas) {
                if pixel(image, x: x, y: 40).r >= 250 { break }
                distance += 1
            }
            return distance
        }
        let small = try reach(size: 4)
        let large = try reach(size: 12)
        XCTAssertGreaterThan(small, 1, "a size-4 shadow must be visible")
        XCTAssertLessThanOrEqual(small, 8, "a size-4 shadow must not reach 8pt (got \(small))")
        XCTAssertGreaterThan(large, small, "a bigger Size must reach further")
        XCTAssertLessThanOrEqual(large, 20, "a size-12 shadow must not reach 20pt (got \(large))")
    }

    /// "Layer Knocks Out Drop Shadow": with the layer at 50% the backdrop
    /// shows through it, not the layer's own shadow.
    func testKnockoutRemovesTheShadowUnderTheLayer() throws {
        var shadow = DropShadowEffect()
        shadow.distance = 0
        shadow.size = 0
        shadow.opacity = 1
        shadow.blendMode = .multiply
        shadow.knocksOut = true
        var effects = LayerEffects()
        effects.dropShadow = shadow

        let knockedOut = try render(scene(effects, squareOpacity: 0.5))
        shadow.knocksOut = false
        effects.dropShadow = shadow
        let showsThrough = try render(scene(effects, squareOpacity: 0.5))

        let centre = (x: 40, y: 40)
        let a = pixel(knockedOut, x: centre.x, y: centre.y)
        let b = pixel(showsThrough, x: centre.x, y: centre.y)
        XCTAssertGreaterThan(Int(a.b), Int(b.b) + 20,
                             "knockout must leave the translucent layer over the white backdrop, not over its own shadow")
    }

    // MARK: - Stroke

    func testOutsideStrokeAddsABandOutsideTheLayerOnly() throws {
        var stroke = StrokeEffect()
        stroke.size = 4
        stroke.position = .outside
        // Black keeps the assertions free of gamut arithmetic: the scene's
        // sources are P3-tagged, but an EffectColor is sRGB, so a saturated
        // effect colour lands on different numbers in a P3 output.
        stroke.color = .black
        var effects = LayerEffects()
        effects.stroke = stroke
        let image = try render(scene(effects))

        // 2pt outside the right edge (x 56): solid black band.
        let band = pixel(image, x: 58, y: 40)
        XCTAssertLessThan(Int(band.r), 20)
        XCTAssertLessThan(Int(band.b), 20)
        XCTAssertEqual(Int(band.a), 255)
        // 6pt outside: past the band, clean white.
        let past = pixel(image, x: 62, y: 40)
        XCTAssertEqual(Int(past.r), 255)
        XCTAssertEqual(Int(past.g), 255)
        // 4pt inside: the layer's own blue, untouched by an OUTSIDE stroke.
        let inside = pixel(image, x: 52, y: 40)
        XCTAssertGreaterThan(Int(inside.b), 200)
        XCTAssertLessThan(Int(inside.g), 60)
    }

    func testInsideStrokeStaysWithinTheLayer() throws {
        var stroke = StrokeEffect()
        stroke.size = 4
        stroke.position = .inside
        // Black keeps the assertions free of gamut arithmetic: the scene's
        // sources are P3-tagged, but an EffectColor is sRGB, so a saturated
        // effect colour lands on different numbers in a P3 output.
        stroke.color = .black
        var effects = LayerEffects()
        effects.stroke = stroke
        let image = try render(scene(effects))

        let outside = pixel(image, x: 58, y: 40)
        XCTAssertEqual(Int(outside.r), 255, "an inside stroke must not cross the layer's edge")
        let band = pixel(image, x: 54, y: 40)
        XCTAssertLessThan(Int(band.b), 20, "the band must be inside the layer's edge")
        let core = pixel(image, x: 40, y: 40)
        XCTAssertGreaterThan(Int(core.b), 200, "the layer's interior must survive")
        XCTAssertLessThan(Int(core.g), 60)
    }

    // MARK: - Overlays

    func testColorOverlayRecoloursTheLayerAndNothingElse() throws {
        var overlay = ColorOverlayEffect()
        overlay.color = EffectColor(red: 1, green: 0, blue: 0)
        var effects = LayerEffects()
        effects.colorOverlay = overlay
        let image = try render(scene(effects))

        let inside = pixel(image, x: 40, y: 40)
        XCTAssertGreaterThan(Int(inside.r), 200)
        XCTAssertLessThan(Int(inside.b), 60)
        let outside = pixel(image, x: 10, y: 10)
        XCTAssertEqual(Int(outside.r), 255)
        XCTAssertEqual(Int(outside.g), 255)
        XCTAssertEqual(Int(outside.b), 255)
    }

    /// A 90° ramp runs bottom-to-top: start colour at the layer's bottom edge,
    /// end colour at its top.
    func testGradientOverlayRunsAlongItsAngle() throws {
        var overlay = GradientOverlayEffect()
        overlay.startColor = .black
        overlay.endColor = .white
        overlay.angle = 90
        var effects = LayerEffects()
        effects.gradientOverlay = overlay
        let image = try render(scene(effects))

        let bottom = pixel(image, x: 40, y: 27)
        let top = pixel(image, x: 40, y: 53)
        XCTAssertLessThan(Int(bottom.r), 80, "the ramp must start dark at the bottom")
        XCTAssertGreaterThan(Int(top.r), 180, "and finish light at the top")
        // Confined to the layer: the backdrop beside it is untouched.
        XCTAssertEqual(Int(pixel(image, x: 8, y: 40).r), 255)
    }

    // MARK: - Interior shadow/glow

    /// An inner shadow sits on the side the light comes from — 120° puts it
    /// along the layer's top-left inside edge, not the bottom-right.
    func testInnerShadowDarkensTheLightSideEdge() throws {
        var shadow = InnerShadowEffect()
        shadow.usesGlobalLight = false
        shadow.angle = 120
        shadow.distance = 6
        shadow.size = 0
        shadow.opacity = 1
        shadow.blendMode = .multiply
        var effects = LayerEffects()
        effects.innerShadow = shadow
        let image = try render(scene(effects))

        let lightSide = pixel(image, x: 40, y: 53)   // just inside the top edge
        let darkSide = pixel(image, x: 40, y: 27)    // just inside the bottom edge
        XCTAssertLessThan(Int(lightSide.b), 100, "the top inside edge must be shadowed")
        XCTAssertGreaterThan(Int(darkSide.b), 200, "the bottom inside edge must not be")
    }

    /// A glow is un-offset, so it must ring the layer symmetrically and fade
    /// with distance. Black-on-white keeps it to one number per probe.
    func testOuterGlowSurroundsTheLayerEvenly() throws {
        var glow = OuterGlowEffect()
        glow.size = 8
        glow.opacity = 1
        glow.blendMode = .normal
        glow.color = .black
        var effects = LayerEffects()
        effects.outerGlow = glow
        let image = try render(scene(effects))

        // The square covers pixels 24…55, so 56 and 23 are the first pixels
        // outside its right/left (and top/bottom) edges: four equivalent
        // probes, which must come back equally darkened.
        let near = [pixel(image, x: 56, y: 40), pixel(image, x: 23, y: 40),
                    pixel(image, x: 40, y: 56), pixel(image, x: 40, y: 23)].map { Int($0.r) }
        for value in near {
            XCTAssertLessThan(value, 230, "glow missing beside an edge — probes \(near)")
        }
        XCTAssertLessThan(near.max()! - near.min()!, 8, "glow must be symmetric — \(near)")
        // Well beyond Size: clean backdrop again.
        XCTAssertEqual(Int(pixel(image, x: 70, y: 40).r), 255)
    }

    // MARK: - Model

    func testOutsetCoversEveryOutwardEffect() {
        var effects = LayerEffects()
        XCTAssertEqual(effects.outsetInCanvasPoints, 0)
        effects.dropShadow = DropShadowEffect()      // distance 5 + size 5
        XCTAssertEqual(effects.outsetInCanvasPoints, 10, accuracy: 0.001)
        var stroke = StrokeEffect()
        stroke.size = 24
        effects.stroke = stroke
        XCTAssertEqual(effects.outsetInCanvasPoints, 24, accuracy: 0.001)
        // An inside stroke reaches nowhere outward.
        effects.stroke?.position = .inside
        effects.dropShadow = nil
        XCTAssertEqual(effects.outsetInCanvasPoints, 0, accuracy: 0.001)
    }

    func testStyledCanvasBoundsGrowWithTheStyle() {
        var layer = Layer(name: "l", source: GeneratedImages.solid(width: 10, height: 10,
                                                                   r: 0, g: 0, b: 0,
                                                                   colorSpace: p3))
        XCTAssertEqual(layer.styledCanvasBounds, layer.canvasBounds)
        var glow = OuterGlowEffect()
        glow.size = 8
        layer.effects.outerGlow = glow
        XCTAssertEqual(layer.styledCanvasBounds, layer.canvasBounds.insetBy(dx: -8, dy: -8))
    }

    // MARK: - Store / undo

    private func makeStyleStore() -> (DocumentStore, UndoManager, UUID) {
        var document = Document(canvasSize: CGSize(width: canvas, height: canvas))
        let layer = Layer(name: "Styled",
                          source: GeneratedImages.solid(width: Int(square), height: Int(square),
                                                        r: 0, g: 0, b: 255, colorSpace: p3),
                          transform: CGAffineTransform(translationX: 24, y: 24))
        document.layers = [layer]
        let store = DocumentStore(document: document)
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        store.selectLayer(layer.id)
        return (store, undoManager, layer.id)
    }

    /// The dialog drags controls through `setLiveLayerEffects` and lands one
    /// `setLayerEffects` on OK, so a whole styling session is a single
    /// "Undo Layer Style".
    func testAWholeStyleSessionIsOneUndoStep() {
        let (store, undoManager, id) = makeStyleStore()
        var effects = LayerEffects()
        for size in stride(from: 2.0, through: 20.0, by: 2.0) {
            effects.setOn(.dropShadow, true)
            effects.dropShadow?.size = size
            store.setLiveLayerEffects(id, effects)
        }
        XCTAssertFalse(store.canUndo, "live preview must not touch history")
        XCTAssertEqual(store.document[layerID: id]?.effects.dropShadow?.size, 20,
                       "the canvas must show the live value")

        undoManager.beginUndoGrouping()
        store.setLayerEffects(id, effects)
        undoManager.endUndoGrouping()
        XCTAssertEqual(undoManager.undoActionName, "Layer Style")

        undoManager.undo()
        XCTAssertTrue(store.document[layerID: id]?.effects.isEmpty ?? false,
                      "one undo must clear the whole session")
    }

    func testFxEyeAndClearStyleAreTheirOwnCommits() {
        let (store, undoManager, id) = makeStyleStore()
        var effects = LayerEffects()
        effects.setOn(.outerGlow, true)
        undoManager.beginUndoGrouping()
        store.setLayerEffects(id, effects)
        undoManager.endUndoGrouping()

        undoManager.beginUndoGrouping()
        store.toggleLayerEffectsEnabled(id)
        undoManager.endUndoGrouping()
        XCTAssertEqual(store.document[layerID: id]?.effects.isEnabled, false)
        XCTAssertEqual(undoManager.undoActionName, "Disable Layer Effects")
        XCTAssertFalse(store.document[layerID: id]?.effects.isEmpty ?? true,
                       "switching effects off must keep them")

        undoManager.beginUndoGrouping()
        store.clearLayerStyle(id)
        undoManager.endUndoGrouping()
        XCTAssertTrue(store.document[layerID: id]?.effects.isEmpty ?? false)
        XCTAssertEqual(undoManager.undoActionName, "Clear Layer Style")

        undoManager.undo()
        XCTAssertEqual(store.document[layerID: id]?.effects.outerGlow?.isEnabled, true)
    }

    /// A Layer Style menu item selects the layer, brings the panel up,
    /// switches the effect on as its own commit and asks the panel to open it.
    func testShowingAnEffectSelectsTheLayerAddsItAndFocusesIt() {
        let (store, undoManager, id) = makeStyleStore()
        store.selectLayer(nil)
        store.rightPanel = .history
        undoManager.beginUndoGrouping()
        store.showLayerEffects(id, focus: .stroke)
        undoManager.endUndoGrouping()
        XCTAssertEqual(store.selectedLayerID, id)
        XCTAssertEqual(store.rightPanel, .layers)
        XCTAssertEqual(store.effectsFocus?.layerID, id)
        XCTAssertEqual(store.effectsFocus?.kind, .stroke)
        XCTAssertEqual(store.document[layerID: id]?.effects.isOn(.stroke), true)
        XCTAssertEqual(undoManager.undoActionName, "Add Stroke")

        // Showing an effect that is already on adds no history.
        let position = store.historyPosition
        store.showLayerEffects(id, focus: .stroke)
        XCTAssertEqual(store.historyPosition, position)
    }

    /// A panel drag previews through `setLiveLayerEffects` and lands one
    /// commit at the end; a release that changed nothing records nothing.
    func testAPanelDragIsOneUndoStep() throws {
        let (store, undoManager, id) = makeStyleStore()
        undoManager.beginUndoGrouping()
        store.addLayerEffect(id, .dropShadow)
        undoManager.endUndoGrouping()
        var effects = try XCTUnwrap(store.document[layerID: id]?.effects)
        let before = store.historyPosition
        for size in stride(from: 2.0, through: 20.0, by: 2.0) {
            effects.dropShadow?.size = size
            store.setLiveLayerEffects(id, effects)
        }
        XCTAssertEqual(store.historyPosition, before, "live preview must not touch history")
        undoManager.beginUndoGrouping()
        store.endLayerEffectsEdit("Change Drop Shadow")
        undoManager.endUndoGrouping()
        XCTAssertEqual(store.historyPosition, before + 1)
        XCTAssertEqual(undoManager.undoActionName, "Change Drop Shadow")

        store.endLayerEffectsEdit("Change Drop Shadow")
        XCTAssertEqual(store.historyPosition, before + 1, "an empty edit must not add a step")

        undoManager.undo()
        XCTAssertNotEqual(store.document[layerID: id]?.effects.dropShadow?.size, 20)
    }

    func testRemovingAnEffectDropsItsParameters() {
        let (store, _, id) = makeStyleStore()
        store.addLayerEffect(id, .outerGlow)
        store.removeLayerEffect(id, .outerGlow)
        XCTAssertNil(store.document[layerID: id]?.effects.outerGlow)
        XCTAssertTrue(store.document[layerID: id]?.effects.isEmpty ?? false)
    }

    /// New effects are sized to the layer, so a shadow on a large layer is
    /// visible without hunting for it; small layers keep Photoshop's floors.
    func testAddedEffectsAreSizedToTheLayer() {
        var large = LayerEffects()
        large.add(.dropShadow, layerSize: CGSize(width: 900, height: 1200))
        XCTAssertEqual(large.dropShadow?.distance, 18)
        XCTAssertEqual(large.dropShadow?.size, 54)

        var small = LayerEffects()
        small.add(.dropShadow, layerSize: CGSize(width: 40, height: 40))
        XCTAssertEqual(small.dropShadow?.distance, 5)
        XCTAssertEqual(small.dropShadow?.size, 5)

        var huge = LayerEffects()
        huge.add(.outerGlow, layerSize: CGSize(width: 20_000, height: 20_000))
        XCTAssertEqual(huge.outerGlow?.size, LayerEffects.Bounds.point.upperBound)

        // Re-adding an unchecked effect restores it rather than resizing it.
        large.dropShadow?.size = 3
        large.setOn(.dropShadow, false)
        large.add(.dropShadow, layerSize: CGSize(width: 900, height: 1200))
        XCTAssertEqual(large.dropShadow?.size, 3)
        XCTAssertTrue(large.isOn(.dropShadow))
    }

    /// At full layer opacity knockout must change nothing — the fill already
    /// covers the shadow. The old 1 − α mask thinned the shadow under soft
    /// edges and then drew the edge over it, leaving a light halo.
    func testKnockoutLeavesSoftEdgesUntouchedAtFullOpacity() throws {
        let size = 48
        let disc = GeneratedImages.image(width: size, height: size, colorSpace: p3) { x, y in
            let d = hypot(Double(x) + 0.5 - 24, Double(y) + 0.5 - 24)
            // A wide soft rim, like an app icon's built-in shadow.
            let alpha = min(max((20 - d) / 6, 0), 1)
            return (255, 255, 255, UInt8((alpha * 255).rounded()))
        }
        func render(knocksOut: Bool, opacity: Float) throws -> RawImage {
            var document = Document(canvasSize: CGSize(width: canvas, height: canvas))
            let backdrop = Layer(name: "grey",
                                 source: GeneratedImages.solid(width: Int(canvas), height: Int(canvas),
                                                               r: 128, g: 128, b: 128, colorSpace: p3))
            var layer = Layer(name: "disc", source: disc,
                              transform: CGAffineTransform(translationX: 16, y: 16))
            var shadow = DropShadowEffect()
            shadow.distance = 0
            shadow.size = 12
            shadow.opacity = 1
            shadow.blendMode = .normal
            shadow.knocksOut = knocksOut
            layer.effects.dropShadow = shadow
            layer.opacity = opacity
            document.layers = [backdrop, layer]
            return try self.render(document)
        }
        XCTAssertEqual(try render(knocksOut: true, opacity: 1).rgba,
                       try render(knocksOut: false, opacity: 1).rgba)

        // Translucent, knockout still hides the shadow under the layer's
        // solid middle. Analytic, in linear light (grey 128 ≈ 0.216):
        // knocked out, 50% white over the grey → 0.608 → 205 encoded;
        // shown through, 50% white over grey darkened by the 50% shadow
        // (0.108) → 0.554 → 196 encoded.
        let knocked = try render(knocksOut: true, opacity: 0.5)
        let through = try render(knocksOut: false, opacity: 0.5)
        XCTAssertEqual(Int(pixel(knocked, x: 40, y: 40).r), 205, accuracy: 2)
        XCTAssertEqual(Int(pixel(through, x: 40, y: 40).r), 196, accuracy: 2)
    }

    /// Merge Down is the one destructive op: the merged pixels must
    /// include the style, and the merged layer has to be big enough to hold a
    /// shadow that fell outside the original bounds.
    func testMergeDownBakesEffectsAndGrowsToFitThem() throws {
        var document = Document(canvasSize: CGSize(width: canvas, height: canvas))
        let backdrop = Layer(name: "white",
                             source: GeneratedImages.solid(width: Int(canvas), height: Int(canvas),
                                                           r: 255, g: 255, b: 255, colorSpace: p3))
        var top = Layer(name: "square",
                        source: GeneratedImages.solid(width: Int(square), height: Int(square),
                                                      r: 0, g: 0, b: 255, colorSpace: p3),
                        transform: CGAffineTransform(translationX: 24, y: 24))
        var shadow = DropShadowEffect()
        shadow.distance = 10
        shadow.size = 0
        shadow.opacity = 1
        shadow.usesGlobalLight = false
        shadow.angle = 120
        top.effects.dropShadow = shadow
        document.layers = [backdrop, top]

        let store = DocumentStore(document: document)
        store.selectLayer(top.id)
        store.mergeDownSelectedLayer()

        XCTAssertEqual(store.document.layers.count, 1)
        let merged = try XCTUnwrap(store.document.layers.first)
        XCTAssertTrue(merged.effects.isEmpty, "the style is baked, not carried")
        let image = try render(store.document)
        // The shadow fell down-right of the square and must survive the bake.
        XCTAssertLessThan(Int(pixel(image, x: 59, y: 20).r), 200)
    }

    func testSetOnKeepsParametersWhenUnchecked() {
        var effects = LayerEffects()
        effects.setOn(.dropShadow, true)
        effects.dropShadow?.distance = 42
        effects.setOn(.dropShadow, false)
        XCTAssertEqual(effects.dropShadow?.distance, 42)
        XCTAssertFalse(effects.isOn(.dropShadow))
        effects.setOn(.dropShadow, true)
        XCTAssertEqual(effects.dropShadow?.distance, 42)
        XCTAssertEqual(effects.activeKinds, [.dropShadow])
    }
}

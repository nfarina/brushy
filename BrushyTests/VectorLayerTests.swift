import AppKit
import CoreGraphics
import Foundation
import XCTest

final class VectorLayerTests: XCTestCase {
    // MARK: Rasterizer

    func testRectangleFillAndStroke() throws {
        var spec = ShapeSpec(kind: .rectangle)
        spec.size = CGSize(width: 120, height: 80)
        spec.fill = ColorSpec(r: 0, g: 0, b: 1)
        spec.stroke = ColorSpec(r: 1, g: 0, b: 0)
        spec.strokeWidth = 6
        let image = try XCTUnwrap(VectorRasterizer.render(shape: spec))
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 80)
        let pixels = try rawRGBA8(image, in: BrushyColorSpace.sRGB)
        let center = pixels[60, 40]
        XCTAssertGreaterThan(center.b, 240, "centre is filled blue")
        let edge = pixels[60, 5] // top edge sits within the stroke band
        XCTAssertGreaterThan(edge.r, 200, "edge is stroked red")
        XCTAssertEqual(pixels[0, 0].a, 0,
                       "the extreme corner outside the inset geometry is clear")
    }

    func testEllipseStaysWithinBounds() throws {
        var spec = ShapeSpec(kind: .ellipse)
        spec.size = CGSize(width: 100, height: 60)
        spec.fill = ColorSpec(r: 0, g: 0.8, b: 0.2)
        spec.stroke = nil
        let image = try XCTUnwrap(VectorRasterizer.render(shape: spec))
        let pixels = try rawRGBA8(image, in: BrushyColorSpace.sRGB)
        XCTAssertGreaterThan(pixels[50, 30].a, 250, "ellipse centre is filled")
        XCTAssertEqual(pixels[3, 3].a, 0, "ellipse corners are empty")
    }

    /// Solid lines are continuous; dashed/dotted lines have gaps.
    func testLineStyles() throws {
        func line(style: ShapeSpec.StrokeStyle) throws -> RawImage {
            var style1 = ShapeSpec(kind: .line)
            style1.stroke = .black
            style1.strokeWidth = 4
            style1.strokeStyle = style
            let (spec, _) = VectorRasterizer.shapeSpec(
                from: .null,
                lineFrom: CGPoint(x: 0, y: 50), lineTo: CGPoint(x: 200, y: 50),
                style: style1)
            let image = try XCTUnwrap(VectorRasterizer.render(shape: spec))
            return try rawRGBA8(image, in: BrushyColorSpace.sRGB)
        }
        func coveredColumns(_ pixels: RawImage) -> [Bool] {
            let midRow = pixels.height / 2
            return (0..<pixels.width).map { pixels[$0, midRow].a > 100 }
        }

        let solidCover = coveredColumns(try line(style: .solid))
        let solidRuns = runCount(solidCover)
        XCTAssertEqual(solidRuns, 1, "a solid line is one unbroken run")

        for style in [ShapeSpec.StrokeStyle.dashed, .dotted] {
            let cover = coveredColumns(try line(style: style))
            XCTAssertGreaterThan(runCount(cover), 4,
                                 "\(style) line must break into segments")
        }
    }

    private func runCount(_ covered: [Bool]) -> Int {
        var runs = 0
        var inRun = false
        for value in covered {
            if value && !inRun { runs += 1 }
            inRun = value
        }
        return runs
    }

    /// Arrowheads: wider than the shaft near the tips, on whichever ends are
    /// flagged.
    func testLineArrowCaps() throws {
        var style = ShapeSpec(kind: .line)
        style.stroke = .black
        style.strokeWidth = 4
        style.arrowStart = true
        style.arrowEnd = true
        let (spec, _) = VectorRasterizer.shapeSpec(
            from: .null,
            lineFrom: CGPoint(x: 0, y: 40), lineTo: CGPoint(x: 220, y: 40),
            style: style)
        let image = try XCTUnwrap(VectorRasterizer.render(shape: spec))
        let pixels = try rawRGBA8(image, in: BrushyColorSpace.sRGB)

        func verticalExtent(atX x: Int) -> Int {
            (0..<pixels.height).filter { pixels[x, $0].a > 100 }.count
        }
        let pad = Int(spec.padding.rounded())
        // Sample near the head's base, where the triangle is widest.
        let headX = pad + Int(spec.arrowLength * 0.85)
        let shaftX = pixels.width / 2
        let tailHeadX = pixels.width - pad - Int(spec.arrowLength * 0.85)
        XCTAssertGreaterThan(verticalExtent(atX: headX), verticalExtent(atX: shaftX) * 2,
                             "start arrowhead must flare wider than the shaft")
        XCTAssertGreaterThan(verticalExtent(atX: tailHeadX), verticalExtent(atX: shaftX) * 2,
                             "end arrowhead must flare wider than the shaft")

        // Single-ended arrow: only the flagged end flares.
        style.arrowStart = false
        let (single, _) = VectorRasterizer.shapeSpec(
            from: .null,
            lineFrom: CGPoint(x: 0, y: 40), lineTo: CGPoint(x: 220, y: 40),
            style: style)
        let singleImage = try XCTUnwrap(VectorRasterizer.render(shape: single))
        let singlePixels = try rawRGBA8(singleImage, in: BrushyColorSpace.sRGB)
        func extent(_ raw: RawImage, _ x: Int) -> Int {
            (0..<raw.height).filter { raw[x, $0].a > 100 }.count
        }
        XCTAssertLessThanOrEqual(extent(singlePixels, headX), Int(style.strokeWidth) + 3,
                                 "unflagged end stays shaft-width")
    }

    func testTextRendersAndGrowsWithContent() throws {
        var spec = TextSpec()
        spec.text = "Hello"
        spec.fontSize = 48
        spec.color = ColorSpec(r: 0.9, g: 0.1, b: 0.1)
        let oneLine = try XCTUnwrap(VectorRasterizer.render(text: spec))
        let pixels = try rawRGBA8(oneLine, in: BrushyColorSpace.sRGB)
        var inked = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].a > 100 { inked += 1 }
        }
        XCTAssertGreaterThan(inked, 200, "text must actually render glyphs")

        spec.text = "Hello\nWorld\nAgain"
        let threeLines = try XCTUnwrap(VectorRasterizer.render(text: spec))
        XCTAssertGreaterThan(threeLines.height, oneLine.height * 2,
                             "multiline text grows vertically")
    }

    /// The shared TextKit stack must agree with the committed raster on size,
    /// across fonts (incl. a missing-font fallback), sizes and line structures.
    func testTextLayoutMeasureMatchesRasterDimensions() throws {
        var specs: [TextSpec] = []
        for (font, size, text) in [
            ("Helvetica Neue", 9.0, "small"),
            ("Helvetica Neue", 64.0, "Hello"),
            ("Menlo", 300.0, "Big"),
            ("NoSuchFont-Xyz", 48.0, "fallback"),
            ("Helvetica Neue", 40.0, "multi\nline\ntext"),
            ("Helvetica Neue", 40.0, "trailing newline\n"),
            ("Helvetica Neue", 40.0, "spaced   out   runs"),
        ] {
            var spec = TextSpec()
            spec.fontName = font
            spec.fontSize = size
            spec.text = text
            specs.append(spec)
        }
        for spec in specs {
            let (width, height) = TextLayout.paddedPixelSize(for: TextLayout.measure(spec))
            let image = try XCTUnwrap(VectorRasterizer.render(text: spec))
            XCTAssertEqual(image.width, width, "width mismatch for \(spec.text)")
            XCTAssertEqual(image.height, height, "height mismatch for \(spec.text)")
        }
    }

    /// The strong guarantee behind in-place editing: an NSTextView built on
    /// the shared TextKit system draws byte-identically to the committed
    /// raster. (NSTextView is fully constructible and drawable without a
    /// window.)
    func testEditorLayoutIsBitmapIdenticalToCommittedRaster() throws {
        var spec = TextSpec()
        spec.text = "Parity 123\nsecond line"
        spec.fontName = "Helvetica Neue"
        spec.fontSize = 52
        spec.color = ColorSpec(r: 0.1, g: 0.3, b: 0.9)

        let committed = try XCTUnwrap(VectorRasterizer.render(text: spec))

        // Editor-side: same factory, hosted in a real NSTextView. The storage
        // must be held — nothing downstream retains it.
        let (storage, layoutManager, container) = TextLayout.makeTextSystem(for: spec)
        let textView = NSTextView(frame: CGRect(origin: .zero, size: TextLayout.containerSize),
                                  textContainer: container)
        textView.textContainerInset = .zero
        let used = TextLayout.usedSize(layoutManager, container)
        let (width, height) = TextLayout.paddedPixelSize(for: used)
        XCTAssertEqual(width, committed.width)
        XCTAssertEqual(height, committed.height)

        var editorPixels = [UInt8](repeating: 0, count: width * height * 4)
        editorPixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: BrushyColorSpace.displayP3,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                XCTFail("context"); return
            }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let glyphs = layoutManager.glyphRange(for: container)
            let origin = CGPoint(x: TextLayout.padding, y: TextLayout.padding)
            layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
        }
        let committedPixels = try rawRGBA8(committed)
        XCTAssertEqual(committedPixels.rgba, editorPixels,
                       "editor drawing must be glyph-identical to the committed raster")
        // Guard against the vacuous-pass failure mode: both sides empty.
        XCTAssertGreaterThan(editorPixels.filter { $0 != 0 }.count, 1000,
                             "parity comparison must involve real glyphs")
        withExtendedLifetime(storage) {}
        _ = textView // kept alive: the container is owned by the view
    }

    // MARK: Store operations

    func testShapeCreationEditAndUndo() {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 400, height: 300)))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager

        store.shapeStyle.kind = .rectangle
        store.shapeStyle.fill = ColorSpec(r: 0, g: 0.5, b: 1)
        store.shapeStyle.stroke = nil
        undoManager.beginUndoGrouping()
        store.addShapeLayer(dragRect: CGRect(x: 100, y: 80, width: 120, height: 60),
                            lineFrom: nil, lineTo: nil)
        undoManager.endUndoGrouping()

        XCTAssertEqual(store.document.layers.count, 1)
        let created = store.document.layers[0]
        XCTAssertNotNil(created.kind.shapeSpec)
        XCTAssertEqual(undoManager.undoActionName, "New Shape Layer")
        // Content box = drag rect inflated by padding; drawn geometry lands on
        // the drag rect.
        let pad = CGFloat(created.kind.shapeSpec!.padding)
        XCTAssertEqual(created.canvasBounds.minX, 100 - pad, accuracy: 0.5)
        XCTAssertEqual(created.canvasBounds.maxY, 140 + pad, accuracy: 0.5)

        // Editing stroke width re-renders but keeps the shape centred.
        let centerBefore = created.canvasBounds.center
        undoManager.beginUndoGrouping()
        store.updateSelectedShape { $0.stroke = .black; $0.strokeWidth = 12 }
        undoManager.endUndoGrouping()
        let edited = store.document.layers[0]
        XCTAssertEqual(edited.canvasBounds.center.x, centerBefore.x, accuracy: 1)
        XCTAssertEqual(edited.canvasBounds.center.y, centerBefore.y, accuracy: 1)
        XCTAssertEqual(edited.kind.shapeSpec?.strokeWidth, 12)
        XCTAssertEqual(undoManager.undoActionName, "Edit Shape")

        undoManager.undo()
        XCTAssertNil(store.document.layers[0].kind.shapeSpec?.stroke)
        undoManager.undo()
        XCTAssertTrue(store.document.layers.isEmpty)
    }

    /// Editing text keeps the top-left anchored — text grows downward like a
    /// text box, even though canvas space is y-up.
    func testTextEditKeepsTopLeftAnchored() {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 600, height: 400)))
        var spec = TextSpec()
        spec.text = "One"
        spec.fontSize = 40
        store.insertTextLayer(spec, topLeftAt: CGPoint(x: 50, y: 300))

        let created = store.document.layers[0]
        XCTAssertNotNil(created.kind.textSpec)
        let topBefore = created.canvasBounds.maxY
        let leftBefore = created.canvasBounds.minX
        XCTAssertEqual(topBefore, 300, accuracy: 0.5, "click point is the text top-left")
        XCTAssertEqual(leftBefore, 50, accuracy: 0.5)

        // Edit through a real inline session.
        store.beginTextSession(editing: created.id, caretAt: nil)
        store.updateTextSessionText("One\nTwo\nThree\nFour")
        store.commitTextSession()
        let edited = store.document.layers[0]
        XCTAssertEqual(edited.canvasBounds.maxY, topBefore, accuracy: 0.5,
                       "top edge stays put when text grows")
        XCTAssertEqual(edited.canvasBounds.minX, leftBefore, accuracy: 0.5)
        XCTAssertGreaterThan(edited.source.height, created.source.height * 2)
        XCTAssertEqual(edited.kind.textSpec?.text, "One\nTwo\nThree\nFour")
    }

    func testVectorLayersSurviveSaveAndReopen() throws {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 400, height: 300)))
        var lineStyle = ShapeSpec(kind: .line)
        lineStyle.stroke = ColorSpec(r: 1, g: 0.2, b: 0)
        lineStyle.strokeWidth = 5
        lineStyle.strokeStyle = .dotted
        lineStyle.arrowEnd = true
        store.shapeStyle = lineStyle
        store.addShapeLayer(dragRect: .null,
                            lineFrom: CGPoint(x: 40, y: 60), lineTo: CGPoint(x: 300, y: 200))

        var text = TextSpec()
        text.text = "Label"
        text.fontSize = 32
        store.insertTextLayer(text, topLeftAt: CGPoint(x: 30, y: 250))

        let wrapper = try DocumentSerializer().fileWrapper(for: store.document)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vector-\(UUID().uuidString).brushy")
        try wrapper.write(to: temp, options: .atomic, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let restored = try DocumentSerializer().document(from: FileWrapper(url: temp))

        XCTAssertEqual(restored.layers.count, 2)
        let restoredLine = try XCTUnwrap(restored.layers[0].kind.shapeSpec)
        XCTAssertEqual(restoredLine.kind, .line)
        XCTAssertEqual(restoredLine.strokeStyle, .dotted)
        XCTAssertTrue(restoredLine.arrowEnd)
        XCTAssertFalse(restoredLine.arrowStart)
        XCTAssertEqual(restoredLine.strokeWidth, 5)
        let restoredText = try XCTUnwrap(restored.layers[1].kind.textSpec)
        XCTAssertEqual(restoredText.text, "Label")
        XCTAssertEqual(restoredText.fontSize, 32)
    }

    // MARK: - Metadata survives re-rasterisation

    /// Editing a vector layer re-renders its pixels and nothing else, so every
    /// property that isn't pixels has to come through unchanged.
    ///
    /// `updateVectorLayer` rebuilds the layer by listing constructor
    /// arguments, and the four below were simply not listed — so they reset to
    /// their defaults. Editing the text of a grouped, clipped, styled layer
    /// dropped it out of its group, released the clipping mask and cleared the
    /// style, all in one keystroke.
    /// Grouping wraps a single layer, and a lone layer in a group has nothing
    /// below it to clip to — so `normalizingClipping` releases the flag. Group
    /// membership and clipping therefore get one test each rather than one
    /// test that fights the model's invariants.
    private func storeWithStyledTextLayer() throws -> (DocumentStore, UUID) {
        let store = DocumentStore(document: Document(canvasSize: CGSize(width: 600, height: 400)))
        store.addPaintLayer()
        var spec = TextSpec()
        spec.text = "One"
        spec.fontSize = 40
        store.insertTextLayer(spec, topLeftAt: CGPoint(x: 50, y: 300))
        let textID = try XCTUnwrap(store.document.layers.last?.id)
        store.setLayerBlendMode(textID, .multiply)
        var effects = LayerEffects()
        var shadow = DropShadowEffect()
        shadow.isEnabled = true
        effects.dropShadow = shadow
        store.setLayerEffects(textID, effects)
        return (store, textID)
    }

    private func editText(_ store: DocumentStore, _ id: UUID) {
        store.beginTextSession(editing: id, caretAt: nil)
        store.updateTextSessionText("One\nTwo")
        store.commitTextSession()
    }

    func testEditingATextLayerKeepsItsGroupBlendModeAndStyle() throws {
        let (store, textID) = try storeWithStyledTextLayer()
        store.selectedLayerID = textID
        store.groupSelection()

        let before = try XCTUnwrap(store.document[layerID: textID])
        let groupID = try XCTUnwrap(before.groupID, "the layer must actually be grouped")
        XCTAssertEqual(before.blendMode, .multiply)
        XCTAssertFalse(before.effects.isEmpty)

        editText(store, textID)

        let after = try XCTUnwrap(store.document[layerID: textID])
        XCTAssertNotEqual(after.sourceID, before.sourceID, "pixels changed: fresh sourceID")
        XCTAssertEqual(after.groupID, groupID, "group membership must survive the edit")
        XCTAssertEqual(after.blendMode, .multiply, "blend mode must survive the edit")
        XCTAssertEqual(after.effects, before.effects, "layer style must survive the edit")
    }

    func testEditingATextLayerKeepsItsClippingMask() throws {
        let (store, textID) = try storeWithStyledTextLayer()
        store.toggleClippingMask(textID)

        let before = try XCTUnwrap(store.document[layerID: textID])
        XCTAssertTrue(before.isClippedToBelow, "setup: the layer must actually be clipped")

        editText(store, textID)

        let after = try XCTUnwrap(store.document[layerID: textID])
        XCTAssertTrue(after.isClippedToBelow, "clipping must survive the edit")
    }

    /// Copy carries the style: `effects` is a property of the layer, unlike
    /// clipping and group membership, which are relationships with the stack
    /// it is leaving.
    func testCopiedLayerCarriesItsStyleThroughThePasteboard() throws {
        var layer = Layer(name: "Styled",
                          source: GeneratedImages.solid(width: 32, height: 24,
                                                        r: 10, g: 200, b: 90,
                                                        colorSpace: BrushyColorSpace.sRGB))
        var effects = LayerEffects()
        var shadow = DropShadowEffect()
        shadow.isEnabled = true
        shadow.size = 17
        effects.dropShadow = shadow
        layer.effects = effects
        layer.isClippedToBelow = true

        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(LayerPasteboard.write(layer: layer,
                                            canvasSize: CGSize(width: 100, height: 100),
                                            renderedImage: layer.source, to: pasteboard))
        guard case .layer(let envelope) = LayerPasteboard.read(from: pasteboard) else {
            return XCTFail("expected the private layer flavour")
        }
        let pasted = try XCTUnwrap(LayerPasteboard.layer(from: envelope))
        XCTAssertEqual(pasted.effects.dropShadow?.size, 17, "style must ride the clipboard")
        XCTAssertFalse(pasted.isClippedToBelow, "clipping is a relationship, not a property")
        XCTAssertNil(pasted.groupID, "group membership is a relationship, not a property")
    }

    /// Same rule across documents: Duplicate Layer To keeps the style and
    /// deliberately drops the relationships.
    func testCrossDocumentDuplicateKeepsTheStyle() throws {
        let source = DocumentStore(document: Document(canvasSize: CGSize(width: 200, height: 200)))
        var layer = Layer(name: "Styled",
                          source: GeneratedImages.solid(width: 32, height: 24,
                                                        r: 10, g: 200, b: 90,
                                                        colorSpace: BrushyColorSpace.sRGB))
        var effects = LayerEffects()
        var shadow = DropShadowEffect()
        shadow.isEnabled = true
        shadow.size = 23
        effects.dropShadow = shadow
        layer.effects = effects
        source.replaceDocument({
            var doc = Document(canvasSize: CGSize(width: 200, height: 200))
            doc.layers = [layer]
            return doc
        }())

        let target = DocumentStore(document: Document(canvasSize: CGSize(width: 200, height: 200)))
        target.receiveLayer(try XCTUnwrap(source.document.layers.first),
                            from: source.document.canvasSize)

        let received = try XCTUnwrap(target.document.layers.last)
        XCTAssertEqual(received.effects.dropShadow?.size, 23,
                       "style must survive a cross-document duplicate")
        XCTAssertNil(received.groupID)
        XCTAssertFalse(received.isClippedToBelow)
    }
}

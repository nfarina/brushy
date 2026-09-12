import CoreGraphics
import XCTest
@testable import Dezzy

/// The op interpreter over `Document` values (§2), and the top-left ↔ canvas
/// flip it hides. No JavaScript involved: these pin the semantics a script
/// (or a model) relies on.
final class ScriptSessionTests: XCTestCase {
    /// 400×300 canvas; three 100×80 layers A, B, C at canvas (10,20), (150,20), (290,20).
    private func makeSession() -> ScriptSession {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        let p3 = DezzyColorSpace.displayP3
        for (i, name) in ["A", "B", "C"].enumerated() {
            var layer = Layer(name: name,
                              source: GeneratedImages.solid(width: 100, height: 80,
                                                            r: UInt8(60 * i + 40), g: 80, b: 120,
                                                            colorSpace: p3))
            layer.transform = CGAffineTransform(translationX: CGFloat(10 + i * 140), y: 20)
            document.layers.append(layer)
        }
        let wd = ScriptSession.working(id: "doc1", title: "Test", document: document)
        var counter = 1
        return ScriptSession(documents: [wd], activeID: "doc1",
                             reserveDocumentID: { counter += 1; return "doc\(counter)" })
    }

    private func frame(_ session: ScriptSession, _ ref: String) throws -> CGRect {
        let state = try session.perform(["op": "state", "doc": "doc1"]) as! [String: Any]
        let layers = state["layers"] as! [[String: Any]]
        let layer = try XCTUnwrap(layers.first { $0["name"] as? String == ref || $0["id"] as? String == ref })
        let f = layer["frame"] as! [String: Double]
        return CGRect(x: f["x"]!, y: f["y"]!, width: f["width"]!, height: f["height"]!)
    }

    private func doc(_ session: ScriptSession) -> Document { session.documents[0].document }

    func testStateUsesTopLeftCoordinates() throws {
        let session = makeSession()
        // Canvas y 20…100 in a 300-tall canvas → top-left y = 300 − 100 = 200.
        XCTAssertEqual(try frame(session, "A"), CGRect(x: 10, y: 200, width: 100, height: 80))
        let state = try session.perform(["op": "state", "doc": "doc1"]) as! [String: Any]
        XCTAssertEqual(state["width"] as? Int, 400)
        XCTAssertEqual(state["height"] as? Int, 300)
        let ids = (state["layers"] as! [[String: Any]]).map { $0["id"] as! String }
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("l") && $0.count == 7 })
    }

    func testMoveDownIncreasesTopLeftY() throws {
        let session = makeSession()
        _ = try session.perform(["op": "move", "doc": "doc1", "layer": "A", "dx": 5, "dy": 10])
        XCTAssertEqual(try frame(session, "A"), CGRect(x: 15, y: 210, width: 100, height: 80))
        XCTAssertTrue(session.documents[0].isTouched)
    }

    func testSetFramePositionOnlyKeepsRotation() throws {
        let session = makeSession()
        _ = try session.perform(["op": "rotate", "doc": "doc1", "layer": "A", "degrees": 90])
        var state = try session.perform(["op": "state", "doc": "doc1"]) as! [String: Any]
        var a = (state["layers"] as! [[String: Any]])[0]
        XCTAssertEqual(try XCTUnwrap(a["rotation"] as? Double), 90, accuracy: 0.001)
        _ = try session.perform(["op": "setFrame", "doc": "doc1", "layer": "A", "x": 0, "y": 0])
        state = try session.perform(["op": "state", "doc": "doc1"]) as! [String: Any]
        a = (state["layers"] as! [[String: Any]])[0]
        XCTAssertEqual(try XCTUnwrap(a["rotation"] as? Double), 90, accuracy: 0.001)
        let f = try frame(session, "A")
        XCTAssertEqual(f.origin, .zero)
        // A 100×80 layer rotated 90° has an 80×100 bounding box.
        XCTAssertEqual(f.size.width, 80, accuracy: 0.01)
        XCTAssertEqual(f.size.height, 100, accuracy: 0.01)
    }

    func testSetFrameSizeRebuildsAxisAligned() throws {
        let session = makeSession()
        _ = try session.perform(["op": "setFrame", "doc": "doc1", "layer": "B",
                                 "x": 0, "y": 0, "width": 200, "height": 40])
        XCTAssertEqual(try frame(session, "B"), CGRect(x: 0, y: 0, width: 200, height: 40))
        let layer = doc(session).layers[1]
        XCTAssertEqual(layer.transform.a, 2, accuracy: 0.0001)
        XCTAssertEqual(layer.transform.d, 0.5, accuracy: 0.0001)
        XCTAssertEqual(layer.transform.b, 0)
    }

    func testArrangeHorizontalWithGap() throws {
        let session = makeSession()
        _ = try session.perform(["op": "arrange", "doc": "doc1", "layers": ["C", "A", "B"],
                                 "direction": "horizontal", "gap": 20, "x": 0, "y": 0])
        XCTAssertEqual(try frame(session, "C"), CGRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(try frame(session, "A"), CGRect(x: 120, y: 0, width: 100, height: 80))
        XCTAssertEqual(try frame(session, "B"), CGRect(x: 240, y: 0, width: 100, height: 80))
    }

    func testArrangeVerticalCenterAligned() throws {
        let session = makeSession()
        _ = try session.perform(["op": "setFrame", "doc": "doc1", "layer": "B", "width": 50, "height": 40])
        _ = try session.perform(["op": "arrange", "doc": "doc1", "layers": ["A", "B"],
                                 "direction": "vertical", "gap": 10, "align": "center", "x": 0, "y": 0])
        XCTAssertEqual(try frame(session, "A"), CGRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(try frame(session, "B"), CGRect(x: 25, y: 90, width: 50, height: 40))
    }

    func testFitCanvasToContentWithPadding() throws {
        let session = makeSession()
        _ = try session.perform(["op": "fitCanvasToContent", "doc": "doc1", "padding": 10])
        // Content spans canvas x 10…390, y 20…100 → 380×80, plus 10 each side.
        XCTAssertEqual(doc(session).canvasSize, CGSize(width: 400, height: 100))
        XCTAssertEqual(try frame(session, "A"), CGRect(x: 10, y: 10, width: 100, height: 80))
    }

    func testResizeCanvasAnchors() throws {
        let session = makeSession()
        _ = try session.perform(["op": "resizeCanvas", "doc": "doc1", "width": 500, "height": 400,
                                 "anchor": "top-left"])
        XCTAssertEqual(doc(session).canvasSize, CGSize(width: 500, height: 400))
        // Top-left anchored: content keeps its top-left position.
        XCTAssertEqual(try frame(session, "A"), CGRect(x: 10, y: 200, width: 100, height: 80))
    }

    func testAddTextLayerLandsAtTopLeft() throws {
        let session = makeSession()
        let result = try session.perform(["op": "addTextLayer", "doc": "doc1", "text": "Hello",
                                          "x": 30, "y": 40, "fontSize": 24, "color": "#ff0000"]) as! [String: Any]
        let id = try XCTUnwrap(result["id"] as? String)
        let f = try frame(session, id)
        XCTAssertEqual(f.origin, CGPoint(x: 30, y: 40))
        let layer = try XCTUnwrap(doc(session).layers.last)
        XCTAssertEqual(layer.name, "Hello")
        XCTAssertEqual(layer.kind.textSpec?.fontSize, 24)
        XCTAssertEqual(layer.kind.textSpec?.color, ColorSpec(r: 1, g: 0, b: 0))
        XCTAssertEqual(session.documents[0].selectedLayerIDs, [layer.id])
    }

    func testSetTextKeepsTopLeft() throws {
        let session = makeSession()
        let id = ((try session.perform(["op": "addTextLayer", "doc": "doc1", "text": "Hi", "x": 30, "y": 40]))
            as! [String: Any])["id"] as! String
        _ = try session.perform(["op": "setText", "doc": "doc1", "layer": id, "text": "Hello there\nworld", "fontSize": 96])
        let f = try frame(session, id)
        XCTAssertEqual(f.origin, CGPoint(x: 30, y: 40))
        XCTAssertEqual(doc(session).layers.last?.kind.textSpec?.text, "Hello there\nworld")
        XCTAssertGreaterThan(f.height, 100)
    }

    func testAddShapeAndSolidLayer() throws {
        let session = makeSession()
        let shape = (try session.perform(["op": "addShapeLayer", "doc": "doc1", "kind": "ellipse",
                                          "x": 10, "y": 10, "width": 50, "height": 30,
                                          "fill": "blue", "stroke": NSNull()]) as! [String: Any])["id"] as! String
        let f = try frame(session, shape)
        // Padding grows the raster symmetrically around the requested rect.
        XCTAssertEqual(f.midX, 35, accuracy: 0.5)
        XCTAssertEqual(f.midY, 25, accuracy: 0.5)
        XCTAssertNil(doc(session).layers.last?.kind.shapeSpec?.stroke)
        let solid = (try session.perform(["op": "addLayer", "doc": "doc1", "color": "white",
                                          "x": 0, "y": 0, "width": 400, "height": 300, "name": "BG"]) as! [String: Any])["id"] as! String
        XCTAssertEqual(try frame(session, solid), CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(doc(session).layers.last!.isPaintable)
        _ = try session.perform(["op": "reorder", "doc": "doc1", "layer": "BG", "to": "back"])
        XCTAssertEqual(doc(session).layers.first?.name, "BG")
    }

    func testGroupGathersLayersContiguously() throws {
        let session = makeSession()
        let result = try session.perform(["op": "group", "doc": "doc1", "layers": ["A", "C"], "name": "Pair"]) as! [String: Any]
        let gid = try XCTUnwrap(result["id"] as? String)
        XCTAssertTrue(gid.hasPrefix("g"))
        let names = doc(session).layers.map(\.name)
        XCTAssertEqual(names, ["B", "A", "C"])
        let group = try XCTUnwrap(doc(session).groups.first)
        XCTAssertEqual(group.name, "Pair")
        XCTAssertEqual(doc(session).layers.filter { $0.groupID == group.id }.map(\.name), ["A", "C"])
        _ = try session.perform(["op": "ungroup", "doc": "doc1", "group": "Pair"])
        XCTAssertTrue(doc(session).groups.isEmpty)
    }

    func testDeleteAndReorder() throws {
        let session = makeSession()
        _ = try session.perform(["op": "setSelectedLayers", "doc": "doc1", "layers": ["A", "B"]])
        _ = try session.perform(["op": "delete", "doc": "doc1", "layer": "A"])
        XCTAssertEqual(doc(session).layers.map(\.name), ["B", "C"])
        XCTAssertEqual(session.documents[0].selectedLayerIDs.count, 1)
        _ = try session.perform(["op": "reorder", "doc": "doc1", "layer": "B", "to": "front"])
        XCTAssertEqual(doc(session).layers.map(\.name), ["C", "B"])
        _ = try session.perform(["op": "reorder", "doc": "doc1", "layer": "B", "below": "C"])
        XCTAssertEqual(doc(session).layers.map(\.name), ["B", "C"])
    }

    func testLayerLookupByNameIsCaseInsensitiveFallback() throws {
        let session = makeSession()
        _ = try session.perform(["op": "move", "doc": "doc1", "layer": "a", "dx": 1, "dy": 0])
        XCTAssertEqual(try frame(session, "A").minX, 11)
        XCTAssertThrowsError(try session.perform(["op": "move", "doc": "doc1", "layer": "nope", "dx": 1, "dy": 0])) {
            XCTAssertTrue("\($0)".contains("No layer \"nope\""))
        }
    }

    func testSelectionAndMaskAndFill() throws {
        let session = makeSession()
        _ = try session.perform(["op": "select", "doc": "doc1", "x": 0, "y": 0, "width": 60, "height": 300])
        let sel = session.documents[0].selection
        XCTAssertEqual(sel.path?.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 60, height: 300))
        _ = try session.perform(["op": "addMask", "doc": "doc1", "layer": "A", "from": "selection"])
        let mask = try XCTUnwrap(doc(session).layers[0].mask)
        // Layer A spans canvas x 10…110; the selection covers x < 60 → the
        // left half of the mask is white, the right half black.
        let row = mask.texture.data.withUnsafeBytes { Array($0[0..<100]) }
        XCTAssertEqual(row[10], 255)
        XCTAssertEqual(row[90], 0)
        // Filling an imported layer is refused; a paint layer takes it.
        XCTAssertThrowsError(try session.perform(["op": "fill", "doc": "doc1", "layer": "A", "color": "red"]))
        let paint = (try session.perform(["op": "addLayer", "doc": "doc1", "name": "Paint"]) as! [String: Any])["id"] as! String
        let before = doc(session).layers.last!.sourceID
        _ = try session.perform(["op": "fill", "doc": "doc1", "layer": paint, "color": "#00ff00"])
        let filled = doc(session).layers.last!
        XCTAssertNotEqual(filled.sourceID, before)
        let pixels = try rawRGBA8(filled.source)
        XCTAssertEqual(pixels[30, 150].a, 255)   // inside the selection
        XCTAssertEqual(pixels[200, 150].a, 0)    // outside
    }

    func testNewDocumentAndCopyLayers() throws {
        let session = makeSession()
        let created = try session.perform(["op": "newDocument", "width": 800, "height": 600, "name": "Fresh"]) as! [String: Any]
        XCTAssertEqual(created["id"] as? String, "doc2")
        let ids = try session.perform(["op": "copyLayers", "doc": "doc1", "layers": ["A", "B"], "to": "doc2",
                                       "x": 0, "y": 0]) as! [String]
        XCTAssertEqual(ids.count, 2)
        let fresh = session.documents[1]
        XCTAssertTrue(fresh.isNew)
        XCTAssertEqual(fresh.document.layers.map(\.name), ["A", "B"])
        let a = ScriptGeometry.topLeft(fresh.document.layers[0].canvasBounds, canvasHeight: 600)
        XCTAssertEqual(a.origin, .zero)
        XCTAssertEqual(session.touchedDocuments.map(\.id), ["doc2"])
    }

    func testChangeSummary() throws {
        let session = makeSession()
        XCTAssertEqual(ScriptSession.changeSummary(session.documents[0]), "no visible change")
        _ = try session.perform(["op": "move", "doc": "doc1", "layer": "A", "dx": 1, "dy": 0])
        _ = try session.perform(["op": "delete", "doc": "doc1", "layer": "C"])
        _ = try session.perform(["op": "addTextLayer", "doc": "doc1", "text": "New"])
        _ = try session.perform(["op": "fitCanvasToContent", "doc": "doc1"])
        let summary = ScriptSession.changeSummary(session.documents[0])
        XCTAssertTrue(summary.contains("canvas 400×300 →"), summary)
        XCTAssertTrue(summary.contains("added \"New\""), summary)
        XCTAssertTrue(summary.contains("removed \"C\""), summary)
        XCTAssertTrue(summary.contains("changed \"A\""), summary)
    }

    func testFillGradientRampsBetweenStops() throws {
        let session = makeSession()
        let added = try session.perform(["op": "addLayer", "doc": "doc1", "name": "G", "color": "white",
                                         "x": 0, "y": 0, "width": 100, "height": 100]) as! [String: Any]
        _ = try session.perform(["op": "fillGradient", "doc": "doc1", "layer": added["id"]!,
                                 "stops": ["#ff0000", "#0000ff"], "from": [0, 0], "to": [0, 100]])
        let layer = try XCTUnwrap(session.documents[0].document.layers.last)
        let pixels = try rawRGBA8(layer.source, in: DezzyColorSpace.sRGB)
        let top = pixels[50, 1], bottom = pixels[50, 98], middle = pixels[50, 50]
        XCTAssertGreaterThan(top.r, 220); XCTAssertLessThan(top.b, 40)
        XCTAssertGreaterThan(bottom.b, 220); XCTAssertLessThan(bottom.r, 40)
        XCTAssertGreaterThan(middle.r, 80); XCTAssertGreaterThan(middle.b, 80)
        XCTAssertNotEqual(layer.sourceID, session.documents[0].base.layers.last?.sourceID)
        // Stops with offsets, radial, and an imported layer are all covered by the argument parsing.
        _ = try session.perform(["op": "fillGradient", "doc": "doc1", "layer": added["id"]!, "shape": "radial",
                                 "stops": [["offset": 0, "color": "white"], ["offset": 1, "color": "black"]]])
        XCTAssertThrowsError(try session.perform(["op": "fillGradient", "doc": "doc1", "layer": "A",
                                                  "stops": ["red", "blue"]]))
        XCTAssertThrowsError(try session.perform(["op": "fillGradient", "doc": "doc1", "layer": added["id"]!,
                                                  "stops": ["red"]]))
    }

    func testFillGradientRespectsSelection() throws {
        let session = makeSession()
        let added = try session.perform(["op": "addLayer", "doc": "doc1", "name": "G", "color": "white",
                                         "x": 0, "y": 0, "width": 100, "height": 100]) as! [String: Any]
        _ = try session.perform(["op": "select", "doc": "doc1", "x": 0, "y": 0, "width": 50, "height": 100])
        _ = try session.perform(["op": "fillGradient", "doc": "doc1", "layer": added["id"]!,
                                 "stops": ["black", "black"]])
        let layer = try XCTUnwrap(session.documents[0].document.layers.last)
        let pixels = try rawRGBA8(layer.source, in: DezzyColorSpace.sRGB)
        XCTAssertLessThan(pixels[10, 50].r, 10)
        XCTAssertGreaterThan(pixels[90, 50].r, 245)
    }

    func testLayerBudgetStopsRunawayScripts() throws {
        let session = makeSession()
        for _ in 0..<ScriptSession.maxAddedLayersPerScript {
            _ = try session.perform(["op": "addTextLayer", "doc": "doc1", "text": "X"])
        }
        XCTAssertThrowsError(try session.perform(["op": "addTextLayer", "doc": "doc1", "text": "X"])) { error in
            XCTAssertTrue("\(error)".contains("fillGradient"), "\(error)")
        }
    }

    func testChangeSummaryCollapsesLongLists() throws {
        let session = makeSession()
        for _ in 0..<12 { _ = try session.perform(["op": "addTextLayer", "doc": "doc1", "text": "X"]) }
        _ = try session.perform(["op": "addTextLayer", "doc": "doc1", "text": "Y"])
        let summary = ScriptSession.changeSummary(session.documents[0])
        XCTAssertTrue(summary.contains("added 13 layers: \"X\" ×12, \"Y\""), summary)
        XCTAssertEqual(ScriptSession.nameList(["A", "B"]), "\"A\", \"B\"")
    }

    // MARK: - draw (Canvas 2D replay)

    /// A white 100×100 paint layer whose top-left sits at `origin` (canvas coordinates).
    private func addWhiteLayer(_ session: ScriptSession, origin: CGPoint = .zero) throws -> String {
        let added = try session.perform(["op": "addLayer", "doc": "doc1", "name": "P", "color": "white",
                                         "x": origin.x, "y": origin.y, "width": 100, "height": 100]) as! [String: Any]
        return added["id"] as! String
    }

    private func pixels(_ session: ScriptSession) throws -> RawImage {
        try rawRGBA8(try XCTUnwrap(session.documents[0].document.layers.last).source, in: DezzyColorSpace.sRGB)
    }

    private func draw(_ session: ScriptSession, _ id: String, _ commands: [[Any]]) throws {
        _ = try session.perform(["op": "draw", "doc": "doc1", "layer": id, "commands": commands])
    }

    private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 220 && p.g < 60 && p.b < 60 }
    private func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 245 && p.g > 245 && p.b > 245 }

    func testDrawFillRectAndArc() throws {
        let session = makeSession()
        let id = try addWhiteLayer(session)
        try draw(session, id, [["fillStyle", "red"], ["fillRect", 0, 0, 50, 100],
                               ["beginPath"], ["arc", 75, 50, 15, 0, Double.pi * 2, false],
                               ["fillStyle", "#0000ff"], ["fill"]])
        let px = try pixels(session)
        XCTAssertTrue(isRed(px[10, 50]), "\(px[10, 50])")
        XCTAssertTrue(px[75, 50].b > 220 && px[75, 50].r < 60, "\(px[75, 50])")
        XCTAssertTrue(isWhite(px[95, 5]), "\(px[95, 5])")
        XCTAssertTrue(isWhite(px[75, 20]), "outside the circle: \(px[75, 20])")
        XCTAssertNotEqual(session.documents[0].document.layers.last?.sourceID,
                          session.documents[0].base.layers.last?.sourceID)
    }

    func testDrawUsesCanvasCoordinatesForOffsetLayer() throws {
        let session = makeSession()
        let id = try addWhiteLayer(session, origin: CGPoint(x: 200, y: 100))
        try draw(session, id, [["fillStyle", "red"], ["fillRect", 200, 100, 50, 50]])
        let px = try pixels(session)
        XCTAssertTrue(isRed(px[10, 10]), "\(px[10, 10])")
        XCTAssertTrue(isWhite(px[90, 90]), "\(px[90, 90])")
        XCTAssertTrue(isWhite(px[10, 90]), "y must not be flipped: \(px[10, 90])")
    }

    func testDrawGradientFill() throws {
        let session = makeSession()
        let id = try addWhiteLayer(session)
        let gradient: [String: Any] = ["kind": "linear", "x0": 0, "y0": 0, "x1": 100, "y1": 0,
                                       "stops": [[0, "white"], [1, "black"]]]
        try draw(session, id, [["fillStyle", gradient], ["fillRect", 0, 0, 100, 100]])
        let px = try pixels(session)
        XCTAssertGreaterThan(px[3, 50].r, 200)
        XCTAssertLessThan(px[96, 50].r, 60)
        XCTAssertLessThan(px[96, 50].r, px[50, 50].r)
    }

    func testDrawTextLandsOnTheBaseline() throws {
        let session = makeSession()
        let id = try addWhiteLayer(session)
        try draw(session, id, [["font", "bold 40px Helvetica"], ["fillText", "HHHH", 5, 80]])
        let px = try pixels(session)
        func dark(rows: ClosedRange<Int>) -> Int {
            var n = 0
            for y in rows { for x in 0..<100 where px[x, y].r < 128 { n += 1 } }
            return n
        }
        XCTAssertGreaterThan(dark(rows: 52...79), 50, "glyphs above the baseline")
        XCTAssertEqual(dark(rows: 0...40), 0, "nothing far above the cap height")
        XCTAssertEqual(dark(rows: 84...99), 0, "H has no descender")
        // textBaseline "top" puts the glyph tops at y.
        let id2 = try addWhiteLayer(session)
        try draw(session, id2, [["font", "bold 40px Helvetica"], ["textBaseline", "top"], ["fillText", "HHHH", 5, 0]])
        let px2 = try pixels(session)
        var n = 0
        for y in 0...30 { for x in 0..<100 where px2[x, y].r < 128 { n += 1 } }
        XCTAssertGreaterThan(n, 50)
        XCTAssertGreaterThan(ScriptDrawing.measureText("HHHH", font: "bold 40px Helvetica"), 80)
    }

    func testDrawRespectsSelectionTransformAndStroke() throws {
        let session = makeSession()
        let id = try addWhiteLayer(session)
        _ = try session.perform(["op": "select", "doc": "doc1", "x": 0, "y": 0, "width": 50, "height": 100])
        try draw(session, id, [["fillStyle", "red"], ["fillRect", 0, 0, 100, 100]])
        _ = try session.perform(["op": "deselect", "doc": "doc1"])
        var px = try pixels(session)
        XCTAssertTrue(isRed(px[10, 50]))
        XCTAssertTrue(isWhite(px[90, 50]), "selection must clip: \(px[90, 50])")

        try draw(session, id, [["save"], ["translate", 50, 0], ["fillStyle", "#00ff00"], ["fillRect", 0, 0, 10, 100],
                               ["restore"], ["strokeStyle", "blue"], ["lineWidth", 10],
                               ["beginPath"], ["moveTo", 0, 90], ["lineTo", 100, 90], ["stroke"]])
        px = try pixels(session)
        XCTAssertTrue(px[55, 50].g > 200 && px[55, 50].r < 60, "translated fill: \(px[55, 50])")
        XCTAssertTrue(isWhite(px[75, 50]), "translate must not leak after restore: \(px[75, 50])")
        XCTAssertTrue(px[75, 90].b > 200 && px[75, 90].r < 60, "stroke: \(px[75, 90])")
        XCTAssertTrue(isWhite(px[75, 80]), "outside the 10px pen: \(px[75, 80])")
    }

    func testDrawRejectsUnknownCommandsAndImportedLayers() throws {
        let session = makeSession()
        let id = try addWhiteLayer(session)
        XCTAssertThrowsError(try draw(session, id, [["fillRect", 0, 0, 10, 10], ["drawImage", "x"]])) { error in
            XCTAssertTrue("\(error)".contains("draw command 2"), "\(error)")
        }
        XCTAssertThrowsError(try draw(session, "A", [["fillRect", 0, 0, 10, 10]]))
    }

    func testCSSFontParsing() {
        let bold = ScriptDrawing.font(fromCSS: "bold 24px Helvetica")
        XCTAssertEqual(bold.pointSize, 24)
        XCTAssertEqual(bold.familyName, "Helvetica")
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let italic = ScriptDrawing.font(fromCSS: "italic 12pt 'Georgia', serif")
        XCTAssertEqual(italic.pointSize, 12)
        XCTAssertEqual(italic.familyName, "Georgia")
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        XCTAssertEqual(ScriptDrawing.font(fromCSS: "16px sans-serif").pointSize, 16)
        XCTAssertEqual(ScriptDrawing.font(fromCSS: "nonsense").pointSize, 10)
    }

    func testDescribeIsCompact() throws {
        let session = makeSession()
        _ = try session.perform(["op": "setLayer", "doc": "doc1", "layer": "B", "opacity": 0.5,
                                 "blendMode": "multiply", "visible": false])
        let text = ScriptSession.describe(session.documents[0])
        XCTAssertTrue(text.hasPrefix("doc1 \"Test\" 400×300 px, 3 layers"), text)
        XCTAssertTrue(text.contains("\"B\" raster 100×80 @ (150, 200) hidden 50% multiply"), text)
        // Top → bottom: C first.
        let cLine = text.range(of: "\"C\"")!.lowerBound
        let aLine = text.range(of: "\"A\"")!.lowerBound
        XCTAssertLessThan(cLine, aLine)
    }

    func testColorAndBlendModeParsing() throws {
        XCTAssertEqual(try ScriptGeometry.color(from: "#f80"), ColorSpec(r: 1, g: 136 / 255, b: 0))
        XCTAssertEqual(try ScriptGeometry.color(from: "#FF8800CC").a, 204 / 255, accuracy: 0.001)
        XCTAssertEqual(try ScriptGeometry.color(from: "rgb(255, 0, 128)"), ColorSpec(r: 1, g: 0, b: 128 / 255))
        XCTAssertEqual(try ScriptGeometry.color(from: "rgba(0,0,0,0.5)").a, 0.5)
        XCTAssertEqual(try ScriptGeometry.color(from: "Orange"), ColorSpec(r: 1, g: 0.647, b: 0))
        XCTAssertEqual(try ScriptGeometry.color(from: ["r": 0.1, "g": 0.2, "b": 0.3]), ColorSpec(r: 0.1, g: 0.2, b: 0.3))
        XCTAssertThrowsError(try ScriptGeometry.color(from: "#12345"))
        XCTAssertEqual(ScriptGeometry.css(ColorSpec(r: 1, g: 0.5, b: 0)), "#ff8000")
        XCTAssertEqual(ScriptGeometry.blendModeName(.colorBurn), "color-burn")
        XCTAssertEqual(try ScriptGeometry.blendMode(named: "Soft Light"), .softLight)
        XCTAssertEqual(try ScriptGeometry.blendMode(named: "multiply"), .multiply)
        XCTAssertThrowsError(try ScriptGeometry.blendMode(named: "plasma"))
    }

    func testFlipAndRotationReporting() throws {
        let session = makeSession()
        _ = try session.perform(["op": "rotate", "doc": "doc1", "layer": "A", "degrees": -45])
        let state = try session.perform(["op": "state", "doc": "doc1"]) as! [String: Any]
        let a = (state["layers"] as! [[String: Any]])[0]
        XCTAssertEqual(try XCTUnwrap(a["rotation"] as? Double), -45, accuracy: 0.001)
        let centerBefore = doc(session).layers[0].canvasBounds
        _ = try session.perform(["op": "flip", "doc": "doc1", "layer": "A", "axis": "horizontal"])
        let centerAfter = doc(session).layers[0].canvasBounds
        XCTAssertEqual(centerBefore.midX, centerAfter.midX, accuracy: 0.001)
        XCTAssertEqual(centerBefore.midY, centerAfter.midY, accuracy: 0.001)
    }
}

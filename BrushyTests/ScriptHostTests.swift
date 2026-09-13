import CoreGraphics
import XCTest
@testable import Brushy

/// The JavaScript surface end to end: prelude → host bridge → session. What
/// a model writes against, per `ScriptAPIDeclaration`.
final class ScriptHostTests: XCTestCase {
    private func makeSession() -> ScriptSession {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        let p3 = BrushyColorSpace.displayP3
        for (i, name) in ["A", "B", "C"].enumerated() {
            var layer = Layer(name: name,
                              source: GeneratedImages.solid(width: 100, height: 80,
                                                            r: UInt8(60 * i + 40), g: 80, b: 120,
                                                            colorSpace: p3))
            layer.transform = CGAffineTransform(translationX: CGFloat(10 + i * 140), y: 20)
            document.layers.append(layer)
        }
        var counter = 1
        return ScriptSession(documents: [ScriptSession.working(id: "doc1", title: "Test", document: document)],
                             activeID: "doc1", reserveDocumentID: { counter += 1; return "doc\(counter)" })
    }

    @discardableResult
    private func run(_ code: String, _ session: ScriptSession, timeout: TimeInterval = 5,
                     file: StaticString = #filePath, line: UInt = #line) -> ScriptHost.Outcome {
        let outcome = ScriptHost.run(code: code, session: session, timeout: timeout)
        if let failure = outcome.failure {
            XCTFail("Script failed: \(failure.message) line \(failure.line ?? -1)", file: file, line: line)
        }
        return outcome
    }

    func testReadsStateAndReturnsValues() {
        let session = makeSession()
        let outcome = run("""
            const names = doc.layers.map(l => l.name);
            console.log("count", doc.layers.length, doc.layer("B").frame);
            return { names, size: [doc.width, doc.height], first: doc.layers[0].frame };
            """, session)
        let value = outcome.returnValue as? [String: Any]
        XCTAssertEqual(value?["names"] as? [String], ["A", "B", "C"])
        XCTAssertEqual(value?["size"] as? [Int], [400, 300])
        XCTAssertEqual((value?["first"] as? [String: Double])?["y"], 200)
        XCTAssertEqual(outcome.logs.count, 1)
        XCTAssertTrue(outcome.logs[0].hasPrefix("count 3 {"), outcome.logs[0])
        let logged = try? JSONSerialization.jsonObject(with: Data(outcome.logs[0].dropFirst(8).utf8)) as? [String: Double]
        XCTAssertEqual(logged, ["x": 150, "y": 200, "width": 100, "height": 80])
        XCTAssertFalse(session.documents[0].isTouched)
    }

    func testMutationsReachTheSession() {
        let session = makeSession()
        run("""
            const b = doc.layer("B");
            b.move(5, 10).opacity = 0.5;
            b.name = "Bee";
            doc.layer("A").frame = { x: 0, y: 0, width: 200, height: 160 };
            doc.arrange(["A", "Bee", "C"], { direction: "vertical", gap: 4, x: 0, y: 0 });
            """, session)
        let doc = session.documents[0].document
        XCTAssertEqual(doc.layers[1].name, "Bee")
        XCTAssertEqual(doc.layers[1].opacity, 0.5)
        let a = ScriptGeometry.topLeft(doc.layers[0].canvasBounds, canvasHeight: 300)
        let b = ScriptGeometry.topLeft(doc.layers[1].canvasBounds, canvasHeight: 300)
        let c = ScriptGeometry.topLeft(doc.layers[2].canvasBounds, canvasHeight: 300)
        XCTAssertEqual(a, CGRect(x: 0, y: 0, width: 200, height: 160))
        XCTAssertEqual(b, CGRect(x: 0, y: 164, width: 100, height: 80))
        XCTAssertEqual(c, CGRect(x: 0, y: 248, width: 100, height: 80))
    }

    func testLoopsCreateManyLayers() {
        let session = makeSession()
        let outcome = run("""
            const made = [];
            for (let row = 0; row < 4; row++)
              for (let col = 0; col < 5; col++)
                made.push(doc.addText("X", { x: col * 40, y: row * 40, fontSize: 20 }));
            const g = doc.group(made, "Grid");
            return { count: doc.layers.length, group: g.name, members: g.layers.length };
            """, session)
        let value = outcome.returnValue as? [String: Any]
        XCTAssertEqual(value?["count"] as? Int, 23)
        XCTAssertEqual(value?["group"] as? String, "Grid")
        XCTAssertEqual(value?["members"] as? Int, 20)
        XCTAssertLessThan(outcome.duration, 5)
    }

    func testStaleLayerHandleAfterDelete() {
        let session = makeSession()
        let outcome = ScriptHost.run(code: """
            const a = doc.layer("A");
            a.delete();
            return a.name;
            """, session: session, timeout: 5)
        XCTAssertNotNil(outcome.failure)
        XCTAssertTrue(outcome.failure?.message.contains("no longer exists") == true)
        XCTAssertEqual(outcome.failure?.line, 3)
    }

    func testThrownErrorsCarryScriptLineNumbers() {
        let session = makeSession()
        let outcome = ScriptHost.run(code: "const x = 1;\n\nthrow new Error('boom');", session: session, timeout: 5)
        XCTAssertEqual(outcome.failure?.message, "boom")
        XCTAssertEqual(outcome.failure?.line, 3)
        XCTAssertFalse(outcome.failure?.isTimeout ?? true)
    }

    func testAPIErrorsPointAtTheScriptLine() {
        let session = makeSession()
        let outcome = ScriptHost.run(code: "doc.layer('A').visible = false;\ndoc.arrange(['nope']);",
                                     session: session, timeout: 5)
        XCTAssertTrue(outcome.failure?.message.contains("No layer \"nope\"") == true, outcome.failure?.message ?? "")
        XCTAssertEqual(outcome.failure?.line, 2)
    }

    func testSyntaxErrorsAreReported() {
        let session = makeSession()
        let outcome = ScriptHost.run(code: "doc.layers.forEach(l => { l.visible = )", session: session, timeout: 5)
        XCTAssertNotNil(outcome.failure)
        XCTAssertTrue(outcome.failure?.message.contains("SyntaxError") == true, outcome.failure?.message ?? "")
    }

    func testInfiniteLoopIsTerminated() {
        let session = makeSession()
        let started = Date()
        let outcome = ScriptHost.run(code: "let i = 0; while (true) { i++; }", session: session, timeout: 0.5)
        XCTAssertEqual(outcome.failure?.isTimeout, true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // The session is untouched and still usable.
        XCTAssertFalse(session.documents[0].isTouched)
        run("doc.layer('A').move(1, 0)", session)
        XCTAssertTrue(session.documents[0].isTouched)
    }

    func testNoFilesystemOrNetworkGlobals() {
        let session = makeSession()
        let outcome = run("""
            return [typeof require, typeof fetch, typeof XMLHttpRequest, typeof process, typeof window];
            """, session)
        XCTAssertEqual(outcome.returnValue as? [String], ["undefined", "undefined", "undefined", "undefined", "undefined"])
    }

    func testMultiDocumentAccess() {
        let session = makeSession()
        let outcome = run("""
            const fresh = brushy.newDocument(640, 480);
            doc.copyLayersTo(["A", "C"], fresh, { x: 10, y: 10 });
            fresh.addLayer({ color: "white", name: "BG" }).sendToBack();
            fresh.fitCanvasToContent(0);
            return { ids: brushy.documents.map(d => d.id), fresh: fresh.describe() };
            """, session)
        let value = outcome.returnValue as? [String: Any]
        XCTAssertEqual(value?["ids"] as? [String], ["doc1", "doc2"])
        let fresh = session.documents[1]
        XCTAssertTrue(fresh.isNew)
        XCTAssertEqual(fresh.document.layers.map(\.name), ["BG", "A", "C"])
        XCTAssertEqual(fresh.document.canvasSize, CGSize(width: 640, height: 480))
        XCTAssertTrue((value?["fresh"] as? String)?.hasPrefix("doc2") == true)
    }

    func testDrawRecordsCanvasCallsIntoOneOp() throws {
        let session = makeSession()
        let outcome = ScriptHost.run(code: """
            const layer = doc.addLayer({ name: "Pattern", color: "white", x: 0, y: 0, width: 100, height: 100 });
            let width = 0;
            layer.draw(ctx => {
              ctx.fillStyle = "red";
              for (let i = 0; i < 5; i++) ctx.fillRect(i * 20, 0, 10, 100);
              const g = ctx.createLinearGradient(0, 0, 0, 100);
              g.addColorStop(0, "blue"); g.addColorStop(1, "blue");
              ctx.fillStyle = g;
              ctx.beginPath(); ctx.arc(95, 95, 4, 0, Math.PI * 2); ctx.fill();
              ctx.font = "20px Helvetica";
              width = ctx.measureText("Hello").width;
              ctx.fillText("x", 50, 50);
            });
            return { width, layers: doc.layers.length };
            """, session: session, timeout: 5)
        XCTAssertNil(outcome.failure, outcome.failure?.message ?? "")
        let result = outcome.returnValue as? [String: Any]
        XCTAssertGreaterThan((result?["width"] as? NSNumber)?.doubleValue ?? 0, 30)
        XCTAssertEqual((result?["layers"] as? NSNumber)?.intValue, 4)
        let layer = try XCTUnwrap(session.documents[0].document.layers.last)
        let px = try rawRGBA8(layer.source, in: BrushyColorSpace.sRGB)
        XCTAssertTrue(px[5, 50].r > 220 && px[5, 50].g < 60, "\(px[5, 50])")
        XCTAssertTrue(px[15, 50].r > 245 && px[15, 50].g > 245, "\(px[15, 50])")
        XCTAssertTrue(px[95, 95].b > 220 && px[95, 95].r < 60, "gradient-filled circle: \(px[95, 95])")
    }

    func testDeclarationMentionsEveryPreludeMethod() {
        // Cheap drift guard: every `name(` method the prelude defines on
        // Doc/Layer/Group should be documented in the .d.ts.
        let prelude = ScriptPrelude.source
        let declaration = ScriptAPIDeclaration.source
        let pattern = try! NSRegularExpression(pattern: #"^\s{4}([a-zA-Z]+)\((?:[^)]*)\)\s*\{"#, options: [.anchorsMatchLines])
        let matches = pattern.matches(in: prelude, range: NSRange(prelude.startIndex..., in: prelude))
        var missing: [String] = []
        for match in matches {
            let name = String(prelude[Range(match.range(at: 1), in: prelude)!])
            guard !name.hasPrefix("_"), name != "constructor", name != "toJSON", name != "toString",
                  name != "remove" else { continue }
            if !declaration.contains(name + "(") { missing.append(name) }
        }
        XCTAssertEqual(missing, [], "Undocumented API methods")
    }
}

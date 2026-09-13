import CoreGraphics
import XCTest
@testable import Brushy

/// Snapshot → run → commit against real stores (§6): one named history
/// entry per touched document, nothing on failure, and no clobbering a
/// document that changed while the script ran.
final class ScriptRunnerTests: XCTestCase {
    private func makeStore(names: [String]) -> DocumentStore {
        var document = Document(canvasSize: CGSize(width: 400, height: 300))
        let p3 = BrushyColorSpace.displayP3
        for (i, name) in names.enumerated() {
            var layer = Layer(name: name,
                              source: GeneratedImages.solid(width: 100, height: 80,
                                                            r: UInt8(60 * i + 40), g: 80, b: 120,
                                                            colorSpace: p3))
            layer.transform = CGAffineTransform(translationX: CGFloat(10 + i * 140), y: 20)
            document.layers.append(layer)
        }
        let store = DocumentStore(document: document)
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        return store
    }

    private func makeRegistry(_ stores: [DocumentStore]) -> DocumentRegistry {
        let registry = DocumentRegistry()
        registry.enumerate = { stores.enumerated().map { ($1, "Doc \($0 + 1)") } }
        registry.active = { stores.first }
        return registry
    }

    private func runScript(_ runner: ScriptRunner, _ code: String, description: String = "Test") -> ScriptRunner.Result {
        let done = expectation(description: "script")
        var result: ScriptRunner.Result?
        runner.run(code: code, description: description) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return result!
    }

    func testCommitsOneHistoryEntryPerTouchedDocument() {
        let first = makeStore(names: ["A", "B"])
        let second = makeStore(names: ["X"])
        let untouched = makeStore(names: ["Q"])
        let registry = makeRegistry([first, second, untouched])
        let runner = ScriptRunner(registry: registry)
        let result = runScript(runner, """
            doc.layer("A").move(0, 50);
            doc.layer("B").delete();
            brushy.doc("doc2").addText("Hi", { x: 5, y: 5 });
            brushy.doc("doc3").layers.length;  // read only
            return "done";
            """, description: "Shuffle things")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.outcome.returnValue as? String, "done")
        XCTAssertEqual(result.changes.map(\.id), ["doc1", "doc2"])
        XCTAssertEqual(first.document.layers.map(\.name), ["A"])
        XCTAssertEqual(second.document.layers.map(\.name), ["X", "Hi"])
        XCTAssertTrue(first.canUndo)
        XCTAssertTrue(second.canUndo)
        XCTAssertFalse(untouched.canUndo)
        XCTAssertEqual(first.historyEntries.last?.actionName, "AI: Shuffle things")
        XCTAssertTrue(result.changes[0].summary.contains("removed \"B\""), result.changes[0].summary)
        XCTAssertTrue(result.changes[1].after.hasPrefix("doc2"))
        // The new text layer is selected in its window, like a tool would leave it.
        XCTAssertEqual(second.selectedLayer?.name, "Hi")
    }

    func testFailureCommitsNothing() {
        let store = makeStore(names: ["A", "B"])
        let runner = ScriptRunner(registry: makeRegistry([store]))
        let result = runScript(runner, """
            doc.layer("A").move(0, 50);
            doc.layer("B").delete();
            throw new Error("halfway");
            """)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.outcome.failure?.line, 3)
        XCTAssertEqual(store.document.layers.map(\.name), ["A", "B"])
        XCTAssertFalse(store.canUndo)
        XCTAssertTrue(result.changes.isEmpty)
    }

    func testStaleSnapshotIsNotCommitted() {
        let store = makeStore(names: ["A", "B"])
        let registry = makeRegistry([store])
        let runner = ScriptRunner(registry: registry)
        let session = runner.snapshot()
        _ = try? session.perform(["op": "delete", "doc": "doc1", "layer": "A"])
        // The user renames a layer while the script is running.
        store.renameLayer(store.document.layers[1].id, to: "Renamed")
        guard case .conflict = runner.commit(session, description: "Late") else {
            return XCTFail("Expected a conflict")
        }
        XCTAssertEqual(store.document.layers.map(\.name), ["A", "Renamed"])
        XCTAssertFalse(store.historyEntries.contains { $0.actionName.hasPrefix("AI:") })
    }

    func testNewDocumentsAreCreatedThroughTheRegistry() {
        let store = makeStore(names: ["A"])
        let registry = makeRegistry([store])
        var created: [(Document, String)] = []
        let createdStore = DocumentStore(document: Document(canvasSize: CGSize(width: 1, height: 1)))
        registry.createDocument = { document, id in
            created.append((document, id))
            createdStore.replaceDocument(document, actionName: DocumentStore.newDocumentActionName)
            return createdStore
        }
        let runner = ScriptRunner(registry: registry)
        let result = runScript(runner, """
            const d = brushy.newDocument(320, 200, "Composite");
            doc.copyLayersTo(["A"], d);
            return d.id;
            """)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.outcome.returnValue as? String, "doc2")
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.1, "doc2")
        XCTAssertEqual(createdStore.document.canvasSize, CGSize(width: 320, height: 200))
        XCTAssertEqual(createdStore.document.layers.map(\.name), ["A"])
        XCTAssertTrue(registry.store(for: "doc2") === createdStore)
        XCTAssertTrue(result.changes.first?.summary.hasPrefix("created 320×200") == true, result.changes.first?.summary ?? "")
    }
}

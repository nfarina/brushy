import CoreGraphics
import Foundation
import XCTest

// No `@testable import Brushy` — see the note atop ClipboardTests.swift.

/// Align & Distribute: the pure `Document` geometry, plus the
/// store's one-entry-per-operation history shape. No rendering — alignment is
/// translation only, so every assertion is on `canvasBounds` / `transform`.
final class AlignOpsTests: XCTestCase {
    private let space = BrushyColorSpace.displayP3

    private func makeLayer(_ name: String, x: CGFloat, y: CGFloat,
                           width: Int = 100, height: Int = 100) -> Layer {
        Layer(name: name,
              source: GeneratedImages.solid(width: width, height: height,
                                            r: 120, g: 140, b: 160, colorSpace: space),
              transform: CGAffineTransform(translationX: x, y: y))
    }

    private func document(_ layers: [Layer], groups: [LayerGroup] = [],
                          canvas: CGSize = CGSize(width: 1000, height: 600)) -> Document {
        var doc = Document(canvasSize: canvas)
        doc.layers = layers
        doc.groups = groups
        return doc
    }

    private func bounds(_ doc: Document, _ name: String) -> CGRect {
        doc.layers.first { $0.name == name }!.canvasBounds
    }

    // MARK: - Align

    func testAlignLeftLandsEveryObjectOnTheLeftmostOriginal() {
        let doc = document([makeLayer("a", x: 40, y: 0),
                            makeLayer("b", x: 300, y: 100),
                            makeLayer("c", x: 700, y: 200)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        let aligned = doc.aligning(objects, to: .left, reference: .selectionBounds)
        for name in ["a", "b", "c"] {
            XCTAssertEqual(bounds(aligned, name).minX, 40, accuracy: 1e-9)
        }
        // Translation only: sizes and the y axis are untouched.
        XCTAssertEqual(bounds(aligned, "b").minY, 100, accuracy: 1e-9)
        XCTAssertEqual(bounds(aligned, "c").width, 100, accuracy: 1e-9)
    }

    func testAlignHorizontalCentersToCanvasCentresEveryObject() {
        let doc = document([makeLayer("a", x: 40, y: 0),
                            makeLayer("b", x: 300, y: 100, width: 250, height: 50)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        let aligned = doc.aligning(objects, to: .centerH, reference: .canvas)
        for name in ["a", "b"] {
            XCTAssertEqual(bounds(aligned, name).midX, doc.canvasSize.width / 2, accuracy: 1e-9)
        }
    }

    /// Canvas space is y-up, so Top is the canvas's high edge.
    func testAlignTopAndBottomUseCanvasYUpEdges() {
        let doc = document([makeLayer("a", x: 0, y: 10), makeLayer("b", x: 200, y: 300)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        let top = doc.aligning(objects, to: .top, reference: .canvas)
        let bottom = doc.aligning(objects, to: .bottom, reference: .canvas)
        for name in ["a", "b"] {
            XCTAssertEqual(bounds(top, name).maxY, doc.canvasSize.height, accuracy: 1e-9)
            XCTAssertEqual(bounds(bottom, name).minY, 0, accuracy: 1e-9)
        }
    }

    func testRotatedLayerAlignsByItsAABB() {
        // 100×100 rotated 45° about its centre: the AABB is √2 wider, and that
        // AABB — what the user sees as the layer's extent, and what the smart
        // guides snap to — is what alignment targets.
        var rotated = makeLayer("rot", x: 0, y: 0)
        rotated.transform = CGAffineTransform(translationX: -50, y: -50)
            .concatenating(CGAffineTransform(rotationAngle: .pi / 4))
            .concatenating(CGAffineTransform(translationX: 400, y: 300))
        let doc = document([rotated])
        let aligned = doc.aligning([.layer(rotated.id)], to: .left, reference: .canvas)
        let box = bounds(aligned, "rot")
        XCTAssertEqual(box.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(box.width, 100 * sqrt(2), accuracy: 1e-6, "no resampling, no rescale")
        XCTAssertEqual(box.midY, 300, accuracy: 1e-9, "the other axis never moves")
    }

    func testHiddenLayersAreExcluded() {
        var hidden = makeLayer("hidden", x: 500, y: 0)
        hidden.isVisible = false
        let doc = document([makeLayer("a", x: 40, y: 0), hidden, makeLayer("c", x: 700, y: 0)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        let aligned = doc.aligning(objects, to: .left, reference: .selectionBounds)
        XCTAssertEqual(bounds(aligned, "hidden").minX, 500, accuracy: 1e-9,
                       "a layer you cannot see must not move")
        XCTAssertEqual(bounds(aligned, "c").minX, 40, accuracy: 1e-9)
    }

    func testMembersOfAHiddenGroupAreExcluded() {
        var group = LayerGroup(name: "G")
        group.isVisible = false
        var member = makeLayer("m", x: 500, y: 0)
        member.groupID = group.id
        let doc = document([member, makeLayer("a", x: 40, y: 0), makeLayer("c", x: 700, y: 0)],
                           groups: [group])
        let objects: [AlignObject] = [.group(group.id), .layer(doc.layers[1].id),
                                      .layer(doc.layers[2].id)]
        let aligned = doc.aligning(objects, to: .left, reference: .selectionBounds)
        XCTAssertEqual(bounds(aligned, "m").minX, 500, accuracy: 1e-9,
                       "effective visibility cascades — a hidden group's members are hidden")
    }

    func testGroupAlignsAsOneUnitWithOneSharedDelta() {
        let group = LayerGroup(name: "G")
        var m1 = makeLayer("m1", x: 200, y: 0)
        var m2 = makeLayer("m2", x: 400, y: 300, width: 50, height: 50)
        m1.groupID = group.id
        m2.groupID = group.id
        let loose = makeLayer("loose", x: 50, y: 0)
        let doc = document([m1, m2, loose], groups: [group])
        let aligned = doc.aligning([.group(group.id), .layer(loose.id)],
                                   to: .left, reference: .selectionBounds)
        let d1 = bounds(aligned, "m1").minX - 200
        let d2 = bounds(aligned, "m2").minX - 400
        XCTAssertEqual(d1, -150, accuracy: 1e-9, "the group's own left edge lands on 50")
        XCTAssertEqual(d1, d2, accuracy: 1e-12, "every member moves by the SAME delta")
        XCTAssertEqual(bounds(aligned, "loose").minX, 50, accuracy: 1e-9)
    }

    func testClippedLayerMovesWithItsBaseAndIsNeverAlignedAlone() {
        var rider = makeLayer("rider", x: 120, y: 0)
        rider.isClippedToBelow = true
        let doc = document([makeLayer("base", x: 100, y: 0), rider,
                            makeLayer("other", x: 600, y: 0)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        let aligned = doc.aligning(objects, to: .left, reference: .canvas)
        XCTAssertEqual(bounds(aligned, "base").minX, 0, accuracy: 1e-9)
        XCTAssertEqual(bounds(aligned, "rider").minX, 20, accuracy: 1e-9,
                       "the rider keeps its offset from the base it is confined to")
        XCTAssertEqual(bounds(aligned, "other").minX, 0, accuracy: 1e-9)

        // Selecting only the clipped layer aligns nothing at all.
        XCTAssertEqual(doc.aligning([.layer(rider.id)], to: .left, reference: .canvas), doc)
    }

    func testSingleObjectAlignsAgainstTheCanvasOnly() {
        let doc = document([makeLayer("a", x: 40, y: 0)])
        XCTAssertEqual(doc.aligning([.layer(doc.layers[0].id)], to: .right,
                                    reference: .selectionBounds),
                       doc, "selection bounds of one object ARE the object")
        let aligned = doc.aligning([.layer(doc.layers[0].id)], to: .right, reference: .canvas)
        XCTAssertEqual(bounds(aligned, "a").maxX, 1000, accuracy: 1e-9)
    }

    // MARK: - Distribute

    /// Three unequal widths at 0…100, 300…360, 500…540: span 540, content
    /// 200, so both gaps must be 170.
    func testDistributeSpacingEqualisesGapsAndHoldsTheExtremes() {
        let doc = document([makeLayer("a", x: 0, y: 0),
                            makeLayer("b", x: 300, y: 0, width: 60, height: 100),
                            makeLayer("c", x: 500, y: 0, width: 40, height: 100)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        let spread = doc.distributing(objects, along: .horizontal, mode: .spacing)
        let a = bounds(spread, "a"), b = bounds(spread, "b"), c = bounds(spread, "c")
        XCTAssertEqual(b.minX - a.maxX, c.minX - b.maxX, accuracy: 1e-9)
        XCTAssertEqual(b.minX - a.maxX, 170, accuracy: 1e-9)
        XCTAssertEqual(a.minX, 0, accuracy: 1e-9, "the outer objects never move")
        XCTAssertEqual(c.minX, 500, accuracy: 1e-9, "the outer objects never move")
    }

    func testDistributeCentersIsEquidistantAndDiffersFromSpacing() {
        let doc = document([makeLayer("a", x: 0, y: 0),
                            makeLayer("b", x: 300, y: 0, width: 60, height: 100),
                            makeLayer("c", x: 500, y: 0, width: 40, height: 100)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        let centers = doc.distributing(objects, along: .horizontal, mode: .centers)
        let a = bounds(centers, "a"), b = bounds(centers, "b"), c = bounds(centers, "c")
        XCTAssertEqual(b.midX - a.midX, c.midX - b.midX, accuracy: 1e-9)
        XCTAssertEqual(a.midX, 50, accuracy: 1e-9)
        XCTAssertEqual(c.midX, 520, accuracy: 1e-9)
        // The two modes must not be conflated: equal centres ≠ equal gaps when
        // the objects differ in size.
        let spacing = doc.distributing(objects, along: .horizontal, mode: .spacing)
        XCTAssertNotEqual(bounds(centers, "b").minX, bounds(spacing, "b").minX)
    }

    func testDistributeVerticalUsesTheOtherAxisOnly() {
        let doc = document([makeLayer("a", x: 0, y: 0, width: 100, height: 40),
                            makeLayer("b", x: 200, y: 100, width: 100, height: 60),
                            makeLayer("c", x: 400, y: 400, width: 100, height: 20)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        let spread = doc.distributing(objects, along: .vertical, mode: .spacing)
        let a = bounds(spread, "a"), b = bounds(spread, "b"), c = bounds(spread, "c")
        XCTAssertEqual(b.minY - a.maxY, c.minY - b.maxY, accuracy: 1e-9)
        XCTAssertEqual(b.minX, 200, accuracy: 1e-9, "x is untouched")
    }

    /// Overlapping objects produce negative gaps. Photoshop does the same —
    /// clamping would silently ignore what the user asked for.
    func testDistributeSpacingAllowsNegativeGaps() {
        let doc = document([makeLayer("a", x: 0, y: 0, width: 200, height: 100),
                            makeLayer("b", x: 50, y: 0, width: 200, height: 100),
                            makeLayer("c", x: 100, y: 0, width: 200, height: 100)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        // Span 0…300 with 600 points of content: the gaps are (300-600)/2.
        let spread = doc.distributing(objects, along: .horizontal, mode: .spacing)
        let a = bounds(spread, "a"), b = bounds(spread, "b"), c = bounds(spread, "c")
        XCTAssertEqual(b.minX - a.maxX, -150, accuracy: 1e-9)
        XCTAssertEqual(c.minX - b.maxX, -150, accuracy: 1e-9)
    }

    func testDistributeNeedsThreeObjects() {
        let doc = document([makeLayer("a", x: 0, y: 0), makeLayer("b", x: 500, y: 0)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        XCTAssertEqual(doc.distributing(objects, along: .horizontal, mode: .spacing), doc)
        XCTAssertEqual(doc.distributing([], along: .horizontal, mode: .centers), doc)
    }

    /// A hidden object drops out, which can take the count below three — the
    /// operation must then do nothing rather than distribute two objects.
    func testDistributeSkipsHiddenObjectsBeforeCounting() {
        var hidden = makeLayer("hidden", x: 300, y: 0)
        hidden.isVisible = false
        let doc = document([makeLayer("a", x: 0, y: 0), hidden, makeLayer("c", x: 600, y: 0)])
        let objects = doc.layers.map { AlignObject.layer($0.id) }
        XCTAssertEqual(doc.distributing(objects, along: .horizontal, mode: .spacing), doc)
    }

    // MARK: - Store: one history entry per operation

    func testAlignAndDistributeAreOneUndoStepEach() {
        let doc = document([makeLayer("a", x: 0, y: 0),
                            makeLayer("b", x: 300, y: 0, width: 60, height: 100),
                            makeLayer("c", x: 500, y: 0, width: 40, height: 100)])
        let store = DocumentStore(document: doc)
        let um = UndoManager()
        um.levelsOfUndo = 100
        um.groupsByEvent = false
        store.undoManager = um
        store.selectPanelRows(Set(doc.layers.map(\.id)))
        XCTAssertTrue(store.canAlignSelection)
        XCTAssertTrue(store.canDistributeSelection)

        let before = store.document.layers.map(\.transform)
        um.beginUndoGrouping()
        store.alignSelection(to: .left)
        um.endUndoGrouping()
        XCTAssertEqual(um.undoActionName, "Align Left")
        for layer in store.document.layers {
            XCTAssertEqual(layer.canvasBounds.minX, 0, accuracy: 1e-9)
        }

        um.undo()
        XCTAssertEqual(store.document.layers.map(\.transform), before,
                       "one operation, one undo step — not one per layer moved")

        // Undo restored the selection the previous snapshot recorded, so
        // re-select before the next relational command.
        store.selectPanelRows(Set(store.document.layers.map(\.id)))
        um.beginUndoGrouping()
        store.distributeSelection(.horizontalSpacing)
        um.endUndoGrouping()
        XCTAssertEqual(um.undoActionName, "Distribute Horizontal Spacing")
        um.undo()
        XCTAssertEqual(store.document.layers.map(\.transform), before)
    }

    func testAlignEnablementFollowsTheObjectCount() {
        let doc = document([makeLayer("a", x: 0, y: 0), makeLayer("b", x: 300, y: 0)])
        let store = DocumentStore(document: doc)
        store.selectLayer(doc.layers[0].id)
        XCTAssertEqual(store.effectiveAlignReference, .canvas,
                       "one object forces the canvas reference")
        XCTAssertTrue(store.canAlignSelection)
        XCTAssertFalse(store.canDistributeSelection)

        store.selectPanelRows(Set(doc.layers.map(\.id)))
        XCTAssertEqual(store.effectiveAlignReference, .selectionBounds)
        XCTAssertTrue(store.canAlignSelection)
        XCTAssertFalse(store.canDistributeSelection, "distribute needs three")

        store.selectLayer(nil)
        XCTAssertFalse(store.canAlignSelection)
    }

    /// A selected group is ONE object to the relational commands, so its
    /// members move together and it cannot distribute against itself.
    func testSelectedGroupIsASingleAlignObject() {
        let group = LayerGroup(name: "G")
        var m1 = makeLayer("m1", x: 200, y: 0)
        var m2 = makeLayer("m2", x: 300, y: 0)
        m1.groupID = group.id
        m2.groupID = group.id
        let store = DocumentStore(document: document([m1, m2], groups: [group]))
        store.selectGroup(group.id)
        XCTAssertEqual(store.alignObjects, [.group(group.id)])
        XCTAssertEqual(store.selectedLayerIDs, [m1.id, m2.id],
                       "the group's members fill the selection set")
        XCTAssertFalse(store.canDistributeSelection)

        store.alignSelection(to: .left)
        XCTAssertEqual(store.document[layerID: m1.id]!.canvasBounds.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(store.document[layerID: m2.id]!.canvasBounds.minX, 100, accuracy: 1e-9,
                       "the folder moves as a unit, keeping its internal layout")
    }
}

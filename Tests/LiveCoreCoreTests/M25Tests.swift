import XCTest
@testable import LiveCoreCore

/// 0.25.0: Layer Designer (hide, lock, flatten, snapping, edge crop, saved layouts).
final class LayerDesignerTests: XCTestCase {
    let a = InputID("a"), b = InputID("b"), c = InputID("c"), s = InputID("scene")

    func testHiddenLayerIsNotDrawnOrHeard() {
        let layers: [InputID: [Layer]] = [
            a: [Layer(source: a), Layer(source: b, rect: LayoutPreset.pipTopRight.rect, hidden: true)],
            b: [Layer(source: b)],
        ]
        let plan = FramePlanner.plan(snapshot: SwitcherSnapshot(program: a), overlays: [], now: 0, layersFor: { layers[$0] })
        XCTAssertEqual(plan.program.map(\.source), [a])
        let heard = OnAir.visibleInputs(switcher: SwitcherSnapshot(program: a), layers: layers, overlays: [])
        XCTAssertEqual(heard, [a])
    }

    func testFlattenedInputIsOnePictureEverywhere() {
        let pip = NormRect(x: 0.6, y: 0.1, width: 0.3, height: 0.3)
        let layers: [InputID: [Layer]] = [
            // Scene `s` (flattened) holds a and b; input c shows scene s as a PiP.
            s: [Layer(source: s, flatten: true), Layer(source: a), Layer(source: b, rect: pip)],
            a: [Layer(source: a)], b: [Layer(source: b)],
            c: [Layer(source: c), Layer(source: s, rect: pip, scaleMode: .fill)],
        ]
        let plan = FramePlanner.plan(snapshot: SwitcherSnapshot(preview: s, program: c), overlays: [], now: 0,
                                     layersFor: { layers[$0] }, keyFor: { _ in ChromaKey(enabled: true) })
        // Program: c, then the flattened scene as one PiP layer (not keyed again).
        XCTAssertEqual(plan.program.map(\.source), [c, s])
        XCTAssertEqual(plan.program[1].rect, pip)
        XCTAssertNil(plan.program[1].key)
        // Preview: the flattened scene itself is one full-frame picture.
        XCTAssertEqual(plan.preview, [DrawCommand(source: s, rect: .full, scaleMode: .stretch, opacity: 1)])
        // One flatten pass with the scene's real layers.
        XCTAssertEqual(plan.flatten.map(\.input), [s])
        XCTAssertEqual(plan.flatten[0].layers.map(\.source), [s, a, b])
        XCTAssertTrue(plan.allCommandLists.joined().contains { $0.source == b }, "the engine fetches b's frame")
        // AFV hears the flattened scene's layers on Program.
        XCTAssertTrue(OnAir.visibleInputs(switcher: SwitcherSnapshot(program: c), layers: layers, overlays: []).isSuperset(of: [a, b]))
    }

    func testNestedFlattenOrderAndCycle() {
        let layers: [InputID: [Layer]] = [
            a: [Layer(source: a, flatten: true), Layer(source: b)],
            b: [Layer(source: b, flatten: true), Layer(source: c)],
            c: [Layer(source: c, flatten: true), Layer(source: a)],   // cycle back to a
        ]
        let plan = FramePlanner.plan(snapshot: SwitcherSnapshot(program: a), overlays: [], now: 0, layersFor: { layers[$0] })
        XCTAssertEqual(Set(plan.flatten.map(\.input)), [a, b, c])
        XCTAssertEqual(plan.flatten.last?.input, a, "the outer input is drawn after what it contains")
        XCTAssertEqual(plan.flatten.firstIndex { $0.input == c }! < plan.flatten.firstIndex { $0.input == b }!, true)
    }

    func testFlattenNeedsMoreThanOneLayer() {
        let layers: [InputID: [Layer]] = [a: [Layer(source: a, flatten: true)]]
        let plan = FramePlanner.plan(snapshot: SwitcherSnapshot(program: a), overlays: [], now: 0, layersFor: { layers[$0] })
        XCTAssertTrue(plan.flatten.isEmpty)
        XCTAssertEqual(plan.program.map(\.source), [a])
    }

    func testOlderLayersDecodeWithoutNewKeys() throws {
        let json = #"{"source":{"raw":"a"},"rect":{"x":0,"y":0,"width":1,"height":1},"scaleMode":"fit","opacity":1}"#
        let l = try JSONDecoder().decode(Layer.self, from: Data(json.utf8))
        XCTAssertFalse(l.isHidden); XCTAssertFalse(l.isLocked); XCTAssertNil(l.flatten)
        let back = try JSONDecoder().decode(Layer.self, from: JSONEncoder().encode(Layer(source: a, hidden: true, locked: true, flatten: true)))
        XCTAssertTrue(back.isHidden && back.isLocked && back.flatten == true)
    }

    func testEdgeResizeMovesOneSide() {
        let r = NormRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let left = LayerEditing.resize(r, handle: .left, dx: 0.1, dy: 0.3, aspect: 1)
        XCTAssertEqual(left.x, 0.3, accuracy: 1e-9); XCTAssertEqual(left.width, 0.3, accuracy: 1e-9)
        XCTAssertEqual(left.y, 0.2); XCTAssertEqual(left.height, 0.4, accuracy: 1e-9)
        let bottom = LayerEditing.resize(r, handle: .bottom, dx: 0.5, dy: -0.1)
        XCTAssertEqual(bottom.height, 0.3, accuracy: 1e-9); XCTAssertEqual(bottom.x, 0.2); XCTAssertEqual(bottom.width, 0.4, accuracy: 1e-9)
    }

    func testSnapMoveToCentreAndOtherLayers() {
        // Centre 0.495 → snaps to 0.5.
        let m = LayerEditing.snapMove(NormRect(x: 0.345, y: 0.25, width: 0.3, height: 0.2), others: [])
        XCTAssertEqual(m.rect.x, 0.35, accuracy: 1e-9)
        XCTAssertEqual(m.guidesX, [0.5])
        XCTAssertEqual(m.guidesY, [])
        // Left edge 0.705 next to another layer's right edge 0.7.
        let n = LayerEditing.snapMove(NormRect(x: 0.705, y: 0.31, width: 0.2, height: 0.2),
                                      others: [NormRect(x: 0.4, y: 0.6, width: 0.3, height: 0.3)])
        XCTAssertEqual(n.rect.x, 0.7, accuracy: 1e-9)
        XCTAssertEqual(n.guidesX, [0.7])
        let far = LayerEditing.snapMove(NormRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1), others: [])
        XCTAssertEqual(far.rect, NormRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1))
    }

    func testSnapResizeOnlyMovedSide() {
        let r = LayerEditing.snapResize(NormRect(x: 0.1, y: 0.1, width: 0.393, height: 0.3), handle: .right, others: [])
        XCTAssertEqual(r.rect.x, 0.1); XCTAssertEqual(r.rect.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(r.guidesX, [0.5])
    }

    func testEdgeCropKeepsPictureInPlace() {
        let r = NormRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        // Drag the left edge 0.1 to the right: 25 % of the source is cut, the box shrinks from the left.
        let (rect, crop) = LayerEditing.crop(r, crop: .none, handle: .left, dx: 0.1, dy: 0, symmetric: false)
        XCTAssertEqual(crop.left, 0.25, accuracy: 1e-9); XCTAssertEqual(crop.right, 0)
        XCTAssertEqual(rect.x, 0.3, accuracy: 1e-9); XCTAssertEqual(rect.width, 0.3, accuracy: 1e-9)
        // Shift: both sides.
        let (sr, sc) = LayerEditing.crop(r, crop: .none, handle: .right, dx: -0.04, dy: 0, symmetric: true)
        XCTAssertEqual(sc.left, 0.1, accuracy: 1e-9); XCTAssertEqual(sc.right, 0.1, accuracy: 1e-9)
        XCTAssertEqual(sr.x, 0.24, accuracy: 1e-9); XCTAssertEqual(sr.width, 0.32, accuracy: 1e-9)
        // Dragging back out restores the uncropped box.
        let (back, bc) = LayerEditing.crop(rect, crop: crop, handle: .left, dx: -0.5, dy: 0, symmetric: false)
        XCTAssertEqual(bc.left, 0); XCTAssertEqual(back.x, 0.2, accuracy: 1e-9); XCTAssertEqual(back.width, 0.4, accuracy: 1e-9)
        // Limits: at most 45 % per side.
        let (_, maxc) = LayerEditing.crop(r, crop: .none, handle: .top, dx: 0, dy: 0.39, symmetric: false)
        XCTAssertEqual(maxc.top, 0.45, accuracy: 1e-9)
    }

    func testLayoutTemplateApply() {
        let t = LayoutTemplate(id: "t", name: "Interview", layers: [
            Layer(source: s, flatten: true),
            Layer(source: a, rect: NormRect(x: 0, y: 0, width: 0.5, height: 1), scaleMode: .fill,
                  style: LayerStyle(cornerRadius: 0.1, borderWidth: 0.01), locked: true),
            Layer(source: b, rect: NormRect(x: 0.5, y: 0, width: 0.5, height: 1), hidden: true),
            Layer(source: InputID("gone"), rect: .full),
        ])
        let target = [Layer(source: c), Layer(source: InputID("cam2"))]
        let out = t.apply(to: target) { [a, b].contains($0) }
        XCTAssertEqual(out.map(\.source), [c, InputID("cam2"), b], "sources kept, missing input skipped")
        XCTAssertNil(out[0].flatten)
        XCTAssertEqual(out[1].rect, NormRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(out[1].style?.cornerRadius, 0.1)
        XCTAssertTrue(out[1].isLocked)
        XCTAssertTrue(out[2].isHidden)
        let data = try! JSONEncoder().encode([t])
        XCTAssertEqual(try! JSONDecoder().decode([LayoutTemplate].self, from: data), [t])
    }

    func testFullscreenOutputsSpreadOverExternalDisplays() {
        let main = DisplayInfo(id: 1, name: "Built-in", isMain: true)
        let tv = DisplayInfo(id: 2, name: "TV", isMain: false), proj = DisplayInfo(id: 3, name: "Projector", isMain: false)
        let all = [main, tv, proj]
        XCTAssertEqual(OutputDisplayPicker.choose(savedID: nil, savedName: nil, displays: all, extraIndex: 0), tv)
        XCTAssertEqual(OutputDisplayPicker.choose(savedID: nil, savedName: nil, displays: all, extraIndex: 1), proj)
        XCTAssertEqual(OutputDisplayPicker.choose(savedID: nil, savedName: nil, displays: all, extraIndex: 3), proj, "fewer displays: the last external")
        XCTAssertEqual(OutputDisplayPicker.choose(savedID: nil, savedName: nil, displays: [main], extraIndex: 2), main)
        XCTAssertEqual(OutputDisplayPicker.choose(savedID: 1, savedName: nil, displays: all, extraIndex: 1), main, "a chosen display wins")
    }
}

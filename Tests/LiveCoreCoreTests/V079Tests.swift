import XCTest
@testable import LiveCoreCore

/// 0.79.0: Mix input (own Preview/Program, flattened into one picture).
final class V079Tests: XCTestCase {
    let mix = InputID("mix"), a = InputID("a"), b = InputID("b"), scene = InputID("scene")

    func testMixBusRestoresAndCuts() {
        let m = MixBus(ProjectMix(preview: b, program: a, duration: 1))
        XCTAssertEqual(m.switcher.state.program, a)
        XCTAssertEqual(m.switcher.state.preview, b)
        m.switcher.cut()
        XCTAssertEqual(m.project, ProjectMix(preview: a, program: b, duration: 1))
    }

    func testMixIsFlattenedAndFades() {
        let m = MixBus(ProjectMix(preview: b, program: scene))
        let layers: [InputID: [Layer]] = [mix: [Layer(source: mix)], a: [Layer(source: a)], b: [Layer(source: b)],
                                          scene: [Layer(source: scene), Layer(source: a, rect: LayoutPreset.pipTopLeft.rect)]]
        var snap = SwitcherSnapshot(); snap.program = mix
        func plan(_ now: Double) -> FramePlan {
            FramePlanner.plan(snapshot: snap, overlays: [], now: now, layersFor: { layers[$0] }, mixes: [mix: m.switcher.state])
        }
        var p = plan(0)
        XCTAssertEqual(p.program.map(\.source), [mix])
        XCTAssertEqual(p.flatten.first { $0.input == mix }?.layers.map(\.source), [scene, a], "a scene keeps its own layers inside the mix")
        m.duration = 1
        m.fade(now: 10)
        p = plan(10.5)
        let l = p.flatten.first { $0.input == mix }!.layers
        XCTAssertEqual(l.map(\.source), [scene, a, b])
        XCTAssertEqual(l.last!.opacity, 0.5, accuracy: 0.001)
        m.switcher.update(now: 11.1)
        XCTAssertEqual(plan(12).flatten.first { $0.input == mix }?.layers.map(\.source), [b])
    }

    func testMixNeverDrawsItself() {
        let m = MixBus(ProjectMix(program: mix))
        let p = FramePlanner.plan(snapshot: SwitcherSnapshot(program: mix), overlays: [], now: 0,
                                  layersFor: { [Layer(source: $0)] }, mixes: [mix: m.switcher.state])
        XCTAssertEqual(p.flatten.first { $0.input == mix }?.layers, [])
    }
}

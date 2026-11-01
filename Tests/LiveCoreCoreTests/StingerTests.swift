import XCTest
@testable import LiveCoreCore

final class StingerTests: XCTestCase {
    private let a = InputID("a"), b = InputID("b"), clip = InputID("clip")

    private func layers(_ id: InputID) -> [Layer]? { [a, b, clip].contains(id) ? [Layer(source: id)] : nil }

    func testConfigResolvesCutPoint() {
        XCTAssertNil(StingerConfig().params(clipDuration: 2))                      // no source
        XCTAssertNil(StingerConfig(source: clip).params(clipDuration: 0))          // unknown duration
        XCTAssertNil(StingerConfig(source: clip).params(clipDuration: .nan))
        XCTAssertEqual(StingerConfig(source: clip).params(clipDuration: 2)?.cutPoint, 1)       // default: middle
        XCTAssertEqual(StingerConfig(source: clip, cutPoint: 5).params(clipDuration: 2)?.cutPoint, 2)  // clamped
        XCTAssertEqual(StingerConfig(source: clip, cutPoint: 0.5).params(clipDuration: 2)?.cutFraction, 0.25)
    }

    func testStingerRunsForClipLengthAndCutsAtCutPoint() {
        let sw = Switcher()
        sw.setPreview(a); sw.cut(); sw.setPreview(b)       // program a, preview b
        let p = StingerParams(source: clip, clipDuration: 2, cutPoint: 0.5)
        sw.auto(kind: .stinger, duration: 0.3, now: 10, stinger: p)
        XCTAssertEqual(sw.state.transition?.duration, 2)  // clip length wins over the duration slider

        func plan(_ now: Double) -> FramePlan {
            FramePlanner.plan(snapshot: sw.state, overlays: [], now: now, layersFor: layers)
        }
        let before = plan(10.4)
        XCTAssertEqual(before.program.map(\.source), [a])
        XCTAssertEqual(before.programInput, a)
        XCTAssertNil(before.transition)
        XCTAssertEqual(before.stinger?.source, clip)
        let after = plan(10.6)
        XCTAssertEqual(after.program.map(\.source), [b])
        XCTAssertEqual(after.programInput, b)
        XCTAssertEqual(after.stinger?.source, clip)

        sw.update(now: 11.9)
        XCTAssertNotNil(sw.state.transition)
        sw.update(now: 12.0)
        XCTAssertNil(sw.state.transition)
        XCTAssertEqual(sw.state.program, b)
        XCTAssertEqual(sw.state.preview, a)
        XCTAssertNil(plan(12.1).stinger)
    }

    func testStingerWithoutClipCuts() {
        let sw = Switcher()
        sw.setPreview(a); sw.cut(); sw.setPreview(b)
        sw.auto(kind: .stinger, duration: 1, now: 0, stinger: nil)
        XCTAssertNil(sw.state.transition)
        XCTAssertEqual(sw.state.program, b)
    }

    func testTBarWithStingerDissolves() {
        let sw = Switcher()
        sw.setPreview(a); sw.cut(); sw.setPreview(b)
        sw.setTBar(0.3, kind: .stinger, now: 0)
        XCTAssertEqual(sw.state.transition?.kind, .dissolve)
    }

    func testRemovedStingerClipIsNotDrawn() {
        let sw = Switcher()
        sw.setPreview(a); sw.cut(); sw.setPreview(b)
        sw.auto(kind: .stinger, duration: 1, now: 0, stinger: StingerParams(source: InputID("gone"), clipDuration: 1, cutPoint: 0.5))
        let plan = FramePlanner.plan(snapshot: sw.state, overlays: [], now: 0.2, layersFor: layers)
        XCTAssertNil(plan.stinger)
        XCTAssertEqual(plan.program.map(\.source), [a])
    }

    func testProjectStingerIsSanitizedAndOptional() throws {
        var doc = ProjectDocument()
        doc.stinger = StingerConfig(source: InputID("missing"), cutPoint: 0.4)
        XCTAssertFalse(doc.validationIssues().isEmpty)
        XCTAssertNil(doc.sanitized().stinger?.source)
        XCTAssertEqual(doc.sanitized().stinger?.cutPoint, 0.4)
        // Older projects have no "stinger" key.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectDocument())) as! [String: Any]
        json.removeValue(forKey: "stinger")
        let old = try JSONDecoder().decode(ProjectDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.stinger)
    }
}

import Foundation
import XCTest
@testable import LiveCoreCore

final class OutputRoutingTests: XCTestCase {
    func testDefaultsAndNormalization() {
        let r = OutputRouting()
        XCTAssertEqual(r.slots.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(r.slot(1).source, .program)
        XCTAssertEqual(r.slot(2).source, .preview)
        let a = InputID("a"), b = InputID("b")
        var odd = OutputRouting(slots: [OutputSlot(index: 3, source: .input(a), syphon: true), OutputSlot(index: 9)])
        XCTAssertEqual(odd.slots.map(\.index), [1, 2, 3, 4], "always four slots in order")
        XCTAssertEqual(odd.slot(3).source, .input(a))
        XCTAssertTrue(odd.slot(3).syphon)
        odd = odd.normalized(existing: [b])
        XCTAssertEqual(odd.slot(3).source, .program, "a removed input falls back to Program")
    }

    func testRenderedPicturesOnlyForActiveOutputs() {
        let a = InputID("a"), b = InputID("b")
        var r = OutputRouting()
        r.setSource(3, .input(a))
        r.setSource(4, .input(a))
        r.setSource(1, .input(b))
        XCTAssertEqual(r.activeOutputs(windows: []), [])
        XCTAssertEqual(r.renderedInputs(active: []), [])
        XCTAssertFalse(r.needsFullPreview(active: [1, 3]))
        XCTAssertTrue(r.needsFullPreview(active: [2]))
        XCTAssertEqual(r.renderedInputs(active: [1, 3, 4]), [b, a], "each input rendered once")
        r.setSyphon(4, true)
        XCTAssertEqual(r.activeOutputs(windows: [2]), [2, 4])
        XCTAssertEqual(r.activeOutputs(windows: []), [4])
        XCTAssertEqual(r.withDefaultSyphon(), r, "an output already sends: nothing changes")
        XCTAssertEqual(OutputRouting().withDefaultSyphon().slots.filter(\.syphon).map(\.index), [1])
    }

    func testCodableRoundTripInProject() throws {
        let a = InputID("a")
        var doc = ProjectDocument(inputs: [ProjectInput(id: a, name: "Cam", source: .colorBars)])
        var r = OutputRouting()
        r.setSource(2, .input(a))
        r.setSyphon(2, true)
        doc.outputs = r
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.outputs, r)
        XCTAssertEqual(back.sanitized().outputs?.slot(2).source, .input(a))
        doc.inputs = []
        XCTAssertEqual(doc.sanitized().outputs?.slot(2).source, .program)
        let old = try JSONEncoder().encode(ProjectDocument())
        XCTAssertNil(try JSONDecoder().decode(ProjectDocument.self, from: old).outputs)
    }

    func testPlannerRendersExtraPictures() {
        let a = InputID("a"), b = InputID("b")
        let layers: [InputID: [Layer]] = [a: [Layer(source: a)], b: [Layer(source: b)]]
        let snap = SwitcherSnapshot(preview: b, program: a)
        let plain = FramePlanner.plan(snapshot: snap, overlays: [], now: 0, layersFor: { layers[$0] })
        XCTAssertTrue(plain.extra.isEmpty)
        XCTAssertNil(plain.fullPreview)
        let gone = InputID("gone")
        let plan = FramePlanner.plan(snapshot: snap, overlays: [], now: 0, layersFor: { layers[$0] },
                                     extraInputs: [b, gone], fullPreview: true)
        XCTAssertEqual(Set(plan.extra.keys), [b], "removed inputs are skipped")
        XCTAssertEqual(plan.extra[b]?.first?.source, b)
        XCTAssertEqual(plan.fullPreview?.map(\.source), plan.preview.map(\.source))
    }
}

final class RecordReminderTests: XCTestCase {
    func testWhenTheWarningShows() {
        XCTAssertFalse(RecordReminder.applies(mode: .off, recording: false, streaming: true))
        XCTAssertTrue(RecordReminder.applies(mode: .always, recording: false, streaming: false))
        XCTAssertFalse(RecordReminder.applies(mode: .always, recording: true, streaming: true))
        XCTAssertFalse(RecordReminder.applies(mode: .whileStreaming, recording: false, streaming: false))
        XCTAssertTrue(RecordReminder.applies(mode: .whileStreaming, recording: false, streaming: true))
        XCTAssertEqual(RecordReminderMode(rawValue: "whileStreaming"), .whileStreaming)
    }

    func testBlinkPhase() {
        XCTAssertTrue(RecordReminder.visible(elapsed: 0))
        XCTAssertTrue(RecordReminder.visible(elapsed: 1.19), "on for 1.2 s of every 2 s")
        XCTAssertFalse(RecordReminder.visible(elapsed: 1.21))
        XCTAssertTrue(RecordReminder.visible(elapsed: 10.4))
        XCTAssertFalse(RecordReminder.visible(elapsed: -0.6), "negative time wraps like positive")
        XCTAssertFalse(RecordReminder.visible(elapsed: 0.61, period: 1))
        XCTAssertTrue(RecordReminder.visible(elapsed: .nan))
        XCTAssertTrue(RecordReminder.visible(elapsed: 3, period: 0))
    }
}

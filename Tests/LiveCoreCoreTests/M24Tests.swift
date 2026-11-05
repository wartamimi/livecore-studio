import XCTest
@testable import LiveCoreCore

/// 0.24.0: NDI output per output slot.
final class NDIRoutingTests: XCTestCase {
    func testNDIMakesAnOutputActive() {
        var r = OutputRouting()
        r.setSource(3, .input(InputID("a")))
        r.setNDI(3, true)
        XCTAssertEqual(r.activeOutputs(windows: []), [3])
        XCTAssertEqual(r.renderedInputs(active: r.activeOutputs(windows: [])), [InputID("a")])
        XCTAssertEqual(OutputRouting.ndiName(3), "LiveCore Output 3")
    }

    func testDefaultSending() {
        let both = OutputRouting().withDefaultSending(ndi: true)
        XCTAssertEqual(both.slots.filter(\.ndi).map(\.index), [1])
        var ndiOnly = OutputRouting()
        ndiOnly.setNDI(2, true)
        XCTAssertEqual(ndiOnly.withDefaultSending(ndi: true), ndiOnly, "NDI already on: stays where it is")
    }

    /// 0.62.0: Syphon was removed; an output that sent over Syphon now sends over NDI.
    func testOlderSyphonRoutingBecomesNDI() throws {
        let json = #"{"slots":[{"index":1,"source":{"program":{}},"syphon":true},{"index":2,"source":{"preview":{}},"syphon":false}]}"#
        let r = try JSONDecoder().decode(OutputRouting.self, from: Data(json.utf8)).normalized(existing: nil)
        XCTAssertEqual(r.slots.count, 4)
        XCTAssertEqual(r.slots.filter(\.ndi).map(\.index), [1])
        XCTAssertEqual(r.slot(2).source, .preview)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(r), as: UTF8.self).contains("syphon"))
    }

    func testNDIRoundTrip() throws {
        var r = OutputRouting()
        r.setNDI(2, true)
        let back = try JSONDecoder().decode(OutputRouting.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertTrue(back.slot(2).ndi)
    }
}

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
        let fresh = OutputRouting()
        let both = fresh.withDefaultSending(ndi: true)
        XCTAssertEqual(both.slots.filter(\.syphon).map(\.index), [1])
        XCTAssertEqual(both.slots.filter(\.ndi).map(\.index), [1])

        var ndiOnly = OutputRouting()
        ndiOnly.setNDI(2, true)
        XCTAssertEqual(ndiOnly.withDefaultSending(ndi: true), ndiOnly, "NDI already on: Syphon is not forced, NDI stays where it is")

        var syphonOnly = OutputRouting()
        syphonOnly.setSyphon(4, true)
        let added = syphonOnly.withDefaultSending(ndi: true)
        XCTAssertEqual(added.slots.filter(\.syphon).map(\.index), [4])
        XCTAssertEqual(added.slots.filter(\.ndi).map(\.index), [1])
        XCTAssertEqual(syphonOnly.withDefaultSending(ndi: false), syphonOnly)
    }

    func testOlderRoutingWithoutNDIKeyDecodes() throws {
        let json = #"{"slots":[{"index":1,"source":{"program":{}},"syphon":true},{"index":2,"source":{"preview":{}},"syphon":false}]}"#
        let r = try JSONDecoder().decode(OutputRouting.self, from: Data(json.utf8)).normalized(existing: nil)
        XCTAssertEqual(r.slots.count, 4)
        XCTAssertTrue(r.slot(1).syphon)
        XCTAssertFalse(r.slots.contains(where: \.ndi))
        XCTAssertEqual(r.slot(2).source, .preview)
    }

    func testNDIRoundTrip() throws {
        var r = OutputRouting()
        r.setNDI(2, true)
        let back = try JSONDecoder().decode(OutputRouting.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertTrue(back.slot(2).ndi)
    }
}

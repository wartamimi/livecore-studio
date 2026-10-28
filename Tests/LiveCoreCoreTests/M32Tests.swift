import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.32.0: MultiCorder (ISO recording of single inputs).
final class M32Tests: XCTestCase {
    let a = InputID("a"), b = InputID("b"), c = InputID("c"), d = InputID("d"), e = InputID("e")

    func testToggleAndLimit() {
        var m = MultiCorderConfig()
        XCTAssertTrue(m.active.isEmpty)
        XCTAssertTrue(m.toggle(a)); XCTAssertTrue(m.toggle(b)); XCTAssertTrue(m.toggle(c)); XCTAssertTrue(m.toggle(d))
        XCTAssertTrue(m.isFull)
        XCTAssertFalse(m.toggle(e), "at most 4 inputs")
        XCTAssertEqual(m.inputs, [a, b, c, d])
        XCTAssertTrue(m.toggle(b), "removing always works")
        XCTAssertEqual(m.inputs, [a, c, d])
        m.enabled = false
        XCTAssertEqual(m.active, [], "off records Program only")
        XCTAssertEqual(m.inputs, [a, c, d], "but keeps the selection")
    }

    func testInitDropsDuplicatesAndExtras() {
        let m = MultiCorderConfig(inputs: [a, a, b, c, d, e])
        XCTAssertEqual(m.inputs, [a, b, c, d])
        XCTAssertEqual(m.keeping(existing: [b, d]).inputs, [b, d])
    }

    func testFileNames() {
        XCTAssertEqual(MultiCorderConfig.fileSuffix(number: 2, name: "Kamera Wide"), " - ISO 2 Kamera Wide")
        XCTAssertEqual(MultiCorderConfig.fileSuffix(number: 3, name: "a/b:c"), " - ISO 3 a-b-c")
        XCTAssertEqual(MultiCorderConfig.fileSuffix(number: 4, name: "  "), " - ISO 4")
        XCTAssertEqual(MultiCorderConfig.fileSuffix(number: 5, name: ".hidden"), " - ISO 5 hidden")
        XCTAssertEqual(MultiCorderConfig.fileSuffix(number: 6, name: String(repeating: "x", count: 100)).count, " - ISO 6 ".count + 60)
        XCTAssertEqual(MultiCorderConfig.isoFileName("LiveCore 2026-10-28 10-00-00.mp4", suffix: " - ISO 2 Cam"),
                       "LiveCore 2026-10-28 10-00-00 - ISO 2 Cam.mp4")
        XCTAssertEqual(MultiCorderConfig.isoFileName("Show (2).mov", suffix: " - ISO 1"), "Show (2) - ISO 1.mov")
        XCTAssertEqual(MultiCorderConfig.isoFileName("noext", suffix: " - ISO 1"), "noext - ISO 1")
    }

    func testProjectRoundTripAndOldProjects() throws {
        var doc = ProjectDocument(inputs: [ProjectInput(id: a, name: "A", source: .color(ProjectColor(r: 0, g: 0, b: 0, a: 1)))])
        doc.multiCorder = MultiCorderConfig(inputs: [a, b], enabled: false)
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.multiCorder, doc.multiCorder)
        XCTAssertEqual(back.sanitized().multiCorder?.inputs, [a], "inputs that are gone are dropped")
        XCTAssertEqual(back.sanitized().multiCorder?.enabled, false)
        let old = try JSONDecoder().decode(MultiCorderConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(old, MultiCorderConfig())
        var noISO = doc; noISO.multiCorder = nil
        let json = String(decoding: try JSONEncoder().encode(noISO), as: UTF8.self)
        XCTAssertFalse(json.contains("multiCorder"))
    }
}

import XCTest
@testable import LiveCoreCore

final class V057Tests: XCTestCase {
    func testTranscriptJoin() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let t = Date(timeIntervalSince1970: 3_723)   // 01:02:03
        let lines = [TranscriptLine(time: t, text: "Halo"), TranscriptLine(time: t, text: "semua")]
        XCTAssertEqual(TranscriptLine.join(lines, timestamps: false), "Halo\nsemua")
        XCTAssertEqual(TranscriptLine.join(lines, timestamps: true, calendar: cal), "[01:02:03] Halo\n[01:02:03] semua")
    }
}

import XCTest
@testable import LiveCoreCore

final class ReplayTests: XCTestCase {
    func fill(_ idx: inout ReplayIndex, count: Int) -> [ReplaySegment] {
        var dropped: [ReplaySegment] = []
        for i in 0..<count { dropped += idx.add(ReplaySegment(id: i, start: Double(i) * 2, end: Double(i + 1) * 2)) }
        return dropped
    }

    func testBufferKeepsAboutBufferSeconds() {
        var idx = ReplayIndex(bufferSeconds: 10)
        let dropped = fill(&idx, count: 12)
        XCTAssertEqual(idx.available, 10, accuracy: 1e-9)
        XCTAssertEqual(dropped.map(\.id), Array(0..<7))
        XCTAssertEqual(idx.segments.first?.id, 7)
    }

    func testClipOfLastSeconds() {
        var idx = ReplayIndex(bufferSeconds: 30)
        _ = fill(&idx, count: 10)   // 0...20 s
        let c = idx.clip(lastSeconds: 5)!
        XCTAssertEqual(c.segments.map(\.id), [7, 8, 9])   // 14-16, 16-18, 18-20
        XCTAssertEqual(c.startOffset, 1, accuracy: 1e-9)  // starts at 15 s
    }

    func testClipLongerThanBufferStartsAtOldest() {
        var idx = ReplayIndex(bufferSeconds: 6)
        _ = fill(&idx, count: 5)
        let c = idx.clip(lastSeconds: 20)!
        XCTAssertEqual(c.segments.first?.id, idx.segments.first?.id)
        XCTAssertEqual(c.startOffset, 0)
    }

    func testEmptyBufferHasNoClip() {
        XCTAssertNil(ReplayIndex().clip(lastSeconds: 5))
        var idx = ReplayIndex()
        _ = fill(&idx, count: 1)
        XCTAssertNil(idx.clip(lastSeconds: 0))
    }

    func testIrregularSegmentsAndRemoveAll() {
        var idx = ReplayIndex(bufferSeconds: 4)
        _ = idx.add(ReplaySegment(id: 0, start: 0, end: 2.5))
        _ = idx.add(ReplaySegment(id: 1, start: 2.5, end: 3.0))   // short: rotated early for a replay
        XCTAssertTrue(idx.add(ReplaySegment(id: 2, start: 3.0, end: 5.0)).isEmpty, "2.5 s left without #0: keep it")
        let dropped = idx.add(ReplaySegment(id: 3, start: 5.0, end: 7.0))
        XCTAssertEqual(dropped.map(\.id), [0, 1])
        XCTAssertEqual(idx.removeAll().map(\.id), [2, 3])
        XCTAssertEqual(idx.available, 0)
    }
}

import XCTest
@testable import LiveCoreCore

/// 0.27.0: Repeat One and "stop after this item".
final class M27Tests: XCTestCase {
    func testRepeatButtonCycles() {
        XCTAssertEqual(RepeatMode.off.cycled, .all)
        XCTAssertEqual(RepeatMode.all.cycled, .one)
        XCTAssertEqual(RepeatMode.one.cycled, .off)
        XCTAssertEqual(RepeatMode(loop: true, one: false), .all)
        XCTAssertEqual(RepeatMode(loop: false, one: false), .off)
        XCTAssertEqual(RepeatMode(loop: false, one: true), .one, "Repeat One wins over the loop flag")
    }

    func testWhatPlaysAfterAnItemEnds() {
        let first: (Range<Int>) -> Int = { $0.lowerBound }
        XCTAssertEqual(PlaylistMath.afterEnd(index: 2, count: 5, repeat: .one, shuffle: true, random: first), 2)
        XCTAssertEqual(PlaylistMath.afterEnd(index: 4, count: 5, repeat: .all, shuffle: false, random: first), 0)
        XCTAssertNil(PlaylistMath.afterEnd(index: 4, count: 5, repeat: .off, shuffle: false, random: first))
        XCTAssertEqual(PlaylistMath.afterEnd(index: 1, count: 5, repeat: .off, shuffle: false, random: first), 2)
        XCTAssertNil(PlaylistMath.afterEnd(index: 1, count: 5, repeat: .one, shuffle: false, stopAfterCurrent: true, random: first),
                     "stop after this item wins over repeat")
        XCTAssertEqual(PlaylistMath.afterEnd(index: 0, count: 1, repeat: .one, shuffle: false, random: first), 0)
        XCTAssertNil(PlaylistMath.afterEnd(index: 0, count: 0, repeat: .all, shuffle: false, random: first))
    }

    func testMusicRepeatOneIsOptionalInOldProjects() throws {
        let old = #"{"id":"m1","name":"Music","tracks":[],"loop":true,"shuffle":false}"#
        let m = try JSONDecoder().decode(ProjectMusic.self, from: Data(old.utf8))
        XCTAssertNil(m.repeatOne)
    }
}

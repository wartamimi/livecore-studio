import XCTest
@testable import LiveCoreCore

/// Bursty capture-card delivery is re-timed to the capture cadence.
final class FramePacerTests: XCTestCase {
    func testBurstyArrivalPlaysEvenly() {
        let iv = 0.04
        // Frames captured every 40 ms but arriving in pairs every 80 ms.
        func arrival(_ n: Int) -> Double { Double(n / 2 * 2 + 1) * iv + 0.01 }
        var shown: [Int] = []
        // Output ticks every 40 ms after the queue is primed: one new frame each tick.
        var q = FramePacer<Int>()
        var feed = 0
        for tick in 0..<16 {
            let now = Double(tick) * iv + 0.105
            while feed < 40, arrival(feed) <= now {
                q.put(feed, pts: Double(feed) * iv, arrival: arrival(feed)); feed += 1
            }
            if let f = q.frame(at: now) { shown.append(f) }
        }
        let steps = zip(shown.dropFirst(), shown).map { $0 - $1 }.dropFirst(2)
        XCTAssertTrue(steps.allSatisfy { $0 == 1 }, "\(shown)")
    }

    func testHoldsLastFrameAndResetsOnRestart() {
        var p = FramePacer<Int>()
        p.put(1, pts: 10, arrival: 10)
        XCTAssertEqual(p.frame(at: 99), 1)
        p.put(2, pts: 1, arrival: 100) // device restarted: clock went back
        XCTAssertEqual(p.frame(at: 100), 2)
    }
}

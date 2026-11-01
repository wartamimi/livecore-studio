import XCTest
@testable import LiveCoreCore

final class TimerTests: XCTestCase {
    func testDurationFormatting() {
        XCTAssertEqual(TimerMath.duration(0), "00:00")
        XCTAssertEqual(TimerMath.duration(65.9), "01:05")
        XCTAssertEqual(TimerMath.duration(3723), "1:02:03")
        XCTAssertEqual(TimerMath.duration(-5), "00:00")
        XCTAssertEqual(TimerMath.duration(3723, showSeconds: false), "1:02")
    }

    func testCountdownRoundsUpAndFinishesAtZero() {
        let c = TimerConfig(mode: .countdown, durationSeconds: 10)
        XCTAssertEqual(TimerMath.text(c, elapsed: 0, secondsOfDay: 0).text, "00:10")
        XCTAssertEqual(TimerMath.text(c, elapsed: 0.2, secondsOfDay: 0).text, "00:10")
        XCTAssertEqual(TimerMath.text(c, elapsed: 9.5, secondsOfDay: 0).text, "00:01")
        XCTAssertFalse(TimerMath.text(c, elapsed: 9.99, secondsOfDay: 0).finished)
        let end = TimerMath.text(c, elapsed: 10, secondsOfDay: 0)
        XCTAssertEqual(end.text, "00:00")
        XCTAssertTrue(end.finished)
        XCTAssertEqual(TimerMath.text(c, elapsed: 99, secondsOfDay: 0).text, "00:00")
    }

    func testClockAndCountUp() {
        XCTAssertEqual(TimerMath.text(TimerConfig(mode: .clock), elapsed: 0, secondsOfDay: 13 * 3600 + 5 * 60 + 9).text, "13:05:09")
        XCTAssertEqual(TimerMath.text(TimerConfig(mode: .clock, showSeconds: false), elapsed: 0, secondsOfDay: 3600 * 9 + 60).text, "09:01")
        XCTAssertEqual(TimerMath.text(TimerConfig(mode: .countUp), elapsed: 75, secondsOfDay: 0).text, "01:15")
    }

    func testRunStateStartPauseReset() {
        var s = TimerRunState()
        XCTAssertEqual(s.elapsed(at: 100), 0)
        s.start(at: 100)
        s.start(at: 105)                       // second start is ignored
        XCTAssertEqual(s.elapsed(at: 110), 10)
        s.pause(at: 110)
        XCTAssertEqual(s.elapsed(at: 200), 10) // paused: time does not advance
        s.start(at: 200)
        XCTAssertEqual(s.elapsed(at: 205), 15)
        s.reset()
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(s.elapsed(at: 300), 0)
    }

    func testProjectRoundTripOfNewSources() throws {
        var doc = ProjectDocument()
        doc.inputs = [
            ProjectInput(id: InputID("b"), name: "Overlay", source: .browser(ProjectBrowser(url: "https://example.com", fps: 30))),
            ProjectInput(id: InputID("t"), name: "Countdown", source: .timer(TimerConfig(mode: .countdown, durationSeconds: 600, label: "Mulai dalam"), nil)),
        ]
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back, doc)
    }
}

final class BrowserURLPolicyTests: XCTestCase {
    func testAllowedAndRejected() {
        XCTAssertEqual(BrowserURLPolicy.check("https://example.com/overlay"), .web("https://example.com/overlay"))
        XCTAssertEqual(BrowserURLPolicy.check("  http://localhost:3000/  "), .web("http://localhost:3000/"))
        XCTAssertEqual(BrowserURLPolicy.check("example.com/scoreboard"), .web("https://example.com/scoreboard"))
        XCTAssertEqual(BrowserURLPolicy.check("localhost:8080/x"), .web("http://localhost:8080/x"))
        XCTAssertEqual(BrowserURLPolicy.check("192.168.1.5:3000"), .web("http://192.168.1.5:3000"))
        XCTAssertEqual(BrowserURLPolicy.check("/Users/me/overlay.html"), .file("file:///Users/me/overlay.html"))
        XCTAssertEqual(BrowserURLPolicy.check("file:///tmp/a.html"), .file("file:///tmp/a.html"))
        for bad in ["", "javascript:alert(1)", "data:text/html,hi", "ftp://x", "mailto:a@b.c", "https://", "a b.com"] {
            if case .rejected = BrowserURLPolicy.check(bad) {} else { XCTFail("should reject \(bad)") }
        }
    }

    func testFPSClamp() {
        XCTAssertEqual(BrowserURLPolicy.clampFPS(60), 30)
        XCTAssertEqual(BrowserURLPolicy.clampFPS(1), 5)
        XCTAssertEqual(BrowserURLPolicy.clampFPS(12), 10)
        XCTAssertEqual(BrowserURLPolicy.clampFPS(15), 15)
    }
}

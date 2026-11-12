import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.74.0: end credits, scoreboard, speaker name tags, logo bug corners, Web Controller score route.
final class V074Tests: XCTestCase {
    let a = InputID("a"), b = InputID("b"), t = InputID("t")

    func testCredits() {
        var c = TickerConfig(text: "Director\n\nAna ")
        XCTAssertFalse(c.isCredits)
        c.direction = .bottomToTop
        XCTAssertTrue(c.isCredits)
        XCTAssertEqual(c.layerRect, .full)
        XCTAssertEqual(c.creditLines, ["Director", "", "Ana"])
        // Starts just below the picture, then rolls up and loops.
        XCTAssertEqual(TickerMath.creditsY(elapsed: 0, speed: 60, textHeight: 400, viewHeight: 1080), -400)
        XCTAssertEqual(TickerMath.creditsY(elapsed: 10, speed: 60, textHeight: 400, viewHeight: 1080), 200)
        XCTAssertEqual(TickerMath.creditsY(elapsed: 1480.0 / 60, speed: 60, textHeight: 400, viewHeight: 1080), -400, accuracy: 0.001)
        XCTAssertEqual(TickerTemplate.endCredits.config(text: "x").scrollDirection, .bottomToTop)
    }

    func testScoreboard() {
        var s = Scoreboard()
        s.perform(.homeMinus)
        XCTAssertEqual(s.homeScore, 0)
        s.perform(.homePlus); s.perform(.homePlus); s.perform(.awayPlus); s.perform(.periodNext)
        XCTAssertEqual(s.titleText, "HOME  2 - 1  AWAY")
        XCTAssertEqual(s.subtitleText, "Babak 2")
        s.periodLabel = ""
        XCTAssertEqual(s.subtitleText, "")
        s.perform(.reset)
        XCTAssertEqual([s.homeScore, s.awayScore, s.period], [0, 0, 1])
        s.perform(.periodBack)
        XCTAssertEqual(s.period, 1)
    }

    func testNameTagger() {
        var cfg = NameTagConfig()
        cfg.tags = [.init(input: a, name: "Ana", role: "Host"), .init(input: b, name: " ")]
        var n = NameTagger()
        XCTAssertNil(n.onProgram(a, now: 0, config: cfg), "off")
        cfg.enabled = true
        XCTAssertNil(n.onProgram(a, now: 0, config: cfg), "no title input")
        cfg.title = t
        XCTAssertEqual(n.onProgram(a, now: 0, config: cfg)?.name, "Ana")
        XCTAssertNil(n.onProgram(a, now: 60, config: cfg), "inside repeat window")
        XCTAssertNotNil(n.onProgram(a, now: 121, config: cfg))
        XCTAssertNil(n.onProgram(b, now: 0, config: cfg), "empty name")
        let p = cfg.pruned(inputs: [b])
        XCTAssertNil(p.title)
        XCTAssertNil(p.tags[0].input)
        cfg.seconds = 0; cfg.overlay = 9
        XCTAssertEqual(cfg.showSeconds, 2)
        XCTAssertEqual(cfg.overlayIndex, 1)
    }

    func testLogoCorners() {
        let r = LogoCorner.topRight.rect()
        XCTAssertEqual(r.x + r.width, 0.97, accuracy: 0.0001)
        XCTAssertEqual(r.y, 0.03 * 16 / 9, accuracy: 0.0001)
        let bl = LogoCorner.bottomLeft.rect()
        XCTAssertEqual(bl.x, 0.03, accuracy: 0.0001)
        XCTAssertEqual(bl.y + bl.height, 1 - 0.03 * 16 / 9, accuracy: 0.0001)
    }

    func testRemoteScore() {
        func req(_ q: [String: String]) -> HTTPRequest {
            HTTPRequest(method: "POST", path: "/api/score", query: q, headers: [:], body: [])
        }
        XCTAssertEqual(RemoteRouter.route(req(["do": "awayPlus"])), .command(.score(.awayPlus)))
        XCTAssertEqual(RemoteRouter.route(req(["do": "x"])), .badRequest("do"))
        var s = RemoteState()
        XCTAssertFalse(s.json.contains("\"score\""))
        s.score = Scoreboard()
        XCTAssertTrue(s.json.contains("\"home\":\"HOME\""))
    }
}

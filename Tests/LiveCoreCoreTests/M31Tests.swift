import Foundation
import XCTest
@testable import LiveCoreCore
@testable import LiveCoreRemote

/// 0.31.0: Web Controller surface: pictures, transition choice, audio mixer.
final class M31Tests: XCTestCase {
    private func route(_ m: String, _ t: String) -> RemoteRoute {
        let (path, query) = HTTPRequest.splitTarget(t)
        return RemoteRouter.route(HTTPRequest(method: m, path: path, query: query))
    }

    func testNewRoutes() {
        XCTAssertEqual(route("GET", "/api/frame?bus=program"), .frame("program"))
        XCTAssertEqual(route("GET", "/api/frame?bus=preview"), .frame("preview"))
        XCTAssertEqual(route("GET", "/api/frame?bus=../etc"), .badRequest("bus"))
        XCTAssertEqual(route("POST", "/api/frame?bus=program"), .methodNotAllowed)
        XCTAssertTrue(RemoteRoute.frame("program").needsPIN, "pictures need the PIN too")
        XCTAssertEqual(route("POST", "/api/transition?kind=1"), .command(.transition(kind: 1, duration: nil)))
        XCTAssertEqual(route("POST", "/api/transition?duration=1.5"), .command(.transition(kind: nil, duration: 1.5)))
        XCTAssertEqual(route("POST", "/api/transition?kind=3&duration=2"), .command(.transition(kind: 3, duration: 2)))
        XCTAssertEqual(route("POST", "/api/transition"), .badRequest("kind"))
        XCTAssertEqual(route("POST", "/api/transition?kind=x"), .badRequest("kind"))
        XCTAssertEqual(route("POST", "/api/transition?duration=0"), .badRequest("duration"))
        XCTAssertEqual(route("POST", "/api/transition?duration=inf"), .badRequest("duration"))
        XCTAssertEqual(route("POST", "/api/audio/master?fader=0.75"), .command(.masterFader(0.75)))
        XCTAssertEqual(route("POST", "/api/audio/master?fader=2"), .badRequest("fader"))
        XCTAssertEqual(route("POST", "/api/audio/fader?id=mic%3AUSB%20Mic&value=0.5"), .command(.channelFader(id: "mic:USB Mic", value: 0.5)))
        XCTAssertEqual(route("POST", "/api/audio/fader?value=0.5"), .badRequest("id"))
        XCTAssertEqual(route("POST", "/api/audio/fader?id=a%0Ab&value=0.5"), .badRequest("id"), "no control characters")
        XCTAssertEqual(route("POST", "/api/audio/mute?id=ndi:1&on=1"), .command(.channelMute(id: "ndi:1", on: true)))
        XCTAssertEqual(route("POST", "/api/audio/mute?id=ndi:1&on=yes"), .badRequest("on"))
    }

    func testStateCarriesSurface() throws {
        var s = RemoteState()
        s.transitionKind = 3; s.transitionDuration = 1.5
        s.transitions = [.init(id: 1, name: "Dissolve"), .init(id: 3, name: "Wipe ←")]
        s.recordTime = 75.4; s.streamTime = 3600
        s.master = .init(id: "master", name: "Master", fader: 0.75, muted: false, levelL: -6, levelR: -7.25)
        s.channels = [.init(id: "mic:1", name: "Mic \"1\"", fader: 0.5, muted: true, levelL: -200, levelR: .nan)]
        s.frames = true
        let o = try JSONSerialization.jsonObject(with: Data(s.json.utf8)) as! [String: Any]
        XCTAssertEqual(o["transitionKind"] as? Int, 3)
        XCTAssertEqual(o["transitionDuration"] as? Double, 1.5)
        XCTAssertEqual((o["transitions"] as? [[String: Any]])?.last?["name"] as? String, "Wipe ←")
        XCTAssertEqual(o["recordTime"] as? Double, 75.4)
        XCTAssertEqual(o["streamTime"] as? Int, 3600)
        XCTAssertEqual((o["master"] as? [String: Any])?["r"] as? Double, -7.25)
        let ch = (o["channels"] as? [[String: Any]])?.first
        XCTAssertEqual(ch?["name"] as? String, "Mic \"1\"")
        XCTAssertEqual(ch?["muted"] as? Bool, true)
        XCTAssertEqual(ch?["l"] as? Int, -120, "meters floor at -120 dBFS")
        XCTAssertEqual(ch?["r"] as? Int, -120, "NaN reads as silence, never as invalid JSON")
        XCTAssertEqual(o["frames"] as? Bool, true)
    }

    func testFramesServedWithPIN() throws {
        let s = RemoteServer(port: 0, pin: "8642", commandQueue: DispatchQueue(label: "t3")) { _ in }
        try s.start()
        defer { s.stop() }
        XCTAssertFalse(s.wantsFrames(), "nobody asked yet")
        let none = try M30Tests.fetch(port: s.port, "GET /api/frame?bus=program HTTP/1.1\r\nHost: 127.0.0.1\r\nX-LiveCore-PIN: 8642\r\n\r\n")
        XCTAssertTrue(none.hasPrefix("HTTP/1.1 204"), "no picture yet")
        XCTAssertTrue(s.wantsFrames(), "a request switches encoding on")
        s.setFrame([0xFF, 0xD8, 0xFF, 0xD9], bus: "program")
        let jpeg = try M30Tests.fetch(port: s.port, "GET /api/frame?bus=program HTTP/1.1\r\nHost: 127.0.0.1\r\nX-LiveCore-PIN: 8642\r\n\r\n")
        XCTAssertTrue(jpeg.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(jpeg.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(jpeg.contains("Content-Length: 4"))
        let denied = try M30Tests.fetch(port: s.port, "GET /api/frame?bus=program HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        XCTAssertTrue(denied.hasPrefix("HTTP/1.1 401"))
    }

    func testPageHasSurfaceControls() {
        let h = RemotePage.html
        for needle in ["/api/frame?bus=", "/api/transition?kind=", "/api/transition?duration=", "/api/audio/master?fader=",
                       "/api/audio/fader?id=", "/api/audio/mute?id=", "id=\"pvwBus\"", "id=\"pgmBus\"", "id=\"slot\"", "navigator.vibrate"] {
            XCTAssertTrue(h.contains(needle), needle)
        }
        XCTAssertFalse(h.contains("http://"))
        XCTAssertFalse(h.contains("https://"))
    }
}

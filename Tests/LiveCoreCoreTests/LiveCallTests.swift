import XCTest
@testable import LiveCoreCore
@testable import LiveCoreRemote

final class LiveCallTests: XCTestCase {
    private func req(_ m: String, _ path: String, query: [String: String] = [:], body: String = "") -> HTTPRequest {
        HTTPRequest(method: m, path: path, query: query, body: Array(body.utf8))
    }

    func testKeyIsRandomAndValid() {
        let a = LiveCallKey.make(), b = LiveCallKey.make()
        XCTAssertEqual(a.count, 22)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(LiveCallKey.isValid(a))
        XCTAssertFalse(LiveCallKey.isValid("../etc"))
        XCTAssertFalse(LiveCallKey.isValid("short"))
    }

    func testICEJSONAddsTURNOnlyWhenValid() throws {
        XCTAssertFalse(LiveCallICE(turnURL: "http://x").json.contains("username"))
        let ice = LiveCallICE(turnURL: "turn:t.example.com:3478, turns:t.example.com:5349", turnUser: "u\"", turnPassword: "p")
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ice.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual((arr[1]["urls"] as? [String])?.count, 2)
        XCTAssertEqual(arr[1]["username"] as? String, "u\"")
    }

    func testJSONStringEscapesScriptBreakers() {
        XCTAssertEqual(LiveCallJSON.string("a\"</script>\n"), "\"a\\\"\\u003c/script\\u003e\\n\"")
    }

    func testOfferAnswerFlow() throws {
        let hub = LiveCallHub()
        let key = LiveCallKey.make()
        let got = EventBox()
        XCTAssertEqual(hub.handle(req("GET", "/live/\(key)"), client: "1.2.3.4").status, 404)
        hub.open(key: key, title: "Wedding <A&B>", iceJSON: LiveCallICE().json) { ev in got.add(ev) }
        XCTAssertEqual(hub.handle(req("GET", "/live/\(key)"), client: "c").status, 200)
        XCTAssertEqual(hub.handle(req("GET", "/live/host"), client: "c").status, 200)
        let info = hub.handle(req("GET", "/live/api/\(key)/info"), client: "c")
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(info.body)) as? [String: Any])
        XCTAssertEqual(j["title"] as? String, "Wedding <A&B>")
        XCTAssertEqual(hub.handle(req("POST", "/live/api/\(key)/offer", body: "{\"sdp\":\"bad\"}"), client: "c").status, 400)
        let o = hub.handle(req("POST", "/live/api/\(key)/offer", body: "{\"sdp\":\"v=0\\r\\n\",\"name\":\"  Budi\\u0007 \"}"), client: "c")
        XCTAssertEqual(String(decoding: o.body, as: UTF8.self), "{\"seq\":1}")
        XCTAssertEqual(got.all, [.offer(.init(seq: 1, sdp: "v=0\r\n", name: "Budi"))])
        XCTAssertEqual(hub.handle(req("GET", "/live/api/\(key)/answer", query: ["seq": "1"]), client: "c").status, 204)
        XCTAssertNotNil(hub.secondsSinceGuest(key: key))
        hub.setAnswer(key: key, seq: 1, sdp: "v=0 answer")
        let a = hub.handle(req("GET", "/live/api/\(key)/answer", query: ["seq": "1"]), client: "c")
        XCTAssertEqual(a.status, 200)
        XCTAssertTrue(String(decoding: a.body, as: UTF8.self).contains("v=0 answer"))
        // A second device with the same link replaces the first.
        _ = hub.handle(req("POST", "/live/api/\(key)/offer", body: "{\"sdp\":\"v=0\"}"), client: "d")
        XCTAssertEqual(hub.handle(req("GET", "/live/api/\(key)/ping", query: ["seq": "1"]), client: "c").status, 409)
        hub.setAnswer(key: key, seq: 1, sdp: "stale")   // ignored: seq 2 is current
        XCTAssertEqual(hub.handle(req("GET", "/live/api/\(key)/answer", query: ["seq": "2"]), client: "d").status, 204)
        _ = hub.handle(req("POST", "/live/api/\(key)/leave", query: ["seq": "2"]), client: "d")
        XCTAssertEqual(got.all.last, .left(seq: 2))
        XCTAssertEqual(hub.handle(req("GET", "/live/api/\(key)/offer"), client: "c").status, 405)
        hub.close(key: key)
        XCTAssertEqual(hub.handle(req("GET", "/live/api/\(key)/info"), client: "c").status, 404)
    }

    func testServerCustomHandlerServesLiveRoutesOnly() throws {
        let hub = LiveCallHub()
        let s = RemoteServer(port: 0, pin: "123456", onCommand: { _ in })
        s.customHandler = { r, c in hub.handle(r, client: c) }
        XCTAssertEqual(s.handle(HTTPRequest(method: "GET", path: "/", headers: ["host": "localhost"]), client: "c").status, 404)
        XCTAssertEqual(s.handle(HTTPRequest(method: "GET", path: "/live/host", headers: ["host": "evil.com"]), client: "c").status, 403)
        XCTAssertEqual(s.handle(HTTPRequest(method: "GET", path: "/live/host", headers: ["host": "127.0.0.1:8089"]), client: "c").status, 200)
    }

    func testProjectSourceRoundTrip() throws {
        let src = ProjectSource.liveCall(ProjectLiveCall(title: "Seminar"))
        let back = try JSONDecoder().decode(ProjectSource.self, from: JSONEncoder().encode(src))
        XCTAssertEqual(back, src)
        XCTAssertEqual(ProjectLiveCall(width: 9999, height: 1, fps: 99).clamped.width, 1920)
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [LiveCallHub.GuestEvent] = []
    func add(_ e: LiveCallHub.GuestEvent) { lock.lock(); list.append(e); lock.unlock() }
    var all: [LiveCallHub.GuestEvent] { lock.lock(); defer { lock.unlock() }; return list }
}

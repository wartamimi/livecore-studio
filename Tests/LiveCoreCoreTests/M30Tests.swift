#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import LiveCoreCore
@testable import LiveCoreRemote

/// 0.30.0: Web Controller (remote control from a browser on the same network).
final class M30Tests: XCTestCase {
    private func req(_ s: String) -> HTTPRequest? {
        if case let .request(r, _) = HTTPRequest.parse(Array(s.utf8)) { return r }
        return nil
    }

    func testParseRequest() {
        let r = req("POST /api/preview?input=3&x=a%20b+c HTTP/1.1\r\nHost: 192.168.1.5:8088\r\nX-LiveCore-PIN:  123456 \r\nContent-Length: 2\r\n\r\nhi")
        XCTAssertEqual(r?.method, "POST")
        XCTAssertEqual(r?.path, "/api/preview")
        XCTAssertEqual(r?.query["input"], "3")
        XCTAssertEqual(r?.query["x"], "a b c")
        XCTAssertEqual(r?.headers["x-livecore-pin"], "123456", "names lower-cased, values trimmed")
        XCTAssertEqual(r?.body, Array("hi".utf8))
    }

    func testParseIncompleteInvalidTooLarge() {
        XCTAssertEqual(HTTPRequest.parse(Array("GET / HTTP/1.1\r\nHost: a".utf8)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(Array("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(Array("garbage\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(HTTPRequest.parse(Array("GET http://x/ HTTP/1.1\r\n\r\n".utf8)), .invalid, "only origin-form targets")
        XCTAssertEqual(HTTPRequest.parse(Array("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(HTTPRequest.parse(Array("GET /%zz HTTP/1.1\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(HTTPRequest.parse(Array(repeating: 65, count: 20_000)), .tooLarge)
        XCTAssertEqual(HTTPRequest.parse(Array("POST / HTTP/1.1\r\nContent-Length: 99999\r\n\r\n".utf8)), .tooLarge)
        if case let .request(_, consumed) = HTTPRequest.parse(Array("GET / HTTP/1.1\r\n\r\nGET".utf8)) {
            XCTAssertEqual(consumed, 18)
        } else { XCTFail() }
    }

    func testRoutes() {
        func route(_ m: String, _ t: String) -> RemoteRoute { RemoteRouter.route(req("\(m) \(t) HTTP/1.1\r\n\r\n")!) }
        XCTAssertEqual(route("GET", "/"), .page)
        XCTAssertEqual(route("GET", "/api/state"), .state)
        XCTAssertEqual(route("GET", "/api/ping"), .ping)
        XCTAssertEqual(route("POST", "/api/cut"), .command(.action(.cut)))
        XCTAssertEqual(route("POST", "/api/auto"), .command(.action(.auto)))
        XCTAssertEqual(route("POST", "/api/preview?input=2"), .command(.action(.preview(2))))
        XCTAssertEqual(route("POST", "/api/program?input=7"), .command(.action(.cutDirect(7))))
        XCTAssertEqual(route("POST", "/api/overlay?n=4"), .command(.action(.overlay(4))))
        XCTAssertEqual(route("POST", "/api/replay?sec=10"), .command(.action(.replay(10))))
        XCTAssertEqual(route("POST", "/api/tbar?value=0.25"), .command(.tbar(0.25)))
        XCTAssertEqual(route("POST", "/api/stream/start"), .command(.stream(true)))
        XCTAssertEqual(route("POST", "/api/record/stop"), .command(.record(false)))
        XCTAssertEqual(route("GET", "/api/cut"), .methodNotAllowed, "commands need POST")
        XCTAssertEqual(route("POST", "/api/state"), .methodNotAllowed)
        XCTAssertEqual(route("POST", "/api/preview?input=0"), .badRequest("input"))
        XCTAssertEqual(route("POST", "/api/overlay?n=5"), .badRequest("n"))
        XCTAssertEqual(route("POST", "/api/replay?sec=7"), .badRequest("sec"))
        XCTAssertEqual(route("POST", "/api/tbar?value=1.5"), .badRequest("value"))
        XCTAssertEqual(route("POST", "/api/tbar?value=nan"), .badRequest("value"))
        XCTAssertEqual(route("GET", "/favicon.ico"), .notFound)
        XCTAssertFalse(RemoteRoute.page.needsPIN)
        XCTAssertTrue(RemoteRoute.state.needsPIN)
    }

    func testPINRules() {
        XCTAssertTrue(RemoteAuth.isValidPIN("1234"))
        XCTAssertTrue(RemoteAuth.isValidPIN("12345678"))
        XCTAssertFalse(RemoteAuth.isValidPIN("123"))
        XCTAssertFalse(RemoteAuth.isValidPIN("12a456"))
        XCTAssertFalse(RemoteAuth.isValidPIN("١٢٣٤"), "ASCII digits only")
        let p = RemoteAuth.generatePIN()
        XCTAssertEqual(p.count, 6)
        XCTAssertTrue(RemoteAuth.isValidPIN(p))
        XCTAssertTrue(RemoteAuth.pinMatches("123456", "123456"))
        XCTAssertFalse(RemoteAuth.pinMatches("123457", "123456"))
        XCTAssertFalse(RemoteAuth.pinMatches("12345", "123456"))
        XCTAssertFalse(RemoteAuth.pinMatches("1234567", "123456"))
        XCTAssertFalse(RemoteAuth.pinMatches(nil, "123456"))
        XCTAssertFalse(RemoteAuth.pinMatches("", ""), "an empty PIN never opens")
    }

    func testHostCheck() {
        for ok in ["192.168.1.20:8088", "10.0.0.5", "localhost:8088", "studio-mac.local:8088", "[fe80::1]:8088"] {
            XCTAssertTrue(RemoteAuth.hostAllowed(ok), ok)
        }
        for bad in [nil, "", "evil.example.com", "evil.example.com:8088", "192.168.1.300", "1.2.3", "a.b.c.d", "x:abc"] as [String?] {
            XCTAssertFalse(RemoteAuth.hostAllowed(bad), bad ?? "nil")
        }
    }

    func testLockoutEscalates() {
        var l = RemoteLockout()
        for _ in 0..<4 { XCTAssertEqual(l.recordFailure("a", now: 0), 0) }
        XCTAssertEqual(l.waitTime("a", now: 0), 0)
        XCTAssertEqual(l.recordFailure("a", now: 0), 60, "5th wrong PIN locks for a minute")
        XCTAssertEqual(l.waitTime("a", now: 10), 50)
        XCTAssertEqual(l.waitTime("b", now: 10), 0, "per client")
        for _ in 0..<4 { l.recordFailure("a", now: 61) }
        XCTAssertEqual(l.recordFailure("a", now: 61), 120, "the next lock doubles")
        l.recordSuccess("a")
        XCTAssertEqual(l.waitTime("a", now: 62), 0)
        var big = RemoteLockout()
        for k in 0..<40 { for _ in 0..<5 { big.recordFailure("c", now: Double(k) * 10_000) } }
        XCTAssertEqual(big.waitTime("c", now: 390_000), 3600, "capped at an hour")
    }

    func testStateJSON() throws {
        var s = RemoteState()
        s.title = "Show \"A\"\n<b>"
        s.program = 1; s.preview = nil; s.tbar = 0.33333; s.tbarRest = 1
        s.inputs = [.init(number: 1, name: "Cam 1", kind: "camera")]
        s.overlays = [.init(index: 1, on: true, onPreview: false, input: 1), .init(index: 2, on: false, onPreview: false, input: nil)]
        s.recording = true; s.replayAvailable = .nan
        let obj = try JSONSerialization.jsonObject(with: Data(s.json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["title"] as? String, "Show \"A\"\n<b>")
        XCTAssertFalse(s.json.contains("<"), "no raw angle brackets")
        XCTAssertEqual(obj["program"] as? Int, 1)
        XCTAssertTrue(obj["preview"] is NSNull)
        XCTAssertEqual(obj["tbar"] as? Double, 0.333)
        XCTAssertEqual(obj["tbarRest"] as? Int, 1)
        XCTAssertEqual(obj["recording"] as? Bool, true)
        XCTAssertEqual(obj["replayAvailable"] as? Int, 0)
        XCTAssertEqual((obj["inputs"] as? [[String: Any]])?.first?["name"] as? String, "Cam 1")
        XCTAssertEqual((obj["overlays"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(obj["replayLengths"] as? [Int], [5, 10, 20])
        XCTAssertEqual(JSON.string("\u{1}"), "\"\\u0001\"")
    }

    func testPageIsSelfContained() {
        let h = RemotePage.html
        XCTAssertTrue(h.hasPrefix("<!doctype html>"))
        XCTAssertFalse(h.contains("http://"), "no external resources")
        XCTAssertFalse(h.contains("https://"))
        for path in ["/api/state", "/api/ping", "/api/cut", "/api/auto", "/api/preview", "/api/program", "/api/overlay",
                     "/api/replay", "/api/tbar", "/api/stream/start", "/api/stream/stop", "/api/record/start", "/api/record/stop", "/api/snapshot"] {
            XCTAssertTrue(h.contains(path), path)
        }
        XCTAssertTrue(h.contains("X-LiveCore-PIN"))
    }

    func testHandlerAuthAndHost() {
        let got = Locked<[RemoteCommand]>([])
        let q = DispatchQueue(label: "t")
        let s = RemoteServer(port: 0, pin: "246810", commandQueue: q) { c in got.mutate { $0.append(c) } }
        func call(_ m: String, _ t: String, host: String? = "192.168.1.9:8088", pin: String? = nil, client: String = "1.1.1.1") -> HTTPResponse {
            var h: [String: String] = [:]
            if let host { h["host"] = host }
            if let pin { h["x-livecore-pin"] = pin }
            let (path, query) = HTTPRequest.splitTarget(t)
            return s.handle(HTTPRequest(method: m, path: path, query: query, headers: h), client: client)
        }
        XCTAssertEqual(call("GET", "/").status, 200, "the page itself needs no PIN")
        XCTAssertEqual(call("GET", "/", host: "evil.example.com").status, 403)
        XCTAssertEqual(call("GET", "/api/state").status, 401)
        XCTAssertEqual(call("GET", "/api/state", pin: "246810").status, 200)
        XCTAssertEqual(call("POST", "/api/cut", pin: "246810").status, 200)
        XCTAssertEqual(call("POST", "/api/preview?input=0", pin: "246810").status, 400)
        q.sync {}
        XCTAssertEqual(got.value, [.action(.cut)])
        XCTAssertEqual(s.activeClients(), 1)
        for _ in 0..<4 { XCTAssertEqual(call("POST", "/api/cut", pin: "000000", client: "2.2.2.2").status, 401) }
        let locked = call("POST", "/api/cut", pin: "000000", client: "2.2.2.2")
        XCTAssertEqual(locked.status, 429)
        XCTAssertTrue(locked.headers.contains { $0.0 == "Retry-After" })
        XCTAssertEqual(call("POST", "/api/cut", pin: "246810", client: "2.2.2.2").status, 429, "locked even with the right PIN")
        XCTAssertEqual(call("GET", "/api/ping", pin: "246810").status, 200, "other clients keep working")
        s.pin = "135790"
        XCTAssertEqual(call("GET", "/api/ping", pin: "246810").status, 401, "a new PIN signs old devices out")
        XCTAssertEqual(call("GET", "/api/ping", pin: "135790", client: "2.2.2.2").status, 200, "a new PIN clears locks")
    }

    func testServerOverSocket() throws {
        let got = Locked<[RemoteCommand]>([])
        let q = DispatchQueue(label: "t2")
        let s = RemoteServer(port: 0, pin: "1234", commandQueue: q) { c in got.mutate { $0.append(c) } }
        XCTAssertThrowsError(try RemoteServer(port: 0, pin: "12", onCommand: { _ in }).start())
        try s.start()
        defer { s.stop() }
        XCTAssertGreaterThan(s.port, 0)
        var st = RemoteState(); st.program = 2
        s.update(state: st.json)
        let page = try Self.fetch(port: s.port, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(page.contains("LiveCore Remote"))
        let state = try Self.fetch(port: s.port, "GET /api/state HTTP/1.1\r\nHost: 127.0.0.1\r\nX-LiveCore-PIN: 1234\r\n\r\n")
        XCTAssertTrue(state.contains("\"program\":2"), state)
        let cmd = try Self.fetch(port: s.port, "POST /api/tbar?value=0.5 HTTP/1.1\r\nHost: localhost\r\nX-LiveCore-PIN: 1234\r\nContent-Length: 0\r\n\r\n")
        XCTAssertTrue(cmd.hasPrefix("HTTP/1.1 200"))
        let bad = try Self.fetch(port: s.port, "nonsense\r\n\r\n")
        XCTAssertTrue(bad.hasPrefix("HTTP/1.1 400"))
        q.sync {}
        XCTAssertEqual(got.value, [.tbar(0.5)])
        XCTAssertFalse(RemoteServer.lanAddresses().contains("127.0.0.1"))
        let port = s.port
        s.stop()
        XCTAssertFalse(s.isRunning)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertThrowsError(try Self.fetch(port: port, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"), "stopped servers refuse connections")
    }

    struct FetchError: Error {}

    static func fetch(port: Int, _ request: String) throws -> String {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw FetchError() }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { throw FetchError() }
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return String(decoding: out, as: UTF8.self)
    }
}

final class Locked<T>: @unchecked Sendable {
    private let l = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { l.sync { v } }
    func mutate(_ f: (inout T) -> Void) { l.sync { f(&v) } }
}

import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#endif
@testable import LiveCoreCore
@testable import LiveCoreRemote

/// 0.54.1: Web Controller keep-alive, TCP_NODELAY and unchanged-picture 204.
final class V0541Tests: XCTestCase {
    func testFrameSinceReturns204WhileUnchanged() {
        let s = RemoteServer(port: 0, pin: "123456", onCommand: { _ in })
        s.setFrame([1, 2, 3], bus: "program")
        func get(_ q: [String: String]) -> HTTPResponse {
            s.handle(HTTPRequest(method: "GET", path: "/api/frame", query: q.merging(["bus": "program"]) { a, _ in a },
                                 headers: ["host": "localhost", "x-livecore-pin": "123456"]), client: "c")
        }
        let first = get([:])
        XCTAssertEqual(first.status, 200)
        let seq = first.headers.first { $0.0 == "X-Frame-Seq" }?.1
        XCTAssertEqual(seq, "1")
        XCTAssertEqual(get(["since": "1"]).status, 204)
        s.setFrame([4], bus: "program")
        XCTAssertEqual(get(["since": "1"]).status, 200)
    }

    func testKeepAliveServesSeveralRequestsOnOneConnection() throws {
        let s = RemoteServer(port: 0, pin: "123456", onCommand: { _ in })
        try s.start()
        defer { s.stop() }
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(s.port).bigEndian)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(rc, 0)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let req = Array("GET /api/ping HTTP/1.1\r\nHost: localhost\r\nX-LiveCore-PIN: 123456\r\n\r\n".utf8)
        for _ in 0..<3 {
            XCTAssertEqual(req.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }, req.count)
            var got: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 2048)
            while !String(decoding: got, as: UTF8.self).contains("{\"ok\":true}") {
                let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                guard n > 0 else { return XCTFail("connection closed: " + String(decoding: got, as: UTF8.self)) }
                got += chunk[0..<n]
            }
            XCTAssertTrue(String(decoding: got, as: UTF8.self).contains("Connection: keep-alive"))
        }
    }

    // 0.54.2: weak-connection mode.
    func testLowFramesFallBackThenServeSmallPicture() {
        let s = RemoteServer(port: 0, pin: "123456", onCommand: { _ in })
        s.setFrame([1, 1, 1, 1], bus: "program")
        let req = HTTPRequest(method: "GET", path: "/api/frame", query: ["bus": "program", "q": "low"],
                              headers: ["host": "localhost", "x-livecore-pin": "123456"])
        XCTAssertEqual(s.handle(req, client: "c").body.count, 4, "normal picture until a small one exists")
        XCTAssertTrue(s.wantsLowFrames())
        s.setFrame([2], bus: "program-low")
        XCTAssertEqual(s.handle(req, client: "c").body, [2])
    }

    func testLowAudioIsMonoHalfRate() {
        let (pcm, rate) = RemoteServer.lowAudio([100, 300, 100, 300, -8, -8, -8, -8], rate: 24_000)
        XCTAssertEqual(rate, 12_000)
        XCTAssertEqual(pcm, [200, -8])
    }

    func testRepeatedCommandIdRunsOnce() {
        let count = Counter()
        let s = RemoteServer(port: 0, pin: "123456", commandQueue: DispatchQueue(label: "cmd")) { _ in count.add() }
        let req = HTTPRequest(method: "POST", path: "/api/cut",
                              headers: ["host": "localhost", "x-livecore-pin": "123456", "x-lcs-req": "abc-1"])
        XCTAssertEqual(s.handle(req, client: "c").status, 200)
        XCTAssertTrue(String(decoding: s.handle(req, client: "c").body, as: UTF8.self).contains("repeat"))
        var other = req; other.headers["x-lcs-req"] = "abc-2"
        _ = s.handle(other, client: "c")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(count.value, 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func add() { l.lock(); n += 1; l.unlock() }
    var value: Int { l.lock(); defer { l.unlock() }; return n }
}

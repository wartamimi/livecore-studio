#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import LiveCoreCore
@testable import LiveCoreRemote

/// 0.62.0: Web Remote picture push stream, new routes and state fields.
final class M62Tests: XCTestCase {
    private func req(_ m: String, _ t: String) -> HTTPRequest {
        let (path, query) = HTTPRequest.splitTarget(t)
        return HTTPRequest(method: m, path: path, query: query, headers: ["host": "127.0.0.1"])
    }

    func testVideoRoute() {
        XCTAssertEqual(RemoteRouter.route(req("GET", "/api/video?stream=1")), .videoStream(buses: ["program", "preview"], quality: "normal"))
        XCTAssertEqual(RemoteRouter.route(req("GET", "/api/video?stream=1&bus=program&q=high")), .videoStream(buses: ["program"], quality: "high"))
        XCTAssertEqual(RemoteRouter.route(req("GET", "/api/video?bus=multiview")), .badRequest("bus"))
        XCTAssertEqual(RemoteRouter.route(req("GET", "/api/video?q=ultra")), .badRequest("q"))
        XCTAssertEqual(RemoteRouter.route(req("POST", "/api/video")), .methodNotAllowed)
        XCTAssertTrue(RemoteRoute.videoStream(buses: ["program"], quality: "low").needsPIN)
        XCTAssertEqual(RemoteRouter.route(req("POST", "/api/fullscreen")), .command(.fullscreen))
    }

    func testVideoRecordLayout() {
        let r = RemoteServer.videoRecord(bus: 1, seq: 0x01020304, jpeg: [0xFF, 0xD8, 0xFF])
        XCTAssertEqual(r.count, 4 + 5 + 3)
        XCTAssertEqual(Array(r[0..<4]), [8, 0, 0, 0], "length counts bus + seq + JPEG")
        XCTAssertEqual(r[4], 1)
        XCTAssertEqual(Array(r[5..<9]), [4, 3, 2, 1])
        XCTAssertEqual(Array(r[9...]), [0xFF, 0xD8, 0xFF])
    }

    func testStateCarriesNewFields() throws {
        var s = RemoteState()
        s.inputs = [.init(number: 1, name: "Cam", kind: "camera", ptz: true), .init(number: 2, name: "Lower third", kind: "text", data: true)]
        s.cpu = 42.5; s.fps = 30; s.dropped = 3; s.fullscreen = true
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.json.utf8)) as? [String: Any])
        let inputs = try XCTUnwrap(o["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs[0]["ptz"] as? Bool, true)
        XCTAssertNil(inputs[0]["data"])
        XCTAssertEqual(inputs[1]["data"] as? Bool, true)
        XCTAssertEqual(o["cpu"] as? Double, 42.5)
        XCTAssertEqual(o["dropped"] as? Int, 3)
        XCTAssertEqual(o["fullscreen"] as? Bool, true)
    }

    func testVideoStreamPushesNewestPicture() throws {
        let s = RemoteServer(port: 0, pin: "1234") { _ in }
        try s.start()
        defer { s.stop() }
        s.setFrame([1, 2, 3], bus: "program")
        #if canImport(Glibc)
        let fd2 = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd2 = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        defer { close(fd2) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(s.port).bigEndian)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd2, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(rc, 0)
        let head = "GET /api/video?stream=1&bus=program HTTP/1.1\r\nHost: 127.0.0.1\r\nX-LiveCore-PIN: 1234\r\n\r\n"
        _ = Array(head.utf8).withUnsafeBytes { send(fd2, $0.baseAddress, $0.count, 0) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd2, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var got: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(3)
        let want: [UInt8] = [8, 0, 0, 0, 0]
        while Date() < deadline {
            let n = buf.withUnsafeMutableBytes { recv(fd2, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            got += buf[0..<n]
            if let end = (0..<max(0, got.count - 3)).first(where: { got[$0] == 13 && got[$0 + 1] == 10 && got[$0 + 2] == 13 && got[$0 + 3] == 10 }) {
                let body = Array(got[(end + 4)...])
                if body.count >= 12 {
                    XCTAssertEqual(Array(body[0..<5]), want)
                    XCTAssertEqual(Array(body[9..<12]), [1, 2, 3])
                    return
                }
            }
        }
        XCTFail("no picture record; got \(got.count) bytes")
    }
}

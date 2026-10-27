import XCTest
@testable import LiveCoreCore

final class ZoomAuthTests: XCTestCase {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testSHA256Vectors() {
        XCTAssertEqual(hex(SHA256.hash(Array("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(SHA256.hash([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(SHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testHMACVectorsRFC4231() {
        XCTAssertEqual(hex(SHA256.hmac(key: [UInt8](repeating: 0x0b, count: 20), message: Array("Hi There".utf8))),
                       "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        XCTAssertEqual(hex(SHA256.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        // Key longer than the block size is hashed first (case 6).
        XCTAssertEqual(hex(SHA256.hmac(key: [UInt8](repeating: 0xaa, count: 131),
                                       message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))),
                       "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    func testBase64URL() {
        XCTAssertEqual(Base64URL.encode(Array("f".utf8)), "Zg")
        XCTAssertEqual(Base64URL.encode(Array("fo".utf8)), "Zm8")
        XCTAssertEqual(Base64URL.encode(Array("foo".utf8)), "Zm9v")
        XCTAssertEqual(Base64URL.encode([0xfb, 0xff]), "-_8")
    }

    func testJWTStructureAndSignature() {
        let jwt = ZoomJWT.make(clientID: "abc", clientSecret: "secret", now: 1_800_000_000)
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], Base64URL.encode(Array(#"{"alg":"HS256","typ":"JWT"}"#.utf8)))
        XCTAssertEqual(parts[1], Base64URL.encode(Array(#"{"appKey":"abc","iat":1799999970,"exp":1800007170,"tokenExp":1800007170}"#.utf8)))
        XCTAssertEqual(parts[2], Base64URL.encode(SHA256.hmac(key: Array("secret".utf8), message: Array("\(parts[0]).\(parts[1])".utf8))))
        XCTAssertFalse(jwt.contains("secret"))
    }

    func testJoinParsing() {
        XCTAssertEqual(ZoomJoinInfo.parse("812 3456 7890"), ZoomJoinInfo(meetingNumber: 81234567890, linkPasscode: nil))
        XCTAssertEqual(ZoomJoinInfo.parse(" https://us05web.zoom.us/j/81234567890?pwd=AbC123.1&from=addon "),
                       ZoomJoinInfo(meetingNumber: 81234567890, linkPasscode: "AbC123.1"))
        XCTAssertEqual(ZoomJoinInfo.parse("123-456-789")?.meetingNumber, 123456789)
        XCTAssertNil(ZoomJoinInfo.parse("hello"))
        XCTAssertNil(ZoomJoinInfo.parse("12345"))
    }
}

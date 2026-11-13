import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.75.0: streaming service presets and the device-login request / response handling.
final class V075Tests: XCTestCase {
    func testServiceMatch() {
        XCTAssertEqual(StreamService.match("rtmp://a.rtmp.youtube.com/live2")?.id, "youtube")
        XCTAssertEqual(StreamService.match("rtmp://b.rtmp.youtube.com/live2?backup=1")?.id, "youtube")
        XCTAssertEqual(StreamService.match(" rtmp://live.twitch.tv/app ")?.id, "twitch")
        XCTAssertNil(StreamService.match("rtmp://192.168.1.10/live"))
        XCTAssertNil(StreamService.match(""))
        XCTAssertEqual(Set(StreamService.all.map(\.id)).count, StreamService.all.count)
    }

    func testRequests() {
        let d = String(decoding: StreamLoginAPI.deviceRequest(.twitch, clientID: "abc"), as: UTF8.self)
        XCTAssertEqual(d, "client_id=abc&scopes=channel:read:stream_key")
        let t = String(decoding: StreamLoginAPI.tokenRequest(.youtube, clientID: "id", secret: "s+1", deviceCode: "dc"), as: UTF8.self)
        XCTAssertTrue(t.contains("client_secret=s%2B1"))
        XCTAssertTrue(t.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
    }

    func testParsing() {
        let google = Data(#"{"device_code":"D","user_code":"ABCD-EFGH","verification_url":"https://www.google.com/device","interval":5}"#.utf8)
        XCTAssertEqual(StreamLoginAPI.parseDeviceCode(google),
                       StreamLoginAPI.DeviceCode(deviceCode: "D", userCode: "ABCD-EFGH", verificationURL: "https://www.google.com/device", interval: 5))
        XCTAssertEqual(StreamLoginAPI.parseToken(Data(#"{"error":"authorization_pending"}"#.utf8)), .pending)
        XCTAssertEqual(StreamLoginAPI.parseToken(Data(#"{"message":"authorization_pending","status":400}"#.utf8)), .pending)
        XCTAssertEqual(StreamLoginAPI.parseToken(Data(#"{"access_token":"T"}"#.utf8)), .token("T"))
        XCTAssertEqual(StreamLoginAPI.parseToken(Data(#"{"error":"access_denied"}"#.utf8)), .failed("access_denied"))

        let list = Data(#"{"items":[{"cdn":{"ingestionInfo":{"ingestionAddress":"rtmp://a.rtmp.youtube.com/live2","streamName":"k-1"}}}]}"#.utf8)
        XCTAssertEqual(StreamLoginAPI.parseYouTubeStream(list)?.key, "k-1")
        let created = Data(#"{"cdn":{"ingestionInfo":{"ingestionAddress":"rtmp://x","streamName":"k-2"}}}"#.utf8)
        XCTAssertEqual(StreamLoginAPI.parseYouTubeStream(created)?.server, "rtmp://x")
        XCTAssertNil(StreamLoginAPI.parseYouTubeStream(Data(#"{"items":[]}"#.utf8)))
        XCTAssertEqual(StreamLoginAPI.parseTwitch(Data(#"{"data":[{"stream_key":"live_1"}]}"#.utf8), field: "stream_key"), "live_1")
    }
}

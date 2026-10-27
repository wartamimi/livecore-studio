import Foundation
import XCTest
@testable import LiveCoreCore

final class TransitionMathTests: XCTestCase {
    private let points: [(Double, Double)] = [(0.01, 0.01), (0.5, 0.5), (0.99, 0.2), (0.3, 0.97)]

    func testEveryKindStartsOnAAndEndsOnB() {
        for k in TransitionKind.allCases where k != .cut {
            for (u, v) in points {
                switch TransitionMath.sample(k, t: 0, u: u, v: v) {
                case .a: break
                default: XCTFail("\(k) at t=0 should show A at (\(u),\(v))")
                }
                switch TransitionMath.sample(k, t: 1, u: u, v: v) {
                case .b: break
                default: XCTFail("\(k) at t=1 should show B at (\(u),\(v))")
                }
            }
        }
    }

    func testWipeDirections() {
        // Halfway: wipe left reveals B on the right half, wipe right on the left half.
        XCTAssertEqual(TransitionMath.sample(.wipeLeft, t: 0.5, u: 0.9, v: 0.5), .b(u: 0.9, v: 0.5))
        XCTAssertEqual(TransitionMath.sample(.wipeLeft, t: 0.5, u: 0.1, v: 0.5), .a(u: 0.1, v: 0.5))
        XCTAssertEqual(TransitionMath.sample(.wipeRight, t: 0.5, u: 0.1, v: 0.5), .b(u: 0.1, v: 0.5))
        XCTAssertEqual(TransitionMath.sample(.wipeUp, t: 0.5, u: 0.5, v: 0.9), .b(u: 0.5, v: 0.9))
        XCTAssertEqual(TransitionMath.sample(.wipeDown, t: 0.5, u: 0.5, v: 0.1), .b(u: 0.5, v: 0.1))
    }

    private func assertSample(_ got: TransitionMath.Sample, _ want: TransitionMath.Sample, file: StaticString = #filePath, line: UInt = #line) {
        switch (got, want) {
        case let (.a(u1, v1), .a(u2, v2)), let (.b(u1, v1), .b(u2, v2)):
            XCTAssertEqual(u1, u2, accuracy: 1e-9, file: file, line: line); XCTAssertEqual(v1, v2, accuracy: 1e-9, file: file, line: line)
        default: XCTAssertEqual(got, want, file: file, line: line)
        }
    }

    func testPushMovesBothPicturesAndSlideKeepsAStill() {
        // Push left at 25 %: A shifted left by 0.25, B enters from the right edge.
        assertSample(TransitionMath.sample(.pushLeft, t: 0.25, u: 0.5, v: 0.5), .a(u: 0.75, v: 0.5))
        assertSample(TransitionMath.sample(.pushLeft, t: 0.25, u: 0.9, v: 0.5), .b(u: 0.15, v: 0.5))
        assertSample(TransitionMath.sample(.pushRight, t: 0.25, u: 0.1, v: 0.5), .b(u: 0.85, v: 0.5))
        assertSample(TransitionMath.sample(.slideLeft, t: 0.25, u: 0.5, v: 0.5), .a(u: 0.5, v: 0.5))
        assertSample(TransitionMath.sample(.slideLeft, t: 0.25, u: 0.8, v: 0.5), .b(u: 0.05, v: 0.5))
        assertSample(TransitionMath.sample(.slideRight, t: 0.25, u: 0.1, v: 0.5), .b(u: 0.85, v: 0.5))
    }

    func testIrisGrowsFromCentre() {
        XCTAssertEqual(TransitionMath.sample(.iris, t: 0.3, u: 0.5, v: 0.5), .b(u: 0.5, v: 0.5))
        XCTAssertEqual(TransitionMath.sample(.iris, t: 0.3, u: 0.02, v: 0.02), .a(u: 0.02, v: 0.02))
        XCTAssertEqual(TransitionMath.sample(.iris, t: 0.99, u: 0.01, v: 0.01), .b(u: 0.01, v: 0.01))
    }

    func testRawValuesAreStableForTheShader() {
        XCTAssertEqual(TransitionKind.allCases.map(\.rawValue), Array(0...12))
    }
}

final class StreamDestinationTests: XCTestCase {
    func testOldSettingsJSONStillDecodes() throws {
        // StreamSettings as saved by 0.1–0.3 (no primaryName/primaryEnabled/additional).
        let old = #"{"serverURL":"rtmp://a.rtmp.youtube.com/live2","keychainAccount":"default","autoReconnect":false,"reconnect":{"initialDelay":1,"maxDelay":30,"multiplier":2,"maxAttempts":10,"jitterFraction":0.2}}"#
        let s = try JSONDecoder().decode(StreamSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.serverURL, "rtmp://a.rtmp.youtube.com/live2")
        XCTAssertFalse(s.autoReconnect)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertTrue(s.additional.isEmpty)
    }

    func testRoundTripAndValidation() throws {
        var s = StreamSettings()
        s.additional = [StreamDestination(id: "fb", name: "Facebook", serverURL: "rtmps://live-api-s.facebook.com:443/rtmp/"),
                        StreamDestination(id: "tw", name: "Twitch", serverURL: "")]
        XCTAssertEqual(s.additional[0].keychainAccount, "dest-fb")
        let back = try JSONDecoder().decode(StreamSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(s.destinationErrors().count, 1)            // Twitch enabled without URL
        s.additional[1].enabled = false
        XCTAssertTrue(s.destinationErrors().isEmpty)
        s.additional.append(StreamDestination(id: "x", name: "X", serverURL: "rtmp://x/live"))
        XCTAssertFalse(s.destinationErrors().isEmpty)            // 4 > max 3
        var p = ProductionSettings(); p.stream = s
        XCTAssertFalse(p.validationErrors().isEmpty)
    }
}

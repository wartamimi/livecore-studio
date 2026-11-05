import XCTest
@testable import LiveCoreCore

/// 24 / 25 fps on capture cards that only offer 48 / 50 / 60 (0.63.4).
final class CaptureRate0634Tests: XCTestCase {
    func testPrefersFormatThatCanBeHalved() {
        let formats = [
            CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [30...30], codec: "yuvs"),
            CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [50...50], codec: "yuvs"),
        ]
        let cfg = CaptureConfig(width: 1920, height: 1080, frameRate: 25)
        XCTAssertEqual(CaptureFormatPicker.pick(formats, config: cfg, outputWidth: 1920, outputHeight: 1080, outputFPS: 25), 1)
    }

    func testHalvingSupport() {
        let f = CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [48...48, 50...50])
        XCTAssertFalse(f.supports(25))
        XCTAssertTrue(f.supportsByHalving(25))
        XCTAssertTrue(f.supportsByHalving(24))
        XCTAssertFalse(f.supportsByHalving(30))
        XCTAssertEqual(CaptureFormatPicker.alwaysOfferedRates, [24, 25])
    }
}

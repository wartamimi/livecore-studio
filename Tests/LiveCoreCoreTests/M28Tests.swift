import XCTest
@testable import LiveCoreCore

/// 0.28.0: advanced capture-card settings.
final class M28Tests: XCTestCase {
    private let formats = [
        CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [5...5], codec: "yuvs"),
        CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [60...60], codec: "dmb1"),
        CaptureFormatCandidate(width: 1280, height: 720, frameRateRanges: [10...10], codec: "yuvs"),
        CaptureFormatCandidate(width: 1280, height: 720, frameRateRanges: [60...60], codec: "dmb1"),
    ]

    func testCodecChoiceWinsAtTheChosenSize() {
        let auto = CaptureConfig(width: 1920, height: 1080, frameRate: 60)
        XCTAssertEqual(CaptureFormatPicker.pick(formats, config: auto, outputWidth: 1920, outputHeight: 1080, outputFPS: 30), 1,
                       "automatic: the format that can do 60 fps")
        var raw = auto; raw.codec = "yuvs"
        XCTAssertEqual(CaptureFormatPicker.pick(formats, config: raw, outputWidth: 1920, outputHeight: 1080, outputFPS: 30), 0,
                       "uncompressed chosen: used even though it cannot do 60 fps")
        var missing = auto; missing.codec = "avc1"
        XCTAssertEqual(CaptureFormatPicker.pick(formats, config: missing, outputWidth: 1920, outputHeight: 1080, outputFPS: 30), 1,
                       "a codec the device lacks is ignored")
    }

    func testCodecChoiceWithAutomaticSize() {
        let c = CaptureConfig(codec: "yuvs")
        XCTAssertEqual(CaptureFormatPicker.pick(formats, config: c, outputWidth: 1280, outputHeight: 720, outputFPS: 30), 2)
    }

    func testCodecNames() {
        XCTAssertEqual(CaptureCodec.fourCC(0x7975_7673), "yuvs")
        XCTAssertTrue(CaptureCodec.isUncompressed("yuvs"))
        XCTAssertTrue(CaptureCodec.isUncompressed("420v"))
        XCTAssertFalse(CaptureCodec.isUncompressed("dmb1"))
        XCTAssertTrue(CaptureCodec.label("dmb1").contains("MJPEG"))
        XCTAssertEqual(CaptureCodec.label("abcd"), "abcd")
    }

    func testOldCaptureConfigStillDecodes() throws {
        let c = try JSONDecoder().decode(CaptureConfig.self, from: Data(#"{"width":1920,"height":1080,"mirror":false}"#.utf8))
        XCTAssertNil(c.codec)
        XCTAssertNil(c.bufferFrames)
    }

    func testRangeFixAndDeinterlace() throws {
        XCTAssertFalse(InputAdjust(range: .limitedToFull).isIdentity)
        XCTAssertFalse(InputAdjust(deinterlace: true).isIdentity)
        XCTAssertEqual(InputAdjust.levels(16.0 / 255, .limitedToFull), 0, accuracy: 1e-9)
        XCTAssertEqual(InputAdjust.levels(235.0 / 255, .limitedToFull), 1, accuracy: 1e-9)
        XCTAssertEqual(InputAdjust.levels(0, .fullToLimited), 16.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(InputAdjust.levels(1, .fullToLimited), 235.0 / 255, accuracy: 1e-9)
        let grey = InputAdjust(range: .limitedToFull).apply(r: 16.0 / 255, g: 16.0 / 255, b: 16.0 / 255)
        XCTAssertEqual(grey.r, 0, accuracy: 1e-6, "washed-out black becomes black")

        let a = InputAdjust(brightness: 0.2, rotation: 90, range: .fullToLimited, deinterlace: true)
        let back = try JSONDecoder().decode(InputAdjust.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a.clamped)
        let reset = a.resetKeepingSignalFixes
        XCTAssertEqual(reset.brightness, 0)
        XCTAssertEqual(reset.rotation, 0)
        XCTAssertEqual(reset.range, .fullToLimited)
        XCTAssertTrue(reset.deinterlace)
        let old = try JSONDecoder().decode(InputAdjust.self, from: Data(#"{"brightness":0.1}"#.utf8))
        XCTAssertEqual(old.range, .none)
        XCTAssertFalse(old.deinterlace)
    }
}

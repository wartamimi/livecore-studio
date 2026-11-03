import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.46.0: scene layouts and editing helpers, vertical framing, wedding and meeting templates.
final class Release046Tests: XCTestCase {
    func testNewSceneLayoutsHaveTheirSlotCounts() {
        XCTAssertEqual(SceneTemplate.allCases.count, 17)
        XCTAssertEqual(SceneTemplate.grid3x3.slots.count, 9)
        XCTAssertEqual(SceneTemplate.sidebar.slots.count, 4)
        XCTAssertEqual(SceneTemplate.panel4.slots.count, 4)
        XCTAssertEqual(SceneTemplate.oneOverThree.slots.count, 4)
    }

    func testAlignAndDistribute() {
        let r = NormRect(x: 0.3, y: 0.2, width: 0.2, height: 0.4)
        XCTAssertEqual(LayerEditing.align(r, .right).x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(LayerEditing.align(r, .centerY).y, 0.3, accuracy: 1e-9)
        XCTAssertEqual(LayerEditing.align(r, .left).width, 0.2)
        let rs = [NormRect(x: 0.6, y: 0, width: 0.2, height: 0.2), NormRect(x: 0, y: 0, width: 0.2, height: 0.2)]
        let d = LayerEditing.distribute(rs, horizontal: true)
        // 1 - 0.4 = 0.6 free, 3 gaps of 0.2; the left box (index 1) stays first.
        XCTAssertEqual(d[1].x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(d[0].x, 0.6, accuracy: 1e-9)
        let dup = LayerEditing.duplicate(Layer(source: InputID("a"), rect: r))
        XCTAssertEqual(dup.rect.x, 0.33, accuracy: 1e-9)
        XCTAssertEqual(dup.source, InputID("a"))
    }

    func testWeddingAndMeetingTemplates() {
        XCTAssertEqual(TitleTemplate.weddingCenter.category, .title)
        XCTAssertEqual(TitleTemplate.weddingFloral.category, .lowerThird)
        XCTAssertNotEqual(TitleTemplate.weddingFloral.defaultDesign.textAnimation, .off)
        XCTAssertEqual(TickerTemplate.weddingGold.config(text: "x").template, .weddingGold)
        for t in [FrameTemplate.conference, .meeting, .webinar, .keynote] {
            let l = FrameLayout.layout(t, aspect: 16.0 / 9)
            XCTAssertLessThanOrEqual(l.camera.x + l.camera.width, 1 + 1e-9, "\(t)")
            XCTAssertLessThanOrEqual(l.camera.y + l.camera.height, 1 + 1e-9, "\(t)")
            XCTAssertNotNil(l.label)
        }
    }
}

/// 0.46.1: capture card (Datavideo CAP-2) format choice and audio pairing.
final class Release0461Tests: XCTestCase {
    func testCaptureCardAudioIsPairedByName() {
        let audio = ["MacBook Pro Microphone", "CAP-2 Audio", "ZoomAudioDevice"]
        XCTAssertEqual(CaptureAudioMatch.partner(videoName: "CAP-2 Video", audioNames: audio), 1)
        XCTAssertEqual(CaptureAudioMatch.partner(videoName: "Cam Link 4K", audioNames: ["Cam Link 4K"]), 0)
        XCTAssertNil(CaptureAudioMatch.partner(videoName: "FaceTime HD Camera", audioNames: audio))
    }

    func testEightBit420IsPreferredAmongUncompressedModes() {
        let f = [CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [60...60], codec: "v210"),
                 CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [60...60], codec: "yuvs"),
                 CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [60...60], codec: "420v"),
                 CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [60...60], codec: "dmb1")]
        XCTAssertEqual(CaptureFormatPicker.pick(f, config: CaptureConfig(), outputWidth: 1920, outputHeight: 1080, outputFPS: 60), 2)
        XCTAssertEqual(CaptureFormatPicker.pick(f, config: CaptureConfig(width: 1920, height: 1080), outputWidth: 1920, outputHeight: 1080, outputFPS: 60), 2)
    }
}

/// 0.46.2: washed-out capture card detection, live browser styling.
final class Release0462Tests: XCTestCase {
    func testLimitedRangePictureIsDetected() {
        var p = LevelProbe()
        let frame: [UInt8] = (0..<1296).map { UInt8(16 + ($0 % 220)) }   // 16…235
        for _ in 0..<LevelProbe.framesNeeded - 1 { p.add(luma: frame) }
        XCTAssertNil(p.verdict)
        p.add(luma: frame)
        XCTAssertEqual(p.verdict, .limitedToFull)
    }

    func testFullRangeAndDarkPicturesAreLeftAlone() {
        var full = LevelProbe(), dark = LevelProbe()
        for _ in 0..<LevelProbe.framesNeeded {
            full.add(luma: (0..<1296).map { UInt8($0 % 256) })
            dark.add(luma: (0..<1296).map { UInt8(16 + $0 % 60) })
        }
        XCTAssertEqual(full.verdict, InputAdjust.RangeFix.none)
        XCTAssertEqual(dark.verdict, InputAdjust.RangeFix.none)
        XCTAssertEqual(LevelProbe.luma(b: 255, g: 255, r: 255), 255)
    }

    func testFullRangeNV12IsPickedAfterVideoRange() {
        let f = [CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [30...30], codec: "420f"),
                 CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [30...30], codec: "420v")]
        XCTAssertEqual(CaptureFormatPicker.pick(f, config: CaptureConfig(), outputWidth: 1920, outputHeight: 1080, outputFPS: 30), 1)
    }

    func testStyleCanBeAppliedLive() {
        var b = ProjectBrowser(url: "https://example.com")
        b.css = "body{color:red}"
        XCTAssertTrue(b.liveStyleScript.contains("__livecoreCSS"))
        b.css = nil
        XCTAssertTrue(b.liveStyleScript.contains("m.muted = false"), "turning mute off unmutes the open page")
    }
}

/// 0.47.0: the levels decision is remembered; web overlay taps go to Preview.
final class Release047Tests: XCTestCase {
    func testRangeDecisionSurvivesSaveAndClamp() throws {
        var a = InputAdjust()
        a.rangeChecked = true
        XCTAssertTrue(a.isIdentity, "the picture is unchanged")
        XCTAssertFalse(a.isEmpty, "but the decision is kept")
        XCTAssertTrue(a.clamped.rangeChecked)
        let back = try JSONDecoder().decode(InputAdjust.self, from: JSONEncoder().encode(a))
        XCTAssertTrue(back.rangeChecked)
        XCTAssertFalse(try JSONDecoder().decode(InputAdjust.self, from: Data("{}".utf8)).rangeChecked)
    }

    func testOverlayPreviewIsAControlAction() {
        XCTAssertTrue(ControlAction.catalog.contains(.overlayPreview(1)))
    }
}

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

    func testVerticalZoomAndFit() {
        let src = PixelSize(width: 1920, height: 1080)
        let r = VerticalCrop.rect(source: src, aspect: 9.0 / 16, centerX: 0.5, zoom: 2, centerY: 0)
        XCTAssertEqual(r.height, 540, accuracy: 1e-6)
        XCTAssertEqual(r.y, 0, accuracy: 1e-6, "kept inside at the top")
        let f = VerticalCrop.fitRect(source: src, output: PixelSize(width: 1080, height: 1920), position: 0.5)
        XCTAssertEqual(f.width, 1080, accuracy: 1e-6)
        XCTAssertEqual(f.height, 607.5, accuracy: 1e-6)
        XCTAssertEqual(f.y, (1920 - 607.5) / 2, accuracy: 1e-6)
    }

    func testOldVerticalSettingsStillDecode() throws {
        let json = #"{"enabled":true,"size":{"width":1080,"height":1920},"follow":"center","manualX":0.5,"smoothing":0.06,"streamURL":"","keychainAccount":"vertical","bitrateKbps":6000,"recordWithProgram":false}"#
        let v = try JSONDecoder().decode(VerticalSettings.self, from: Data(json.utf8))
        XCTAssertEqual(v.bitrateKbps, 6000)
        XCTAssertEqual(v.fill, .crop)
        XCTAssertEqual(v.zoom, 1)
        XCTAssertEqual(v.audioBitrateKbps, 128)
        var w = v; w.fill = .fitBlur; w.zoom = 1.5
        XCTAssertEqual(try JSONDecoder().decode(VerticalSettings.self, from: JSONEncoder().encode(w)), w)
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

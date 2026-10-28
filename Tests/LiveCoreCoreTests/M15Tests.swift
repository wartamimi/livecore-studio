import Foundation
import XCTest
@testable import LiveCoreCore

final class SceneTemplateTests: XCTestCase {
    func testEveryTemplateSlotIsInsideTheCanvas() {
        for t in SceneTemplate.allCases {
            XCTAssertFalse(t.slots.isEmpty, "\(t)")
            for r in t.slots {
                XCTAssertGreaterThanOrEqual(r.x, -1e-9); XCTAssertGreaterThanOrEqual(r.y, -1e-9)
                XCTAssertLessThanOrEqual(r.x + r.width, 1 + 1e-9, "\(t)"); XCTAssertLessThanOrEqual(r.y + r.height, 1 + 1e-9, "\(t)")
            }
        }
    }

    func testApplyKeepsTheBaseLayerAndFillsSlotsInOrder() {
        let base = Layer(source: InputID("scene"))
        let layers = [base] + (1...5).map { Layer(source: InputID("i\($0)"), rect: NormRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)) }
        let out = SceneTemplate.grid2x2.apply(to: layers, skip: 1)
        XCTAssertEqual(out[0], base)
        XCTAssertEqual(Array(out[1...4]).map(\.rect), SceneTemplate.grid2x2.slots)
        XCTAssertEqual(out[5].rect, layers[5].rect, "layers beyond the slots stay where they are")
        XCTAssertEqual(out[1].scaleMode, .fill)
    }
}

final class CaptureFormatTests: XCTestCase {
    let formats = [
        CaptureFormatCandidate(width: 640, height: 480, frameRateRanges: [5...30]),
        CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [29.97...29.97, 59.94...59.94]),
        CaptureFormatCandidate(width: 1280, height: 720, frameRateRanges: [60...60]),
        CaptureFormatCandidate(width: 3840, height: 2160, frameRateRanges: [30...30]),
    ]

    func testAutomaticPicksTheOutputSizeAtTheOutputRate() {
        XCTAssertEqual(CaptureFormatPicker.pick(formats, config: CaptureConfig(), outputWidth: 1920, outputHeight: 1080, outputFPS: 30), 1)
        // 720p60 output: 1280x720 supports 60.
        XCTAssertEqual(CaptureFormatPicker.pick(formats, config: CaptureConfig(), outputWidth: 1280, outputHeight: 720, outputFPS: 60), 2)
    }

    func testUncompressedUSB3ModeIsPreferred() {
        let card = [
            CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [60...60], codec: "MJPG"),
            CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [60...60], codec: "yuvs"),
            CaptureFormatCandidate(width: 1920, height: 1080, frameRateRanges: [30...30], codec: "420v"),
        ]
        XCTAssertEqual(CaptureFormatPicker.pick(card, config: CaptureConfig(), outputWidth: 1920, outputHeight: 1080, outputFPS: 60), 1)
        XCTAssertEqual(CaptureFormatPicker.pick(card, config: CaptureConfig(width: 1920, height: 1080), outputWidth: 1920, outputHeight: 1080, outputFPS: 60), 1)
        // An explicit codec still wins.
        XCTAssertEqual(CaptureFormatPicker.pick(card, config: CaptureConfig(codec: "MJPG"), outputWidth: 1920, outputHeight: 1080, outputFPS: 60), 0)
    }

    func testExplicitFormatWins() {
        let c = CaptureConfig(width: 3840, height: 2160, frameRate: 30)
        XCTAssertEqual(CaptureFormatPicker.pick(formats, config: c, outputWidth: 1920, outputHeight: 1080, outputFPS: 30), 3)
        // A size the device does not have falls back to automatic.
        let missing = CaptureConfig(width: 800, height: 600)
        XCTAssertEqual(CaptureFormatPicker.pick(formats, config: missing, outputWidth: 1920, outputHeight: 1080, outputFPS: 30), 1)
    }

    func testOfferedFrameRates() {
        XCTAssertEqual(formats[0].offeredFrameRates, [5, 24, 25, 30])
        XCTAssertEqual(formats[1].offeredFrameRates, [29.97, 59.94])
    }
}

final class AudioPropertiesTests: XCTestCase {
    func testChannelModes() {
        var l: [Float] = [1, 1], r: [Float] = [0, 0.5]
        ChannelMode.apply(.leftOnly, left: &l, right: &r, frames: 2)
        XCTAssertEqual(r, [1, 1])
        l = [1, 1]; r = [0, 0.5]
        ChannelMode.apply(.monoMix, left: &l, right: &r, frames: 2)
        XCTAssertEqual(l, [0.5, 0.75]); XCTAssertEqual(r, [0.5, 0.75])
        l = [1, 2]; r = [3, 4]
        ChannelMode.apply(.swap, left: &l, right: &r, frames: 2)
        XCTAssertEqual(l, [3, 4]); XCTAssertEqual(r, [1, 2])
    }

    func testDelayLineDelaysByTheRequestedSamples() {
        var d = StereoDelay(capacity: 16)
        var l: [Float] = (1...8).map(Float.init), r = l
        d.process(left: &l, right: &r, frames: 8, samples: 3)
        XCTAssertEqual(l, [0, 0, 0, 1, 2, 3, 4, 5])
        var l2: [Float] = (9...16).map(Float.init), r2 = l2
        d.process(left: &l2, right: &r2, frames: 8, samples: 3)
        XCTAssertEqual(l2, [6, 7, 8, 9, 10, 11, 12, 13], "continuous across blocks and wrap-around")
        XCTAssertEqual(r2, l2)
    }

    func testStripAppliesPhaseInvertAndDelay() {
        let c = ChannelControls()
        c.invertPhase.value = true
        c.delayMs.value = 1   // 48 samples at 48 kHz
        var dsp = ChannelStripDSP(controls: c, sampleRate: 48_000)
        var l = [Float](repeating: 0.5, count: 128), r = l
        // Settle the fader ramp first so the comparison is exact.
        for _ in 0..<20 { var a = l, b = r; dsp.process(left: &a, right: &b, frames: 128) }
        dsp.process(left: &l, right: &r, frames: 128)
        XCTAssertEqual(l[100], -0.5, accuracy: 1e-4)
        let c2 = ChannelControls(); c2.delayMs.value = 1
        var dsp2 = ChannelStripDSP(controls: c2, sampleRate: 48_000)
        var impulse = [Float](repeating: 0, count: 128), rr = impulse
        impulse[0] = 1; rr[0] = 1
        for _ in 0..<1 { dsp2.process(left: &impulse, right: &rr, frames: 128) }
        XCTAssertEqual(impulse.firstIndex { abs($0) > 0.01 }, 48)
    }
}

final class M15ProjectTests: XCTestCase {
    func testNewSourcesCaptureConfigAndAudioPropertiesRoundTrip() throws {
        var cam = ProjectInput(id: InputID("cam"), name: "Cam Link", source: .camera(uniqueID: "u", deviceName: "Cam Link 4K"))
        cam.capture = CaptureConfig(width: 1920, height: 1080, frameRate: 59.94, mirror: true)
        let bars = ProjectInput(id: InputID("bars"), name: "Bars", source: .colorBars)
        let scene = ProjectInput(id: InputID("scene"), name: "Scene 1", source: .scene,
                                 layers: [Layer(source: InputID("scene")), Layer(source: InputID("cam"), rect: LayoutPreset.pipTopRight.rect)])
        var doc = ProjectDocument(inputs: [cam, bars, scene])
        var ch = ProjectAudioChannel(deviceUniqueID: "mic", name: "Mic")
        ch.channelMode = ChannelMode.leftOnly.rawValue; ch.invertPhase = true; ch.delayMs = 80; ch.compAttackMs = 5; ch.gateRangeDB = -30
        doc.audio.channels = [ch]
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back, doc)
        XCTAssertTrue(back.validationIssues().isEmpty)
    }

    func testSceneThumbnailsAndDetailUseTheWholeScene() {
        let scene = InputID("scene"), cam = InputID("cam")
        let layers: [InputID: [Layer]] = [scene: [Layer(source: scene), Layer(source: cam, rect: LayoutPreset.pipTopRight.rect)],
                                          cam: [Layer(source: cam)]]
        let plan = FramePlanner.plan(snapshot: SwitcherSnapshot(), overlays: [], now: 0, layersFor: { layers[$0] },
                                     thumbnailsFor: [scene, cam], composedThumbnails: [scene], detailInput: scene)
        XCTAssertEqual(plan.thumbnails[scene]?.map(\.source), [scene, cam])
        XCTAssertEqual(plan.thumbnails[cam]?.map(\.source), [cam])
        XCTAssertEqual(plan.thumbnails[cam]?.first?.rect, .full)
        XCTAssertEqual(plan.detail?.map(\.source), [scene, cam])
        XCTAssertNil(FramePlanner.plan(snapshot: SwitcherSnapshot(), overlays: [], now: 0, layersFor: { layers[$0] }).detail)
    }
}

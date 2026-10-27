import Foundation
import XCTest
@testable import LiveCoreCore

final class InputAdjustTests: XCTestCase {
    func testIdentityLeavesColoursUnchanged() {
        let a = InputAdjust()
        XCTAssertTrue(a.isIdentity)
        let c = a.apply(r: 0.2, g: 0.5, b: 0.9)
        XCTAssertEqual(c.r, 0.2, accuracy: 1e-9); XCTAssertEqual(c.g, 0.5, accuracy: 1e-9); XCTAssertEqual(c.b, 0.9, accuracy: 1e-9)
        XCTAssertFalse(InputAdjust(flipHorizontal: true).isIdentity)
        XCTAssertFalse(InputAdjust(flipHorizontal: true).hasColorChange)
    }

    func testBrightnessContrastSaturationGamma() {
        XCTAssertEqual(InputAdjust(brightness: 0.1).apply(r: 0.5, g: 0.5, b: 0.5).r, 0.6, accuracy: 1e-9)
        XCTAssertEqual(InputAdjust(contrast: 2).apply(r: 0.75, g: 0.75, b: 0.75).r, 1.0, accuracy: 1e-9)
        XCTAssertEqual(InputAdjust(contrast: 2).apply(r: 0.4, g: 0.4, b: 0.4).r, 0.3, accuracy: 1e-9)
        let grey = InputAdjust(saturation: 0).apply(r: 1, g: 0, b: 0)
        XCTAssertEqual(grey.r, 0.2126, accuracy: 1e-9); XCTAssertEqual(grey.g, grey.r, accuracy: 1e-12)
        XCTAssertEqual(InputAdjust(gamma: 2).apply(r: 0.25, g: 0.25, b: 0.25).r, 0.5, accuracy: 1e-9)
        XCTAssertEqual(InputAdjust.pow(2, 10), 1024, accuracy: 1e-6)
    }

    func testClampingAndOldProjectsDecode() throws {
        let a = InputAdjust(brightness: 3, contrast: -1, saturation: 9, gamma: 0.1).clamped
        XCTAssertEqual(a, InputAdjust(brightness: 0.5, contrast: 0, saturation: 2, gamma: 0.5))
        let partial = try JSONDecoder().decode(InputAdjust.self, from: Data(#"{"brightness":0.2}"#.utf8))
        XCTAssertEqual(partial, InputAdjust(brightness: 0.2))
    }
}

final class ToneGeneratorTests: XCTestCase {
    func testLevelFrequencyAndContinuity() {
        var g = ToneGenerator(frequency: 1000, levelDB: -18)
        var a = [Float](repeating: 0, count: 480), b = a
        g.fill(&a, count: 480)
        g.fill(&b, count: 480)
        let peak = (a + b).map(abs).max()!
        XCTAssertEqual(Double(peak), 0.12589, accuracy: 0.001, "-18 dBFS peak")
        // 1 kHz at 48 kHz: one cycle every 48 samples, so sample 48 equals sample 0 and sample 12 is the crest.
        XCTAssertEqual(a[0], 0, accuracy: 1e-6)
        XCTAssertEqual(a[12], peak, accuracy: 1e-5)
        XCTAssertEqual(a[48], a[0], accuracy: 1e-5)
        XCTAssertEqual(b[0], a[0], accuracy: 1e-4, "phase continues across calls (480 = 10 cycles)")
        XCTAssertEqual(ToneGenerator.sine(0.25), 1, accuracy: 1e-9)
        XCTAssertEqual(ToneGenerator.sine(0.75), -1, accuracy: 1e-9)
    }

    func testProjectRoundTrip() throws {
        var doc = ProjectDocument()
        doc.audio.tones = [ProjectTone(id: "t1", frequency: 440, levelDB: -20)]
        var pi = ProjectInput(id: InputID("cam"), name: "Cam", source: .colorBars)
        pi.adjust = InputAdjust(brightness: 0.1, flipVertical: true)
        doc.inputs = [pi]
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back, doc)
    }
}

final class M17Tests: XCTestCase {
    func testRotationCornersAndSize() {
        let r90 = InputAdjust(rotation: 90)
        // Clockwise: the destination's top-left shows the source's bottom-left.
        XCTAssertEqual(r90.cornerUVs.map { [$0.u, $0.v] }, [[0, 1], [1, 1], [0, 0], [1, 0]])
        XCTAssertEqual(r90.outputSize(width: 1920, height: 1080).width, 1080)
        XCTAssertEqual(InputAdjust(rotation: 180).cornerUVs.map { [$0.u, $0.v] }, [[1, 1], [1, 0], [0, 1], [0, 0]])
        XCTAssertEqual(InputAdjust(rotation: 270).cornerUVs.map { [$0.u, $0.v] }, [[1, 0], [0, 0], [1, 1], [0, 1]])
        XCTAssertEqual(InputAdjust(rotation: -90).normalizedRotation, 270)
        XCTAssertFalse(InputAdjust(rotation: 90).isIdentity)
        XCTAssertEqual(InputAdjust(flipHorizontal: true).cornerUVs.map { [$0.u, $0.v] }, [[1, 0], [1, 1], [0, 0], [0, 1]])
    }

    func testTickerOffsetCycles() {
        // 1000 px strip, 1920 px view, 100 px/s: starts at the right edge, wraps after 29.2 s.
        XCTAssertEqual(TickerMath.offset(elapsed: 0, speed: 100, stripWidth: 1000, viewWidth: 1920), 1920)
        XCTAssertEqual(TickerMath.offset(elapsed: 10, speed: 100, stripWidth: 1000, viewWidth: 1920), 920)
        XCTAssertEqual(TickerMath.offset(elapsed: 29.2, speed: 100, stripWidth: 1000, viewWidth: 1920), 1920, accuracy: 1e-6)
        XCTAssertEqual(TickerConfig(text: "x", speed: 5000).clamped.speed, 600)
    }

    func testSlideshowPositions() {
        let p0 = SlideshowMath.position(elapsed: 1, count: 3, interval: 5, fade: 1, loop: true)
        XCTAssertEqual(p0, .init(index: 0, next: nil, mix: 0, finished: false))
        let fading = SlideshowMath.position(elapsed: 4.5, count: 3, interval: 5, fade: 1, loop: true)
        XCTAssertEqual(fading.index, 0); XCTAssertEqual(fading.next, 1); XCTAssertEqual(fading.mix, 0.5, accuracy: 1e-9)
        XCTAssertEqual(SlideshowMath.position(elapsed: 16, count: 3, interval: 5, fade: 1, loop: true).index, 0, "wraps")
        let end = SlideshowMath.position(elapsed: 100, count: 3, interval: 5, fade: 1, loop: false)
        XCTAssertEqual(end, .init(index: 2, next: nil, mix: 0, finished: true))
        XCTAssertNil(SlideshowMath.position(elapsed: 4.9, count: 1, interval: 5, fade: 1, loop: true).next)
    }

    func testNewSourcesRoundTrip() throws {
        let t = ProjectInput(id: InputID("t"), name: "Ticker", source: .ticker(TickerConfig(text: "Breaking news")))
        let s = ProjectInput(id: InputID("s"), name: "Photos",
                             source: .slideshow(ProjectSlideshow(images: [ProjectMediaRef(path: "/a.jpg", relativePath: "a.jpg")], interval: 4)))
        var doc = ProjectDocument(inputs: [t, s])
        doc.inputs[0].adjust = InputAdjust(rotation: 270)
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back, doc)
    }
}

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

final class M171Tests: XCTestCase {
    func testDelayChangeCrossFadesWithoutAJump() {
        var d = StereoDelay(capacity: 48_000, fadeFrames: 960)
        var phase: Float = 0
        var out: [Float] = []
        // 100 Hz sine, delay jumps from 0 to 500 samples (~10 ms) mid-stream.
        for block in 0..<40 {
            var l = [Float](repeating: 0, count: 128)
            for i in 0..<128 { l[i] = sin(phase); phase += 2 * .pi * 100 / 48_000 }
            var r = l
            d.process(left: &l, right: &r, frames: 128, samples: block < 10 ? 0 : 500)
            out += l
        }
        let maxStep = zip(out.dropFirst(), out).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxStep, 0.05, "no click: the old and new taps are cross-faded")
        XCTAssertEqual(out[30 * 128], sin(2 * .pi * 100 / 48_000 * Float(30 * 128 - 500)), accuracy: 5e-3,
                       "after the fade the signal is delayed by 500 samples")
    }
}

final class AFVCrossfadeTests: XCTestCase {
    let cam = InputID("cam"), clip = InputID("clip")

    func testAudioFollowsTheIncomingSideAsSoonAsAutoStarts() {
        let sw = Switcher()
        sw.setPreview(cam); sw.cut(); sw.setPreview(clip)
        sw.auto(kind: .dissolve, duration: 2, now: 0)
        XCTAssertEqual(OnAir.audioInputs(switcher: sw.state, layers: [:], overlays: []), [clip])
        XCTAssertEqual(OnAir.audioFadeSeconds(switcher: sw.state), 2)
        sw.update(now: 3)
        XCTAssertEqual(OnAir.audioFadeSeconds(switcher: sw.state), 0.05, "cuts and finished transitions de-click only")
    }

    func testAFVGateFadesOverTheSetTime() {
        let c = ChannelControls()
        var dsp = ChannelStripDSP(controls: c, sampleRate: 48_000)
        func block() -> Float {
            var l = [Float](repeating: 0.5, count: 480), r = l
            dsp.process(left: &l, right: &r, frames: 480)
            return l[479]
        }
        for _ in 0..<10 { _ = block() }
        c.afvFadeSeconds.value = 0.1          // 4800 samples = 10 blocks
        c.afvClosed.value = true
        XCTAssertEqual(block(), 0.45, accuracy: 0.01, "10% into the fade")
        for _ in 0..<4 { _ = block() }
        XCTAssertEqual(block(), 0.2, accuracy: 0.01, "60% into the fade")
        for _ in 0..<5 { _ = block() }
        XCTAssertEqual(block(), 0, accuracy: 1e-6)
    }
}

final class M18Tests: XCTestCase {
    func testKenBurnsStaysInsideThePhotoAndIsContinuous() {
        for i in 0..<4 {
            for k in 0...10 {
                let r = SlideshowMath.kenBurnsRect(progress: Double(k) / 10, index: i)
                XCTAssertGreaterThanOrEqual(r.x, -1e-9); XCTAssertGreaterThanOrEqual(r.y, -1e-9)
                XCTAssertLessThanOrEqual(r.x + r.width, 1 + 1e-9); XCTAssertLessThanOrEqual(r.y + r.height, 1 + 1e-9)
            }
        }
        XCTAssertEqual(SlideshowMath.kenBurnsRect(progress: 0, index: 0).width, 1, accuracy: 1e-9, "even photos start full")
        XCTAssertEqual(SlideshowMath.kenBurnsRect(progress: 1, index: 0).width, 1 / 1.15, accuracy: 1e-9)
        // The image fading in at the end of a slot has the same progress when it becomes the shown one.
        let atEnd = SlideshowMath.motionProgress(within: 5, interval: 5, fade: 1).next
        let atStart = SlideshowMath.motionProgress(within: 0, interval: 5, fade: 1).current
        XCTAssertEqual(atEnd, atStart, accuracy: 1e-9)
    }

    func testOldSlideshowAndTickerProjectsDecode() throws {
        let old = #"{"images":[{"path":"/a.jpg"}],"interval":4,"fade":1,"loop":true}"#
        let s = try JSONDecoder().decode(ProjectSlideshow.self, from: Data(old.utf8))
        XCTAssertNil(s.kenBurns); XCTAssertNil(s.folder)
        var t = TickerConfig(text: "x"); t.textFilePath = "/tmp/news.txt"
        XCTAssertEqual(try JSONDecoder().decode(TickerConfig.self, from: JSONEncoder().encode(t)), t)
    }
}

final class M19Tests: XCTestCase {
    func testLeftToRightTickerEntersOnTheLeft() {
        XCTAssertEqual(TickerMath.offset(elapsed: 0, speed: 100, stripWidth: 1000, viewWidth: 1920, direction: .leftToRight), -1000)
        XCTAssertEqual(TickerMath.offset(elapsed: 10, speed: 100, stripWidth: 1000, viewWidth: 1920, direction: .leftToRight), 0)
        XCTAssertEqual(TickerConfig(text: "x").scrollDirection, .rightToLeft, "old projects keep scrolling right to left")
    }

    func testRSSAndAtomTitles() {
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Channel Name</title>
        <item><title>Gempa 5,1 SR &amp; tidak berpotensi tsunami</title><link>x</link></item>
        <item><title><![CDATA[Harga <b>beras</b> turun]]></title></item>
        <item><title>Skor &#8211; 2:1 &#x2014; final</title></item>
        </channel></rss>
        """
        XCTAssertEqual(FeedTitles.parse(rss), ["Gempa 5,1 SR & tidak berpotensi tsunami", "Harga beras turun", "Skor \u{2013} 2:1 \u{2014} final"])
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Feed</title>
        <entry><title type="html">Satu</title></entry><entry><title type="text">
          Dua   baris
        </title></entry></feed>
        """
        XCTAssertEqual(FeedTitles.parse(atom), ["Satu", "Dua baris"])
        XCTAssertEqual(FeedTitles.parse("<rss><item><titles>no</titles></item></rss>"), [])
        XCTAssertEqual(FeedTitles.parse(rss, limit: 1).count, 1)
    }
}

final class M20Tests: XCTestCase {
    func testOverlayAnimationsStartOffScreenAndEndInPlace() {
        let r = LayoutPreset.lowerThird.rect
        for a in OverlayAnimation.allCases {
            let end = a.placement(r, progress: 1)
            XCTAssertEqual(end.rect, r, "\(a) ends at its preset")
            XCTAssertEqual(end.opacity, 1, accuracy: 1e-9)
        }
        XCTAssertLessThanOrEqual(OverlayAnimation.slideFromLeft.placement(r, progress: 0).rect.x + r.width, 1e-9)
        XCTAssertGreaterThanOrEqual(OverlayAnimation.slideFromRight.placement(r, progress: 0).rect.x, 1 - 1e-9)
        XCTAssertGreaterThanOrEqual(OverlayAnimation.slideFromBottom.placement(r, progress: 0).rect.y, 1 - 1e-9)
        XCTAssertLessThanOrEqual(OverlayAnimation.slideFromTop.placement(r, progress: 0).rect.y + r.height, 1e-9)
        XCTAssertEqual(OverlayAnimation.fade.placement(r, progress: 0.3).opacity, 0.3, accuracy: 1e-9)
        let half = OverlayAnimation.slideFromLeft.placement(r, progress: 0.5)
        XCTAssertEqual(half.rect.x, -0.5, accuracy: 1e-9, "eased: half way at half time")
    }

    func testPlannerMovesASlidingOverlayAndProjectKeepsTheAnimation() throws {
        let sw = Switcher()
        var ch = OverlayChannel(index: 1, source: InputID("lt"), preset: .lowerThird, fadeDuration: 1)
        ch.animation = .slideFromRight
        ch.set(on: true, now: 0)
        let plan = FramePlanner.plan(snapshot: sw.state, overlays: [ch], now: 0.5,
                                     layersFor: { [Layer(source: $0)] }, keyFor: { _ in nil })
        XCTAssertEqual(plan.overlays.first?.rect.x ?? -1, 0.5, accuracy: 1e-9)
        let o = ProjectOverlay(index: 1, source: InputID("lt"), preset: .lowerThird, fadeDuration: 1, animation: .zoom)
        XCTAssertEqual(try JSONDecoder().decode(ProjectOverlay.self, from: JSONEncoder().encode(o)).animation, .zoom)
        let old = #"{"index":1,"preset":"lowerThird","fadeDuration":0.5}"#
        XCTAssertNil(try JSONDecoder().decode(ProjectOverlay.self, from: Data(old.utf8)).animation)
    }
}

final class EyedropperTests: XCTestCase {
    func testSampleAveragesTheAreaUnderTheCursor() {
        // 20×10 BGRA: left half green screen with noise, right half grey.
        let w = 20, h = 10
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            if x < 10 { px[i] = 64 + UInt8((x + y) % 2) * 2; px[i + 1] = 176 - UInt8((x * y) % 3); px[i + 2] = 0 }
            else { px[i] = 128; px[i + 1] = 128; px[i + 2] = 128 }
            px[i + 3] = 255
        } }
        let c = px.withUnsafeBufferPointer { ChromaKey.sampleColor(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4, x: 4, y: 5, radius: 3) }
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.g, 0.685, accuracy: 0.01)
        XCTAssertEqual(c!.r, 0, accuracy: 1e-9)
        XCTAssertEqual(c!.b, 0.255, accuracy: 0.01)
        let clear = [UInt8](repeating: 0, count: 16)
        XCTAssertNil(clear.withUnsafeBufferPointer { ChromaKey.sampleColor(bgra: $0.baseAddress!, width: 2, height: 2, bytesPerRow: 8, x: 0, y: 0) })
    }
}

final class MusicFadeTests: XCTestCase {
    func testFadeInAndOutAtTheEndsOfASong() {
        XCTAssertEqual(MusicFade.gain(position: 1, duration: 200, fade: 0), 1)
        XCTAssertEqual(MusicFade.gain(position: 0, duration: 200, fade: 4), 0)
        XCTAssertEqual(MusicFade.gain(position: 1, duration: 200, fade: 4), 0.25, accuracy: 1e-9)
        XCTAssertEqual(MusicFade.gain(position: 100, duration: 200, fade: 4), 1)
        XCTAssertEqual(MusicFade.gain(position: 198, duration: 200, fade: 4), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MusicFade.gain(position: 3, duration: 9, fade: 8), 1, accuracy: 1e-9, "short songs fade over a third at most")
        XCTAssertEqual(MusicFade.gain(position: 2, duration: nil, fade: 4), 0.5, accuracy: 1e-9)
        let old = #"{"id":"m","name":"Music","tracks":[],"loop":true,"shuffle":false}"#
        XCTAssertNil(try JSONDecoder().decode(ProjectMusic.self, from: Data(old.utf8)).fadeSeconds)
    }
}

final class PlaylistEditTests: XCTestCase {
    func testRemovingAndMovingKeepTheSongThatPlays() {
        XCTAssertEqual(PlaylistEdit.remove(at: 0, current: 2, count: 4).current, 1)
        XCTAssertFalse(PlaylistEdit.remove(at: 3, current: 2, count: 4).removedCurrent)
        let r = PlaylistEdit.remove(at: 3, current: 3, count: 4)
        XCTAssertTrue(r.removedCurrent); XCTAssertEqual(r.current, 2, "the last song removed: the one before plays")
        let list = ["a", "b", "c", "d"]
        for from in 0..<4 { for to in 0..<4 { for cur in 0..<4 {
            let m = PlaylistEdit.moved(list, from: from, to: to)
            XCTAssertEqual(m[PlaylistEdit.move(from: from, to: to, current: cur)], list[cur], "from \(from) to \(to) playing \(cur)")
        } } }
    }
}

final class M3UTests: XCTestCase {
    func testParseAndWrite() {
        let text = "\u{FEFF}#EXTM3U\r\n#EXTINF:215,Artist - Song\r\n/Music/a song.mp3\r\n\r\nrelative/b.m4a\nfile:///Users/x/Lagu%20Saya.mp3\n"
        XCTAssertEqual(M3U.parse(text), ["/Music/a song.mp3", "relative/b.m4a", "/Users/x/Lagu Saya.mp3"])
        let w = M3U.write(paths: ["/Music/a.b.mp3"])
        XCTAssertEqual(w, "#EXTM3U\n#EXTINF:-1,a.b\n/Music/a.b.mp3\n")
        XCTAssertEqual(M3U.parse(w), ["/Music/a.b.mp3"])
    }
}

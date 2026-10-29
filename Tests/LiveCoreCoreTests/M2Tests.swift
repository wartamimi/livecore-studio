import Foundation
import XCTest
@testable import LiveCoreCore

final class ResamplerTests: XCTestCase {
    private func run(_ rs: inout LinearResampler, _ input: [Float], blocks: Int) -> [Float] {
        var out: [Float] = []
        let per = input.count / blocks
        for b in 0..<blocks {
            let chunk = Array(input[(b * per)..<((b + 1) * per)])
            let cap = rs.maxOutputFrames(forInput: chunk.count)
            var l = [Float](repeating: 0, count: cap), r = [Float](repeating: 0, count: cap)
            let n = chunk.withUnsafeBufferPointer { inp in
                rs.process(inLeft: inp.baseAddress!, inRight: inp.baseAddress!, inputFrames: chunk.count,
                           outLeft: &l, outRight: &r, outputCapacity: cap)
            }
            out += l[0..<n]
            XCTAssertEqual(l[0..<n], r[0..<n])
        }
        return out
    }

    func testPassthroughIsIdentityAcrossBlocks() {
        var rs = LinearResampler(inputRate: 48_000, outputRate: 48_000)
        let input = (0..<4800).map { Float($0) }
        let out = run(&rs, input, blocks: 10)
        // One sample of latency (the carried-over sample) and nothing else.
        XCTAssertEqual(out.count, input.count)
        XCTAssertEqual(out.first, 0)
        XCTAssertEqual(Array(out[1...]), Array(input[0..<(input.count - 1)]))
    }

    func testOutputCountMatchesRateRatio() {
        var rs = LinearResampler(inputRate: 44_100, outputRate: 48_000)
        let input = [Float](repeating: 0.5, count: 44_100)
        let out = run(&rs, input, blocks: 49)   // 900-frame blocks
        XCTAssertEqual(Double(out.count), 48_000, accuracy: 2)
        XCTAssertTrue(out.dropFirst().allSatisfy { abs($0 - 0.5) < 1e-6 })
    }

    func testSineKeepsFrequencyAndAmplitude() {
        var rs = LinearResampler(inputRate: 44_100, outputRate: 48_000)
        let f = 1000.0
        let input = (0..<44_100).map { Float(sin(2 * Double.pi * f * Double($0) / 44_100)) }
        let out = run(&rs, input, blocks: 100)
        // Compare against an ideal 48 kHz sine delayed by one input sample.
        var maxErr: Float = 0
        for (k, v) in out.enumerated().dropFirst(10) {
            let t = Double(k) / 48_000 - 1 / 44_100
            maxErr = max(maxErr, abs(v - Float(sin(2 * Double.pi * f * t))))
        }
        XCTAssertLessThan(maxErr, 0.01)   // linear interpolation error at 1 kHz
    }

    func testDownsamplingAndLimitedCapacity() {
        var rs = LinearResampler(inputRate: 96_000, outputRate: 48_000)
        let input = (0..<960).map { Float($0) }
        let out = run(&rs, input, blocks: 4)
        XCTAssertEqual(Double(out.count), 480, accuracy: 2)
        var rs2 = LinearResampler(inputRate: 48_000, outputRate: 48_000)
        var l = [Float](repeating: 0, count: 10), r = l
        let n = input.withUnsafeBufferPointer {
            rs2.process(inLeft: $0.baseAddress!, inRight: $0.baseAddress!, inputFrames: 100, outLeft: &l, outRight: &r, outputCapacity: 10)
        }
        XCTAssertEqual(n, 10)
    }
}

final class NoiseGateTests: XCTestCase {
    func testGateAttenuatesNoiseAndPassesSignal() {
        var g = NoiseGate(sampleRate: 48_000)
        g.thresholdDB = -40; g.rangeDB = -60
        let n = 48_00
        var noise = (0..<n).map { _ in Float.random(in: -0.001...0.001) }   // about -60 dBFS
        noise.withUnsafeMutableBufferPointer { g.process(left: $0.baseAddress!, right: nil, frames: n) }
        XCTAssertFalse(g.isOpen)
        XCTAssertLessThan(noise.map { abs($0) }.max()!, 0.00001)
        XCTAssertGreaterThan(g.gainReductionDB, 50)

        var tone = (0..<n).map { Float(0.3 * sin(Double($0) * 0.05)) }
        tone.withUnsafeMutableBufferPointer { g.process(left: $0.baseAddress!, right: nil, frames: n) }
        XCTAssertTrue(g.isOpen)
        XCTAssertLessThan(g.gainReductionDB, 0.1)
        // After the 2 ms attack the tone passes essentially unchanged.
        XCTAssertEqual(tone[n - 1], Float(0.3 * sin(Double(n - 1) * 0.05)), accuracy: 0.001)
    }

    func testHoldKeepsGateOpenBrieflyThenReleases() {
        var g = NoiseGate(sampleRate: 48_000)
        g.thresholdDB = -40; g.holdSeconds = 0.05
        var loud = [Float](repeating: 0.5, count: 480)
        loud.withUnsafeMutableBufferPointer { g.process(left: $0.baseAddress!, right: nil, frames: 480) }
        XCTAssertTrue(g.isOpen)
        var quiet = [Float](repeating: 0, count: 1200)   // 25 ms < hold
        quiet.withUnsafeMutableBufferPointer { g.process(left: $0.baseAddress!, right: nil, frames: 1200) }
        XCTAssertTrue(g.isOpen)
        var longQuiet = [Float](repeating: 0, count: 48_000)
        longQuiet.withUnsafeMutableBufferPointer { g.process(left: $0.baseAddress!, right: nil, frames: 48_000) }
        XCTAssertFalse(g.isOpen)
        XCTAssertGreaterThan(g.gainReductionDB, 50)
    }

    func testChannelStripAppliesGateWhenEnabled() {
        let c = ChannelControls()
        c.gateEnabled.value = true
        c.gateThresholdDB.value = -30
        var dsp = ChannelStripDSP(controls: c, sampleRate: 48_000)
        var l = [Float](repeating: 0.001, count: 4800), r = l
        dsp.process(left: &l, right: &r, frames: 4800)
        XCTAssertLessThan(abs(l[4799]), 0.000_01)
        XCTAssertGreaterThan(c.gateReductionDB.value, 60)
        c.gateEnabled.value = false
        var l2 = [Float](repeating: 0.001, count: 4800), r2 = l2
        dsp.process(left: &l2, right: &r2, frames: 4800)
        XCTAssertEqual(l2[4799], 0.001, accuracy: 1e-6)
        XCTAssertEqual(c.gateReductionDB.value, 0)
    }
}

final class ChromaKeyTests: XCTestCase {
    func testKeysGreenScreenKeepsSkinAndGrey() {
        let k = ChromaKey(enabled: true)
        XCTAssertEqual(k.alpha(r: 0.0, g: 0.69, b: 0.25), 0, accuracy: 1e-9)      // key colour
        XCTAssertEqual(k.alpha(r: 0.2, g: 0.7, b: 0.3), 0, accuracy: 1e-9)        // lit green screen
        XCTAssertEqual(k.alpha(r: 0.9, g: 0.7, b: 0.6), 1, accuracy: 1e-9)        // skin tone
        XCTAssertEqual(k.alpha(r: 0.5, g: 0.5, b: 0.5), 1, accuracy: 1e-9)        // grey
        XCTAssertEqual(k.alpha(r: 1, g: 1, b: 1), 1, accuracy: 1e-9)              // white shirt
    }

    func testEdgeIsSoftAndMonotonic() {
        let k = ChromaKey(enabled: true, similarity: 0.1, smoothness: 0.2)
        var last = -1.0
        for i in 0...20 {
            let t = Double(i) / 20   // blend from key green towards grey
            let a = k.alpha(r: 0.5 * t, g: 0.69 + (0.5 - 0.69) * t, b: 0.25 + 0.25 * t)
            XCTAssertGreaterThanOrEqual(a, last - 1e-12)
            last = a
        }
        XCTAssertEqual(last, 1, accuracy: 1e-9)
    }

    func testPlannerAttachesOnlyEnabledKeys() {
        let s = Switcher()
        let a = InputID("a"), b = InputID("b")
        s.setPreview(a); s.cut(); s.setPreview(b)
        let layers: [InputID: [Layer]] = [a: [Layer(source: a), Layer(source: b, rect: LayoutPreset.pipTopRight.rect)], b: [Layer(source: b)]]
        let keys: [InputID: ChromaKey] = [b: ChromaKey(enabled: true, similarity: 5), a: ChromaKey(enabled: false)]
        let plan = FramePlanner.plan(snapshot: s.state, overlays: [], now: 0, layersFor: { layers[$0] }, keyFor: { keys[$0] })
        XCTAssertNil(plan.program[0].key)
        XCTAssertEqual(plan.program[1].key?.similarity, 0.6)   // clamped
        XCTAssertNotNil(plan.preview[0].key)
    }
}

final class ProjectTests: XCTestCase {
    private func sample() -> ProjectDocument {
        let cam = InputID("cam"), clip = InputID("clip"), title = InputID("title")
        var doc = ProjectDocument()
        doc.settings.output = .hd720p60
        doc.settings.stream.serverURL = "rtmp://example.com/live"
        doc.inputs = [
            ProjectInput(id: cam, name: "Cam 1", source: .camera(uniqueID: "0x1234", deviceName: "FaceTime HD"),
                         layers: [Layer(source: cam), Layer(source: clip, rect: LayoutPreset.pipTopRight.rect, scaleMode: .fill)],
                         chromaKey: ChromaKey(enabled: true)),
            ProjectInput(id: clip, name: "Intro", source: .videoFile(path: "/Users/op/Show/intro.mov", relativePath: "intro.mov", loop: true)),
            ProjectInput(id: title, name: "Speaker", source: .title(ProjectTitleStyle(title: "Budi", subtitle: "CEO"))),
        ]
        doc.overlays = [ProjectOverlay(index: 1, source: title, preset: .lowerThird)]
        var ch = ProjectAudioChannel(deviceUniqueID: "mic-1", name: "USB Mic")
        ch.faderDB = -3; ch.gateEnabled = true
        doc.audio.channels = [ch, ProjectAudioChannel(inputID: clip, name: "Intro")]
        doc.previewInput = clip
        doc.programInput = cam
        return doc
    }

    func testJSONRoundTrip() throws {
        let doc = sample()
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(ProjectDocument.self, from: data)
        XCTAssertEqual(back, doc)
        XCTAssertTrue(doc.validationIssues().isEmpty)
        // The stream key is never part of the document.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("streamkey"))
    }

    func testSanitizeRemovesDanglingReferences() {
        var doc = sample()
        doc.inputs.remove(at: 1)   // remove the clip that a layer, the preview and a channel refer to
        doc.overlays.append(ProjectOverlay(index: 9, source: nil, preset: .fullScreen))
        doc.inputs.append(doc.inputs[0])   // duplicate id
        XCTAssertFalse(doc.validationIssues().isEmpty)
        let clean = doc.sanitized()
        XCTAssertTrue(clean.validationIssues().isEmpty)
        XCTAssertEqual(clean.inputs.count, 2)
        XCTAssertEqual(clean.inputs[0].layers, [Layer(source: InputID("cam"))])
        XCTAssertNil(clean.previewInput)
        XCTAssertEqual(clean.programInput, InputID("cam"))
        XCTAssertEqual(clean.overlays.map(\.index), [1])
    }

    func testSanitizeRestoresSelfLayer() {
        var doc = ProjectDocument()
        let a = InputID("a")
        doc.inputs = [ProjectInput(id: a, name: "A", source: .color(ProjectColor(r: 0, g: 0, b: 0)))]
        doc.inputs[0].layers = []
        XCTAssertEqual(doc.sanitized().inputs[0].layers, [Layer(source: a)])
    }

    func testRelativePaths() {
        XCTAssertEqual(ProjectPaths.relative(file: "/Users/op/Show/media/a.mov", toDirectory: "/Users/op/Show"), "media/a.mov")
        XCTAssertEqual(ProjectPaths.relative(file: "/Users/op/Clips/a.mov", toDirectory: "/Users/op/Show"), "../Clips/a.mov")
        XCTAssertEqual(ProjectPaths.relative(file: "/a.mov", toDirectory: "/Users/op"), "../../a.mov")
        XCTAssertNil(ProjectPaths.relative(file: "a.mov", toDirectory: "/x"))
        XCTAssertEqual(ProjectPaths.resolve("../Clips/a.mov", againstDirectory: "/Users/op/Show"), "/Users/op/Clips/a.mov")
        XCTAssertEqual(ProjectPaths.resolve("./media/a.mov", againstDirectory: "/Volumes/USB/Show"), "/Volumes/USB/Show/media/a.mov")
        for (f, d) in [("/Users/op/Show/media/a.mov", "/Users/op/Show"), ("/x/y/z.png", "/x/q/r")] {
            XCTAssertEqual(ProjectPaths.resolve(ProjectPaths.relative(file: f, toDirectory: d)!, againstDirectory: d), f)
        }
    }
}

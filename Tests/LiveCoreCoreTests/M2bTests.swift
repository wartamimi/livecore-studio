import Foundation
import XCTest
@testable import LiveCoreCore

final class DriftCompensatorTests: XCTestCase {
    /// Producer runs `ppm` fast/slow relative to the consumer; the buffer must stay bounded with
    /// no underruns and no overflow for 10 simulated minutes.
    private func simulate(ppm: Double) -> (minFill: Int, maxFill: Int, underruns: Int, ratio: Double) {
        let ringL = SPSCFloatRingBuffer(minimumCapacity: 48_000), ringR = SPSCFloatRingBuffer(minimumCapacity: 48_000)
        let dc = DriftCompensator(targetFill: 1536, maxFrames: 4096)
        let block = 512
        var outL = [Float](repeating: 0, count: block), outR = outL
        let src = [Float](repeating: 0.25, count: 4096)
        var produced = 0.0, written = 0
        // Pre-fill to the target, then run.
        src.withUnsafeBufferPointer { _ = ringL.write($0.baseAddress!, count: 1536); _ = ringR.write($0.baseAddress!, count: 1536) }
        var minFill = Int.max, maxFill = 0, underruns = 0
        let blocks = 10 * 60 * 48_000 / block
        for b in 0..<blocks {
            // Producer delivers in 480-frame bursts (like a 10 ms capture callback) at its own clock.
            produced += Double(block) * (1 + ppm / 1_000_000)
            while Double(written) + 480 <= produced {
                src.withUnsafeBufferPointer { _ = ringL.write($0.baseAddress!, count: 480); _ = ringR.write($0.baseAddress!, count: 480) }
                written += 480
            }
            if !dc.render(ringL: ringL, ringR: ringR, outL: &outL, outR: &outR, frames: block) { underruns += 1 }
            if b > blocks / 4 {   // after settling
                let fill = ringL.availableToRead
                minFill = min(minFill, fill); maxFill = max(maxFill, fill)
            }
        }
        return (minFill, maxFill, underruns, dc.ratio)
    }

    func testTracksFastProducer() {
        let r = simulate(ppm: 300)
        XCTAssertEqual(r.underruns, 0)
        XCTAssertLessThan(r.maxFill, 4000)
        XCTAssertGreaterThan(r.ratio, 1.0001)
        XCTAssertLessThan(r.ratio, 1.0006)
    }

    func testTracksSlowProducer() {
        let r = simulate(ppm: -300)
        XCTAssertEqual(r.underruns, 0)
        XCTAssertGreaterThan(r.minFill, 0)
        XCTAssertLessThan(r.ratio, 0.9999)
    }

    func testMatchedClocksPassSignalUnchanged() {
        let ringL = SPSCFloatRingBuffer(minimumCapacity: 8192), ringR = SPSCFloatRingBuffer(minimumCapacity: 8192)
        let dc = DriftCompensator(targetFill: 1024, maxFrames: 512)
        let ramp = (0..<4096).map { Float($0) }
        ramp.withUnsafeBufferPointer { _ = ringL.write($0.baseAddress!, count: 4096); _ = ringR.write($0.baseAddress!, count: 4096) }
        var l = [Float](repeating: 0, count: 256), r = l
        XCTAssertTrue(dc.render(ringL: ringL, ringR: ringR, outL: &l, outR: &r, frames: 256))
        // Output is a smooth ramp with slope ≈ ratio (≈ 1, slightly > 1 because the buffer is over target).
        for i in 1..<256 { XCTAssertEqual(l[i] - l[i - 1], Float(dc.ratio), accuracy: 0.01) }
        XCTAssertEqual(l, r)
    }

    func testUnderrunReturnsSilenceWithoutConsuming() {
        let ringL = SPSCFloatRingBuffer(minimumCapacity: 1024), ringR = SPSCFloatRingBuffer(minimumCapacity: 1024)
        let dc = DriftCompensator(targetFill: 256, maxFrames: 512)
        let x = [Float](repeating: 1, count: 100)
        x.withUnsafeBufferPointer { _ = ringL.write($0.baseAddress!, count: 100); _ = ringR.write($0.baseAddress!, count: 100) }
        var l = [Float](repeating: 9, count: 256), r = l
        XCTAssertFalse(dc.render(ringL: ringL, ringR: ringR, outL: &l, outR: &r, frames: 256))
        XCTAssertTrue(l.allSatisfy { $0 == 0 })
        XCTAssertEqual(ringL.availableToRead, 100)
    }
}

final class EqualizerTests: XCTestCase {
    func testHighPassAttenuatesRumble() {
        var eq = ChannelEQ(sampleRate: 48_000)
        var p = ChannelEQ.Params(); p.highPassEnabled = true; p.highPassHz = 80
        eq.update(p)
        XCTAssertLessThan(eq.responseDB(at: 20), -20)
        XCTAssertEqual(eq.responseDB(at: 80), -3, accuracy: 0.3)
        XCTAssertEqual(eq.responseDB(at: 1000), 0, accuracy: 0.1)
    }

    func testBandsHitTheirGains() {
        var eq = ChannelEQ(sampleRate: 48_000)
        var p = ChannelEQ.Params(); p.eqEnabled = true
        p.lowGainDB = 6; p.midGainDB = -4; p.midHz = 2500; p.highGainDB = 3
        eq.update(p)
        XCTAssertEqual(eq.responseDB(at: 30), 6, accuracy: 0.5)
        XCTAssertEqual(eq.responseDB(at: 2500), -4, accuracy: 0.6)
        XCTAssertEqual(eq.responseDB(at: 20_000), 3, accuracy: 0.5)
        XCTAssertEqual(eq.responseDB(at: 600), 0, accuracy: 1.5)
    }

    func testProcessingMatchesResponse() {
        var eq = ChannelEQ(sampleRate: 48_000)
        var p = ChannelEQ.Params(); p.eqEnabled = true; p.midGainDB = 6; p.midHz = 1000
        eq.update(p)
        let n = 48_000
        var l = (0..<n).map { Float(0.1 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }, r = l
        eq.processEQ(left: &l, right: &r, frames: n)
        let peak = l[(n / 2)...].map { abs($0) }.max()!
        XCTAssertEqual(Double(20 * log10(peak / 0.1)), 6, accuracy: 0.3)
        XCTAssertEqual(l, r)
    }

    func testChannelStripRunsEQWhenEnabled() {
        let c = ChannelControls()
        c.highPassEnabled.value = true; c.highPassHz.value = 200
        var dsp = ChannelStripDSP(controls: c, sampleRate: 48_000)
        var l = [Float](repeating: 0.5, count: 48_000), r = l   // DC is fully removed by a high-pass
        dsp.process(left: &l, right: &r, frames: 48_000)
        XCTAssertLessThan(abs(l[47_999]), 0.001)
    }
}

final class LayerEditingTests: XCTestCase {
    func testMoveKeepsLayerGrabbable() {
        let r = NormRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)
        let m = LayerEditing.move(r, dx: 2, dy: -5)
        XCTAssertEqual(m.x, 0.95, accuracy: 1e-9)
        XCTAssertEqual(m.y, LayerEditing.minimumVisible - 0.3, accuracy: 1e-9)
        XCTAssertEqual(m.width, 0.3)
    }

    func testResizeAnchorsOppositeCornerAndKeepsAspect() {
        let r = NormRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4)
        let free = LayerEditing.resize(r, handle: .topLeft, dx: -0.1, dy: 0.05)
        XCTAssertEqual(free.x + free.width, 0.9, accuracy: 1e-9)
        XCTAssertEqual(free.y + free.height, 0.9, accuracy: 1e-9)
        XCTAssertEqual(free.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(free.height, 0.35, accuracy: 1e-9)
        let locked = LayerEditing.resize(r, handle: .bottomRight, dx: 0.2, dy: 0, aspect: 1)
        XCTAssertEqual(locked.width, locked.height, accuracy: 1e-9)
        XCTAssertEqual(locked.x, 0.5); XCTAssertEqual(locked.y, 0.5)
        let tiny = LayerEditing.resize(r, handle: .bottomRight, dx: -1, dy: -1)
        XCTAssertEqual(tiny.width, LayerEditing.minimumSize, accuracy: 1e-9)
    }

    func testAspectReorderAndSnap() {
        XCTAssertEqual(LayerEditing.normalizedAspect(source: PixelSize(width: 1920, height: 1080), canvas: PixelSize(width: 1280, height: 720))!, 1, accuracy: 1e-9)
        XCTAssertEqual(LayerEditing.normalizedAspect(source: PixelSize(width: 1080, height: 1080), canvas: PixelSize(width: 1920, height: 1080))!, 0.5625, accuracy: 1e-9)
        let a = InputID("a"), b = InputID("b"), c = InputID("c")
        let layers = [Layer(source: a), Layer(source: b), Layer(source: c)]
        XCTAssertEqual(LayerEditing.reorder(layers, from: 2, to: 1).map(\.source), [a, c, b])
        XCTAssertEqual(LayerEditing.reorder(layers, from: 0, to: 2).map(\.source), [a, b, c])
        XCTAssertEqual(LayerEditing.snap(0.495), 0.5)
        XCTAssertEqual(LayerEditing.snap(0.3), 0.3)
    }
}

final class ProjectCompatTests: XCTestCase {
    /// A project written by 0.2.0 (no EQ, no title sizes/layout) must still open.
    func testDecodes020ProjectWithoutNewFields() throws {
        let json = """
        {"version":1,"settings":\(String(decoding: try JSONEncoder().encode(ProductionSettings()), as: UTF8.self)),
         "inputs":[{"id":{"raw":"t"},"name":"T","layers":[{"source":{"raw":"t"},"rect":{"x":0,"y":0.7,"width":1,"height":0.25},"scaleMode":"fit","opacity":1}],
           "source":{"title":{"_0":{"title":"Budi","subtitle":"CEO","showBar":true,"textColor":{"r":1,"g":1,"b":1,"a":1},"barColor":{"r":0,"g":0,"b":1,"a":1}}}}}],
         "overlays":[],
         "audio":{"masterFaderDB":0,"limiterEnabled":true,"monitorVolume":1,"syncOffsetMs":0,
           "channels":[{"deviceUniqueID":"mic","name":"Mic","faderDB":0,"gainDB":0,"pan":0,"muted":false,"toProgram":true,
             "compressorEnabled":false,"compThresholdDB":-18,"compRatio":3,"gateEnabled":true,"gateThresholdDB":-45}]}}
        """
        let doc = try JSONDecoder().decode(ProjectDocument.self, from: Data(json.utf8))
        XCTAssertNil(doc.audio.channels[0].eq)
        guard case let .title(t) = doc.inputs[0].source else { return XCTFail("expected title") }
        XCTAssertEqual(t.title, "Budi")
        XCTAssertNil(t.titleSize)
        XCTAssertNil(t.layout)
    }
}

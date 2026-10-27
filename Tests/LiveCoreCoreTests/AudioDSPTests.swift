import XCTest
@testable import LiveCoreCore

final class AudioDSPTests: XCTestCase {
    func testDBConversions() {
        XCTAssertEqual(AudioMath.dbToLinear(0), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioMath.dbToLinear(-6.0206), 0.5, accuracy: 1e-4)
        XCTAssertEqual(AudioMath.linearToDB(0.1), -20, accuracy: 1e-4)
        XCTAssertEqual(AudioMath.linearToDB(0), AudioMath.silenceDB)
        XCTAssertEqual(AudioMath.dbToLinear(-200), 0)
    }

    func testFaderLawMonotonicAndRoundTrips() {
        XCTAssertEqual(FaderLaw.db(forPosition: 0.75), 0, accuracy: 1e-6)
        XCTAssertEqual(FaderLaw.db(forPosition: 1), 10, accuracy: 1e-6)
        XCTAssertEqual(FaderLaw.db(forPosition: 0), AudioMath.silenceDB)
        var last: Float = -1000
        for i in 1...100 {
            let d = FaderLaw.db(forPosition: Double(i) / 100)
            XCTAssertGreaterThan(d, last); last = d
            XCTAssertEqual(FaderLaw.position(forDB: d), Double(i) / 100, accuracy: 1e-4)
        }
    }

    func testCompressorStaticCurve() {
        var c = Compressor(sampleRate: 48000)
        c.thresholdDB = -20; c.ratio = 4; c.kneeDB = 0
        XCTAssertEqual(c.staticReduction(inputDB: -30), 0)
        XCTAssertEqual(c.staticReduction(inputDB: -8), 9, accuracy: 1e-5) // 12 dB over * (1 - 1/4)
        c.kneeDB = 6
        XCTAssertEqual(c.staticReduction(inputDB: -24), 0)
        XCTAssertEqual(c.staticReduction(inputDB: -20), 0.75 * 9 / 12, accuracy: 1e-5) // mid-knee
        XCTAssertEqual(c.staticReduction(inputDB: -8), 9, accuracy: 1e-5)
    }

    func testCompressorReducesSteadyToneToExpectedLevel() {
        var c = Compressor(sampleRate: 48000)
        c.thresholdDB = -20; c.ratio = 4; c.kneeDB = 0; c.attackSeconds = 0.001; c.releaseSeconds = 0.05
        let n = 48000
        let amp = AudioMath.dbToLinear(-8)
        var l = (0..<n).map { i in amp * sinf(2 * .pi * 1000 * Float(i) / 48000) }
        var r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            c.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: n)
        } }
        let tailPeak = AudioMath.linearToDB(AudioMath.peak(Array(l[(n - 4800)...]), count: 4800))
        // Peak detector on a sine settles between the peak-derived target (-17 dB) and the
        // uncompressed level; with 1 ms attack/50 ms release it sits within ~1.5 dB of -17.
        XCTAssertEqual(tailPeak, -17, accuracy: 1.5)
        XCTAssertGreaterThan(c.gainReductionDB, 7)
    }

    func testLimiterNeverExceedsCeiling() {
        var lim = Limiter(sampleRate: 48000)
        lim.ceilingDB = -1
        let ceiling = AudioMath.dbToLinear(-1)
        var l: [Float] = (0..<4800).map { i in (i % 100 == 0 ? 3.0 : 0.2) * (i % 2 == 0 ? 1 : -1) }
        var r = l.map { $0 * 0.5 }
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            lim.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: lp.count)
        } }
        XCTAssertLessThanOrEqual(AudioMath.peak(l, count: l.count), ceiling + 1e-6)
        XCTAssertLessThanOrEqual(AudioMath.peak(r, count: r.count), ceiling + 1e-6)
    }

    func testGainRampIsClickFreeAndReachesTarget() {
        var ramp = GainRamp(initial: 1)
        var l = [Float](repeating: 1, count: 100)
        l.withUnsafeMutableBufferPointer { ramp.apply(target: 0, left: $0.baseAddress!, right: nil, frames: 100) }
        XCTAssertEqual(l.last!, 0, accuracy: 1e-6)
        for i in 1..<100 { XCTAssertLessThanOrEqual(abs(l[i] - l[i - 1]), 0.011) }
        XCTAssertEqual(ramp.current, 0)
    }

    func testChannelStripMuteFaderAndMeter() {
        let ctl = ChannelControls()
        var strip = ChannelStripDSP(controls: ctl, sampleRate: 48000)
        func run(_ v: Float, frames: Int = 512) -> ([Float], [Float]) {
            var l = [Float](repeating: v, count: frames), r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                strip.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames)
            } }
            return (l, r)
        }
        _ = run(0.5)
        XCTAssertEqual(ctl.peakL.exchange(0), 0.5, accuracy: 1e-6)
        ctl.faderDB.value = -6.0206
        _ = run(0.5)                     // ramp block
        let (l, _) = run(0.5)
        XCTAssertEqual(l[0], 0.25, accuracy: 1e-3)
        ctl.muted.value = true
        _ = run(0.5)
        let (lm, rm) = run(0.5)
        XCTAssertEqual(AudioMath.peak(lm, count: lm.count), 0)
        XCTAssertEqual(AudioMath.peak(rm, count: rm.count), 0)
        ctl.muted.value = false; ctl.faderDB.value = 0; ctl.pan.value = -1
        _ = run(0.5)
        let (pl, pr) = run(0.5)
        XCTAssertEqual(pl[0], 0.5, accuracy: 1e-6); XCTAssertEqual(pr[0], 0, accuracy: 1e-6)
    }

    func testMeterBallisticsDecayAndHold() {
        var m = MeterBallistics()
        m.update(peakLinear: 1, dt: 0.05, now: 0)
        XCTAssertEqual(m.levelDB, 0, accuracy: 1e-6)
        m.update(peakLinear: 0, dt: 0.5, now: 0.5)
        XCTAssertEqual(m.levelDB, -12, accuracy: 1e-4)
        XCTAssertEqual(m.peakHoldDB, 0, accuracy: 1e-6, "held")
        m.update(peakLinear: 0, dt: 1.5, now: 2.0)
        XCTAssertLessThan(m.peakHoldDB, 0, "hold released after holdSeconds")
    }
}

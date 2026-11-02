/// Clock-drift correction for one mixer input.
///
/// Every audio device has its own crystal: a USB mic "48 kHz" may really run at 48 010 Hz while
/// the output device runs at 47 995 Hz. Without correction the channel's jitter buffer slowly
/// fills up or runs dry, and the mixer has to drop or insert a block (an audible click every few
/// minutes). This compensator pulls exactly `frames` output samples per render call and reads
/// slightly more or fewer input samples (adaptive resampling, at most ±`maxAdjust`), steering the
/// buffer fill towards `targetFill` with a PI controller on a smoothed fill measurement.
///
/// Real-time safe: no allocation after init, no locks, no system calls. One instance per channel,
/// used only by the consumer (render) thread.
public final class DriftCompensator: @unchecked Sendable {
    public let targetFill: Int
    public var maxAdjust: Double = 0.005           // ±0.5 % = ±5000 ppm, far beyond real crystals
    public private(set) var ratio: Double = 1      // input samples consumed per output sample
    public private(set) var smoothedFill: Double
    private var integral: Double = 0
    private var frac: Double = 0                   // position between s0 and s1
    private var s0L: Float = 0, s0R: Float = 0, s1L: Float = 0, s1R: Float = 0
    private var started = false
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int
    // Controller gains (per render block): fill error is normalised to targetFill.
    private let kp = 0.0015
    private let ki = 0.000_002
    private let fillSmoothing = 0.02               // one-pole per block (~0.5 s at 10 ms blocks)

    public init(targetFill: Int, maxFrames: Int) {
        precondition(targetFill > 0 && maxFrames > 0)
        self.targetFill = targetFill
        smoothedFill = Double(targetFill)
        scratchCapacity = Int(Double(maxFrames) * 1.01) + 4
        scratchL = .allocate(capacity: scratchCapacity)
        scratchR = .allocate(capacity: scratchCapacity)
        scratchL.initialize(repeating: 0, count: scratchCapacity)
        scratchR.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit { scratchL.deallocate(); scratchR.deallocate() }

    /// Forget the controller and interpolation state (after an underrun or re-prime).
    public func reset() {
        started = false; frac = 0; integral = 0; ratio = 1
        smoothedFill = Double(targetFill)
    }

    /// Fills `outL/outR` with exactly `frames` samples. Returns false on underrun (not enough
    /// input buffered): the output is then silent and nothing is consumed, so the caller can
    /// re-prime its jitter buffer.
    @discardableResult
    public func render(ringL: SPSCFloatRingBuffer, ringR: SPSCFloatRingBuffer,
                       outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        guard frames > 0 else { return true }
        let available = min(ringL.availableToRead, ringR.availableToRead)

        // Controller: steer the smoothed fill to the target.
        smoothedFill += (Double(available) - smoothedFill) * fillSmoothing
        let err = (smoothedFill - Double(targetFill)) / Double(targetFill)
        integral = min(max(integral + err, -maxAdjust / ki), maxAdjust / ki)
        ratio = 1 + min(max(kp * err + ki * integral, -maxAdjust), maxAdjust)

        if !started {
            guard available >= 2 + frames else { silence(outL, outR, frames); return false }
            ringL.read(into: &s0L, count: 1); ringR.read(into: &s0R, count: 1)
            ringL.read(into: &s1L, count: 1); ringR.read(into: &s1R, count: 1)
            frac = 0
            started = true
        }

        // Dry run: how many input samples does this block advance over?
        var f = frac
        var need = 0
        for _ in 0..<frames {
            f += ratio
            while f >= 1 { f -= 1; need += 1 }
        }
        guard need <= scratchCapacity, need <= min(ringL.availableToRead, ringR.availableToRead) else {
            silence(outL, outR, frames)
            started = false
            return false
        }
        ringL.read(into: scratchL, count: need)
        ringR.read(into: scratchR, count: need)

        var k = 0
        f = frac
        for i in 0..<frames {
            let ff = Float(f)
            outL[i] = s0L + (s1L - s0L) * ff
            outR[i] = s0R + (s1R - s0R) * ff
            f += ratio
            while f >= 1 {
                f -= 1
                s0L = s1L; s0R = s1R
                s1L = scratchL[k]; s1R = scratchR[k]
                k += 1
            }
        }
        frac = f
        return true
    }

    private func silence(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        l.update(repeating: 0, count: n); r.update(repeating: 0, count: n)
    }
}

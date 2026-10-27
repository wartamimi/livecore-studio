/// Shared, lock-free parameter block for one mixer channel. Written by the UI (main thread),
/// read by the audio render callback. Meter values flow back the other way.
public final class ChannelControls: @unchecked Sendable {
    public let gainDB = AtomicFloat(0)          // input trim, -24...+24 dB
    public let faderDB = AtomicFloat(0)         // fader, -inf...+10 dB
    public let pan = AtomicFloat(0)             // -1 ... +1 (balance)
    public let muted = AtomicBool(false)
    public let solo = AtomicBool(false)         // affects the monitor bus only
    public let toProgram = AtomicBool(true)     // routed to the Program (stream/record) bus
    public let toBusA = AtomicBool(false)       // routed (post-fader) to aux bus A
    public let toBusB = AtomicBool(false)       // routed (post-fader) to aux bus B
    public let compressorEnabled = AtomicBool(false)
    public let compThresholdDB = AtomicFloat(-18)
    public let compRatio = AtomicFloat(3)
    public let compMakeupDB = AtomicFloat(0)
    public let gateEnabled = AtomicBool(false)
    public let gateThresholdDB = AtomicFloat(-50)
    public let gateRangeDB = AtomicFloat(-80)
    public let highPassEnabled = AtomicBool(false)
    public let highPassHz = AtomicFloat(80)
    public let eqEnabled = AtomicBool(false)
    public let eqLowDB = AtomicFloat(0)
    public let eqMidDB = AtomicFloat(0)
    public let eqMidHz = AtomicFloat(1000)
    public let eqHighDB = AtomicFloat(0)
    // Meters (post-fader), consumed with `exchange(0)` by the UI.
    public let peakL = AtomicFloat(0)
    public let peakR = AtomicFloat(0)
    public let gainReductionDB = AtomicFloat(0)
    public let gateReductionDB = AtomicFloat(0)

    public init() {}
}

/// Real-time DSP for one stereo channel:
/// trim -> high-pass -> noise gate -> EQ -> compressor -> fader/pan (ramped) -> meter.
/// Owned by the render thread; `ChannelControls` is the only shared state.
public struct ChannelStripDSP: Sendable {
    public let controls: ChannelControls
    private var ramp = GainRamp(initial: 1)
    private var panRampL = GainRamp(initial: 1)
    private var panRampR = GainRamp(initial: 1)
    private var compressor: Compressor
    private var gate: NoiseGate
    private var eq: ChannelEQ

    public init(controls: ChannelControls, sampleRate: Float) {
        self.controls = controls
        self.compressor = Compressor(sampleRate: sampleRate)
        self.gate = NoiseGate(sampleRate: sampleRate)
        self.eq = ChannelEQ(sampleRate: Double(sampleRate))
    }

    /// Processes in place. Returns false when the channel is muted (buffers are zeroed).
    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let muted = controls.muted.value
        let trim = AudioMath.dbToLinear(controls.gainDB.value)
        let gateOn = controls.gateEnabled.value
        let compOn = controls.compressorEnabled.value
        var eqp = ChannelEQ.Params()
        eqp.highPassEnabled = controls.highPassEnabled.value
        eqp.highPassHz = Double(controls.highPassHz.value)
        eqp.eqEnabled = controls.eqEnabled.value
        eqp.lowGainDB = Double(controls.eqLowDB.value)
        eqp.midGainDB = Double(controls.eqMidDB.value)
        eqp.midHz = Double(controls.eqMidHz.value)
        eqp.highGainDB = Double(controls.eqHighDB.value)
        eq.update(eqp)
        if gateOn || compOn || eqp.highPassEnabled || eqp.eqEnabled {
            // Processing sees the trimmed signal, so thresholds are independent of the fader.
            if trim != 1 { for i in 0..<frames { left[i] *= trim; right[i] *= trim } }
            eq.processHighPass(left: left, right: right, frames: frames)
            if gateOn {
                gate.thresholdDB = controls.gateThresholdDB.value
                gate.rangeDB = controls.gateRangeDB.value
                gate.process(left: left, right: right, frames: frames)
                controls.gateReductionDB.value = gate.gainReductionDB
            } else {
                controls.gateReductionDB.value = 0
            }
            eq.processEQ(left: left, right: right, frames: frames)
            if compOn {
                compressor.thresholdDB = controls.compThresholdDB.value
                compressor.ratio = max(1, controls.compRatio.value)
                compressor.makeupDB = controls.compMakeupDB.value
                compressor.process(left: left, right: right, frames: frames)
                controls.gainReductionDB.value = compressor.gainReductionDB
            } else {
                controls.gainReductionDB.value = 0
            }
            ramp.apply(target: muted ? 0 : AudioMath.dbToLinear(controls.faderDB.value), left: left, right: right, frames: frames)
        } else {
            controls.gainReductionDB.value = 0
            controls.gateReductionDB.value = 0
            ramp.apply(target: muted ? 0 : trim * AudioMath.dbToLinear(controls.faderDB.value), left: left, right: right, frames: frames)
        }
        // Balance-style pan (linear): centre = unity on both sides, hard left mutes right.
        let p = min(max(controls.pan.value, -1), 1)
        let gl: Float = p <= 0 ? 1 : 1 - p
        let gr: Float = p >= 0 ? 1 : 1 + p
        panRampL.apply(target: gl, left: left, right: nil, frames: frames)
        panRampR.apply(target: gr, left: right, right: nil, frames: frames)

        controls.peakL.storeMax(AudioMath.peak(left, count: frames))
        controls.peakR.storeMax(AudioMath.peak(right, count: frames))
    }
}

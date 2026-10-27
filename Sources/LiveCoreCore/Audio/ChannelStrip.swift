/// Shared, lock-free parameter block for one mixer channel. Written by the UI (main thread),
/// read by the audio render callback. Meter values flow back the other way.
public final class ChannelControls: @unchecked Sendable {
    public let gainDB = AtomicFloat(0)          // input trim, -24...+24 dB
    public let faderDB = AtomicFloat(0)         // fader, -inf...+10 dB
    public let pan = AtomicFloat(0)             // -1 ... +1 (balance)
    public let muted = AtomicBool(false)
    /// Audio-follow-video gate: true while the linked input is off air (engine-controlled,
    /// independent of the operator's mute).
    public let afvClosed = AtomicBool(false)
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
    public let compAttackMs = AtomicFloat(10)
    public let compReleaseMs = AtomicFloat(150)
    /// `ChannelMode` raw value (stored as a float so it shares the lock-free cell type).
    public let channelMode = AtomicFloat(0)
    public let invertPhase = AtomicBool(false)
    /// Delays this channel (lip-sync for a camera that is late), 0...`ChannelStripDSP.maxDelayMs`.
    public let delayMs = AtomicFloat(0)
    public var mode: ChannelMode {
        get { ChannelMode(rawValue: Int(channelMode.value.rounded())) ?? .stereo }
        set { channelMode.value = Float(newValue.rawValue) }
    }
    // Meters (post-fader), consumed with `exchange(0)` by the UI.
    public let peakL = AtomicFloat(0)
    public let peakR = AtomicFloat(0)
    public let gainReductionDB = AtomicFloat(0)
    public let gateReductionDB = AtomicFloat(0)

    public init() {}
}

/// How the two input channels are used (audio properties). Raw values are stored in projects.
public enum ChannelMode: Int, CaseIterable, Codable, Sendable {
    case stereo = 0
    case leftOnly = 1      // left input on both sides (mono microphone on input 1)
    case rightOnly = 2     // right input on both sides
    case monoMix = 3       // (L + R) / 2 on both sides
    case swap = 4          // left and right exchanged

    /// Applies the mode in place.
    public static func apply(_ mode: ChannelMode, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        switch mode {
        case .stereo: return
        case .leftOnly: for i in 0..<frames { right[i] = left[i] }
        case .rightOnly: for i in 0..<frames { left[i] = right[i] }
        case .monoMix: for i in 0..<frames { let m = (left[i] + right[i]) * 0.5; left[i] = m; right[i] = m }
        case .swap: for i in 0..<frames { let t = left[i]; left[i] = right[i]; right[i] = t }
        }
    }
}

/// Fixed-capacity stereo delay line (allocated once, no allocation on the audio thread).
public struct StereoDelay: Sendable {
    private var bufL: [Float]
    private var bufR: [Float]
    private var write = 0
    public init(capacity: Int) {
        bufL = [Float](repeating: 0, count: max(1, capacity))
        bufR = [Float](repeating: 0, count: max(1, capacity))
    }
    public var capacity: Int { bufL.count }

    /// Delays the signal by `samples` (clamped to capacity - 1). 0 still feeds the line so a later
    /// change starts from real history instead of silence.
    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, samples: Int) {
        let n = bufL.count
        let d = min(max(samples, 0), n - 1)
        bufL.withUnsafeMutableBufferPointer { bl in
            bufR.withUnsafeMutableBufferPointer { br in
                var w = write
                for i in 0..<frames {
                    bl[w] = left[i]; br[w] = right[i]
                    if d > 0 {
                        var r = w - d
                        if r < 0 { r += n }
                        left[i] = bl[r]; right[i] = br[r]
                    }
                    w += 1
                    if w == n { w = 0 }
                }
                write = w
            }
        }
    }
}

/// Real-time DSP for one stereo channel:
/// channel mode / phase / delay -> trim -> high-pass -> noise gate -> EQ -> compressor -> fader/pan (ramped) -> meter.
/// Owned by the render thread; `ChannelControls` is the only shared state.
public struct ChannelStripDSP: Sendable {
    public let controls: ChannelControls
    private var ramp = GainRamp(initial: 1)
    private var panRampL = GainRamp(initial: 1)
    private var panRampR = GainRamp(initial: 1)
    private var compressor: Compressor
    private var gate: NoiseGate
    private var eq: ChannelEQ
    private var delay: StereoDelay
    private let sampleRate: Float
    public static let maxDelayMs: Float = 1000

    public init(controls: ChannelControls, sampleRate: Float) {
        self.controls = controls
        self.sampleRate = sampleRate
        self.delay = StereoDelay(capacity: Int(sampleRate * Self.maxDelayMs / 1000) + 1)
        self.compressor = Compressor(sampleRate: sampleRate)
        self.gate = NoiseGate(sampleRate: sampleRate)
        self.eq = ChannelEQ(sampleRate: Double(sampleRate))
    }

    /// Processes in place. Returns false when the channel is muted (buffers are zeroed).
    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        ChannelMode.apply(controls.mode, left: left, right: right, frames: frames)
        if controls.invertPhase.value { for i in 0..<frames { left[i] = -left[i]; right[i] = -right[i] } }
        let delaySamples = Int((min(max(controls.delayMs.value, 0), Self.maxDelayMs) / 1000 * sampleRate).rounded())
        delay.process(left: left, right: right, frames: frames, samples: delaySamples)
        let muted = controls.muted.value || controls.afvClosed.value
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
                compressor.attackSeconds = min(max(controls.compAttackMs.value, 0.1), 200) / 1000
                compressor.releaseSeconds = min(max(controls.compReleaseMs.value, 5), 2000) / 1000
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

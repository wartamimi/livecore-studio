#if os(macOS)
import AVFoundation
import AudioToolbox
import CoreAudio
import LiveCoreCore

/// One mixer input channel. Its ring buffers are filled by an `AudioCaptureInput` (capture
/// queue) and drained by the mixer's render callback (Core Audio IO thread).
public final class MixerChannel: @unchecked Sendable {
    public let id: String
    public var name: String
    public let controls = ChannelControls()
    /// Protected against being closed from the mixer (main thread; saved in projects).
    public var locked = false
    let ringL: SPSCFloatRingBuffer
    let ringR: SPSCFloatRingBuffer
    /// Jitter buffer: frames buffered before playback starts, and the most that may queue up
    /// before the excess is dropped back to 2 × `primeFrames` (bounds latency).
    let primeFrames: Int
    let maxBufferedFrames: Int
    // Render-thread-only state:
    var dsp: ChannelStripDSP
    var primed = false
    let drift: DriftCompensator
    let underruns = AtomicCounter()
    /// Measured clock offset of this input relative to the output clock (parts per million).
    public let driftPPM = AtomicFloat(0)
    public var underrunCount: UInt64 { underruns.value }

    init(id: String, name: String, sampleRate: Double, primeFrames: Int = 1024, maxBufferedFrames: Int = 4800) {
        self.id = id
        self.name = name
        self.primeFrames = primeFrames
        self.maxBufferedFrames = max(maxBufferedFrames, primeFrames * 2)
        ringL = SPSCFloatRingBuffer(minimumCapacity: Int(sampleRate))   // 1 s headroom
        ringR = SPSCFloatRingBuffer(minimumCapacity: Int(sampleRate))
        drift = DriftCompensator(targetFill: primeFrames + primeFrames / 2, maxFrames: AudioMixerEngine.maxFrames)
        dsp = ChannelStripDSP(controls: controls, sampleRate: Float(sampleRate))
    }

    /// A channel that is not part of any mixer (its audio goes nowhere). Used as a safe fallback.
    static func detached() -> MixerChannel { MixerChannel(id: "detached", name: "", sampleRate: 48_000) }
}

/// Audio mixer built on AVAudioEngine with a single AVAudioSourceNode that performs all
/// mixing in one real-time callback:
///
///   input rings -> per-channel DSP (trim, comp, fader, pan, meter)
///               -> Program bus -> master fader -> limiter -> meters -> program ring (encoders)
///               -> Monitor bus (solo or program) * monitor volume -> output device
///               -> Aux A / Aux B (post-fader sends) -> bus fader -> optional own output device
///
/// Format: 48 kHz, 2 ch, Float32, non-interleaved everywhere inside the mixer. The output
/// device may run at another rate; AVAudioEngine's mainMixer converts.
/// Real-time rules in the render block: no allocation, no locks that can block (only
/// `withTryLock`), no Objective-C messaging, no logging.
public final class AudioMixerEngine {
    public let sampleRate: Double = 48_000
    public static let maxFrames = 4096

    public let master = ChannelControls()
    public let monitorVolume = AtomicFloat(1)
    public let limiterEnabled = AtomicBool(true)
    /// Aux buses A and B: fader, mute and meters (same control block as a channel).
    public static let auxCount = 2
    public let aux: [ChannelControls] = (0..<AudioMixerEngine.auxCount).map { _ in ChannelControls() }
    /// Device each aux bus plays on (nil = none). Main thread.
    public private(set) var auxDeviceIDs: [AudioDeviceID?] = Array(repeating: nil, count: AudioMixerEngine.auxCount)
    /// Program audio for the encoders. Single consumer: `ProgramAudioPump`.
    public let programRingL: SPSCFloatRingBuffer
    public let programRingR: SPSCFloatRingBuffer
    /// Aux bus audio for the encoders (recording/stream fed from Bus A/B). Written in the same
    /// block as the program ring, all or nothing, so every encoder ring stays sample-aligned
    /// with the program ring and shares its clock anchor.
    public let auxEncodeRingsL: [SPSCFloatRingBuffer]
    public let auxEncodeRingsR: [SPSCFloatRingBuffer]
    public let anchor = ClockAnchor()
    public let programOverflows = AtomicCounter()
    /// Automatic ducking (music down while the MC speaks): settings and current reduction.
    public let ducking = DuckingControls()
    /// Program loudness (EBU R128, LUFS) measured after the limiter; -inf until there is audio.
    public let lufsMomentary = AtomicFloat(-.infinity)
    public let lufsShortTerm = AtomicFloat(-.infinity)
    public let lufsIntegrated = AtomicFloat(-.infinity)
    /// Incremented by the UI to restart the integrated measurement.
    public let loudnessResets = AtomicCounter()
    public private(set) var isRunning = false
    public var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private let graphLock = UnfairLock()
    private var channels: [MixerChannel] = []
    private var limiter: Limiter
    private var masterRamp = GainRamp(initial: 1)
    private var monitorRamp = GainRamp(initial: 1)
    private var configObserver: NSObjectProtocol?
    private var auxRamps = Array(repeating: GainRamp(initial: 1), count: AudioMixerEngine.auxCount)
    private let auxRingsL: [SPSCFloatRingBuffer]
    private let auxRingsR: [SPSCFloatRingBuffer]
    /// The render thread writes an aux ring only while an output consumes it.
    private let auxRingActive: [AtomicBool]
    private var auxOutputs: [AuxOutput?] = Array(repeating: nil, count: AudioMixerEngine.auxCount)
    // Render-thread-only state for ducking and loudness.
    private var ducker = Ducker()
    private var duckFrom: Float = 1
    private var duckTo: Float = 1
    private var duckNext: Float = 1
    private var triggerPeak: Float = 0
    private var loudness = LoudnessMeter()
    private var loudnessResetsSeen: UInt64 = 0

    // Pre-allocated scratch (render thread only)
    private let chL, chR, progL, progR, monL, monR: UnsafeMutablePointer<Float>
    private let auxL, auxR: [UnsafeMutablePointer<Float>]

    public init() {
        programRingL = SPSCFloatRingBuffer(minimumCapacity: 48_000 * 2)
        programRingR = SPSCFloatRingBuffer(minimumCapacity: 48_000 * 2)
        auxEncodeRingsL = (0..<Self.auxCount).map { _ in SPSCFloatRingBuffer(minimumCapacity: 48_000 * 2) }
        auxEncodeRingsR = (0..<Self.auxCount).map { _ in SPSCFloatRingBuffer(minimumCapacity: 48_000 * 2) }
        limiter = Limiter(sampleRate: 48_000)
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
            p.initialize(repeating: 0, count: Self.maxFrames)
            return p
        }
        chL = alloc(); chR = alloc(); progL = alloc(); progR = alloc(); monL = alloc(); monR = alloc()
        auxL = (0..<Self.auxCount).map { _ in alloc() }
        auxR = (0..<Self.auxCount).map { _ in alloc() }
        auxRingsL = (0..<Self.auxCount).map { _ in SPSCFloatRingBuffer(minimumCapacity: 48_000) }
        auxRingsR = (0..<Self.auxCount).map { _ in SPSCFloatRingBuffer(minimumCapacity: 48_000) }
        auxRingActive = (0..<Self.auxCount).map { _ in AtomicBool(false) }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        sourceNode = AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, abl in
            self.render(timestamp: timestamp, frames: Int(frameCount), output: abl)
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.prepare()

        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            // Output device changed/unplugged: AVAudioEngine stops itself; restart on the new default.
            Log.audio.info("audio engine configuration changed; restarting")
            self?.restart()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
        auxOutputs.forEach { $0?.stop() }
        ([chL, chR, progL, progR, monL, monR] + auxL + auxR).forEach { $0.deallocate() }
    }

    public func start() {
        do {
            try engine.start()
            isRunning = true
        } catch {
            isRunning = false
            onError?("Audio engine failed to start: \(error.localizedDescription)")
        }
    }

    public func stop() { engine.stop(); isRunning = false }

    private func restart() {
        engine.stop()
        engine.connect(sourceNode, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        start()
    }

    /// Routes the monitor output to a specific Core Audio device (nil = system default).
    public func setMonitorDevice(_ deviceID: AudioDeviceID?) {
        let wasRunning = isRunning
        engine.stop()
        if var dev = deviceID ?? AudioDevices.defaultOutputID(), let au = engine.outputNode.audioUnit {
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { onError?("Cannot select output device (OSStatus \(st))") }
        }
        if wasRunning { start() }
    }

    /// Plays aux bus `index` on an output device, or stops it (nil). Returns an error message.
    @discardableResult
    public func setAuxOutput(_ index: Int, deviceID: AudioDeviceID?) -> String? {
        guard auxDeviceIDs.indices.contains(index) else { return nil }
        auxRingActive[index].value = false
        auxOutputs[index]?.stop()
        auxOutputs[index] = nil
        auxDeviceIDs[index] = nil
        guard let deviceID else { return nil }
        do {
            // The new output flushes stale samples before it starts reading.
            auxOutputs[index] = try AuxOutput(deviceID: deviceID, ringL: auxRingsL[index], ringR: auxRingsR[index])
            auxDeviceIDs[index] = deviceID
            auxRingActive[index].value = true
            return nil
        } catch {
            return "Aux \(index == 0 ? "A" : "B"): \(error.localizedDescription)"
        }
    }

    /// Underruns of an aux output (its device asked for audio faster than the mixer produced it).
    public func auxUnderruns(_ index: Int) -> UInt64 { auxOutputs.indices.contains(index) ? auxOutputs[index]?.underruns.value ?? 0 : 0 }

    /// Adds a channel. Live devices use the default ~21 ms jitter buffer; sources that deliver
    /// audio in large bursts (AVPlayer taps hand over up to ~90 ms at once) pass larger values.
    public func addChannel(id: String, name: String, primeFrames: Int = 1024, maxBufferedFrames: Int = 4800) -> MixerChannel {
        let ch = MixerChannel(id: id, name: name, sampleRate: sampleRate, primeFrames: primeFrames, maxBufferedFrames: maxBufferedFrames)
        graphLock.withLock { channels.append(ch) }
        return ch
    }

    public func removeChannel(id: String) {
        graphLock.withLock { channels.removeAll { $0.id == id } }
    }

    public var channelList: [MixerChannel] { graphLock.withLock { channels } }

    // MARK: Real-time render (Core Audio IO thread)

    private func render(timestamp: UnsafePointer<AudioTimeStamp>, frames: Int, output: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let out = UnsafeMutableAudioBufferListPointer(output)
        guard frames <= Self.maxFrames, out.count >= 2,
              let outL = out[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = out[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

        progL.update(repeating: 0, count: frames); progR.update(repeating: 0, count: frames)
        monL.update(repeating: 0, count: frames); monR.update(repeating: 0, count: frames)
        for b in 0..<Self.auxCount { auxL[b].update(repeating: 0, count: frames); auxR[b].update(repeating: 0, count: frames) }

        // Host time of this block's first sample: prefer the timestamp's host time.
        let ts = timestamp.pointee
        let host = ts.mFlags.contains(.hostTimeValid) ? HostClock.seconds(fromHostTicks: ts.mHostTime) : HostClock.now()

        // Channel list is only mutated under graphLock by the main thread. If we lose the race
        // (rare: add/remove in progress) this block is rendered silent instead of blocking.
        soloFlag = false
        duckFrom = duckTo
        duckTo = duckNext
        triggerPeak = 0
        _ = graphLock.withTryLock { () -> Bool in
            for ch in channels { mixChannel(ch, frames: frames) }
            return true
        }
        let soloActive = soloFlag
        let duckDB = ducker.step(triggerPeakDB: AudioMath.linearToDB(triggerPeak), seconds: Float(frames) / Float(sampleRate),
                                 settings: ducking.settings)
        duckNext = AudioMath.dbToLinear(duckDB)
        ducking.reductionDB.value = duckDB

        // Master fader + protective limiter on the program bus.
        let masterGain = master.muted.value ? 0 : AudioMath.dbToLinear(master.faderDB.value)
        masterRamp.apply(target: masterGain, left: progL, right: progR, frames: frames)
        if limiterEnabled.value { limiter.process(left: progL, right: progR, frames: frames) }
        master.peakL.storeMax(AudioMath.peak(progL, count: frames))
        master.peakR.storeMax(AudioMath.peak(progR, count: frames))
        master.gainReductionDB.value = limiterEnabled.value ? limiter.gainReductionDB : 0
        let resets = loudnessResets.value
        if resets != loudnessResetsSeen { loudnessResetsSeen = resets; loudness.reset() }
        loudness.process(left: progL, right: progR, frames: frames)
        lufsMomentary.value = Float(loudness.momentary)
        lufsShortTerm.value = Float(loudness.shortTerm)
        lufsIntegrated.value = Float(loudness.integrated)

        // Aux buses: fader/mute, meters, and the ring of the bus's own output device.
        for b in 0..<Self.auxCount {
            let c = aux[b]
            auxRamps[b].apply(target: c.muted.value ? 0 : AudioMath.dbToLinear(c.faderDB.value), left: auxL[b], right: auxR[b], frames: frames)
            c.peakL.storeMax(AudioMath.peak(auxL[b], count: frames))
            c.peakR.storeMax(AudioMath.peak(auxR[b], count: frames))
            if auxRingActive[b].value {
                _ = auxRingsL[b].write(auxL[b], count: frames)
                _ = auxRingsR[b].write(auxR[b], count: frames)
            }
        }

        // Encoder rings (program + aux buses) for the stream/recorder.
        // Anchor = ring write position of this block's first sample (the consumer timestamps
        // by ring read position, so dropped samples on overflow never skew the mapping).
        // Written all or nothing so the buses stay aligned sample for sample.
        var room = min(programRingL.availableToWrite, programRingR.availableToWrite)
        for b in 0..<Self.auxCount { room = min(room, auxEncodeRingsL[b].availableToWrite, auxEncodeRingsR[b].availableToWrite) }
        if room >= frames {
            anchor.publish(sampleIndex: programRingL.totalWritten, hostSeconds: host)
            _ = programRingL.write(progL, count: frames)
            _ = programRingR.write(progR, count: frames)
            for b in 0..<Self.auxCount {
                _ = auxEncodeRingsL[b].write(auxL[b], count: frames)
                _ = auxEncodeRingsR[b].write(auxR[b], count: frames)
            }
        } else {
            programOverflows.add()
        }

        // Monitor output.
        let srcL = soloActive ? monL : progL
        let srcR = soloActive ? monR : progR
        outL.update(from: srcL, count: frames)
        outR.update(from: srcR, count: frames)
        monitorRamp.apply(target: monitorVolume.value, left: outL, right: outR, frames: frames)
        return noErr
    }

    private var soloFlag = false

    @inline(__always)
    private func mixChannel(_ ch: MixerChannel, frames: Int) {
        // Jitter buffer: wait for `primeFrames` before the first read; bound latency at `maxBufferedFrames`.
        // Drift correction then keeps the fill near 1.5 × primeFrames by resampling ±0.5 %.
        let avail = min(ch.ringL.availableToRead, ch.ringR.availableToRead)
        if !ch.primed {
            if avail >= ch.primeFrames { ch.primed = true; ch.drift.reset() } else { return }
        }
        if avail > ch.maxBufferedFrames {
            // Safety net only (e.g. a stalled render thread); drift correction normally prevents it.
            let excess = avail - ch.primeFrames * 2
            ch.ringL.skip(excess); ch.ringR.skip(excess)
        }
        if !ch.drift.render(ringL: ch.ringL, ringR: ch.ringR, outL: chL, outR: chR, frames: frames) {
            ch.underruns.add()
            ch.primed = false
        }
        ch.driftPPM.value = Float((ch.drift.ratio - 1) * 1_000_000)
        ch.dsp.process(left: chL, right: chR, frames: frames)
        if ch.controls.duckTrigger.value {
            triggerPeak = max(triggerPeak, AudioMath.peak(chL, count: frames), AudioMath.peak(chR, count: frames))
        }
        if ch.controls.duckTarget.value, duckFrom != 1 || duckTo != 1 {
            // Ramp across the block from the previous gain to this block's gain (no zipper noise).
            let step = (duckTo - duckFrom) / Float(frames)
            var g = duckFrom
            for i in 0..<frames { g += step; chL[i] *= g; chR[i] *= g }
        }
        if ch.controls.toProgram.value {
            for i in 0..<frames { progL[i] += chL[i]; progR[i] += chR[i] }
        }
        if ch.controls.toBusA.value { let l = auxL[0], r = auxR[0]; for i in 0..<frames { l[i] += chL[i]; r[i] += chR[i] } }
        if ch.controls.toBusB.value { let l = auxL[1], r = auxR[1]; for i in 0..<frames { l[i] += chL[i]; r[i] += chR[i] } }
        if ch.controls.solo.value {
            soloFlag = true
            for i in 0..<frames { monL[i] += chL[i]; monR[i] += chR[i] }
        }
    }
}
#endif

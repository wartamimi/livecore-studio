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
    let ringL: SPSCFloatRingBuffer
    let ringR: SPSCFloatRingBuffer
    /// Jitter buffer: frames buffered before playback starts, and the most that may queue up
    /// before the excess is dropped back to 2 × `primeFrames` (bounds latency).
    let primeFrames: Int
    let maxBufferedFrames: Int
    // Render-thread-only state:
    var dsp: ChannelStripDSP
    var primed = false
    let underruns = AtomicCounter()

    init(id: String, name: String, sampleRate: Double, primeFrames: Int = 1024, maxBufferedFrames: Int = 4800) {
        self.id = id
        self.name = name
        self.primeFrames = primeFrames
        self.maxBufferedFrames = max(maxBufferedFrames, primeFrames * 2)
        ringL = SPSCFloatRingBuffer(minimumCapacity: Int(sampleRate))   // 1 s headroom
        ringR = SPSCFloatRingBuffer(minimumCapacity: Int(sampleRate))
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
    /// Program audio for the encoders. Single consumer: `ProgramAudioPump`.
    public let programRingL: SPSCFloatRingBuffer
    public let programRingR: SPSCFloatRingBuffer
    public let anchor = ClockAnchor()
    public let programOverflows = AtomicCounter()
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

    // Pre-allocated scratch (render thread only)
    private let chL, chR, progL, progR, monL, monR: UnsafeMutablePointer<Float>

    public init() {
        programRingL = SPSCFloatRingBuffer(minimumCapacity: 48_000 * 2)
        programRingR = SPSCFloatRingBuffer(minimumCapacity: 48_000 * 2)
        limiter = Limiter(sampleRate: 48_000)
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
            p.initialize(repeating: 0, count: Self.maxFrames)
            return p
        }
        chL = alloc(); chR = alloc(); progL = alloc(); progR = alloc(); monL = alloc(); monR = alloc()

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
        [chL, chR, progL, progR, monL, monR].forEach { $0.deallocate() }
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

        // Host time of this block's first sample: prefer the timestamp's host time.
        let ts = timestamp.pointee
        let host = ts.mFlags.contains(.hostTimeValid) ? HostClock.seconds(fromHostTicks: ts.mHostTime) : HostClock.now()

        // Channel list is only mutated under graphLock by the main thread. If we lose the race
        // (rare: add/remove in progress) this block is rendered silent instead of blocking.
        soloFlag = false
        _ = graphLock.withTryLock { () -> Bool in
            for ch in channels { mixChannel(ch, frames: frames) }
            return true
        }
        let soloActive = soloFlag

        // Master fader + protective limiter on the program bus.
        let masterGain = master.muted.value ? 0 : AudioMath.dbToLinear(master.faderDB.value)
        masterRamp.apply(target: masterGain, left: progL, right: progR, frames: frames)
        if limiterEnabled.value { limiter.process(left: progL, right: progR, frames: frames) }
        master.peakL.storeMax(AudioMath.peak(progL, count: frames))
        master.peakR.storeMax(AudioMath.peak(progR, count: frames))
        master.gainReductionDB.value = limiterEnabled.value ? limiter.gainReductionDB : 0

        // Program ring for encoders/recorder.
        // Anchor = ring write position of this block's first sample (the consumer timestamps
        // by ring read position, so dropped samples on overflow never skew the mapping).
        anchor.publish(sampleIndex: programRingL.totalWritten, hostSeconds: host)
        let wl = programRingL.write(progL, count: frames)
        let wr = programRingR.write(progR, count: frames)
        if wl < frames || wr < frames { programOverflows.add() }

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
        let avail = min(ch.ringL.availableToRead, ch.ringR.availableToRead)
        if !ch.primed {
            if avail >= ch.primeFrames { ch.primed = true } else { return }
        }
        if avail > ch.maxBufferedFrames {
            let excess = avail - ch.primeFrames * 2
            ch.ringL.skip(excess); ch.ringR.skip(excess)
        }
        let nl = ch.ringL.read(into: chL, count: frames)
        let nr = ch.ringR.read(into: chR, count: frames)
        let n = min(nl, nr)
        if n < frames {
            (chL + nl).update(repeating: 0, count: frames - nl)
            (chR + nr).update(repeating: 0, count: frames - nr)
            ch.underruns.add()
            ch.primed = false
        }
        ch.dsp.process(left: chL, right: chR, frames: frames)
        if ch.controls.toProgram.value {
            for i in 0..<frames { progL[i] += chL[i]; progR[i] += chR[i] }
        }
        if ch.controls.solo.value {
            soloFlag = true
            for i in 0..<frames { monL[i] += chL[i]; monR[i] += chR[i] }
        }
    }
}
#endif

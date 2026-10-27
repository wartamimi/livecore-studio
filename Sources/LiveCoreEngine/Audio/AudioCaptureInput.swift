#if os(macOS)
import AVFoundation
import CoreMedia
import LiveCoreCore

/// Captures one macOS audio input device (built-in mic, USB interface, camera/capture-card
/// audio, virtual devices...) with AVCaptureAudioDataOutput, which converts to our mixer
/// format (48 kHz Float32 non-interleaved stereo) before delivering buffers. Samples are
/// pushed into the channel's lock-free rings on the capture queue.
public final class AudioCaptureInput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    public let deviceUniqueID: String
    public let channel: MixerChannel
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { let s = status; DispatchQueue.main.async { self.onStatusChange?(s) } } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue: DispatchQueue
    private var ablStorage: UnsafeMutableRawPointer?
    private var ablCapacity = 0
    private var interleaveScratch: [Float] = []
    private var observers: [NSObjectProtocol] = []

    public init(device: AVCaptureDevice, channel: MixerChannel) {
        self.deviceUniqueID = device.uniqueID
        self.channel = channel
        self.queue = DispatchQueue(label: "livecore.audio-in.\(device.uniqueID)", qos: .userInteractive)
        super.init()
    }

    deinit { ablStorage?.deallocate() }

    public func start() { queue.async { [weak self] in self?.configureAndRun() } }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.observers.forEach { NotificationCenter.default.removeObserver($0) }
            self.observers.removeAll()
        }
    }

    private func configureAndRun() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            status = .error("Microphone permission not granted. Enable it in System Settings › Privacy & Security › Microphone.")
            return
        }
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else { status = .noSignal("device not connected"); return }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw NSError(domain: "LiveCore", code: 2) }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            status = .error("Cannot open audio device: \(error.localizedDescription)")
            return
        }
        if session.outputs.isEmpty {
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
                AVLinearPCMIsBigEndianKey: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()
        if observers.isEmpty {
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil) { [weak self] _ in
                self?.status = .noSignal("device disconnected")
            })
            observers.append(nc.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil) { [weak self] n in
                guard let self, let d = n.object as? AVCaptureDevice, d.uniqueID == self.deviceUniqueID else { return }
                self.queue.async { if self.session.isRunning { self.session.stopRunning() }; self.configureAndRun() }
            })
        }
        session.startRunning()
        status = session.isRunning ? .live : .error("Audio capture failed to start")
    }

    // MARK: Delegate (capture queue)

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else {
            if status.isHealthy { status = .error("Unexpected capture format") }
            return
        }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil,
                                                                bufferListSize: 0, blockBufferAllocator: nil,
                                                                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        if needed > ablCapacity {
            ablStorage?.deallocate()
            ablStorage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
            ablCapacity = needed
        }
        guard let raw = ablStorage else { return }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: ablCapacity,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard st == noErr else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        if nonInterleaved {
            guard let l = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let r = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) ?? l : l
            channel.ringL.write(l, count: frames)
            channel.ringR.write(r, count: frames)
        } else {
            // Interleaved fallback (some drivers ignore the requested layout).
            guard let p = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = Int(max(asbd.mChannelsPerFrame, 1))
            if interleaveScratch.count < frames * 2 { interleaveScratch = [Float](repeating: 0, count: frames * 2) }
            interleaveScratch.withUnsafeMutableBufferPointer { s in
                let l = s.baseAddress!, r = s.baseAddress! + frames
                for i in 0..<frames { l[i] = p[i * ch]; r[i] = p[i * ch + (ch > 1 ? 1 : 0)] }
                channel.ringL.write(l, count: frames)
                channel.ringR.write(r, count: frames)
            }
        }
        if !status.isHealthy { status = .live }
    }
}

/// Drains the mixer's program ring in 1024-frame chunks (one AAC frame) on its own queue and
/// fans the PCM out to the stream encoder and the recorder, stamped with host time.
public final class ProgramAudioPump {
    public struct Chunk {
        public var left: [Float]
        public var right: [Float]
        public var hostTime: Double      // host time of the first sample
        /// Aux bus A/B audio for the same samples.
        public var auxLeft: [[Float]] = []
        public var auxRight: [[Float]] = []
        public var frames: Int { left.count }

        /// The same chunk carrying the chosen bus in `left`/`right`.
        public func bus(_ bus: OutputBus) -> Chunk {
            guard let i = bus.auxIndex, auxLeft.indices.contains(i), auxRight.indices.contains(i) else { return self }
            return Chunk(left: auxLeft[i], right: auxRight[i], hostTime: hostTime)
        }
    }

    public static let chunkFrames = 1024
    private let mixer: AudioMixerEngine
    private let queue = DispatchQueue(label: "livecore.audio-pump", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var sinks: [String: (Chunk) -> Void] = [:]
    private let sinksLock = UnfairLock()
    /// Positive values delay audio relative to video (compensates capture latency differences).
    public let syncOffsetSeconds = AtomicFloat(0)

    public init(mixer: AudioMixerEngine) { self.mixer = mixer }

    public func addSink(_ key: String, _ sink: @escaping (Chunk) -> Void) {
        sinksLock.withLock { sinks[key] = sink }
        startIfNeeded()
    }

    public func removeSink(_ key: String) {
        let empty = sinksLock.withLock { () -> Bool in sinks[key] = nil; return sinks.isEmpty }
        if empty { stop() }
    }

    private func startIfNeeded() {
        guard timer == nil else { return }
        // Discard anything buffered while no output was running so timestamps start "now".
        let stale = available()
        for r in rings { r.skip(stale) }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    /// Program and aux encoder rings, read in lockstep (the mixer writes them all or nothing).
    private var rings: [SPSCFloatRingBuffer] {
        [mixer.programRingL, mixer.programRingR] + mixer.auxEncodeRingsL + mixer.auxEncodeRingsR
    }

    private func available() -> Int { rings.map(\.availableToRead).min() ?? 0 }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    private func drain() {
        let n = Self.chunkFrames
        while available() >= n {
            let index = mixer.programRingL.totalRead
            func take(_ ring: SPSCFloatRingBuffer) -> [Float] {
                var a = [Float](repeating: 0, count: n)
                a.withUnsafeMutableBufferPointer { _ = ring.read(into: $0.baseAddress!, count: n) }
                return a
            }
            let l = take(mixer.programRingL), r = take(mixer.programRingR)
            let al = mixer.auxEncodeRingsL.map(take), ar = mixer.auxEncodeRingsR.map(take)
            guard let host = mixer.anchor.hostTime(ofSample: index, sampleRate: mixer.sampleRate) else { continue }
            let chunk = Chunk(left: l, right: r, hostTime: host + Double(syncOffsetSeconds.value), auxLeft: al, auxRight: ar)
            let current = sinksLock.withLock { Array(sinks.values) }
            for s in current { s(chunk) }
        }
    }
}
#endif

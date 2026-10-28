#if os(macOS)
import CNDI
import CoreVideo
import Foundation
import LiveCoreCore

/// Lists the NDI® sources on the network (and on this Mac) while something is watching.
/// The NDI finder runs on its own thread; the list is delivered on the main thread.
public final class NDIFinder: @unchecked Sendable {
    private let running = AtomicBool()
    private var thread: Thread?

    public init() {}

    /// Starts watching; `onChange` gets the full list whenever it changes (main thread).
    public func start(onChange: @escaping ([String]) -> Void) {
        guard !running.value, NDIRuntime.isAvailable else { return }
        running.value = true
        let running = self.running
        let t = Thread {
            guard let finder = lc_ndi_finder_create() else { return }
            defer { lc_ndi_finder_destroy(finder) }
            var last: [String]? = nil
            var buf = [CChar](repeating: 0, count: 16_384)
            while running.value {
                _ = lc_ndi_finder_sources(finder, &buf, Int32(buf.count), 1000)
                let list = String(cString: buf).split(separator: "\n").map(String.init).sorted()
                if list != last {
                    last = list
                    DispatchQueue.main.async { onChange(list) }
                }
            }
        }
        t.name = "livecore.ndi.finder"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    public func stop() { running.value = false; thread = nil }
    deinit { running.value = false }
}

/// An NDI® source received as an input: video frames copied into BGRA buffers (BGRA sources
/// keep their straight alpha), audio on its own mixer channel at 48 kHz. Receiving runs on a
/// dedicated thread; a lost sender is reconnected by NDI itself when it comes back.
public final class NDISource: VideoSource, @unchecked Sendable {
    public let id: InputID
    public let kind: InputKind = .ndi
    public var name: String
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    /// Called on the main thread when audio is wanted; must return the mixer channel to feed.
    public var audioChannelProvider: (() -> MixerChannel)?

    public private(set) var config: ProjectNDI
    private let slot = FrameSlot()
    private var running: AtomicBool?
    private var audioChannel: MixerChannel?

    /// Picture size and frame rate the sender delivers, for the input settings.
    public struct Signal: Equatable, Sendable {
        public var width = 0, height = 0
        public var fps: Double = 0
        public var audioRate = 0, audioChannels = 0
        public var alpha = false
    }
    public var signal: Signal { signalLock.withLock { _signal } }
    private var _signal = Signal()
    private let signalLock = UnfairLock()

    public init(id: InputID, config: ProjectNDI) {
        self.id = id
        self.config = config
        self.name = config.displayName
    }

    public func currentFrame() -> CVPixelBuffer? { slot.get() }

    /// Main thread.
    public func start() {
        guard running == nil else { return }
        guard NDIRuntime.isAvailable else {
            status = .error("NDI runtime not installed (NDI Tools: \(NDIRuntime.downloadURL.absoluteString))")
            return
        }
        if config.wantsAudio, audioChannel == nil, let provider = audioChannelProvider { audioChannel = provider() }
        let flag = AtomicBool(true)
        running = flag
        status = .starting
        let cfg = config
        let channel = config.wantsAudio ? audioChannel : nil
        let t = Thread { [weak self] in self?.receive(cfg, channel: channel, running: flag) }
        t.name = "livecore.ndi.recv"
        t.qualityOfService = .userInteractive
        t.start()
    }

    public func stop() {
        running?.value = false
        running = nil
    }

    /// Another source or quality (main thread): reconnects.
    public func reconfigure(_ c: ProjectNDI) {
        stop()
        config = c
        slot.clear()
        start()
    }

    private func setStatus(_ s: SourceStatus) {
        DispatchQueue.main.async { [weak self] in self?.status = s }
    }

    // MARK: Receive thread

    private func receive(_ cfg: ProjectNDI, channel: MixerChannel?, running: AtomicBool) {
        let receiverName = "LiveCore Studio (\(cfg.displayName))"
        guard let rx = lc_ndi_input_create(cfg.sourceName, receiverName, cfg.wantsLowBandwidth) else {
            setStatus(.error("NDI receiver could not be created"))
            return
        }
        defer { lc_ndi_receiver_destroy(rx) }
        var pool: CVPixelBufferPool?
        var poolSize = (0, 0)
        var resampler: LinearResampler?
        var resampleRate = 0
        var outL = [Float](), outR = [Float]()
        var lastVideo = HostClock.now()
        var reported: SourceStatus = .starting
        var windowStart = HostClock.now(), windowFrames = 0
        func report(_ s: SourceStatus) { if s != reported { reported = s; setStatus(s) } }

        while running.value {
            var v = lc_ndi_video()
            var a = lc_ndi_audio()
            let type = lc_ndi_capture(rx, 100, &v, &a)
            let now = HostClock.now()
            if type == 1 {
                let w = Int(v.width), h = Int(v.height)
                if pool == nil || poolSize != (w, h) {
                    pool = PixelBufferFactory.makePool(width: w, height: h)
                    poolSize = (w, h)
                }
                var out: CVPixelBuffer?
                if let pool { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) }
                if let pb = out {
                    CVPixelBufferLockBaseAddress(pb, [])
                    if let dst = CVPixelBufferGetBaseAddress(pb) {
                        lc_ndi_copy_video(&v, dst.assumingMemoryBound(to: UInt8.self), Int32(CVPixelBufferGetBytesPerRow(pb)))
                    }
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    // NDI alpha is straight (not premultiplied); the compositor premultiplies it.
                    CVBufferSetAttachment(pb, kCVImageBufferAlphaChannelModeKey,
                                          (v.has_alpha ? kCVImageBufferAlphaChannelMode_StraightAlpha
                                                       : kCVImageBufferAlphaChannelMode_PremultipliedAlpha) as CFString,
                                          .shouldPropagate)
                    slot.put(pb)
                }
                lc_ndi_release_video(rx)
                lastVideo = now
                windowFrames += 1
                if now - windowStart >= 1 {
                    let fps = Double(windowFrames) / (now - windowStart)
                    let alpha = v.has_alpha
                    signalLock.withLock { _signal.width = w; _signal.height = h; _signal.fps = fps; _signal.alpha = alpha }
                    windowStart = now; windowFrames = 0
                }
                report(.live)
            } else if type == 2 {
                if let channel, a.samples > 0, a.channels > 0, let data = a.data {
                    let n = Int(a.samples), stride = Int(a.channel_stride) / MemoryLayout<Float>.stride
                    let left = data
                    let right = a.channels > 1 ? data + stride : data
                    let rate = Int(a.sample_rate)
                    if rate == 48_000 {
                        channel.ringL.write(left, count: n)
                        channel.ringR.write(right, count: n)
                    } else if rate > 0 {
                        if resampler == nil || resampleRate != rate {
                            resampler = LinearResampler(inputRate: Double(rate), outputRate: 48_000)
                            resampleRate = rate
                        }
                        let cap = resampler!.maxOutputFrames(forInput: n)
                        if outL.count < cap { outL = [Float](repeating: 0, count: cap); outR = outL }
                        let got = outL.withUnsafeMutableBufferPointer { l in
                            outR.withUnsafeMutableBufferPointer { r in
                                resampler!.process(inLeft: left, inRight: right, inputFrames: n,
                                                   outLeft: l.baseAddress!, outRight: r.baseAddress!, outputCapacity: cap)
                            }
                        }
                        outL.withUnsafeBufferPointer { channel.ringL.write($0.baseAddress!, count: got) }
                        outR.withUnsafeBufferPointer { channel.ringR.write($0.baseAddress!, count: got) }
                    }
                    let chans = Int(a.channels)
                    signalLock.withLock { _signal.audioRate = rate; _signal.audioChannels = chans }
                }
                lc_ndi_release_audio(rx)
            } else if type < 0 {
                report(.noSignal("NDI connection lost, waiting for \"\(cfg.sourceName)\""))
            }
            if now - lastVideo > 2 {
                report(lc_ndi_receiver_connections(rx) > 0 ? .noSignal("connected, no video from the sender")
                                                          : .noSignal("waiting for \"\(cfg.sourceName)\""))
            }
        }
    }
}
#endif

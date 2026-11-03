#if os(macOS)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import LiveCoreCore
import VideoToolbox

/// SRT input (0.54.0): MPEG-TS over SRT from an encoder, received by LiveCore's own SRT stack
/// (`SRTInputLink`), demuxed, decoded with VideoToolbox (H.264 / HEVC, hardware where the Mac has
/// it) and AVAudioConverter (AAC → 48 kHz float), shown in presentation-time order. Audio goes
/// to its own mixer channel "srt:<input>".
public final class SRTSource: VideoSource, @unchecked Sendable {
    public let id: InputID
    public let kind: InputKind = .srt
    public var name: String
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    /// Called on the main thread when audio is wanted; must return the mixer channel to feed.
    public var audioChannelProvider: (() -> MixerChannel)?

    public private(set) var config: ProjectSRTInput
    private let slot = FrameSlot()
    private var link: SRTInputLink?
    private var audioChannel: MixerChannel?

    /// What arrives, for the input settings.
    public struct Signal: Equatable, Sendable {
        public var width = 0, height = 0
        public var fps: Double = 0
        public var videoCodec = ""
        public var audio = ""
        public var kbps = 0
        public var peer = ""
        public var streamID = ""
        public var srt = SRTReceiver.Stats()
        public var decodeErrors = 0
        /// Last decoder error (OSStatus) and frames the decoder skipped on purpose.
        public var lastDecodeError: Int32 = 0
        public var decoderDropped = 0
        /// "hardware" or "software" decoder, and the first failed picture (NAL types, frame number in the GOP).
        public var decoder = ""
        public var firstDecodeFailure = ""
        /// Pictures the decoder returned; TS continuity errors and damaged access units seen.
        public var decoded = 0
        public var continuityErrors = 0, damagedUnits = 0
        /// Totals since the input started: pictures shown, audio frames decoded.
        public var frames = 0, audioFrames = 0
    }
    public var signal: Signal {
        var s = signalLock.withLock { _signal }
        if let l = link { s.srt = l.stats; s.peer = l.peer; if s.streamID.isEmpty { s.streamID = l.stats.peerStreamID } }
        return s
    }
    private var _signal = Signal()
    private let signalLock = UnfairLock()

    public init(id: InputID, config: ProjectSRTInput) {
        self.id = id
        self.config = config
        self.name = config.displayName
    }

    public func currentFrame() -> CVPixelBuffer? { slot.get() }

    /// Main thread.
    public func start() {
        guard link == nil else { return }
        if let p = config.problem {
            status = .error(p == .badPort ? "The SRT port must be 1–65535" : "Enter the address of the SRT sender")
            return
        }
        if config.wantsAudio, audioChannel == nil, let provider = audioChannelProvider { audioChannel = provider() }
        let c = config
        let l = SRTInputLink(config: .init(role: c.mode == .listener ? .listener : .caller, host: c.host, port: c.port,
                                           latencyMs: c.clampedLatency, streamID: c.streamID))
        let pipeline = SRTDecodePipeline(slot: slot, channel: c.wantsAudio ? audioChannel : nil) { [weak self] update in
            guard let self else { return }
            self.signalLock.withLock { update(&self._signal) }
        }
        // Decoding runs on its own queue so the network thread always drains the socket: a decoder
        // stall (session set-up, a slow software decoder) must not overflow the UDP buffer.
        let queue = DispatchQueue(label: "livecore.srt-input.decode", qos: .userInteractive)
        l.onPayload = { p in queue.async { pipeline.feed(p) } }
        l.onTick = { now in queue.async { pipeline.tick(now: now) } }
        l.onEvent = { [weak self] e in
            switch e {
            case let .waiting(s): self?.setStatus(.noSignal(s))
            case .connected: self?.setStatus(.noSignal("connected, waiting for video"))
            case let .disconnected(s): queue.async { pipeline.reset() }; self?.setStatus(.noSignal(s))
            case let .failed(s): self?.setStatus(.error(s))
            }
        }
        pipeline.onLive = { [weak self] in self?.setStatus(.live) }
        link = l
        status = .starting
        l.start()
    }

    public func stop() {
        link?.stop()
        link = nil
    }

    /// New settings (main thread): reconnects.
    public func reconfigure(_ c: ProjectSRTInput) {
        stop()
        config = c
        slot.clear()
        signalLock.withLock { _signal = Signal() }
        start()
    }

    /// Decodes a whole MPEG-TS recording through the same pipeline, without the network (checks).
    public static func decodeCheck(_ ts: [UInt8]) -> (decoded: Int, errors: Int, firstFailure: String) {
        let p = SRTDecodePipeline(slot: FrameSlot(), channel: nil) { _ in }
        var o = 0
        while o < ts.count {
            let k = min(1316, ts.count - o)
            p.feed(ts[o..<(o + k)])
            o += k
        }
        return (p.decoded, p.decodeErrors, p.firstFailure)
    }

    private func setStatus(_ s: SourceStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.link != nil else { return }
            self.status = s
        }
    }
}

/// Demux → decode → present, all on one serial decode queue.
final class SRTDecodePipeline: @unchecked Sendable {
    private let demux = MPEGTSDemuxer()
    private let slot: FrameSlot
    private let channel: MixerChannel?
    private let report: (( inout SRTSource.Signal) -> Void) -> Void
    var onLive: (() -> Void)?

    // Video.
    private var codec: MPEGTSDemuxer.Codec?
    private var paramSets: [[UInt8]] = []
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var haveKeyframe = false
    private var queue: [(pts: Int64, pb: CVPixelBuffer)] = []
    private var refPTS: Int64?
    private var refTime = 0.0
    private var lastArrival = 0.0
    private var live = false
    private(set) var decodeErrors = 0
    private(set) var decoded = 0
    private var damagedUnits = 0
    private(set) var lastDecodeError: OSStatus = 0
    private var decoderDropped = 0
    private var consecutiveErrors = 0
    private var usingHardware = false
    private(set) var firstFailure = ""
    private var sinceKeyframe = 0
    // Rates.
    private var windowStart = 0.0, windowFrames = 0, windowBytes = 0
    private var totalFrames = 0, totalAudio = 0
    private var size = (0, 0)

    // Audio.
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var outFormat: AVAudioFormat?
    private var audioKey = (0, 0, 0)

    /// Video is shown this long after it arrives (audio passes the mixer's own buffer).
    static let presentationDelay = 0.045

    init(slot: FrameSlot, channel: MixerChannel?, report: @escaping ((inout SRTSource.Signal) -> Void) -> Void) {
        self.slot = slot
        self.channel = channel
        self.report = report
    }

    deinit {
        if let s = session { VTDecompressionSessionInvalidate(s) }
    }

    func reset() {
        queue.removeAll()
        refPTS = nil
        haveKeyframe = false
        live = false
    }

    func feed(_ payload: ArraySlice<UInt8>) {
        let now = SRTInputLink.now()
        windowBytes += payload.count
        for au in demux.feed(payload) {
            if au.codec.isVideo { video(au, now: now) } else if au.codec == .aac { audio(au) }
        }
    }

    func tick(now: Double) {
        present(now: now)
        if now - windowStart >= 1 {
            let fps = Double(windowFrames) / max(0.001, now - windowStart)
            let kbps = Int(Double(windowBytes) * 8 / 1000 / max(0.001, now - windowStart))
            let (w, h) = size
            let vc = demux.videoCodec?.name ?? ""
            let errs = decodeErrors, frames = totalFrames, audioFrames = totalAudio
            let lastErr = lastDecodeError, dropped = decoderDropped
            let okCount = decoded, cc = demux.continuityErrors, dmg = damagedUnits
            let dec = session == nil ? "" : (usingHardware ? "hardware" : "software"), ff = firstFailure
            report { s in
                s.fps = fps; s.kbps = kbps; s.width = w; s.height = h; s.videoCodec = vc; s.decodeErrors = errs
                s.lastDecodeError = lastErr; s.decoderDropped = dropped; s.decoder = dec; s.firstDecodeFailure = ff
                s.decoded = okCount; s.continuityErrors = cc; s.damagedUnits = dmg
                s.frames = frames; s.audioFrames = audioFrames
            }
            windowStart = now; windowFrames = 0; windowBytes = 0
        }
        // The sender went quiet: drop the picture after 2 s so the input shows "no signal".
        if live, now - lastArrival > 2 {
            live = false
        }
    }

    // MARK: Video

    private func video(_ au: MPEGTSDemuxer.AccessUnit, now: Double) {
        lastArrival = now
        if au.damaged { damagedUnits += 1 }
        let nals = AVC.splitAnnexB(au.data)
        guard !nals.isEmpty else { return }
        let hevc = au.codec == .hevc
        var sets: [[UInt8]] = []
        var slices: [ArraySlice<UInt8>] = []
        var keyframe = false
        for n in nals {
            guard let first = n.first else { continue }
            if hevc {
                let t = HEVC.nalType(first)
                if t == HEVC.vps || t == HEVC.sps || t == HEVC.pps { sets.append(Array(n)); continue }
                if t == 35 || t == 39 || t == 40 { continue }          // AUD, SEI
                if HEVC.isKeyframe(t) { keyframe = true }
                slices.append(n)
            } else {
                let t = AVC.nalType(first)
                if t == 7 || t == 8 { sets.append(Array(n)); continue }
                if t == 9 || t == 6 { continue }                         // AUD, SEI
                if t == 5 { keyframe = true }
                slices.append(n)
            }
        }
        if !sets.isEmpty, sets != paramSets || codec != au.codec {
            if makeSession(sets: sets, hevc: hevc) { paramSets = sets; codec = au.codec }
        }
        guard let session, let format, !slices.isEmpty else { return }
        if !haveKeyframe { guard keyframe else { return }; haveKeyframe = true }
        sinceKeyframe = keyframe ? 0 : sinceKeyframe + 1
        let types = slices.map { hevc ? Int(HEVC.nalType($0.first!)) : Int(AVC.nalType($0.first!)) }
        let frameNo = sinceKeyframe
        guard let sample = Self.sampleBuffer(slices, format: format, pts: au.pts ?? 0, dts: au.dts ?? au.pts ?? 0) else { return }
        let pts = au.pts ?? 0
        let dts = au.dts ?? pts
        var flags = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: &flags) { [weak self] status, info, image, _, _ in
            guard let self else { return }
            if info.contains(.frameDropped) { self.decoderDropped += 1; return }
            if status != noErr || image == nil {
                self.decodeErrors += 1; self.lastDecodeError = status; self.consecutiveErrors += 1
                if self.firstFailure.isEmpty {
                    self.firstFailure = "status \(status), NAL \(types), picture \(frameNo) after the keyframe, \(self.usingHardware ? "hardware" : "software")"
                }
                return
            }
            self.consecutiveErrors = 0
            self.decoded += 1
            self.enqueue(pts: pts, pb: image!)
        }
        if st != noErr {
            decodeErrors += 1
            lastDecodeError = st
            consecutiveErrors += 1
            if st == kVTInvalidSessionErr { self.session = nil; paramSets = [] }
        }
        // Anchor the presentation clock on the first decoded unit's decode time.
        if refPTS == nil {
            refPTS = dts
            refTime = now + Self.presentationDelay
        }
    }

    private func makeSession(sets: [[UInt8]], hevc: Bool) -> Bool {
        let ptrs = sets.map { s -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            p.initialize(from: s, count: s.count)
            return p
        }
        defer { ptrs.forEach { $0.deallocate() } }
        let pointers = ptrs.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var fd: CMFormatDescription?
        let st: OSStatus
        if hevc {
            // VPS, SPS, PPS each needed.
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                     parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                     nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
        } else {
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                     parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                     nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        }
        guard st == noErr, let fd else { return false }
        if let old = session { VTDecompressionSessionInvalidate(old) }
        session = nil
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var s: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: nil,
                                                   imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                   decompressionSessionOut: &s)
        guard created == noErr, let s else { decodeErrors += 1; return false }
        session = s
        format = fd
        var hw: CFTypeRef?
        usingHardware = VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                              allocator: kCFAllocatorDefault, valueOut: &hw) == noErr && (hw as? Bool ?? false)
        size = (Int(dims.width), Int(dims.height))
        haveKeyframe = false
        return true
    }

    private static func sampleBuffer(_ nals: [ArraySlice<UInt8>], format: CMVideoFormatDescription, pts: Int64, dts: Int64) -> CMSampleBuffer? {
        // AVCC: 4-byte big-endian length before each NAL, copied once into memory the block owns now
        // (a block created without kCMBlockBufferAssureMemoryNowFlag has no memory to copy into).
        let avcc = AVC.avcc(from: nals)
        let total = avcc.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block,
              avcc.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                                   dataLength: total) }) == kCMBlockBufferNoErr
        else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
                                        decodeTimeStamp: CMTime(value: dts, timescale: 90_000))
        var sampleSize = total
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// 33-bit PTS difference a − b as a signed value.
    private static func delta(_ a: Int64, _ b: Int64) -> Int64 {
        var d = (a - b) & 0x1_FFFF_FFFF
        if d > 0x1_0000_0000 { d -= 0x2_0000_0000 }
        return d
    }

    private func enqueue(pts: Int64, pb: CVPixelBuffer) {
        // Sorted by presentation time (B-frames are decoded out of order).
        let idx = queue.firstIndex { Self.delta($0.pts, pts) > 0 } ?? queue.count
        queue.insert((pts, pb), at: idx)
        if queue.count > 32 { queue.removeFirst(queue.count - 32) }
    }

    private func present(now: Double) {
        guard let ref = refPTS, !queue.isEmpty else { return }
        var shown: CVPixelBuffer?
        while let first = queue.first {
            let due = refTime + Double(Self.delta(first.pts, ref)) / 90_000
            // A jump in time stamps (encoder restarted, stream switched): re-anchor.
            if abs(due - now) > 3 {
                refPTS = first.pts
                refTime = now
                continue
            }
            guard due <= now else { break }
            shown = first.pb
            queue.removeFirst()
            windowFrames += 1
            totalFrames += 1
        }
        if let pb = shown {
            slot.put(pb)
            if !live { live = true; onLive?() }
        }
    }

    // MARK: Audio

    private func audio(_ au: MPEGTSDemuxer.AccessUnit) {
        guard let channel else { return }
        for f in ADTS.frames(au.data) {
            let key = (f.sampleRate, f.channels, f.objectType)
            if converter == nil || key != audioKey {
                var asbd = AudioStreamBasicDescription(mSampleRate: Double(f.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                                                       mFormatFlags: UInt32(f.objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                                       mBytesPerFrame: 0, mChannelsPerFrame: UInt32(f.channels), mBitsPerChannel: 0, mReserved: 0)
                guard let inF = AVAudioFormat(streamDescription: &asbd),
                      let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                               channels: AVAudioChannelCount(min(f.channels, 2)), interleaved: false),
                      let conv = AVAudioConverter(from: inF, to: outF) else { continue }
                conv.downmix = f.channels > 2
                converter = conv; inFormat = inF; outFormat = outF; audioKey = key
                let desc = "AAC \(f.sampleRate / 1000) kHz \(f.channels) ch"
                report { $0.audio = desc }
            }
            guard let conv = converter, let inF = inFormat, let outF = outFormat else { continue }
            let input = AVAudioCompressedBuffer(format: inF, packetCapacity: 1, maximumPacketSize: max(f.payload.count, 1))
            f.payload.withUnsafeBytes { src in input.data.copyMemory(from: src.baseAddress!, byteCount: src.count) }
            input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                        mDataByteSize: UInt32(f.payload.count))
            input.packetCount = 1
            input.byteLength = UInt32(f.payload.count)
            guard let out = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: 4096) else { continue }
            var given = false
            var error: NSError?
            let status = conv.convert(to: out, error: &error) { _, st in
                if given { st.pointee = .noDataNow; return nil }
                given = true
                st.pointee = .haveData
                return input
            }
            guard status != .error, out.frameLength > 0, let data = out.floatChannelData else { continue }
            let n = Int(out.frameLength)
            totalAudio += n
            channel.ringL.write(data[0], count: n)
            channel.ringR.write(out.format.channelCount > 1 ? data[1] : data[0], count: n)
        }
    }
}
#endif

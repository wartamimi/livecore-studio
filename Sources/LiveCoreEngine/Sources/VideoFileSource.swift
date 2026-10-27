#if os(macOS)
import AVFoundation
import CoreVideo
import MediaToolbox
import QuartzCore
import LiveCoreCore

/// Video file playback (any format AVFoundation decodes: H.264/HEVC/ProRes in MP4/MOV/M4V).
/// Decoding is done by AVPlayer (hardware-accelerated where available); frames are pulled
/// with AVPlayerItemVideoOutput at the render clock.
///
/// Audio: an MTAudioProcessingTap on the file's first audio track copies the decoded PCM into
/// a mixer channel (resampled to 48 kHz when needed) and then silences the player's own
/// output, so file audio is heard only through the mixer (fader, mute, routing, meters).
public final class VideoFileSource: NSObject, VideoSource {
    public let id: InputID
    public let kind: InputKind = .videoFile
    public var name: String
    public let url: URL
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { let s = status; DispatchQueue.main.async { self.onStatusChange?(s) } } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    public var loop = true
    /// Called on the main thread once the file turns out to contain audio; must return the
    /// mixer channel the audio is delivered to.
    public var audioChannelProvider: (() -> MixerChannel)?
    public private(set) var audioChannel: MixerChannel?
    /// Sample rate / channel count reported by the tap (0 until the tap is prepared).
    public var audioFormatDescription: String { tapContext?.formatDescription ?? "" }

    private let player = AVPlayer()
    private let output: AVPlayerItemVideoOutput
    private let slot = FrameSlot()
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var item: AVPlayerItem?
    private var tapContext: FileAudioTapContext?

    public init(id: InputID, url: URL) {
        self.id = id; self.url = url; self.name = url.deletingPathExtension().lastPathComponent
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        super.init()
        // Not muted: the tap needs the audio pipeline running. The tap zeroes the player's own
        // output after copying, so nothing bypasses the mixer.
        player.isMuted = false
        player.volume = 1
        player.actionAtItemEnd = .pause
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        tapContext?.active.value = false
    }

    public func start() {
        if item != nil { player.play(); return }
        let asset = AVURLAsset(url: url)
        let newItem = AVPlayerItem(asset: asset)
        newItem.add(output)
        item = newItem
        statusObservation = newItem.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
            switch it.status {
            case .readyToPlay: self?.status = .live
            case .failed: self?.status = .error(it.error?.localizedDescription ?? "cannot play file")
            default: break
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: newItem,
                                                             queue: .main) { [weak self] _ in
            guard let self, self.loop else { return }
            self.player.seek(to: .zero)
            self.player.play()
        }
        player.replaceCurrentItem(with: newItem)
        player.play()
        asset.loadTracks(withMediaType: .audio) { [weak self] tracks, _ in
            guard let track = tracks?.first else { return }
            DispatchQueue.main.async { self?.attachAudioTap(track: track, item: newItem) }
        }
    }

    private func attachAudioTap(track: AVAssetTrack, item: AVPlayerItem) {
        guard tapContext == nil, item === self.item, let provider = audioChannelProvider else { return }
        let channel = provider()
        audioChannel = channel
        let ctx = FileAudioTapContext(channel: channel)
        guard let tap = FileAudioTapContext.makeTap(ctx) else {
            status = .error("Cannot attach audio tap; file audio unavailable")
            return
        }
        tapContext = ctx
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    public func stop() {
        player.pause()
        tapContext?.active.value = false
    }
    public func play() { tapContext?.active.value = true; player.play() }
    public func pause() { player.pause() }
    public func restart() { tapContext?.active.value = true; player.seek(to: .zero); player.play() }
    public var isPlaying: Bool { player.rate != 0 }

    /// Called from the render queue. AVPlayerItemVideoOutput's hasNewPixelBuffer/copyPixelBuffer
    /// are designed to be called from a display-link/render thread.
    public func currentFrame() -> CVPixelBuffer? {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: t),
           let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            slot.put(pb)
        }
        return slot.get()
    }
}

/// State shared with the MTAudioProcessingTap C callbacks. Retained by the tap (released in
/// `finalize`), so it outlives the source if AVFoundation tears the tap down later.
final class FileAudioTapContext {
    let channel: MixerChannel
    let active = AtomicBool(true)
    private(set) var formatDescription = ""
    // Prepared in `prepare` (not real-time), used in `process` (real-time).
    private var resampler: LinearResampler?
    private var interleaved = false
    private var isFloat32 = false
    private var channelsPerFrame = 0
    private var maxFrames = 0
    private var inL: UnsafeMutablePointer<Float>?
    private var inR: UnsafeMutablePointer<Float>?
    private var outL: UnsafeMutablePointer<Float>?
    private var outR: UnsafeMutablePointer<Float>?
    private var outCapacity = 0

    init(channel: MixerChannel) { self.channel = channel }
    deinit { freeBuffers() }

    static func makeTap(_ ctx: FileAudioTapContext) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: Int32(kMTAudioProcessingTapCallbacksVersion_0),
            clientInfo: Unmanaged.passRetained(ctx).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<FileAudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, format in
                Unmanaged<FileAudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().prepare(maxFrames: Int(maxFrames), format: format.pointee)
            },
            unprepare: { tap in
                Unmanaged<FileAudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().freeBuffers()
            },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
                guard status == noErr else { framesOut.pointee = 0; return }
                Unmanaged<FileAudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().process(bufferList, frames: Int(framesOut.pointee))
            })
        // The macOS SDK returns the tap as a +1 Unmanaged reference.
        var tapRef: Unmanaged<MTAudioProcessingTap>?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tapRef)
        let tap = tapRef?.takeRetainedValue()
        if err != noErr || tap == nil {
            Unmanaged.passUnretained(ctx).release()   // balance passRetained: the tap will never finalize
            Log.audio.error("MTAudioProcessingTapCreate failed: \(err)")
            return nil
        }
        return tap
    }

    private func prepare(maxFrames: Int, format asbd: AudioStreamBasicDescription) {
        freeBuffers()
        isFloat32 = asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
        interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        channelsPerFrame = Int(asbd.mChannelsPerFrame)
        self.maxFrames = max(maxFrames, 1)
        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        let rs = LinearResampler(inputRate: rate, outputRate: 48_000)
        resampler = rs
        outCapacity = rs.maxOutputFrames(forInput: self.maxFrames)
        inL = .allocate(capacity: self.maxFrames); inR = .allocate(capacity: self.maxFrames)
        outL = .allocate(capacity: outCapacity); outR = .allocate(capacity: outCapacity)
        formatDescription = "\(Int(rate)) Hz · \(channelsPerFrame) ch" + (isFloat32 ? "" : " (unsupported sample format)")
        Log.audio.info("file audio tap prepared: \(self.formatDescription, privacy: .public), max \(maxFrames) frames")
    }

    fileprivate func freeBuffers() {
        inL?.deallocate(); inR?.deallocate(); outL?.deallocate(); outR?.deallocate()
        inL = nil; inR = nil; outL = nil; outR = nil
        resampler = nil
    }

    /// Real-time: copies the block into the mixer channel, then silences the player output.
    private func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        defer { for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } } }
        guard active.value, isFloat32, frames > 0, frames <= maxFrames, abl.count > 0,
              let inL, let inR, let outL, let outR, var rs = resampler else { return }
        // Copy into our own buffers first: the tap's buffers are zeroed on exit.
        if interleaved {
            guard let p = abl[0].mData?.assumingMemoryBound(to: Float.self), channelsPerFrame > 0 else { return }
            let ch = channelsPerFrame
            for i in 0..<frames { inL[i] = p[i * ch]; inR[i] = p[i * ch + (ch > 1 ? 1 : 0)] }
        } else {
            guard let l = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let r = abl.count > 1 ? (abl[1].mData?.assumingMemoryBound(to: Float.self) ?? l) : l
            inL.update(from: l, count: frames); inR.update(from: r, count: frames)
        }
        let srcL = UnsafePointer(inL), srcR = UnsafePointer(inR)
        if rs.isPassthrough {
            channel.ringL.write(srcL, count: frames)
            channel.ringR.write(srcR, count: frames)
        } else {
            let n = rs.process(inLeft: srcL, inRight: srcR, inputFrames: frames, outLeft: outL, outRight: outR, outputCapacity: outCapacity)
            resampler = rs
            channel.ringL.write(outL, count: n)
            channel.ringR.write(outR, count: n)
        }
    }
}
#endif

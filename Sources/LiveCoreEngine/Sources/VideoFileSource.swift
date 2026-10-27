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
    /// What happens when the input goes on/off Program (vMix "auto play").
    public enum AutoPlay: String, Codable, CaseIterable, Sendable {
        case off            // play/pause only by hand
        case playPause      // play when on Program, pause when it leaves
        case restartPause   // like playPause, but start the clip (or playlist) from the beginning
    }

    public let id: InputID
    public let kind: InputKind = .videoFile
    public var name: String
    /// Clips played in order (a single clip for a plain video input).
    public private(set) var urls: [URL]
    public private(set) var index = 0
    /// The clip currently loaded.
    public var url: URL { urls[min(index, urls.count - 1)] }
    public var isPlaylist: Bool { urls.count > 1 }
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { let s = status; DispatchQueue.main.async { self.onStatusChange?(s) } } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    /// Single clip: repeat it. Playlist: go back to the first clip after the last.
    public var loop = true
    public var autoPlay: AutoPlay = .off
    /// Clip length in seconds once the file is ready (main thread).
    public private(set) var duration: Double?
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
    private var loadToken = 0
    private var started = false
    private var wantsPlay = true

    public convenience init(id: InputID, url: URL) { self.init(id: id, urls: [url]) }

    public init(id: InputID, urls: [URL]) {
        precondition(!urls.isEmpty)
        self.id = id; self.urls = urls
        self.name = urls.count > 1 ? "Playlist" : urls[0].deletingPathExtension().lastPathComponent
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
        if started { return }
        started = true
        // New media inputs load paused on their first frame; the operator (or auto play) starts them.
        load(0, play: false)
    }

    /// Loads clip `i`. The audio track is looked up first so the tap is in place before the
    /// first sample plays (file audio never reaches the speakers outside the mixer).
    private func load(_ i: Int, play: Bool) {
        guard urls.indices.contains(i) else { return }
        index = i
        wantsPlay = play
        loadToken += 1
        let token = loadToken
        let asset = AVURLAsset(url: urls[i])
        asset.loadTracks(withMediaType: .audio) { [weak self] tracks, _ in
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.install(asset: asset, audioTrack: tracks?.first)
            }
        }
    }

    private func install(asset: AVURLAsset, audioTrack: AVAssetTrack?) {
        if let old = item {
            old.remove(output)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        }
        tapContext?.active.value = false
        tapContext = nil
        let newItem = AVPlayerItem(asset: asset)
        newItem.add(output)
        if let audioTrack { attachAudioTap(track: audioTrack, item: newItem) }
        item = newItem
        duration = nil
        statusObservation = newItem.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
            switch it.status {
            case .readyToPlay:
                // Duration first, so the input-list update triggered by `.live` already sees it.
                let d = it.duration.seconds
                DispatchQueue.main.async {
                    guard it === self?.item else { return }
                    self?.duration = d.isFinite && d > 0 ? d : nil
                    self?.status = .live
                    // Paused clips: a precise seek makes the video output deliver the poster frame.
                    if let self, !self.isPlaying {
                        self.player.seek(to: self.player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            case .failed: self?.status = .error(it.error?.localizedDescription ?? "cannot play file")
            default: break
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: newItem,
                                                             queue: .main) { [weak self] _ in self?.clipEnded() }
        player.replaceCurrentItem(with: newItem)
        if wantsPlay { player.play() }
        onClipChange?()
    }

    /// Called on the main thread when another clip of the playlist is loaded.
    public var onClipChange: (() -> Void)?

    private func clipEnded() {
        if let n = PlaylistMath.next(index: index, count: urls.count, loop: loop, shuffle: false, random: { $0.lowerBound }) {
            if n == index { player.seek(to: .zero); player.play() } else { load(n, play: true) }
        }
        // Otherwise the last clip stays paused on its last frame.
    }

    private func attachAudioTap(track: AVAssetTrack, item: AVPlayerItem) {
        let channel: MixerChannel
        if let existing = audioChannel { channel = existing }
        else if let provider = audioChannelProvider { channel = provider(); audioChannel = channel }
        else { return }
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
    public func play() { wantsPlay = true; tapContext?.active.value = true; player.play() }
    public func pause() { wantsPlay = false; player.pause() }
    /// From the beginning: first clip of a playlist, or the start of a single clip.
    public func restart() {
        tapContext?.active.value = true
        if index != 0 { load(0, play: true); return }
        wantsPlay = true
        player.seek(to: .zero); player.play()
    }
    public var isPlaying: Bool { player.rate != 0 }
    /// Pauses on the first frame, ready to start instantly (stinger clips).
    public func cue() { wantsPlay = false; tapContext?.active.value = true; player.pause(); player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }

    // Playlist navigation (main thread). Keeps the current play/pause state.
    public func nextClip() {
        guard urls.count > 1 else { return }
        load(PlaylistMath.next(index: index, count: urls.count, loop: true, shuffle: false, random: { $0.lowerBound }) ?? 0, play: isPlaying)
    }
    public func previousClip() {
        guard urls.count > 1 else { player.seek(to: .zero); return }
        load(PlaylistMath.previous(index: index, count: urls.count), play: isPlaying)
    }
    public func selectClip(_ i: Int) { load(i, play: isPlaying || wantsPlay) }
    public func setURLs(_ new: [URL]) {
        guard !new.isEmpty else { return }
        urls = new
        load(min(index, new.count - 1), play: isPlaying)
    }

    /// Jumps to `seconds` in the current clip (frame-accurate when paused, for scrubbing).
    public func seek(to seconds: Double) {
        let t = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        if isPlaying { player.seek(to: t) } else { player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    /// Seconds into the current clip.
    public var position: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(t, 0) : 0
    }

    /// Most recent decoded frame without pulling a new one (safe from any thread).
    public func lastFrame() -> CVPixelBuffer? { slot.get() }

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

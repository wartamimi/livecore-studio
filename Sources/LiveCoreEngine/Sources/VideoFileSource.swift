#if os(macOS)
import AVFoundation
import CoreVideo
import QuartzCore
import LiveCoreCore

/// Video file playback (any format AVFoundation decodes: H.264/HEVC/ProRes in MP4/MOV/M4V).
/// Decoding is done by AVPlayer (hardware-accelerated where available); frames are pulled
/// with AVPlayerItemVideoOutput at the render clock.
///
/// Milestone 1 limitation: the file's audio is NOT routed into the mixer yet (requires an
/// MTAudioProcessingTap); the player is muted so audio never bypasses the mixer.
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

    private let player = AVPlayer()
    private let output: AVPlayerItemVideoOutput
    private let slot = FrameSlot()
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var item: AVPlayerItem?

    public init(id: InputID, url: URL) {
        self.id = id; self.url = url; self.name = url.deletingPathExtension().lastPathComponent
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        super.init()
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    public func start() {
        if item != nil { player.play(); return }
        let newItem = AVPlayerItem(url: url)
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
    }

    public func stop() { player.pause() }
    public func play() { player.play() }
    public func pause() { player.pause() }
    public func restart() { player.seek(to: .zero); player.play() }
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
#endif

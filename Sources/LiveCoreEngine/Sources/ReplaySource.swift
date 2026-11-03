#if os(macOS)
import AVFoundation
import CoreVideo
import QuartzCore
import LiveCoreCore

/// The "Replay" input: plays a clip from the instant-replay buffer at 100 %, 50 % or 25 %
/// speed. A new clip loads paused on its first frame; it starts when the input goes on
/// Program (or with Play) and holds its last frame at the end.
public final class ReplaySource: NSObject, VideoSource {
    public let id: InputID
    public let kind: InputKind = .replay
    public var name = "Replay"
    public private(set) var status: SourceStatus = .noSignal("no replay loaded") {
        didSet { if status != oldValue { let s = status; DispatchQueue.main.async { self.onStatusChange?(s) } } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    /// Playback speed (1, 0.5, 0.25).
    public var speed: Double = 0.5 { didSet { if isPlaying { player.rate = Float(speed) } } }
    /// Length of the loaded clip from its start point, seconds.
    public private(set) var clipLength: Double = 0
    /// Called on the main thread when a clip is loaded or playback starts/stops.
    public var onChange: (() -> Void)?

    private let player = AVPlayer()
    private let output: AVPlayerItemVideoOutput
    private let slot = FrameSlot()
    private var startTime = CMTime.zero
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    public init(id: InputID) {
        self.id = id
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        super.init()
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    deinit { if let endObserver { NotificationCenter.default.removeObserver(endObserver) } }

    public func start() {}
    public func stop() { player.pause() }

    /// Loads a replay clip paused on its first frame (main thread).
    public func load(_ clip: ReplayRecorder.Clip) {
        if let old = player.currentItem { old.remove(output) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let item = AVPlayerItem(asset: clip.asset)
        item.add(output)
        // Smooth slow motion: let AVFoundation pick frames for any rate.
        item.audioTimePitchAlgorithm = .varispeed
        startTime = clip.start
        clipLength = max(0, clip.asset.duration.seconds - clip.start.seconds)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self, it === self.player.currentItem else { return }
                switch it.status {
                case .readyToPlay:
                    self.status = .live
                    self.player.seek(to: self.startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                case .failed: self.status = .error(it.error?.localizedDescription ?? "cannot play replay")
                default: break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.onChange?()
        }
        player.replaceCurrentItem(with: item)
        player.pause()
        onChange?()
    }

    public var hasClip: Bool { player.currentItem != nil }
    public var isPlaying: Bool { player.rate != 0 }

    public func play() {
        guard let item = player.currentItem else { return }
        // At the end: start over.
        if item.currentTime() >= item.duration - CMTime(value: 1, timescale: 30) { player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) }
        player.rate = Float(speed)
        onChange?()
    }

    public func pause() { player.pause(); onChange?() }

    /// Back to the start of the replay, paused.
    public func cue() {
        player.pause()
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        onChange?()
    }

    /// Seconds played since the replay start point.
    public var position: Double { max(0, player.currentTime().seconds - startTime.seconds) }

    public func currentFrame() -> CVPixelBuffer? {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: t), let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            slot.put(pb)
        }
        return slot.get()
    }
}
#endif

#if os(macOS)
import AppKit
import CoreVideo
import Lottie
import LiveCoreCore
import QuartzCore

/// Lottie animation (.json or .lottie) rendered with transparency, for animated titles, lower
/// thirds and logos. Lottie's main-thread engine draws each frame into a BGRA buffer on a
/// main-thread timer (at the animation's frame rate, at most 30 fps).
public final class LottieSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .lottie
    public var name: String
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    public let url: URL
    /// Loops at the end; otherwise it stops on the last frame.
    public var loop = true
    /// Same modes as video inputs (play / restart when on air, pause when off air).
    public var autoPlay: VideoFileSource.AutoPlay = .off
    public private(set) var isPlaying = true
    /// Seconds.
    public private(set) var duration: Double = 0
    public private(set) var position: Double = 0

    private var animationLayer: LottieAnimationLayer?
    private var animation: LottieAnimation?
    private var canvas = PixelSize(width: 0, height: 0)
    private var timer: Timer?
    private var lastTick: Double = 0
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?
    /// Largest side of the rendered frame; the compositor scales it like any input.
    static let maxSide = 1920

    public init(id: InputID, url: URL) {
        self.id = id
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        load()
    }

    private func load() {
        let config = LottieConfiguration(renderingEngine: .mainThread)
        if url.pathExtension.lowercased() == "lottie" {
            switch DotLottieFile.SynchronouslyBlockingCurrentThread.loadedFrom(filepath: url.path) {
            case let .success(file):
                guard let first = file.animations.first else { return fail("The .lottie file has no animation.") }
                let layer = LottieAnimationLayer(animation: nil, configuration: config)
                layer.loadAnimation(atIndex: 0, from: file)
                setUp(first.animation, layer: layer)
            case let .failure(error):
                fail(error.localizedDescription)
            }
        } else {
            guard let anim = LottieAnimation.filepath(url.path) else { return fail("Not a valid Lottie JSON file.") }
            // Images referenced by the JSON are looked up next to the file.
            let layer = LottieAnimationLayer(animation: anim,
                                             imageProvider: FilepathImageProvider(filepath: url.deletingLastPathComponent()),
                                             configuration: config)
            setUp(anim, layer: layer)
        }
    }

    private func setUp(_ anim: LottieAnimation, layer: LottieAnimationLayer) {
        let size = anim.size
        guard size.width >= 1, size.height >= 1 else { return fail("The animation has no size.") }
        let scale = min(1, Double(Self.maxSide) / Double(max(size.width, size.height)))
        canvas = PixelSize(width: max(2, Int((Double(size.width) * scale).rounded())),
                           height: max(2, Int((Double(size.height) * scale).rounded())))
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.mainThreadRenderingEngineShouldForceDisplayUpdateOnEachFrame = true
        animation = anim
        animationLayer = layer
        duration = anim.duration
        render()
        status = .live
    }

    private func fail(_ message: String) {
        status = .error(message)
    }

    public func start() {
        guard timer == nil else { return }
        lastTick = HostClock.now()
        let fps = min(max(animation?.framerate ?? 30, 1), 30)
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    // MARK: Transport (main thread)

    public func play() {
        if !loop, duration > 0, position >= duration { position = 0 }
        isPlaying = true
        lastTick = HostClock.now()
    }
    public func pause() { isPlaying = false }
    public func restart() { position = 0; play(); render() }
    /// Back to the first frame, paused (what auto play does when the input leaves air).
    public func cue() { isPlaying = false; position = 0; render() }

    private func tick() {
        let now = HostClock.now()
        let dt = now - lastTick
        lastTick = now
        guard isPlaying, duration > 0 else { return }
        position += dt
        if position >= duration {
            if loop { position = position.truncatingRemainder(dividingBy: duration) } else { position = duration; isPlaying = false }
        }
        render()
    }

    private func render() {
        guard let layer = animationLayer, let anim = animation, canvas.width > 0 else { return }
        let total = anim.endFrame - anim.startFrame
        let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.currentFrame = anim.startFrame + total * progress
        layer.forceDisplayUpdate()
        CATransaction.commit()
        let w = canvas.width, h = canvas.height
        let size = anim.size
        let pb = PixelBufferFactory.draw(width: w, height: h) { ctx in
            ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
            // CALayer draws with a top-left origin; the bitmap context is bottom-left.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            layer.render(in: ctx)
        }
        if let pb { lock.withLock { frame = pb } }
    }

    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}
#endif

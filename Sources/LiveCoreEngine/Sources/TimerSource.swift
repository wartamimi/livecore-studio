#if os(macOS)
import AppKit
import CoreVideo
import LiveCoreCore

/// Clock / countdown / count-up generator. Text comes from `TimerMath`; the buffer is redrawn
/// by a 10 Hz main-thread timer only when the displayed text changes (once per second).
public final class TimerSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .timer
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    public private(set) var config: TimerConfig
    public private(set) var run = TimerRunState()
    public var textColor: NSColor = .white
    public var alertColor = NSColor(calibratedRed: 1, green: 0.3, blue: 0.25, alpha: 1)
    private let canvas: PixelSize
    private var timer: Timer?
    private var lastDrawn: (String, Bool, String)?
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?

    /// Default placement of a timer layer (top-right corner, one third of the width).
    public static let defaultRect = NormRect(x: 0.65, y: 0.04, width: 0.31, height: 0.31 / 3 * (16.0 / 9.0))

    /// Canvas: one third of the program width, 3:1.
    public init(id: InputID, config: TimerConfig, outputSize: PixelSize) {
        self.id = id
        self.config = config
        let w = max(240, outputSize.width / 3)
        canvas = PixelSize(width: w, height: w / 3)
        name = TimerSource.defaultName(config)
        redraw(force: true)
    }

    static func defaultName(_ c: TimerConfig) -> String {
        switch c.mode {
        case .clock: return "Clock"
        case .countdown: return "Countdown"
        case .countUp: return "Stopwatch"
        }
    }

    public func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.redraw(force: false) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    public func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    // Controls (main thread)
    public func play() { run.start(at: HostClock.now()); redraw(force: true) }
    public func pause() { run.pause(at: HostClock.now()); redraw(force: true) }
    public func reset() { run.reset(); redraw(force: true) }
    public var isRunning: Bool { run.isRunning }

    public func update(_ c: TimerConfig) {
        if c.mode != config.mode { run.reset() }
        config = c
        redraw(force: true)
    }

    private func secondsOfDay() -> Double {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        return now.timeIntervalSince(start)
    }

    private func redraw(force: Bool) {
        let (text, finished) = TimerMath.text(config, elapsed: run.elapsed(at: HostClock.now()), secondsOfDay: secondsOfDay())
        if !force, let l = lastDrawn, l.0 == text, l.1 == finished, l.2 == config.label { return }
        lastDrawn = (text, finished, config.label)
        let w = canvas.width, h = canvas.height
        let label = config.label
        let color = finished ? alertColor : textColor
        let pb = PixelBufferFactory.draw(width: w, height: h) { ctx in
            // Rounded dark plate so the time reads over any picture.
            let plate = CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: CGFloat(h) * 0.04, dy: CGFloat(h) * 0.04)
            ctx.addPath(CGPath(roundedRect: plate, cornerWidth: CGFloat(h) * 0.12, cornerHeight: CGFloat(h) * 0.12, transform: nil))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.fillPath()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let hasLabel = !label.isEmpty
            let timeSize = CGFloat(h) * (hasLabel ? 0.5 : 0.62)
            let timeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: timeSize, weight: .bold), .foregroundColor: color]
            let t = NSAttributedString(string: text, attributes: timeAttrs)
            let ts = t.size()
            let timeY = hasLabel ? CGFloat(h) * 0.1 : (CGFloat(h) - ts.height) / 2
            t.draw(at: NSPoint(x: (CGFloat(w) - ts.width) / 2, y: timeY))
            if hasLabel {
                let la = NSAttributedString(string: label, attributes: [
                    .font: NSFont.systemFont(ofSize: CGFloat(h) * 0.2, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
                let ls = la.size()
                la.draw(at: NSPoint(x: (CGFloat(w) - ls.width) / 2, y: CGFloat(h) * 0.66))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        lock.withLock { frame = pb }
    }

    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}
#endif

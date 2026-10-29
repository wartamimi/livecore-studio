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
        case .untilTime: return "Countdown to time"
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
        let now = HostClock.now()
        let d = TimerMath.display(config, elapsed: run.elapsed(at: now), secondsOfDay: secondsOfDay())
        let st = config.look
        // Finished countdowns blink twice a second.
        let blinkOff = st.blinkWhenFinished && d.state == .finished && Int(now * 2) % 2 == 1
        let key = "\(d.text)|\(d.state)|\(blinkOff)|\(Int((d.fraction ?? 0) * 200))|\(config.label)|\(st.showDate ? dateLine() : "")"
        if !force, lastKey == key { return }
        lastKey = key
        let w = canvas.width, h = canvas.height
        let label = config.label
        let color: NSColor
        switch d.state {
        case .finished, .overtime: color = NSColor(hex: st.accentHex) ?? alertColor
        case .warning: color = NSColor(hex: st.warnHex) ?? .systemOrange
        case .normal: color = NSColor(hex: st.textHex) ?? textColor
        }
        let plateColor = (NSColor(hex: st.plateHex) ?? .black).withAlphaComponent(st.plateOpacity)
        let date = st.showDate && config.mode == .clock ? dateLine() : ""
        let pb = PixelBufferFactory.draw(width: w, height: h) { ctx in
            let W = CGFloat(w), H = CGFloat(h)
            let inset = H * 0.04
            let plate = CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: inset, dy: inset)
            ctx.setFillColor(plateColor.cgColor)
            switch st.plate {
            case .rounded, .progress, .ring:
                ctx.addPath(CGPath(roundedRect: plate, cornerWidth: H * 0.12, cornerHeight: H * 0.12, transform: nil)); ctx.fillPath()
            case .pill:
                ctx.addPath(CGPath(roundedRect: plate, cornerWidth: plate.height / 2, cornerHeight: plate.height / 2, transform: nil)); ctx.fillPath()
            case .bar:
                ctx.fill(plate)
                ctx.setFillColor((NSColor(hex: st.accentHex) ?? alertColor).cgColor)
                ctx.fill(CGRect(x: plate.minX, y: plate.minY, width: H * 0.06, height: plate.height))
            case .none:
                break
            }
            var textRect = plate
            if st.plate == .progress, let f = d.fraction {
                let bar = CGRect(x: plate.minX + H * 0.08, y: plate.minY + H * 0.07, width: (plate.width - H * 0.16), height: H * 0.06)
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor); ctx.fill(bar)
                ctx.setFillColor(color.cgColor)
                ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(f), height: bar.height))
                textRect.origin.y += H * 0.08; textRect.size.height -= H * 0.08
            }
            if st.plate == .ring {
                let r = plate.height * 0.36
                let c = CGPoint(x: plate.minX + plate.height * 0.5, y: plate.midY)
                ctx.setLineWidth(H * 0.07)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
                ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()
                if let f = d.fraction, f > 0 {
                    ctx.setStrokeColor(color.cgColor); ctx.setLineCap(.round)
                    ctx.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * CGFloat(f), clockwise: true)
                    ctx.strokePath()
                }
                textRect.origin.x += plate.height * 0.9; textRect.size.width -= plate.height * 0.9
            }
            guard !blinkOff else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let lines = (label.isEmpty ? 0 : 1) + (date.isEmpty ? 0 : 1)
            let timeSize = H * (lines == 0 ? 0.62 : lines == 1 ? 0.5 : 0.42)
            let t = NSAttributedString(string: d.text, attributes: [.font: Self.font(st.font, size: timeSize), .foregroundColor: color])
            var ts = t.size()
            var scale: CGFloat = 1
            if ts.width > textRect.width * 0.94 { scale = textRect.width * 0.94 / ts.width }
            let tt = scale < 1 ? NSAttributedString(string: d.text, attributes: [.font: Self.font(st.font, size: timeSize * scale), .foregroundColor: color]) : t
            ts = tt.size()
            let timeY: CGFloat = lines == 0 ? textRect.minY + (textRect.height - ts.height) / 2
                : textRect.minY + (date.isEmpty ? H * 0.06 : H * 0.2)
            tt.draw(at: NSPoint(x: textRect.minX + (textRect.width - ts.width) / 2, y: timeY))
            func small(_ s: String, y: CGFloat) {
                let a = NSAttributedString(string: s, attributes: [
                    .font: Self.font(st.font == .mono ? .system : st.font, size: H * 0.17),
                    .foregroundColor: (NSColor(hex: st.textHex) ?? .white).withAlphaComponent(0.85)])
                let sz = a.size()
                a.draw(at: NSPoint(x: textRect.minX + (textRect.width - sz.width) / 2, y: y))
            }
            if !label.isEmpty { small(label, y: textRect.minY + textRect.height * 0.7) }
            if !date.isEmpty { small(date, y: textRect.minY + H * 0.03) }
            NSGraphicsContext.restoreGraphicsState()
        }
        lock.withLock { frame = pb }
    }

    private var lastKey = ""

    private func dateLine() -> String {
        let f = DateFormatter()
        f.dateStyle = .full; f.timeStyle = .none
        return f.string(from: Date())
    }

    static func font(_ f: TimerStyle.Font, size: CGFloat) -> NSFont {
        switch f {
        case .system: return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        case .rounded:
            let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .serif:
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .condensed:
            return NSFont(name: "HelveticaNeue-CondensedBold", size: size) ?? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .heavy)
        }
    }

    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}
#endif

#if os(macOS)
public extension NSColor {
    /// "#RRGGBB" colour (0.45.0).
    convenience init?(hex: String) {
        guard let c = ProjectColor(hex: hex) else { return nil }
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
#endif

/// Scrolling text (news ticker / running text) shown in a band at the bottom of the picture.
public struct TickerConfig: Codable, Equatable, Sendable {
    public var text: String
    /// Scroll speed in pixels per second at 1080p (scaled with the output height).
    public var speed: Double
    /// Text size in points at 1080p.
    public var fontSize: Double
    public var textColor: ProjectColor
    public var barColor: ProjectColor
    public var showBar: Bool
    /// Band height as a fraction of the picture height.
    public var bandHeight: Double
    /// Plain-text file whose contents replace `text`, re-read when the file changes (since 0.18.0).
    public var textFilePath: String?

    public init(text: String, speed: Double = 120, fontSize: Double = 44,
                textColor: ProjectColor = ProjectColor(r: 1, g: 1, b: 1),
                barColor: ProjectColor = ProjectColor(r: 0.6, g: 0.05, b: 0.05, a: 0.9),
                showBar: Bool = true, bandHeight: Double = 0.08) {
        self.text = text; self.speed = speed; self.fontSize = fontSize; self.textColor = textColor
        self.barColor = barColor; self.showBar = showBar; self.bandHeight = bandHeight
    }

    public static let speedRange: ClosedRange<Double> = 20...600
    public var clamped: TickerConfig {
        var c = self
        c.speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        c.fontSize = min(max(fontSize, 12), 120)
        c.bandHeight = min(max(bandHeight, 0.04), 0.25)
        return c
    }

    /// Normalised layer rectangle of the band (bottom of the picture).
    public var layerRect: NormRect {
        let h = clamped.bandHeight
        return NormRect(x: 0, y: 1 - h - 0.04, width: 1, height: h)
    }
}

public enum TickerMath {
    /// X position (pixels) of the text strip's left edge at `elapsed` seconds: it enters at the
    /// right edge of the view, leaves on the left, and starts again (one copy on screen at a time).
    public static func offset(elapsed: Double, speed: Double, stripWidth: Double, viewWidth: Double) -> Double {
        let cycle = stripWidth + viewWidth
        guard cycle > 0, speed > 0 else { return viewWidth }
        var d = (elapsed * speed).truncatingRemainder(dividingBy: cycle)
        if d < 0 { d += cycle }
        return viewWidth - d
    }
}

/// Photo slideshow: images shown in order for `interval` seconds with a cross-fade.
public struct ProjectSlideshow: Codable, Equatable, Sendable {
    public var images: [ProjectMediaRef]
    public var interval: Double
    public var fade: Double
    public var loop: Bool
    /// Slow zoom and pan on each photo (since 0.18.0).
    public var kenBurns: Bool?
    /// Folder the photos came from; new or removed photos there are picked up while running (since 0.18.0).
    public var folder: ProjectMediaRef?
    public init(images: [ProjectMediaRef], interval: Double = 5, fade: Double = 1, loop: Bool = true,
                kenBurns: Bool? = nil, folder: ProjectMediaRef? = nil) {
        self.images = images; self.interval = interval; self.fade = fade; self.loop = loop
        self.kenBurns = kenBurns; self.folder = folder
    }
}

public enum SlideshowMath {
    public struct Position: Equatable, Sendable {
        /// Image shown (fading out while `mix` > 0).
        public var index: Int
        /// Image fading in, nil when no fade is running.
        public var next: Int?
        /// 0...1 progress of the fade into `next`.
        public var mix: Double
        /// True once a non-looping show has reached its last image.
        public var finished: Bool
    }

    /// Ken Burns motion progress (0...1) of the shown image and of the one fading in, `within`
    /// seconds into the current slot. Each image moves from the start of its fade-in to the end of
    /// its fade-out, so the motion carries on without a jump when the next image takes over.
    public static func motionProgress(within: Double, interval: Double, fade: Double) -> (current: Double, next: Double) {
        let iv = max(interval, 0.5)
        let fd = min(max(fade, 0), iv * 0.9)
        let span = iv + fd
        let cur = min(max((within + fd) / span, 0), 1)
        let nxt = min(max((within - (iv - fd)) / span, 0), 1)
        return (cur, nxt)
    }

    /// Part of image `index` (normalised, origin top-left) shown at motion `progress`: even images
    /// zoom in, odd ones zoom out (100 % ↔ 115 %), each drifting toward a different corner.
    public static func kenBurnsRect(progress: Double, index: Int) -> NormRect {
        let p = min(max(progress, 0), 1)
        let zoom = index % 2 == 0 ? 1 + 0.15 * p : 1.15 - 0.15 * p
        let w = 1 / zoom
        let dirs: [(Double, Double)] = [(1, 1), (-1, 1), (1, -1), (-1, -1)]
        let d = dirs[((index % 4) + 4) % 4]
        let travel = (1 - w) / 2 * (2 * p - 1)
        let cx = 0.5 + d.0 * travel, cy = 0.5 + d.1 * travel
        return NormRect(x: cx - w / 2, y: cy - w / 2, width: w, height: w)
    }

    /// Where the show is after `elapsed` seconds. Each image is shown for `interval` seconds
    /// (fade included); the fade into the next image takes the last `fade` seconds of that.
    public static func position(elapsed: Double, count: Int, interval: Double, fade: Double, loop: Bool) -> Position {
        guard count > 0 else { return Position(index: 0, next: nil, mix: 0, finished: true) }
        let iv = max(interval, 0.5)
        let fd = min(max(fade, 0), iv * 0.9)
        let t = max(elapsed, 0)
        var slot = Int((t / iv).rounded(.down))
        let within = t - Double(slot) * iv
        if !loop && slot >= count - 1 { return Position(index: count - 1, next: nil, mix: 0, finished: true) }
        slot %= count
        let next = (slot + 1) % count
        if count > 1, fd > 0, within > iv - fd {
            return Position(index: slot, next: next, mix: min(1, (within - (iv - fd)) / fd), finished: false)
        }
        return Position(index: slot, next: nil, mix: 0, finished: false)
    }
}

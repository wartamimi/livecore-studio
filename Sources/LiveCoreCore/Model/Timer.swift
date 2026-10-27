/// Clock / countdown / count-up generator: configuration, run state and text formatting.
/// Pure and Foundation-free so the formatting and timing rules are unit-tested on Linux; the
/// engine's `TimerSource` renders the text.
public struct TimerConfig: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case clock       // time of day
        case countdown   // counts down from `durationSeconds`, stops at 0:00
        case countUp     // stopwatch
    }
    public var mode: Mode
    public var durationSeconds: Double
    public var showSeconds: Bool
    /// Optional caption drawn above the time ("Starting in", "Live", ...).
    public var label: String
    public init(mode: Mode = .countdown, durationSeconds: Double = 300, showSeconds: Bool = true, label: String = "") {
        self.mode = mode; self.durationSeconds = durationSeconds; self.showSeconds = showSeconds; self.label = label
    }
}

/// Start/pause/reset state of a countdown or count-up. Times are host seconds.
public struct TimerRunState: Equatable, Sendable {
    public private(set) var accumulated: Double = 0
    public private(set) var startedAt: Double?
    public init() {}
    public var isRunning: Bool { startedAt != nil }
    public func elapsed(at now: Double) -> Double { accumulated + (startedAt.map { max(now - $0, 0) } ?? 0) }
    public mutating func start(at now: Double) { if startedAt == nil { startedAt = now } }
    public mutating func pause(at now: Double) {
        if let s = startedAt { accumulated += max(now - s, 0); startedAt = nil }
    }
    public mutating func reset() { accumulated = 0; startedAt = nil }
}

public enum TimerMath {
    /// "1:02:03", "05:07" (hours only when needed). Negative values clamp to 0.
    public static func duration(_ seconds: Double, showSeconds: Bool = true) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        if !showSeconds { return h > 0 ? "\(h):\(two(m))" : "\(two(m)) min" }
        return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(two(m)):\(two(s))"
    }

    /// Countdown remaining time: whole seconds rounded up, so "00:01" shows during the last second
    /// and "00:00" appears exactly when the time is up.
    public static func remaining(duration: Double, elapsed: Double) -> Double {
        let r = duration - elapsed
        return r <= 0 ? 0 : r.rounded(.up)
    }

    /// Time of day from seconds since local midnight, 24-hour clock.
    public static func clock(secondsOfDay: Double, showSeconds: Bool) -> String {
        let t = Int(max(secondsOfDay, 0)) % 86_400
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return showSeconds ? "\(two(h)):\(two(m)):\(two(s))" : "\(two(h)):\(two(m))"
    }

    /// Text shown for a timer, and whether a countdown has finished (drawn in the alert colour).
    public static func text(_ config: TimerConfig, elapsed: Double, secondsOfDay: Double) -> (text: String, finished: Bool) {
        switch config.mode {
        case .clock:
            return (clock(secondsOfDay: secondsOfDay, showSeconds: config.showSeconds), false)
        case .countdown:
            let r = remaining(duration: config.durationSeconds, elapsed: elapsed)
            return (duration(r, showSeconds: config.showSeconds), r <= 0)
        case .countUp:
            return (duration(elapsed, showSeconds: config.showSeconds), false)
        }
    }
}

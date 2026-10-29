/// Clock / countdown / count-up generator: configuration, run state and text formatting.
/// Pure and Foundation-free so the formatting and timing rules are unit-tested on Linux; the
/// engine's `TimerSource` renders the text.
public struct TimerConfig: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case clock       // time of day
        case countdown   // counts down from `durationSeconds`, stops at 0:00
        case countUp     // stopwatch
        case untilTime   // counts down to a time of day (`targetSecondsOfDay`), 0.45.0
    }
    public var mode: Mode
    public var durationSeconds: Double
    public var showSeconds: Bool
    /// Optional caption drawn above the time ("Starting in", "Live", ...).
    public var label: String
    /// Look and extra behaviour (0.45.0; nil = the 0.6 look).
    public var style: TimerStyle?
    /// Time of day for `.untilTime` (seconds since midnight).
    public var targetSecondsOfDay: Double?
    public var look: TimerStyle { style ?? TimerStyle() }
    public init(mode: Mode = .countdown, durationSeconds: Double = 300, showSeconds: Bool = true, label: String = "") {
        self.mode = mode; self.durationSeconds = durationSeconds; self.showSeconds = showSeconds; self.label = label
    }
}

/// Graphic and behaviour options of a timer (0.45.0).
public struct TimerStyle: Codable, Equatable, Sendable {
    public enum Plate: String, Codable, Sendable, CaseIterable {
        case rounded, pill, bar, none
        /// Rounded plate with a progress bar along the bottom (countdowns).
        case progress
        /// Ring that empties as the countdown runs (square canvas look inside the plate).
        case ring
    }
    public enum Font: String, Codable, Sendable, CaseIterable { case system, rounded, mono, serif, condensed }
    public var plate: Plate = .rounded
    public var font: Font = .system
    /// "#RRGGBB" colours.
    public var textHex: String = "#FFFFFF"
    public var plateHex: String = "#000000"
    public var plateOpacity: Double = 0.6
    public var accentHex: String = "#FF4D40"
    /// Countdown: from this many seconds left the time turns amber (0 = off).
    public var warnSeconds: Double = 60
    public var warnHex: String = "#FFB020"
    /// Countdown: after zero, keep counting as overtime ("−00:12") instead of stopping.
    public var overtime: Bool = false
    /// Countdown: text shown at zero instead of 00:00 (empty = 00:00).
    public var finishedText: String = ""
    /// Countdown: blink when finished.
    public var blinkWhenFinished: Bool = true
    /// Clock: 12-hour with AM/PM.
    public var twelveHour: Bool = false
    /// Clock: date line under the time.
    public var showDate: Bool = false
    /// Count-up / countdown: tenths of a second.
    public var showTenths: Bool = false
    public init() {}
}

/// What a timer shows at one moment (0.45.0).
public struct TimerDisplay: Equatable, Sendable {
    public enum State: Equatable, Sendable { case normal, warning, finished, overtime }
    public var text: String
    public var state: State
    /// Countdown progress 1 → 0 (nil for clock / count-up).
    public var fraction: Double?
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

    /// "h:mm AM" style clock.
    public static func clock12(secondsOfDay: Double, showSeconds: Bool) -> String {
        let t = Int(max(secondsOfDay, 0)) % 86_400
        let h24 = t / 3600, m = (t % 3600) / 60, s = t % 60
        let h = h24 % 12 == 0 ? 12 : h24 % 12
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return (showSeconds ? "\(h):\(two(m)):\(two(s))" : "\(h):\(two(m))") + (h24 < 12 ? " AM" : " PM")
    }

    /// Seconds from `now` (seconds of day) until `target`, wrapping past midnight.
    public static func untilTime(target: Double, now: Double) -> Double {
        var d = target - now
        if d < -1 { d += 86_400 }
        return max(d, 0)
    }

    /// Full display for the 0.45 timer graphics: text, warning / finished / overtime state and
    /// countdown progress.
    public static func display(_ c: TimerConfig, elapsed: Double, secondsOfDay: Double) -> TimerDisplay {
        let st = c.look
        func dur(_ v: Double) -> String {
            var s = duration(v, showSeconds: c.showSeconds)
            if st.showTenths && c.showSeconds { s += "." + String(Int((max(v, 0) * 10).rounded(.down)) % 10) }
            return s
        }
        switch c.mode {
        case .clock:
            let t = st.twelveHour ? clock12(secondsOfDay: secondsOfDay, showSeconds: c.showSeconds)
                                  : clock(secondsOfDay: secondsOfDay, showSeconds: c.showSeconds)
            return TimerDisplay(text: t, state: .normal, fraction: nil)
        case .countUp:
            return TimerDisplay(text: dur(elapsed), state: .normal, fraction: nil)
        case .countdown, .untilTime:
            let total: Double
            let left: Double
            if c.mode == .countdown {
                total = max(c.durationSeconds, 0.001)
                left = c.durationSeconds - elapsed
            } else {
                let target = c.targetSecondsOfDay ?? 0
                left = untilTime(target: target, now: secondsOfDay)
                total = max(c.durationSeconds, 0.001)
            }
            if left <= 0 {
                if st.overtime && c.mode == .countdown {
                    return TimerDisplay(text: "−" + dur(-left), state: .overtime, fraction: 0)
                }
                return TimerDisplay(text: st.finishedText.isEmpty ? dur(0) : st.finishedText, state: .finished, fraction: 0)
            }
            let shown = st.showTenths ? left : left.rounded(.up)
            let warn = st.warnSeconds > 0 && left <= st.warnSeconds
            return TimerDisplay(text: dur(shown), state: warn ? .warning : .normal, fraction: min(max(left / total, 0), 1))
        }
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
        case .untilTime:
            let r = untilTime(target: config.targetSecondsOfDay ?? 0, now: secondsOfDay).rounded(.up)
            return (duration(r, showSeconds: config.showSeconds), r <= 0)
        }
    }
}

extension ProjectColor {
    /// "#RRGGBB" or "#RRGGBBAA" (0.45.0).
    public init?(hex: String) {
        var h = hex.droppingHash
        if h.count == 6 { h += "FF" }
        guard h.count == 8, let v = UInt32(h, radix: 16) else { return nil }
        self.init(r: Double(v >> 24 & 0xff) / 255, g: Double(v >> 16 & 0xff) / 255,
                  b: Double(v >> 8 & 0xff) / 255, a: Double(v & 0xff) / 255)
    }

    /// "#RRGGBB" (alpha dropped).
    public var hex: String {
        func c(_ v: Double) -> String {
            let i = Int((min(max(v, 0), 1) * 255).rounded())
            let s = String(i, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + c(r) + c(g) + c(b)
    }
}

private extension String {
    var droppingHash: String { hasPrefix("#") ? String(dropFirst()) : self }
}

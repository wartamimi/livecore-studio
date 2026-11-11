/// Teleprompter (0.71.0): a script that scrolls at reading speed on a Mac window (external
/// screen, mirrored for a beam-splitter glass) and on phones through the Web Controller.
/// The position is a fraction of the script (0 = top, 1 = end), so every screen shows the same
/// place whatever its size; speed is in words per minute, the way presenters think about it.
public struct TeleprompterScript: Codable, Equatable, Sendable {
    public var text: String = ""
    /// Reading speed in words per minute.
    public var wpm: Double = 140
    /// Font size on the Mac window (points); phones scale it to their width.
    public var fontSize: Double = 56
    /// Mirror horizontally (for prompter glass).
    public var mirror = false

    public init(text: String = "") { self.text = text }

    public static let wpmRange: ClosedRange<Double> = 40 ... 400
    public static let fontRange: ClosedRange<Double> = 18 ... 160

    public var clampedWPM: Double {
        min(max(wpm.isFinite ? wpm : 140, Self.wpmRange.lowerBound), Self.wpmRange.upperBound)
    }

    public var wordCount: Int {
        var n = 0, inWord = false
        for c in text.unicodeScalars {
            let space = c == " " || c == "\n" || c == "\t" || c == "\r"
            if !space && !inWord { n += 1 }
            inWord = !space
        }
        return n
    }

    /// Seconds to read the whole script at the current speed (at least 5 s).
    public var readingSeconds: Double { max(5, Double(wordCount) / clampedWPM * 60) }

    /// Position after `dt` seconds of scrolling.
    public func advanced(_ position: Double, by dt: Double) -> Double {
        guard dt.isFinite, dt > 0 else { return position }
        return min(1, max(0, position + dt / readingSeconds))
    }

    /// Jump by `seconds` of reading (negative = back).
    public func jumped(_ position: Double, seconds: Double) -> Double {
        min(1, max(0, position + seconds / readingSeconds))
    }
}

/// Web Controller commands for the teleprompter.
public enum TeleprompterCommand: String, Sendable, CaseIterable {
    case play, pause, toggle, restart, faster, slower, back, forward, bigger, smaller, mirror
}

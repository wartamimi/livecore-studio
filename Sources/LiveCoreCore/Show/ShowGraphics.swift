/// Show graphics driven by state (0.74.0): a scoreboard and automatic speaker name tags. Both
/// write their text into an ordinary title input, so every title template, colour and
/// animation can be used for them.

// MARK: - Scoreboard

public struct Scoreboard: Codable, Equatable, Sendable {
    /// Title input that shows the score (nil = not set up).
    public var input: InputID?
    public var home = "HOME"
    public var away = "AWAY"
    public var homeScore = 0
    public var awayScore = 0
    public var period = 1
    /// Word before the period number ("Babak", "Set", "Quarter"); empty = no period line.
    public var periodLabel = "Babak"

    public init() {}

    public static let maxScore = 999
    public static let maxPeriod = 99

    public var titleText: String { "\(home)  \(homeScore) - \(awayScore)  \(away)" }
    public var subtitleText: String { periodLabel.isEmpty ? "" : "\(periodLabel) \(period)" }

    public mutating func perform(_ c: ScoreCommand) {
        switch c {
        case .homePlus: homeScore = min(homeScore + 1, Self.maxScore)
        case .homeMinus: homeScore = max(homeScore - 1, 0)
        case .awayPlus: awayScore = min(awayScore + 1, Self.maxScore)
        case .awayMinus: awayScore = max(awayScore - 1, 0)
        case .periodNext: period = min(period + 1, Self.maxPeriod)
        case .periodBack: period = max(period - 1, 1)
        case .reset: homeScore = 0; awayScore = 0; period = 1
        }
    }
}

/// Scoreboard buttons (app, Web Controller `/api/score?do=`, shortcuts).
public enum ScoreCommand: String, CaseIterable, Sendable {
    case homePlus, homeMinus, awayPlus, awayMinus, periodNext, periodBack, reset
}

// MARK: - Automatic name tags

/// When a speaker's camera goes on Program, their name and role are written into a lower-third
/// title, shown on an overlay channel and hidden again after `seconds`.
public struct NameTagConfig: Codable, Equatable, Sendable {
    public struct Tag: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var input: InputID?
        public var name: String
        public var role: String
        public init(input: InputID? = nil, name: String = "", role: String = "", id: String = MacroBook.newID()) {
            self.id = id; self.input = input; self.name = name; self.role = role
        }
    }

    public var enabled = false
    /// Lower-third title input that carries the text.
    public var title: InputID?
    public var overlay = 1
    public var seconds: Double = 6
    /// The same speaker is not tagged again within this time (cutting back and forth).
    public var repeatAfterSeconds: Double = 120
    public var tags: [Tag] = []

    public init() {}

    public var showSeconds: Double { min(max(seconds.isFinite ? seconds : 6, 2), 60) }
    public var overlayIndex: Int { (1...4).contains(overlay) ? overlay : 1 }

    public func tag(for input: InputID) -> Tag? {
        tags.first { $0.input == input && !$0.name.trimmed.isEmpty }
    }

    public func pruned(inputs: Set<InputID>) -> NameTagConfig {
        var c = self
        if let t = c.title, !inputs.contains(t) { c.title = nil }
        for k in c.tags.indices where c.tags[k].input.map({ !inputs.contains($0) }) ?? false { c.tags[k].input = nil }
        return c
    }
}

/// Decides when to show a tag. Feed it every Program change.
public struct NameTagger: Sendable {
    private var lastShown: [InputID: Double] = [:]

    public init() {}

    /// The tag to show for `program` now, or nil.
    public mutating func onProgram(_ program: InputID, now: Double, config: NameTagConfig) -> NameTagConfig.Tag? {
        guard config.enabled, config.title != nil, let tag = config.tag(for: program) else { return nil }
        if let last = lastShown[program], now - last < max(config.repeatAfterSeconds, 0) { return nil }
        lastShown[program] = now
        return tag
    }

    public mutating func reset() { lastShown = [:] }
}

// MARK: - Logo bug

/// A small logo in a corner of the picture (station bug / watermark).
public enum LogoCorner: String, CaseIterable, Codable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Layer rect for a logo `width` wide (fraction of the picture), square in a 16:9 frame.
    public func rect(width: Double = 0.14, margin: Double = 0.03) -> NormRect {
        let w = min(max(width, 0.02), 0.5), h = w * 16 / 9
        let mx = margin, my = margin * 16 / 9
        let left = self == .topLeft || self == .bottomLeft, top = self == .topLeft || self == .topRight
        return NormRect(x: left ? mx : 1 - mx - w, y: top ? my : 1 - my - h, width: w, height: h)
    }
}

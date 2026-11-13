/// Show automation (0.71.0): backup stream failover, the safe slate shown when the camera on
/// Program loses its signal, and the auto-director that cuts to whoever is talking.
/// Portable decision logic only (tested on Linux); the app feeds it statuses and levels.

// MARK: - Backup stream

/// Which server a destination with a backup ingest URL uses. Reconnects stay on the current
/// server for `switchAfter` failures, then move to the other one; a destination that cannot
/// connect at the very start tries the backup once before giving up.
public struct StreamFailover: Equatable, Sendable {
    public let hasBackup: Bool
    public var switchAfter: Int
    public private(set) var onBackup = false
    public private(set) var failuresOnServer = 0
    public private(set) var triedBackup = false

    public init(hasBackup: Bool, switchAfter: Int = 2) {
        self.hasBackup = hasBackup
        self.switchAfter = max(1, switchAfter)
    }

    /// The connection was lost (or could not be made). Returns true when the next attempt goes
    /// to the other server.
    @discardableResult
    public mutating func connectionFailed() -> Bool {
        failuresOnServer += 1
        guard hasBackup, failuresOnServer >= switchAfter else { return false }
        flip()
        return true
    }

    /// First connect failed before the stream was ever live: try the backup right away (once).
    /// Returns false when there is nothing else to try.
    public mutating func initialFailure() -> Bool {
        guard hasBackup, !triedBackup else { return false }
        flip()
        return true
    }

    /// Published: the server works, count again from zero.
    public mutating func connected() { failuresOnServer = 0 }

    private mutating func flip() {
        onBackup.toggle()
        if onBackup { triedBackup = true }
        failuresOnServer = 0
    }
}

// MARK: - Safe slate

/// Per production: which input stands in when the input on Program loses its signal.
public struct SafeSlateConfig: Codable, Equatable, Sendable {
    public var enabled = false
    /// The slate ("We'll be right back" picture, colour, video...). nil = feature off.
    public var slate: InputID?
    /// How long Program must be without signal before the slate is cut in.
    public var delaySeconds: Double = 2
    /// Cut back to the input once its signal has been back for `returnSeconds`.
    public var autoReturn = true
    public var returnSeconds: Double = 3

    public init() {}

    public var isActive: Bool { enabled && slate != nil }
    static let delayRange: ClosedRange<Double> = 0.5 ... 30
    var delay: Double { min(max(delaySeconds.isFinite ? delaySeconds : 2, Self.delayRange.lowerBound), Self.delayRange.upperBound) }
    var returnDelay: Double { min(max(returnSeconds.isFinite ? returnSeconds : 3, 0.5), 60) }
}

/// Watches the Program input. Call `update` a few times a second.
public struct SafeSlateWatch: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case cutToSlate(InputID, replacing: InputID)
        case returnTo(InputID)
    }

    /// The input the slate stands in for (nil when the slate is not on because of a loss).
    public private(set) var replaced: InputID?
    private var badSince: Double?
    private var goodSince: Double?

    public init() {}

    /// - Parameters:
    ///   - healthy: false while an input has no signal or an error (a starting input counts as
    ///     healthy, so a camera that is still opening does not trigger the slate).
    public mutating func update(now: Double, config: SafeSlateConfig, program: InputID?,
                                healthy: (InputID) -> Bool) -> Action {
        guard config.isActive, let slate = config.slate else { reset(); return .none }
        if let r = replaced {
            guard program == slate else { reset(); return .none }   // the operator took over
            guard config.autoReturn, healthy(r) else { goodSince = nil; return .none }
            let since = goodSince ?? now
            goodSince = since
            guard now - since >= config.returnDelay else { return .none }
            reset()
            return .returnTo(r)
        }
        guard let p = program, p != slate, !healthy(p) else { badSince = nil; return .none }
        let since = badSince ?? now
        badSince = since
        guard now - since >= config.delay, healthy(slate) else { return .none }
        badSince = nil
        goodSince = nil
        replaced = p
        return .cutToSlate(slate, replacing: p)
    }

    public mutating func reset() {
        replaced = nil; badSince = nil; goodSince = nil
    }
}

// MARK: - Auto-director

/// Per production: which microphone belongs to which camera.
public struct AutoDirectorConfig: Codable, Equatable, Sendable {
    public struct Pair: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// Mixer channel id of the microphone.
        public var channel: String
        public var input: InputID?
        public init(channel: String, input: InputID? = nil, id: String = MacroBook.newID()) {
            self.id = id; self.channel = channel; self.input = input
        }
    }

    public var enabled = false
    public var pairs: [Pair] = []
    /// Shot used when several people talk at once or nobody talks for a while (optional).
    public var wideInput: InputID?
    /// A microphone counts as talking above this level.
    public var thresholdDB: Double = -38
    /// Speech must last this long before the camera changes (coughs and "mm" do not cut).
    public var talkSeconds: Double = 0.8
    /// A shot stays on at least this long.
    public var minHoldSeconds: Double = 4
    /// Silence before going to the wide shot (0 = stay on the last speaker).
    public var silenceToWideSeconds: Double = 8
    /// Switch with the current transition (AUTO) instead of a cut.
    public var useTransition = false

    public init() {}

    /// Inputs the director switches between; when anything else is on Program the operator
    /// has taken over and the director waits.
    public var managedInputs: Set<InputID> {
        var s = Set(pairs.compactMap(\.input))
        if let w = wideInput { s.insert(w) }
        return s
    }

    public func pruned(inputs: Set<InputID>) -> AutoDirectorConfig {
        var c = self
        for k in c.pairs.indices where c.pairs[k].input.map({ !inputs.contains($0) }) ?? false { c.pairs[k].input = nil }
        if let w = c.wideInput, !inputs.contains(w) { c.wideInput = nil }
        return c
    }
}

/// Decides the next shot from microphone levels. Call `update` about 10 times a second.
public struct AutoDirector: Sendable {
    /// Short dips between words do not end a talk.
    public static let hangoverSeconds: Double = 0.35

    private var talkStart: [String: Double] = [:]
    private var lastLoud: [String: Double] = [:]
    private var lastSwitch: Double = -.infinity
    private var silentSince: Double?

    public init() {}

    /// - Parameter levelsDB: level of each unmuted microphone (missing = silent).
    /// - Returns: the input to put on Program, or nil to stay.
    public mutating func update(now: Double, levelsDB: [String: Double], program: InputID?,
                                config: AutoDirectorConfig) -> InputID? {
        guard config.enabled else { reset(); return nil }
        var talking: [(channel: String, input: InputID, level: Double)] = []
        for p in config.pairs {
            let level = levelsDB[p.channel] ?? -.infinity
            if level >= config.thresholdDB {
                if talkStart[p.channel] == nil { talkStart[p.channel] = now }
                lastLoud[p.channel] = now
            } else if let l = lastLoud[p.channel], now - l > Self.hangoverSeconds {
                talkStart[p.channel] = nil
                lastLoud[p.channel] = nil
            }
            if let input = p.input, let start = talkStart[p.channel], now - start >= max(config.talkSeconds, 0) {
                talking.append((p.channel, input, level))
            }
        }
        let anyoneLoud = config.pairs.contains { lastLoud[$0.channel] != nil }
        if anyoneLoud { silentSince = nil } else if silentSince == nil { silentSince = now }

        // Something else on air (a video, a title page): the operator is in charge.
        if let p = program, !config.managedInputs.contains(p) { return nil }
        guard now - lastSwitch >= max(config.minHoldSeconds, 0) else { return nil }

        let target: InputID?
        let distinct = Set(talking.map(\.input))
        if distinct.count == 1 {
            target = distinct.first
        } else if distinct.count > 1 {
            // Several people at once: wide shot, or else the loudest.
            target = config.wideInput ?? talking.max { $0.level < $1.level }?.input
        } else if let w = config.wideInput, config.silenceToWideSeconds > 0, let s = silentSince,
                  now - s >= config.silenceToWideSeconds {
            target = w
        } else {
            target = nil
        }
        guard let t = target, t != program else { return nil }
        lastSwitch = now
        return t
    }

    /// The operator switched by hand: the new shot gets the full hold time too.
    public mutating func noteManualSwitch(now: Double) { lastSwitch = now }

    public mutating func reset() {
        talkStart = [:]; lastLoud = [:]; silentSince = nil
    }
}

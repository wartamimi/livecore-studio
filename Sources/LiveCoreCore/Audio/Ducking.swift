/// Automatic ducking: while a "trigger" channel (the MC's microphone) is above the threshold,
/// "ducked" channels (music, video) are turned down by `depthDB`, and come back up after the
/// speaker stops for `holdMs`. Settings are stored in projects.
public struct DuckingSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Trigger level (post-fader peak of the trigger channels).
    public var thresholdDB: Float = -35
    /// How far ducked channels go down (negative).
    public var depthDB: Float = -15
    public var attackMs: Float = 80
    public var holdMs: Float = 500
    public var releaseMs: Float = 900

    public init() {}

    public static let thresholdRange: ClosedRange<Float> = -70 ... -5
    public static let depthRange: ClosedRange<Float> = -40 ... -3
    public static let attackRange: ClosedRange<Float> = 5 ... 1_000
    public static let holdRange: ClosedRange<Float> = 0 ... 5_000
    public static let releaseRange: ClosedRange<Float> = 50 ... 5_000

    public var clamped: DuckingSettings {
        func c(_ v: Float, _ r: ClosedRange<Float>, _ d: Float) -> Float { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : d }
        var s = self
        s.thresholdDB = c(thresholdDB, Self.thresholdRange, -35)
        s.depthDB = c(depthDB, Self.depthRange, -15)
        s.attackMs = c(attackMs, Self.attackRange, 80)
        s.holdMs = c(holdMs, Self.holdRange, 500)
        s.releaseMs = c(releaseMs, Self.releaseRange, 900)
        return s
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DuckingSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        thresholdDB = (try? c.decodeIfPresent(Float.self, forKey: .thresholdDB)) ?? d.thresholdDB
        depthDB = (try? c.decodeIfPresent(Float.self, forKey: .depthDB)) ?? d.depthDB
        attackMs = (try? c.decodeIfPresent(Float.self, forKey: .attackMs)) ?? d.attackMs
        holdMs = (try? c.decodeIfPresent(Float.self, forKey: .holdMs)) ?? d.holdMs
        releaseMs = (try? c.decodeIfPresent(Float.self, forKey: .releaseMs)) ?? d.releaseMs
        self = clamped
    }
}

/// Lock-free ducking controls shared between the UI and the audio thread.
public final class DuckingControls: @unchecked Sendable {
    public let enabled = AtomicBool(false)
    public let thresholdDB = AtomicFloat(-35)
    public let depthDB = AtomicFloat(-15)
    public let attackMs = AtomicFloat(80)
    public let holdMs = AtomicFloat(500)
    public let releaseMs = AtomicFloat(900)
    /// Current reduction applied to ducked channels (0 ... depth), for the UI.
    public let reductionDB = AtomicFloat(0)

    public init() {}

    public var settings: DuckingSettings {
        get {
            var s = DuckingSettings()
            s.enabled = enabled.value; s.thresholdDB = thresholdDB.value; s.depthDB = depthDB.value
            s.attackMs = attackMs.value; s.holdMs = holdMs.value; s.releaseMs = releaseMs.value
            return s
        }
        set {
            let s = newValue.clamped
            enabled.value = s.enabled; thresholdDB.value = s.thresholdDB; depthDB.value = s.depthDB
            attackMs.value = s.attackMs; holdMs.value = s.holdMs; releaseMs.value = s.releaseMs
        }
    }
}

/// Ducking envelope (audio thread). `step` is called once per block with the loudest trigger
/// channel's peak and returns the gain in dB for ducked channels at the end of the block.
public struct Ducker {
    public private(set) var gainDB: Float = 0
    private var holdLeft: Float = 0

    public init() {}

    public mutating func step(triggerPeakDB: Float, seconds dt: Float, settings s: DuckingSettings) -> Float {
        guard s.enabled, dt > 0 else {
            gainDB = 0
            holdLeft = 0
            return 0
        }
        let depth = min(0, s.depthDB)
        if triggerPeakDB >= s.thresholdDB {
            holdLeft = s.holdMs / 1_000
            // Linear in dB: the full depth is reached after `attackMs`.
            gainDB = max(depth, gainDB + depth * dt / max(s.attackMs / 1_000, 0.001))
        } else if holdLeft > 0 {
            holdLeft -= dt
        } else {
            gainDB = min(0, gainDB - depth * dt / max(s.releaseMs / 1_000, 0.001))
        }
        return gainDB
    }
}

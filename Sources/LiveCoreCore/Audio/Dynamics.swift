#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Feed-forward, stereo-linked peak compressor with hard/soft knee.
/// Real-time safe: `process` performs no allocation, no locking, no system calls.
/// Parameters are plain stored values; the engine updates them from the UI through
/// `AtomicFloat`s and copies them in at the start of each render block.
public struct Compressor: Sendable {
    public var thresholdDB: Float = -18
    public var ratio: Float = 3
    public var kneeDB: Float = 6
    public var attackSeconds: Float = 0.010
    public var releaseSeconds: Float = 0.150
    public var makeupDB: Float = 0
    public private(set) var sampleRate: Float
    public private(set) var gainReductionDB: Float = 0   // current envelope (positive dB)

    public init(sampleRate: Float) { self.sampleRate = sampleRate }

    /// Static gain computer: dB of reduction for an input level in dB.
    public func staticReduction(inputDB x: Float) -> Float {
        let slope = 1 - 1 / max(ratio, 1)
        let over = x - thresholdDB
        if kneeDB > 0 {
            if 2 * over < -kneeDB { return 0 }
            if 2 * abs(over) <= kneeDB {
                let t = over + kneeDB / 2
                return slope * t * t / (2 * kneeDB)
            }
            return slope * over
        }
        return over > 0 ? slope * over : 0
    }

    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) {
        let aC = AudioMath.timeConstantCoeff(seconds: attackSeconds, sampleRate: sampleRate)
        let rC = AudioMath.timeConstantCoeff(seconds: releaseSeconds, sampleRate: sampleRate)
        var env = gainReductionDB
        for i in 0..<frames {
            let l = left[i]
            let r = right?[i] ?? l
            let x = AudioMath.linearToDB(max(abs(l), abs(r)))
            let target = staticReduction(inputDB: x)
            let c = target > env ? aC : rC
            env = target + c * (env - target)
            let g = AudioMath.dbToLinear(makeupDB - env)
            left[i] = l * g
            right?[i] = r * g
        }
        gainReductionDB = env
    }
}

/// Brick-wall style peak limiter without look-ahead: instant attack (the gain reduction for a
/// sample is applied to that same sample), exponential release, and a final safety clamp at the
/// ceiling. Because there is no look-ahead, fast transients are clamped hard rather than
/// smoothly — acceptable as a protective output limiter, documented in KNOWN_ISSUES.
public struct Limiter: Sendable {
    public var ceilingDB: Float = -1
    public var releaseSeconds: Float = 0.080
    public private(set) var sampleRate: Float
    public private(set) var gainReductionDB: Float = 0

    public init(sampleRate: Float) { self.sampleRate = sampleRate }

    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) {
        let rC = AudioMath.timeConstantCoeff(seconds: releaseSeconds, sampleRate: sampleRate)
        let ceiling = AudioMath.dbToLinear(ceilingDB)
        var env = gainReductionDB
        for i in 0..<frames {
            let l = left[i]
            let r = right?[i] ?? l
            let x = AudioMath.linearToDB(max(abs(l), abs(r)))
            let target = max(0, x - ceilingDB)
            env = target > env ? target : target + rC * (env - target)
            let g = AudioMath.dbToLinear(-env)
            left[i] = min(max(l * g, -ceiling), ceiling)
            right?[i] = min(max(r * g, -ceiling), ceiling)
        }
        gainReductionDB = env
    }
}

/// Stereo-linked noise gate with hysteresis and hold. Closes to `rangeDB` (not hard zero by
/// default) so room tone does not "pump". Real-time safe, like the other processors.
public struct NoiseGate: Sendable {
    public var thresholdDB: Float = -50
    /// The gate closes only when the level falls this far below the threshold (prevents chatter).
    public var hysteresisDB: Float = 4
    public var rangeDB: Float = -80
    public var attackSeconds: Float = 0.002
    public var holdSeconds: Float = 0.060
    public var releaseSeconds: Float = 0.150
    public private(set) var sampleRate: Float
    public private(set) var isOpen = false
    private var gain: Float
    private var holdRemaining = 0

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
        gain = AudioMath.dbToLinear(-80)
    }

    /// Current attenuation in dB (positive; 0 = fully open).
    public var gainReductionDB: Float { -AudioMath.linearToDB(gain) }

    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) {
        let aC = AudioMath.timeConstantCoeff(seconds: attackSeconds, sampleRate: sampleRate)
        let rC = AudioMath.timeConstantCoeff(seconds: releaseSeconds, sampleRate: sampleRate)
        let openLin = AudioMath.dbToLinear(thresholdDB)
        let closeLin = AudioMath.dbToLinear(thresholdDB - max(hysteresisDB, 0))
        let floorGain = AudioMath.dbToLinear(min(rangeDB, 0))
        let holdSamples = Int(holdSeconds * sampleRate)
        var g = gain
        var open = isOpen
        var hold = holdRemaining
        for i in 0..<frames {
            let l = left[i]
            let r = right?[i] ?? l
            let level = max(abs(l), abs(r))
            if level >= openLin {
                open = true
                hold = holdSamples
            } else if open && level < closeLin {
                if hold > 0 { hold -= 1 } else { open = false }
            }
            let target: Float = open ? 1 : floorGain
            let c = target > g ? aC : rC
            g = target + c * (g - target)
            left[i] = l * g
            right?[i] = r * g
        }
        gain = g
        isOpen = open
        holdRemaining = hold
    }
}

/// Click-free gain changes: linearly ramps from the previous to the new gain over one block.
public struct GainRamp: Sendable {
    public private(set) var current: Float
    public init(initial: Float = 1) { current = initial }

    public mutating func apply(target: Float, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) {
        guard frames > 0 else { return }
        if current == target {
            if target == 1 { return }
            for i in 0..<frames { left[i] *= target; right?[i] *= target }
            return
        }
        let step = (target - current) / Float(frames)
        var g = current
        for i in 0..<frames {
            g += step
            left[i] *= g
            right?[i] *= g
        }
        current = target
    }
}

/// UI-side meter ballistics (runs on the main thread from polled peaks).
public struct MeterBallistics: Sendable {
    public var decayDBPerSecond: Float = 24
    public var holdSeconds: Double = 1.5
    public private(set) var levelDB: Float = AudioMath.silenceDB
    public private(set) var peakHoldDB: Float = AudioMath.silenceDB
    private var peakHoldTime: Double = 0

    public init() {}

    public mutating func update(peakLinear: Float, dt: Double, now: Double) {
        let inDB = AudioMath.linearToDB(peakLinear)
        let decayed = levelDB - decayDBPerSecond * Float(dt)
        levelDB = max(inDB, max(decayed, AudioMath.silenceDB))
        if inDB >= peakHoldDB || now - peakHoldTime > holdSeconds {
            peakHoldDB = inDB >= peakHoldDB ? inDB : levelDB
            peakHoldTime = now
        }
    }
}

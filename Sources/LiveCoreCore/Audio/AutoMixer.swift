#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Gain-sharing automatic microphone mixer (0.65.0), in the style of Dan Dugan's design:
/// every microphone in the auto-mix group gets the share of the total that its own level is,
///
///     gain_i = sqrt(w_i / Σ w_j)      w = smoothed power × weight
///
/// so one talker comes through at (almost) full level while the open but quiet microphones go
/// down; two talkers get −3 dB each, and with nobody talking every microphone sits at
/// 1/N (−10·log10 N dB), which keeps the room sound constant instead of gating it. The sum of
/// the microphones' power stays the same as one open microphone (no build-up of noise and
/// reverb, less feedback risk). No threshold to set.
///
/// Real time: the mixer measures each channel's pre-fader power per block, then uses these
/// helpers (no allocation) to set the gain the next block ramps to. One block of delay
/// (about 10 ms) is inaudible for speech.
public enum AutoMixer {
    /// Silence floor added to every channel (−100 dBFS power), so a silent group shares equally.
    public static let floorPower: Float = 1e-10
    /// Lowest gain a channel is turned down to.
    public static let minGainDB: Float = -60
    /// Operator weight: + makes a channel win more often (the chair's microphone), − less.
    public static let weightRange: ClosedRange<Float> = -12 ... 12
    /// Level detector time constants: fast attack (speech onsets), slower release (no pumping
    /// between words).
    public static let attackSeconds: Float = 0.005
    public static let releaseSeconds: Float = 0.15

    /// One-pole detector on block power.
    @inline(__always)
    public static func smooth(_ env: Float, power: Float, seconds: Float) -> Float {
        let p = power.isFinite ? max(power, 0) : 0
        let tau = p > env ? attackSeconds : releaseSeconds
        let a = 1 - expf(-max(seconds, 0) / tau)
        return env + (p - env) * a
    }

    /// The channel's weighted share input: power (with the floor) times the weight.
    @inline(__always)
    public static func weighted(_ env: Float, weightDB: Float) -> Float {
        let w = min(max(weightDB.isFinite ? weightDB : 0, weightRange.lowerBound), weightRange.upperBound)
        return (max(env, 0) + floorPower) * powf(10, w / 10)
    }

    /// Linear amplitude gain for a channel's weighted value given the group total.
    @inline(__always)
    public static func gain(weighted w: Float, total: Float) -> Float {
        guard total > 0, w > 0 else { return AudioMath.dbToLinear(minGainDB) }
        return max(sqrtf(min(w / total, 1)), AudioMath.dbToLinear(minGainDB))
    }

    /// Mean-square power of a stereo block (both sides averaged).
    @inline(__always)
    public static func power(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Float {
        guard frames > 0 else { return 0 }
        var s: Float = 0
        for i in 0..<frames { s += left[i] * left[i] + right[i] * right[i] }
        return s / Float(2 * frames)
    }

    /// Whole-group calculation for steady levels (tests, previews): gains for the given powers.
    /// A group of fewer than two channels is left alone (gain 1).
    public static func gains(powers: [Float], weightsDB: [Float]? = nil) -> [Float] {
        guard powers.count >= 2 else { return powers.map { _ in 1 } }
        let w = powers.indices.map { weighted(powers[$0], weightDB: weightsDB?[$0] ?? 0) }
        let total = w.reduce(0, +)
        return w.map { gain(weighted: $0, total: total) }
    }
}

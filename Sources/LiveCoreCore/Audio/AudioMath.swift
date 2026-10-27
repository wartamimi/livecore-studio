#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum AudioMath {
    public static let silenceDB: Float = -120

    @inline(__always) public static func dbToLinear(_ db: Float) -> Float {
        db <= silenceDB ? 0 : powf(10, db / 20)
    }
    @inline(__always) public static func linearToDB(_ lin: Float) -> Float {
        lin <= 1e-6 ? silenceDB : 20 * log10f(lin)
    }
    /// One-pole smoothing coefficient for a time constant in seconds.
    @inline(__always) public static func timeConstantCoeff(seconds: Float, sampleRate: Float) -> Float {
        seconds <= 0 ? 0 : expf(-1 / (seconds * sampleRate))
    }
    /// Peak absolute value of a buffer.
    @inline(__always) public static func peak(_ p: UnsafePointer<Float>, count: Int) -> Float {
        var m: Float = 0
        for i in 0..<count { let v = abs(p[i]); if v > m { m = v } }
        return m
    }
}

/// Fader law used by the UI: maps fader position 0...1 to dB (-inf ... +10 dB).
/// 0.75 ≈ 0 dB, so unity gain sits at three quarters of the travel like most console faders.
public enum FaderLaw {
    public static func db(forPosition p: Double) -> Float {
        let p = min(max(p, 0), 1)
        if p <= 0.0001 { return AudioMath.silenceDB }
        if p >= 0.75 { return Float((p - 0.75) / 0.25 * 10) }      // 0 ... +10 dB
        if p >= 0.25 { return Float((p - 0.75) / 0.5 * 30) }        // -30 ... 0 dB
        return Float(-30 - (0.25 - p) / 0.25 * 60)                    // -90 ... -30 dB
    }
    public static func position(forDB db: Float) -> Double {
        if db <= -90 { return 0 }
        if db >= 0 { return min(1, 0.75 + Double(db) / 10 * 0.25) }
        if db >= -30 { return 0.75 + Double(db) / 30 * 0.5 }
        return 0.25 - (Double(-db) - 30) / 60 * 0.25
    }
}

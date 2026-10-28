#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Loudness meter after ITU-R BS.1770-4 / EBU R128 (48 kHz stereo): K-weighting, momentary
/// (400 ms), short-term (3 s) and gated integrated loudness in LUFS.
///
/// Real-time safe: every buffer is allocated in `init`; `process` only does arithmetic. The
/// integrated value uses a histogram of 0.1 LU bins instead of keeping every block, so a show of
/// any length uses the same memory (accuracy ±0.05 LU).
public struct LoudnessMeter {
    public static let silence = -Double.infinity
    /// Samples per 100 ms step at 48 kHz.
    public static let stepFrames = 4_800
    private static let histogramMin = -70.0
    private static let binWidth = 0.1
    private static let binCount = 800   // -70 ... +10 LUFS

    // K-weighting biquads (BS.1770 coefficients for 48 kHz), direct form I state per channel.
    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        @inline(__always) mutating func run(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
    private static func shelf() -> Biquad {
        Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585)
    }
    private static func highPass() -> Biquad {
        Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)
    }
    private var shelfL = LoudnessMeter.shelf(), shelfR = LoudnessMeter.shelf()
    private var hpL = LoudnessMeter.highPass(), hpR = LoudnessMeter.highPass()

    /// Sum of squares (L + R) of the last 30 steps (3 s), ring indexed by `stepIndex`.
    private var steps: [Double]
    private var stepIndex = 0
    private var stepsFilled = 0
    private var acc = 0.0
    private var accFrames = 0
    private var binCounts: [Int]
    private var binEnergy: [Double]

    public private(set) var momentary = LoudnessMeter.silence
    public private(set) var shortTerm = LoudnessMeter.silence
    public private(set) var integrated = LoudnessMeter.silence
    /// Gated 400 ms blocks counted in the integrated value.
    public private(set) var integratedBlocks = 0

    public init() {
        steps = Array(repeating: 0, count: 30)
        binCounts = Array(repeating: 0, count: Self.binCount)
        binEnergy = Array(repeating: 0, count: Self.binCount)
    }

    /// Loudness of a mean square energy summed over both channels.
    @inline(__always) public static func lufs(meanSquareSum z: Double) -> Double {
        z > 0 ? -0.691 + 10 * log10(z) : silence
    }

    public mutating func reset() {
        self = LoudnessMeter()
    }

    public mutating func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        var i = 0
        while i < frames {
            let n = min(frames - i, Self.stepFrames - accFrames)
            var sum = acc
            for k in i..<(i + n) {
                let l = hpL.run(shelfL.run(Double(left[k])))
                let r = hpR.run(shelfR.run(Double(right[k])))
                sum += l * l + r * r
            }
            acc = sum
            accFrames += n
            i += n
            if accFrames == Self.stepFrames { finishStep() }
        }
    }

    private mutating func finishStep() {
        steps[stepIndex] = acc
        stepIndex = (stepIndex + 1) % steps.count
        stepsFilled = min(stepsFilled + 1, steps.count)
        acc = 0
        accFrames = 0
        if stepsFilled >= 4 {
            let z = window(4)
            momentary = Self.lufs(meanSquareSum: z)
            if momentary > Self.histogramMin {
                let bin = min(Self.binCount - 1, max(0, Int((momentary - Self.histogramMin) / Self.binWidth)))
                binCounts[bin] += 1
                binEnergy[bin] += z
                integratedBlocks += 1
                updateIntegrated()
            }
        }
        if stepsFilled >= 30 { shortTerm = Self.lufs(meanSquareSum: window(30)) }
    }

    /// Mean square (L + R) of the last `count` steps.
    private func window(_ count: Int) -> Double {
        var s = 0.0
        for k in 1...count { s += steps[(stepIndex - k + steps.count) % steps.count] }
        return s / Double(count * Self.stepFrames)
    }

    private mutating func updateIntegrated() {
        var energy = 0.0, count = 0
        for b in 0..<Self.binCount where binCounts[b] > 0 { energy += binEnergy[b]; count += binCounts[b] }
        guard count > 0 else { integrated = Self.silence; return }
        let relativeGate = Self.lufs(meanSquareSum: energy / Double(count)) - 10
        let firstBin = max(0, Int(((relativeGate - Self.histogramMin) / Self.binWidth).rounded(.up)))
        energy = 0; count = 0
        if firstBin < Self.binCount {
            for b in firstBin..<Self.binCount where binCounts[b] > 0 { energy += binEnergy[b]; count += binCounts[b] }
        }
        integrated = count > 0 ? Self.lufs(meanSquareSum: energy / Double(count)) : Self.silence
    }
}

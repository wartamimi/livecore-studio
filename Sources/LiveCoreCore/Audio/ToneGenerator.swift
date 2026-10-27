/// Sine test tone (line-up tone, 1 kHz at -18 dBFS by default, like the tone sent with colour
/// bars). Phase-continuous across calls; real-time safe (no allocation).
public struct ToneGenerator: Sendable {
    public var frequency: Double
    public var levelDB: Double
    public let sampleRate: Double
    private var phase: Double = 0

    public init(frequency: Double = 1000, levelDB: Double = -18, sampleRate: Double = 48_000) {
        self.frequency = frequency; self.levelDB = levelDB; self.sampleRate = sampleRate
    }

    public static let frequencyRange: ClosedRange<Double> = 20...20_000
    public static let levelRange: ClosedRange<Double> = -60...0

    /// Fills `count` samples (mono; copy to both sides for a stereo channel).
    public mutating func fill(_ out: UnsafeMutablePointer<Float>, count: Int) {
        let f = min(max(frequency, Self.frequencyRange.lowerBound), Self.frequencyRange.upperBound)
        let amp = Float(AudioMath.dbToLinear(Float(min(max(levelDB, Self.levelRange.lowerBound), Self.levelRange.upperBound))))
        let step = f / sampleRate
        for i in 0..<count {
            out[i] = amp * Float(Self.sine(phase))
            phase += step
            if phase >= 1 { phase -= 1 }
        }
    }

    /// sin(2π p) for p in 0..<1, Foundation-free (range-reduced Taylor series, error < 1e-9).
    static func sine(_ p: Double) -> Double {
        var x = (p - p.rounded(.down)) * 2 * Double.pi   // 0..<2π
        if x > Double.pi { x -= 2 * Double.pi }            // -π...π
        if x > Double.pi / 2 { x = Double.pi - x } else if x < -Double.pi / 2 { x = -Double.pi - x }
        let x2 = x * x
        var term = x, sum = x
        var n = 1.0
        for _ in 0..<10 { term *= -x2 / ((n + 1) * (n + 2)); sum += term; n += 2 }
        return sum
    }
}

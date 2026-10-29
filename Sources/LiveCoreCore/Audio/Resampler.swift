/// Streaming stereo sample-rate converter (linear interpolation).
///
/// Used to bring audio that arrives at another rate (e.g. 44.1 kHz video-file audio) to the
/// mixer's 48 kHz. Linear interpolation is adequate for upsampling speech/music beds; it is not
/// a mastering-grade converter (documented in docs/KNOWN_ISSUES.md).
/// Real-time safe: `process` performs no allocation, no locking and no system calls.
public struct LinearResampler: Sendable {
    /// Input samples consumed per output sample (inputRate / outputRate).
    public private(set) var ratio: Double
    /// Read position relative to the current input block; -1 addresses the carried-over sample.
    private var position: Double = -1
    private var lastL: Float = 0
    private var lastR: Float = 0
    private var primed = false

    public init(inputRate: Double, outputRate: Double) {
        precondition(inputRate > 0 && outputRate > 0)
        ratio = inputRate / outputRate
    }

    public var isPassthrough: Bool { ratio == 1 }

    /// Output capacity needed for `inputFrames` input frames.
    public func maxOutputFrames(forInput inputFrames: Int) -> Int {
        Int((Double(inputFrames) / ratio).rounded(.up)) + 2
    }

    public mutating func reset() { position = -1; lastL = 0; lastR = 0; primed = false }

    /// Converts one block. Returns the number of output frames written (never more than
    /// `outputCapacity`; size the output with `maxOutputFrames(forInput:)` to never lose input).
    public mutating func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, inputFrames n: Int,
                                 outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>,
                                 outputCapacity: Int) -> Int {
        guard n > 0 else { return 0 }
        if !primed { lastL = inLeft[0]; lastR = inRight[0]; primed = true }
        var t = position
        var out = 0
        let limit = Double(n - 1)
        while t < limit && out < outputCapacity {
            let i = Int(t.rounded(.down))      // -1 ... n-2
            let f = Float(t - Double(i))
            let l0 = i < 0 ? lastL : inLeft[i], r0 = i < 0 ? lastR : inRight[i]
            let l1 = inLeft[i + 1], r1 = inRight[i + 1]
            outLeft[out] = l0 + (l1 - l0) * f
            outRight[out] = r0 + (r1 - r0) * f
            out += 1
            t += ratio
        }
        if t < limit { t = limit }   // capacity exhausted: drop the rest of this block
        position = t - Double(n)
        lastL = inLeft[n - 1]; lastR = inRight[n - 1]
        return out
    }
}

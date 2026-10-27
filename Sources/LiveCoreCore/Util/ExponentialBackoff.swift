/// Reconnect schedule for the streaming engine.
/// delay(n) = min(maxDelay, initial * multiplier^n), with optional deterministic jitter.
public struct ExponentialBackoff: Equatable, Codable, Sendable {
    public var initialDelay: Double
    public var multiplier: Double
    public var maxDelay: Double
    public var maxAttempts: Int   // 0 = unlimited
    public var jitterFraction: Double

    public init(initialDelay: Double = 1, multiplier: Double = 2, maxDelay: Double = 30,
                maxAttempts: Int = 10, jitterFraction: Double = 0.1) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.jitterFraction = jitterFraction
    }

    /// Returns nil when attempts are exhausted. `random01` is injected for testability.
    public func delay(forAttempt attempt: Int, random01: Double = 0.5) -> Double? {
        if maxAttempts > 0 && attempt >= maxAttempts { return nil }
        var d = initialDelay
        for _ in 0..<max(0, attempt) {
            d *= multiplier
            if d >= maxDelay { d = maxDelay; break }
        }
        d = min(d, maxDelay)
        let jitter = d * jitterFraction * (random01 * 2 - 1)
        return max(0, d + jitter)
    }
}

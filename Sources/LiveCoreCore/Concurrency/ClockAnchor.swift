import CAtomics

/// Publishes a (sampleIndex, hostTime) pair from the audio render thread to another thread
/// without locks (sequence lock). The reader retries if it raced with a write.
/// Used to timestamp program audio: host(n) = anchorHost + (n - anchorIndex) / sampleRate.
public final class ClockAnchor: @unchecked Sendable {
    private let seq: UnsafeMutablePointer<lc_atomic_u64>
    private let index: UnsafeMutablePointer<lc_atomic_u64>
    private let host: UnsafeMutablePointer<lc_atomic_u64>   // Double bit pattern (seconds)

    public init() {
        seq = .allocate(capacity: 1); index = .allocate(capacity: 1); host = .allocate(capacity: 1)
        lc_atomic_u64_init(seq, 0); lc_atomic_u64_init(index, 0); lc_atomic_u64_init(host, 0)
    }
    deinit { seq.deallocate(); index.deallocate(); host.deallocate() }

    /// Single writer only.
    public func publish(sampleIndex: UInt64, hostSeconds: Double) {
        let s = lc_atomic_u64_load_relaxed(seq)
        lc_atomic_u64_store_release(seq, s &+ 1)
        lc_atomic_u64_store_release(index, sampleIndex)
        lc_atomic_u64_store_release(host, hostSeconds.bitPattern)
        lc_atomic_u64_store_release(seq, s &+ 2)
    }

    /// Returns nil until the first publish.
    public func read() -> (sampleIndex: UInt64, hostSeconds: Double)? {
        for _ in 0..<1000 {
            let s1 = lc_atomic_u64_load_acquire(seq)
            if s1 & 1 == 1 { continue }
            let i = lc_atomic_u64_load_acquire(index)
            let h = lc_atomic_u64_load_acquire(host)
            let s2 = lc_atomic_u64_load_acquire(seq)
            if s1 == s2 { return s1 == 0 ? nil : (i, Double(bitPattern: h)) }
        }
        return nil
    }

    public func hostTime(ofSample n: UInt64, sampleRate: Double) -> Double? {
        guard let a = read() else { return nil }
        return a.hostSeconds + (Double(n) - Double(a.sampleIndex)) / sampleRate
    }
}

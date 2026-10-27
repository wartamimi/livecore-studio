import CAtomics

/// Single-producer / single-consumer lock-free ring buffer of `Float` samples.
///
/// Used to move audio between threads that must never block:
///   capture queue (producer)  ->  audio render callback (consumer)
///   audio render callback (producer) -> encoder / recorder queue (consumer)
///
/// Storage is allocated once at init. `write` and `read` never allocate, never lock and
/// never call into the OS, so they are safe on the Core Audio IO thread.
/// Exactly one thread may call `write`/`writeSilence`, and exactly one thread may call
/// `read`/`skip`/`availableToRead` from the consumer side.
public final class SPSCFloatRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    // Monotonic positions (never wrap in practice: 2^64 samples).
    private let writePos: UnsafeMutablePointer<lc_atomic_u64>
    private let readPos: UnsafeMutablePointer<lc_atomic_u64>

    /// - Parameter minimumCapacity: rounded up to the next power of two.
    public init(minimumCapacity: Int) {
        precondition(minimumCapacity > 0)
        var cap = 1
        while cap < minimumCapacity { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        buffer = .allocate(capacity: cap)
        buffer.initialize(repeating: 0, count: cap)
        writePos = .allocate(capacity: 1)
        readPos = .allocate(capacity: 1)
        lc_atomic_u64_init(writePos, 0)
        lc_atomic_u64_init(readPos, 0)
    }

    deinit {
        buffer.deallocate()
        writePos.deallocate()
        readPos.deallocate()
    }

    public var availableToRead: Int {
        Int(lc_atomic_u64_load_acquire(writePos) &- lc_atomic_u64_load_acquire(readPos))
    }

    public var availableToWrite: Int { capacity - availableToRead }

    /// Total samples ever written (producer position). Used as a sample clock index.
    public var totalWritten: UInt64 { lc_atomic_u64_load_acquire(writePos) }
    /// Total samples ever consumed (read or skipped).
    public var totalRead: UInt64 { lc_atomic_u64_load_acquire(readPos) }

    /// Writes up to `count` samples. Returns the number actually written (overflow drops the tail).
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let w = lc_atomic_u64_load_relaxed(writePos)
        let r = lc_atomic_u64_load_acquire(readPos)
        let free = capacity - Int(w &- r)
        let n = min(count, free)
        if n <= 0 { return 0 }
        let start = Int(w & UInt64(mask))
        let first = min(n, capacity - start)
        (buffer + start).update(from: source, count: first)
        if n > first { buffer.update(from: source + first, count: n - first) }
        lc_atomic_u64_store_release(writePos, w &+ UInt64(n))
        return n
    }

    /// Reads up to `count` samples into `destination`. Returns number read; the remainder of
    /// `destination` is left untouched (caller decides whether to zero-fill = underrun).
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let r = lc_atomic_u64_load_relaxed(readPos)
        let w = lc_atomic_u64_load_acquire(writePos)
        let n = min(count, Int(w &- r))
        if n <= 0 { return 0 }
        let start = Int(r & UInt64(mask))
        let first = min(n, capacity - start)
        destination.update(from: buffer + start, count: first)
        if n > first { (destination + first).update(from: buffer, count: n - first) }
        lc_atomic_u64_store_release(readPos, r &+ UInt64(n))
        return n
    }

    /// Consumer-side discard (used to bound latency when the producer runs ahead).
    @discardableResult
    public func skip(_ count: Int) -> Int {
        let r = lc_atomic_u64_load_relaxed(readPos)
        let w = lc_atomic_u64_load_acquire(writePos)
        let n = min(count, Int(w &- r))
        if n > 0 { lc_atomic_u64_store_release(readPos, r &+ UInt64(n)) }
        return max(n, 0)
    }
}

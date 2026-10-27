import CAtomics

/// Lock-free Float storage (bit-cast into a 32-bit atomic). Safe to read/write from the
/// audio render thread: no locks, no allocation after init.
public final class AtomicFloat: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<lc_atomic_u32>

    public init(_ value: Float = 0) {
        storage = .allocate(capacity: 1)
        lc_atomic_u32_init(storage, value.bitPattern)
    }
    deinit { storage.deallocate() }

    public var value: Float {
        get { Float(bitPattern: lc_atomic_u32_load(storage)) }
        set { lc_atomic_u32_store(storage, newValue.bitPattern) }
    }

    /// Atomically raise the stored value to `candidate` if larger (used for peak-hold metering).
    public func storeMax(_ candidate: Float) {
        while true {
            let current = lc_atomic_u32_load(storage)
            if Float(bitPattern: current) >= candidate { return }
            if lc_atomic_u32_cas(storage, current, candidate.bitPattern) { return }
        }
    }

    /// Read and reset to `reset` in one atomic step (UI side "consume peak since last poll").
    public func exchange(_ newValue: Float) -> Float {
        Float(bitPattern: lc_atomic_u32_exchange(storage, newValue.bitPattern))
    }
}

/// Lock-free Bool flag.
public final class AtomicBool: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<lc_atomic_u32>
    public init(_ value: Bool = false) {
        storage = .allocate(capacity: 1)
        lc_atomic_u32_init(storage, value ? 1 : 0)
    }
    deinit { storage.deallocate() }
    public var value: Bool {
        get { lc_atomic_u32_load(storage) != 0 }
        set { lc_atomic_u32_store(storage, newValue ? 1 : 0) }
    }
}

/// Lock-free monotonically increasing counter (dropped frames, bytes sent, ...).
public final class AtomicCounter: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<lc_atomic_u64>
    public init(_ value: UInt64 = 0) {
        storage = .allocate(capacity: 1)
        lc_atomic_u64_init(storage, value)
    }
    deinit { storage.deallocate() }
    @discardableResult
    public func add(_ v: UInt64 = 1) -> UInt64 { lc_atomic_u64_fetch_add(storage, v) &+ v }
    public var value: UInt64 { lc_atomic_u64_load_acquire(storage) }
    public func reset() { lc_atomic_u64_store_release(storage, 0) }
}

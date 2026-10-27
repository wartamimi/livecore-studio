#if os(macOS)
import os

/// Thin wrapper over os_unfair_lock with a stable heap address (required: os_unfair_lock must
/// not move in memory, so it cannot live inline in a Swift class property).
public final class UnfairLock: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    @inline(__always)
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try body()
    }

    /// Non-blocking variant for real-time threads: returns nil instead of waiting.
    @inline(__always)
    public func withTryLock<T>(_ body: () throws -> T) rethrows -> T? {
        guard os_unfair_lock_trylock(lock) else { return nil }
        defer { os_unfair_lock_unlock(lock) }
        return try body()
    }
}

/// A value protected by an UnfairLock.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = UnfairLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public func read<T>(_ body: (Value) throws -> T) rethrows -> T { try lock.withLock { try body(value) } }
    public func mutate<T>(_ body: (inout Value) throws -> T) rethrows -> T { try lock.withLock { try body(&value) } }
    public var current: Value { lock.withLock { value } }
}
#endif

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

#if os(macOS)
import Dispatch

/// Runs a handler with the newest posted value on a serial queue of its own (0.58.1). Values
/// posted while the handler is still busy replace each other, so a slow consumer only ever
/// sees the latest one. Used to put monitor and output-window frames on screen without the
/// main thread: opening a window, a sheet or a menu no longer freezes Preview, Program or the
/// picture on an external display.
public final class LatestOnQueue<Value>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let slot = Locked<Value?>(nil)
    public init(label: String) { queue = DispatchQueue(label: label, qos: .userInteractive) }
    /// `merge` folds a new value into one still waiting (default: the new one replaces it).
    public func post(_ value: Value, merge: ((inout Value, Value) -> Void)? = nil,
                     _ handler: @escaping (Value) -> Void) {
        let schedule = slot.mutate { s -> Bool in
            guard var waiting = s else { s = value; return true }
            if let merge { merge(&waiting, value) } else { waiting = value }
            s = waiting
            return false
        }
        guard schedule else { return }
        queue.async { [slot] in
            guard let v = slot.mutate({ s -> Value? in let out = s; s = nil; return out }) else { return }
            handler(v)
        }
    }
}
#endif

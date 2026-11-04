#if os(macOS)
import AppKit
import LiveCoreCore

/// One insert slot: a loaded plug-in, or a placeholder for one that is missing / failed to load
/// (kept so the project keeps its settings).
public final class PluginSlot: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let descriptor: AudioPluginDescriptor
    /// Operator bypass (render thread reads it).
    public let bypassed = AtomicBool(false)
    /// `PluginFault` raw value set by the render thread when the plug-in had to be taken out.
    let faultCode = AtomicFloat(0)
    /// Highest render time / block time since the UI last read it (1 = 100 % of real time).
    public let load = AtomicFloat(0)
    var processor: PluginProcessor?
    /// Why there is no processor (missing plug-in, load error, blocked after a crash).
    public internal(set) var loadError: String?
    /// Last state known for this slot: what the project had, refreshed on every save. A
    /// placeholder or crashed plug-in saves this, so nothing is lost.
    public internal(set) var savedState: Data?
    // Render thread only.
    private var watchdog = PluginWatchdog()
    private let dryL: UnsafeMutablePointer<Float>
    private let dryR: UnsafeMutablePointer<Float>

    init(descriptor: AudioPluginDescriptor, processor: PluginProcessor?, loadError: String? = nil, savedState: Data? = nil) {
        self.descriptor = descriptor
        self.processor = processor
        self.loadError = loadError
        self.savedState = savedState
        dryL = .allocate(capacity: AudioMixerEngine.maxFrames); dryL.initialize(repeating: 0, count: AudioMixerEngine.maxFrames)
        dryR = .allocate(capacity: AudioMixerEngine.maxFrames); dryR.initialize(repeating: 0, count: AudioMixerEngine.maxFrames)
    }

    deinit { dryL.deallocate(); dryR.deallocate() }

    public var name: String { descriptor.name }
    public var isLoaded: Bool { processor != nil }
    public var outOfProcess: Bool { processor?.outOfProcess ?? false }
    public var latencySamples: Int { processor?.latencySamples ?? 0 }
    public var lastErrorCode: Int { processor?.lastErrorCode ?? 0 }
    public var fault: PluginFault { PluginFault(rawValue: Int(faultCode.value.rounded())) ?? .none }

    /// Operator-facing status line ("" when everything is fine).
    public var statusText: String {
        if let loadError { return loadError }
        switch fault {
        case .none: return ""
        case .renderErrors: return "Stopped: the plug-in kept failing (crashed or not responding; error \(lastErrorCode)). Bypassed."
        case .tooSlow: return "Stopped: too slow for real time (CPU). Bypassed."
        case .invalidOutput: return "Stopped: the plug-in produced invalid audio. Bypassed."
        case .crashed: return "Stopped: the plug-in crashed (its process ended). Bypassed."
        }
    }

    // MARK: Render thread

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard let processor, !bypassed.value, faultCode.value == 0 else { return }
        dryL.update(from: left, count: frames)
        dryR.update(from: right, count: frames)
        let t0 = HostClock.now()
        let ok = processor.process(left: left, right: right, frames: frames)
        let dt = HostClock.now() - t0
        var finite = true
        if ok {
            for i in 0..<frames where !left[i].isFinite || !right[i].isFinite { finite = false; break }
        }
        if !ok || !finite {
            left.update(from: dryL, count: frames)
            right.update(from: dryR, count: frames)
        }
        let block = Double(frames) / AudioMixerEngine.sampleRateHz
        load.storeMax(Float(dt / block))
        let f = watchdog.record(ok: ok, seconds: dt, blockSeconds: block, finite: finite)
        if f != .none { faultCode.value = Float(f.rawValue) }
    }

    // MARK: Main thread

    /// Current state (refreshes `savedState` when the plug-in is running normally).
    func captureState() -> Data? {
        if let processor, fault == .none, let s = processor.state() { savedState = s }
        return savedState
    }

    func close() {
        processor?.close()
        processor = nil
    }

    public func parameters() -> [PluginParameter] { processor?.parameters() ?? [] }
    public func setParameter(_ id: UInt64, normalized: Double) { processor?.setParameter(id, normalized: normalized) }
    public func display(_ id: UInt64, normalized: Double) -> String { processor?.display(id, normalized: normalized) ?? "" }
    public func openEditor(in container: NSView, resize: @escaping (NSSize) -> Void, completion: @escaping (NSSize?) -> Void) {
        guard let processor else { completion(nil); return }
        processor.openEditor(in: container, resize: resize, completion: completion)
    }
    public func editorResized(to size: NSSize) -> NSSize { processor?.editorResized(to: size) ?? size }
    public var editorResizable: Bool { processor?.editorResizable ?? false }
    public func closeEditor() { processor?.closeEditor() }
    /// Read-and-reset of the load meter (UI).
    public func takeLoad() -> Float { load.exchange(0) }
}

/// The insert chain of one mixer channel or the master bus. Edited on the main thread; the
/// render thread processes a snapshot it reads under a try-lock (never waits).
public final class PluginInsertChain: AudioInsertProcessing, @unchecked Sendable {
    public static let maxSlots = 8
    public static let didChange = Notification.Name("LiveCorePluginChainDidChange")
    private let lock = UnfairLock()
    private var rtSlots: [PluginSlot] = []
    private let active = AtomicBool(false)
    /// Main thread.
    public private(set) var slots: [PluginSlot] = []

    public init() {}

    public var insertsActive: Bool { active.value }

    public func processInserts(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        _ = lock.withTryLock { () -> Bool in
            for s in rtSlots { s.render(left: left, right: right, frames: frames) }
            return true
        }
    }

    private func publish() {
        let snapshot = slots
        lock.withLock { rtSlots = snapshot }
        active.value = snapshot.contains { $0.isLoaded }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public var isFull: Bool { slots.count >= Self.maxSlots }

    func append(_ slot: PluginSlot) {
        guard !isFull else { slot.close(); return }
        slots.append(slot)
        publish()
    }

    /// Replaces the whole chain (project load); closes the old plug-ins.
    func replaceAll(_ new: [PluginSlot]) {
        let old = slots
        slots = Array(new.prefix(Self.maxSlots))
        publish()
        old.forEach { $0.close() }
    }

    func replace(_ id: UUID, with slot: PluginSlot) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { slot.close(); return }
        let old = slots[i]
        slots[i] = slot
        publish()
        old.close()
    }

    public func remove(_ id: UUID) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        let old = slots.remove(at: i)
        publish()
        old.close()
    }

    public func move(_ id: UUID, by offset: Int) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), slots.count - 1)
        guard i != j else { return }
        slots.swapAt(i, j)
        publish()
    }

    public func setBypassed(_ id: UUID, _ on: Bool) {
        slots.first { $0.id == id }?.bypassed.value = on
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func removeAll() { replaceAll([]) }

    /// Project form; nil when there are no inserts.
    public func projectSlots() -> [ProjectPluginSlot]? {
        slots.isEmpty ? nil : slots.map { ProjectPluginSlot(plugin: $0.descriptor, bypassed: $0.bypassed.value, state: $0.captureState()) }
    }

    /// Total latency the active plug-ins add (samples).
    public var latencySamples: Int { slots.filter { !$0.bypassed.value && $0.fault == .none }.reduce(0) { $0 + $1.latencySamples } }
}
#endif

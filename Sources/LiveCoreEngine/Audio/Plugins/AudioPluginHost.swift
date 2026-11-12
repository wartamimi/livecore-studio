#if os(macOS)
import AVFoundation
import AudioToolbox
import CVST3
import Foundation
import LiveCoreCore

/// Where LiveCore keeps plug-in files (scan cache, crash guard).
enum PluginFiles {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("LiveCore Studio/Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Command-line mode of the app binary that scans one VST 3 bundle in a separate process, so a
/// plug-in that crashes while loading cannot take the app down:
///   LiveCoreStudio --lc-vst3-scan /path/Plugin.vst3
public enum PluginScanChild {
    public static let flag = "--lc-vst3-scan"

    /// Call first thing in main(); returns only when the process is not a scanner.
    public static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        guard arguments.count >= 3, arguments[1] == flag else { return }
        var err = [CChar](repeating: 0, count: 512)
        if let json = lc_vst3_scan(arguments[2], &err, Int32(err.count)) {
            print("")
            print(String(cString: json))
            lc_vst3_free(json)
            fflush(stdout)
            exit(0)
        }
        print("LCERR:" + String(cString: err))
        fflush(stdout)
        exit(3)
    }
}

public struct PluginScanFailure: Hashable, Sendable {
    public let path: String
    public let reason: String
}

/// Installed effects: Audio Units from the system registry and VST 3 bundles from the standard
/// folders (each new or changed bundle scanned in a child process, results cached).
public final class PluginCatalog {
    public static let didChange = Notification.Name("LiveCorePluginCatalogDidChange")
    public private(set) var plugins: [AudioPluginDescriptor] = []
    public private(set) var failures: [PluginScanFailure] = []
    public private(set) var isScanning = false
    public private(set) var hasScanned = false
    /// Executable that understands `PluginScanChild.flag` (the app itself).
    public var scannerExecutable: URL? = Bundle.main.executableURL
    private let queue = DispatchQueue(label: "studio.livecore.plugin-scan", qos: .utility)

    public init() {}

    public static var vst3Folders: [URL] {
        [URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3")]
    }

    public var audioUnits: [AudioPluginDescriptor] { plugins.filter { $0.format == .audioUnit } }
    public var vst3: [AudioPluginDescriptor] { plugins.filter { $0.format == .vst3 } }

    /// Scans in the background (main-thread API). `force` ignores the VST 3 cache.
    public func scan(force: Bool = false, extraVST3: [URL] = [], completion: (() -> Void)? = nil) {
        guard !isScanning else { return }
        isScanning = true
        NotificationCenter.default.post(name: Self.didChange, object: self)
        let scanner = scannerExecutable
        queue.async {
            let aus = Self.scanAudioUnits()
            let (vst, failed) = Self.scanVST3(folders: Self.vst3Folders, extra: extraVST3, scanner: scanner, force: force)
            DispatchQueue.main.async {
                self.plugins = (aus + vst).sorted { ($0.vendor.lowercased(), $0.name.lowercased()) < ($1.vendor.lowercased(), $1.name.lowercased()) }
                self.failures = failed
                self.isScanning = false
                self.hasScanned = true
                Log.audio.info("plug-in scan: \(aus.count) Audio Units, \(vst.count) VST 3, \(failed.count) failed")
                NotificationCenter.default.post(name: Self.didChange, object: self)
                completion?()
            }
        }
    }

    public func descriptor(matching d: AudioPluginDescriptor) -> AudioPluginDescriptor? {
        plugins.first { $0.sameClass(as: d) }
    }

    static func scanAudioUnits() -> [AudioPluginDescriptor] {
        var out: [AudioPluginDescriptor] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0,
                                                 componentFlags: 0, componentFlagsMask: 0)
            for c in AVAudioUnitComponentManager.shared().components(matching: desc) {
                let d = c.audioComponentDescription
                let v3 = d.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0
                out.append(AudioPluginDescriptor(
                    format: .audioUnit,
                    identifier: FourCC.identifier(type: d.componentType, subtype: d.componentSubType, manufacturer: d.componentManufacturer),
                    name: c.name, vendor: c.manufacturerName.isEmpty ? "Unknown" : c.manufacturerName, version: c.versionString,
                    category: type == kAudioUnitType_MusicEffect ? "Music Effect" : "Effect", isV3: v3))
            }
        }
        return out
    }

    // MARK: VST 3

    private struct CacheEntry: Codable {
        var modified: Double
        var entries: [VST3ScanEntry]?
        var error: String?
    }

    private static var cacheURL: URL { PluginFiles.directory.appendingPathComponent("vst3-scan-cache.json") }

    static func bundles(in folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension.lowercased() == "vst3" {
            out.append(url)
            e.skipDescendants()
        }
        return out
    }

    static func scanVST3(folders: [URL], extra: [URL], scanner: URL?, force: Bool) -> ([AudioPluginDescriptor], [PluginScanFailure]) {
        var cache: [String: CacheEntry] = [:]
        if !force, let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode([String: CacheEntry].self, from: d) { cache = c }
        var newCache: [String: CacheEntry] = [:]
        var found: [AudioPluginDescriptor] = []
        var failures: [PluginScanFailure] = []
        var seen = Set<String>()
        for bundle in folders.flatMap(bundles(in:)) + extra {
            let path = bundle.path
            let modified = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
            var entry: CacheEntry
            if let c = cache[path], c.modified == modified { entry = c } else {
                entry = CacheEntry(modified: modified, entries: nil, error: nil)
                switch runScanner(scanner, path: path) {
                case let .success(list): entry.entries = list
                case let .failure(e): entry.error = e.message
                }
            }
            newCache[path] = entry
            if let err = entry.error { failures.append(PluginScanFailure(path: path, reason: err)); continue }
            for e in entry.entries ?? [] where seen.insert(e.cid).inserted { found.append(e.descriptor(path: path)) }
        }
        if let d = try? JSONEncoder().encode(newCache) { try? d.write(to: cacheURL, options: .atomic) }
        return (found, failures)
    }

    /// Runs the scanner child process (30 s limit).
    static func runScanner(_ exe: URL?, path: String) -> Result<[VST3ScanEntry], PluginError> {
        guard let exe else { return .failure(PluginError("No scanner executable")) }
        let p = Process()
        p.executableURL = exe
        p.arguments = [PluginScanChild.flag, path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(PluginError("Scanner could not start: \(error.localizedDescription)")) }
        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if reader.wait(timeout: .now() + 30) == .timedOut {
            p.terminate()
            _ = reader.wait(timeout: .now() + 3)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return .failure(PluginError("Scan timed out (the plug-in hung while loading)"))
        }
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if p.terminationReason == .uncaughtSignal {
            return .failure(PluginError("The plug-in crashed while loading (signal \(p.terminationStatus))"))
        }
        if let line = text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("LCERR:") }) {
            return .failure(PluginError(String(line.dropFirst(6))))
        }
        guard let list = VST3ScanEntry.parse(scannerOutput: text) else {
            return .failure(PluginError("No VST 3 effects found (exit \(p.terminationStatus))"))
        }
        if list.isEmpty { return .failure(PluginError("Contains no audio effects (instrument or unsupported)")) }
        return .success(list)
    }
}

/// Loads plug-ins into insert chains and protects the app from plug-ins that crash it:
///   * VST 3 bundles are scanned in a child process.
///   * Audio Units run out of process by default (a crash ends only their service; the slot is
///     bypassed and can be reloaded).
///   * In-process plug-ins (VST 3, or an AU that cannot run out of process) are tracked in a
///     guard file. If LiveCore dies while loading one, that plug-in is blocked at the next launch;
///     if it dies while such plug-ins run, the next launch restores them bypassed (safe mode).
public final class AudioPluginHost {
    public let catalog = PluginCatalog()
    /// Messages for the operator (main thread).
    public var onNotice: ((String) -> Void)?
    /// The last session ended abnormally with in-process plug-ins running: restored ones start bypassed.
    public private(set) var safeMode = false
    public private(set) var blocked: Set<String>
    /// Audio Units run out of process (Settings; default on).
    public var auOutOfProcess: Bool {
        get { UserDefaults.standard.object(forKey: "plugins.au.outOfProcess") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "plugins.au.outOfProcess") }
    }
    private var guardState = GuardState()
    private var invalidationObserver: NSObjectProtocol?
    /// Chains whose plug-ins the host watches for out-of-process crashes.
    private var chains: [WeakChain] = []
    private var pendingNotices: [String] = []

    private struct GuardState: Codable {
        var loading: String?
        var loadingName: String?
        var running: [String: String] = [:]   // slot id -> plug-in name
    }
    private struct WeakChain { weak var chain: PluginInsertChain? }
    private static var guardURL: URL { PluginFiles.directory.appendingPathComponent("crash-guard.json") }

    public init() {
        blocked = Set(UserDefaults.standard.stringArray(forKey: "plugins.blocked") ?? [])
        if let d = try? Data(contentsOf: Self.guardURL), let g = try? JSONDecoder().decode(GuardState.self, from: d) {
            if let id = g.loading {
                blocked.insert(id)
                UserDefaults.standard.set(Array(blocked), forKey: "plugins.blocked")
                pendingNotices.append("Plug-in \"\(g.loadingName ?? id)\" closed LiveCore Studio while loading last time. It is disabled; open the plug-in list to enable it again.")
            } else if !g.running.isEmpty {
                safeMode = true
                let names = Set(g.running.values).sorted().joined(separator: ", ")
                pendingNotices.append("LiveCore Studio did not close normally while plug-ins ran inside it (\(names)). They are restored bypassed: turn them on again in the plug-in list.")
            }
        }
        writeGuard()
        invalidationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: kAudioComponentInstanceInvalidationNotification as String), object: nil, queue: .main
        ) { [weak self] note in self?.componentInvalidated(note) }
    }

    deinit { if let invalidationObserver { NotificationCenter.default.removeObserver(invalidationObserver) } }

    /// Shows notices from the last launch (call once the UI listens).
    public func deliverStartupNotices() {
        let n = pendingNotices
        pendingNotices = []
        n.forEach { onNotice?($0) }
    }

    public func isBlocked(_ d: AudioPluginDescriptor) -> Bool { blocked.contains(d.id) }

    public func unblock(_ d: AudioPluginDescriptor) {
        blocked.remove(d.id)
        UserDefaults.standard.set(Array(blocked), forKey: "plugins.blocked")
    }

    func watch(_ chain: PluginInsertChain) {
        chains.removeAll { $0.chain == nil }
        if !chains.contains(where: { $0.chain === chain }) { chains.append(WeakChain(chain: chain)) }
    }

    // MARK: Loading

    /// Adds a plug-in at the end of `chain`.
    public func add(_ d: AudioPluginDescriptor, to chain: PluginInsertChain, completion: ((PluginSlot) -> Void)? = nil) {
        guard !chain.isFull else { onNotice?("A channel holds at most \(PluginInsertChain.maxSlots) plug-ins."); return }
        watch(chain)
        load(d, state: nil, bypassed: false) { slot in
            chain.append(slot)
            if let e = slot.loadError { self.onNotice?("\(d.name): \(e)") }
            completion?(slot)
        }
    }

    /// Restores a saved chain (project load): order kept, missing plug-ins kept as placeholders.
    public func restore(_ saved: [ProjectPluginSlot]?, into chain: PluginInsertChain, completion: (() -> Void)? = nil) {
        let saved = Array((saved ?? []).prefix(PluginInsertChain.maxSlots))
        guard !saved.isEmpty else { chain.removeAll(); completion?(); return }
        watch(chain)
        var loaded = [PluginSlot?](repeating: nil, count: saved.count)
        let group = DispatchGroup()
        for (i, s) in saved.enumerated() {
            group.enter()
            let inProcess = s.plugin.format == .vst3 || !auOutOfProcess
            load(s.plugin, state: s.state, bypassed: s.bypassed || (safeMode && inProcess)) { slot in
                loaded[i] = slot
                group.leave()
            }
        }
        group.notify(queue: .main) {
            chain.replaceAll(loaded.compactMap { $0 })
            let failed = loaded.compactMap { $0 }.filter { $0.loadError != nil }
            if !failed.isEmpty {
                self.onNotice?("Plug-ins not loaded: " + failed.map { "\($0.name) (\($0.loadError ?? ""))" }.joined(separator: "; "))
            }
            completion?()
        }
    }

    /// Removes a plug-in from a chain and closes it.
    public func remove(_ slot: PluginSlot, from chain: PluginInsertChain) {
        chain.remove(slot.id)
        untrack(slot)
    }

    /// Loads a fresh instance of a slot's plug-in with its last state (after a crash).
    public func reload(_ slot: PluginSlot, in chain: PluginInsertChain) {
        let state = slot.captureState()
        load(slot.descriptor, state: state, bypassed: slot.bypassed.value) { new in
            chain.replace(slot.id, with: new)
            self.untrack(slot)
            if let e = new.loadError { self.onNotice?("\(new.name): \(e)") }
        }
    }

    /// Main thread. Always completes with a slot (a placeholder carrying the error on failure).
    func load(_ d: AudioPluginDescriptor, state: Data?, bypassed: Bool, completion: @escaping (PluginSlot) -> Void) {
        func finish(_ p: PluginProcessor?, _ error: String?) {
            if let p, let state, !p.restore(state) { Log.audio.error("plug-in \(d.name): saved state not accepted") }
            let slot = PluginSlot(descriptor: d, processor: p, loadError: error, savedState: state)
            slot.bypassed.value = bypassed
            if let p, !p.outOfProcess { track(slot) }
            completion(slot)
        }
        if blocked.contains(d.id) {
            finish(nil, "Disabled: it closed LiveCore Studio while loading. Enable it in the plug-in list to try again.")
            return
        }
        switch d.format {
        case .audioUnit:
            let oop = auOutOfProcess
            func inProcess() {
                // Guarded: an in-process Audio Unit that crashes the app is blocked next launch.
                beginGuardedLoad(d)
                AUPluginProcessor.instantiate(d, outOfProcess: false) { r in
                    self.endGuardedLoad()
                    switch r {
                    case let .success(p): finish(p, nil)
                    case let .failure(e): finish(nil, e.localizedDescription)
                    }
                }
            }
            guard oop else { inProcess(); return }
            AUPluginProcessor.instantiate(d, outOfProcess: true) { result in
                switch result {
                case let .success(p): finish(p, nil)
                case let .failure(e):
                    // Some Audio Units cannot run out of process: try inside the app.
                    Log.audio.info("AU \(d.name) out of process failed (\(e.localizedDescription)); trying in process")
                    inProcess()
                }
            }
        case .vst3:
            guard let path = resolvedPath(d) else {
                finish(nil, "Not installed on this Mac (\(d.path ?? "no path"))")
                return
            }
            beginGuardedLoad(d)
            do {
                let p = try VST3PluginProcessor(path: path, cid: d.identifier)
                endGuardedLoad()
                finish(p, nil)
            } catch {
                endGuardedLoad()
                finish(nil, error.localizedDescription)
            }
        }
    }

    private func resolvedPath(_ d: AudioPluginDescriptor) -> String? {
        if let p = d.path, FileManager.default.fileExists(atPath: p) { return p }
        return catalog.descriptor(matching: d)?.path
    }

    // MARK: Crash guard

    private func beginGuardedLoad(_ d: AudioPluginDescriptor) {
        guardState.loading = d.id
        guardState.loadingName = d.name
        writeGuard()
    }

    private func endGuardedLoad() {
        guardState.loading = nil
        guardState.loadingName = nil
        writeGuard()
    }

    private func track(_ slot: PluginSlot) {
        guardState.running[slot.id.uuidString] = slot.name
        writeGuard()
    }

    func untrack(_ slot: PluginSlot) {
        guard guardState.running.removeValue(forKey: slot.id.uuidString) != nil else { return }
        writeGuard()
    }

    /// Forgets slots that are no longer in any chain (call after removing plug-ins).
    public func pruneGuard() {
        let live = Set(chains.compactMap { $0.chain }.flatMap { $0.slots }.map { $0.id.uuidString })
        let before = guardState.running.count
        guardState.running = guardState.running.filter { live.contains($0.key) }
        if guardState.running.count != before { writeGuard() }
    }

    private func writeGuard() {
        if let d = try? JSONEncoder().encode(guardState) { try? d.write(to: Self.guardURL, options: .atomic) }
    }

    /// Clean shutdown: closes every plug-in and removes the guard file.
    public func shutdown() {
        chains.compactMap { $0.chain }.forEach { $0.removeAll() }
        try? FileManager.default.removeItem(at: Self.guardURL)
    }

    private func componentInvalidated(_ note: Notification) {
        guard let au = note.object as? AUAudioUnit else { return }
        for chain in chains.compactMap({ $0.chain }) {
            for slot in chain.slots {
                if let p = slot.processor as? AUPluginProcessor, p.au === au {
                    slot.faultCode.value = Float(PluginFault.crashed.rawValue)
                    onNotice?("Plug-in \(slot.name) crashed. It is bypassed; use Reload in the plug-in list.")
                    NotificationCenter.default.post(name: PluginInsertChain.didChange, object: chain)
                }
            }
        }
    }
}
#endif

#if os(macOS)
import AVFoundation
import Foundation
import IOKit.ps
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices
import Network

/// Pre-flight check: gathers what the app knows (inputs, permissions, audio level, disk, stream
/// destinations and a connection test to each server) and turns it into OK / warning / problem
/// lines with `Preflight.check`.
extension AppModel {
    public struct PreflightPlan: Equatable {
        public var stream: Bool
        public var record: Bool
        public var minutes: Double
    }

    /// What the operator probably intends: stream when a destination is set up, always record.
    public var defaultPreflightPlan: PreflightPlan {
        PreflightPlan(stream: readyDestinationCount > 0, record: true, minutes: 180)
    }

    /// Listens to the master for 3 seconds and tests each stream server, then reports.
    public func runPreflight(_ plan: PreflightPlan, completion: @escaping ([PreflightItem]) -> Void) {
        var f = PreflightFacts()
        f.willStream = plan.stream
        f.willRecord = plan.record
        f.plannedMinutes = plan.minutes

        // Inputs and Program
        f.inputCount = inputs.count
        f.programSet = switcher.program != nil
        f.inputsWithProblems = inputs.filter {
            switch $0.status {
            case .error, .noSignal: return true
            default: return false
            }
        }.map(\.name)

        // Permissions
        func permission(_ type: AVMediaType) -> PreflightFacts.Permission {
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        }
        // Only matters when the production uses that kind of device.
        if inputs.contains(where: { $0.kind == .camera }) { f.camera = permission(.video) }
        if !audioChannels.isEmpty || !audioDevices.isEmpty { f.microphone = permission(.audio) }

        // Audio routing
        f.programChannels = audioChannels.filter { $0.toProgram && !$0.muted }.count
        f.masterMuted = engine?.mixer.master.muted.value ?? false

        // Stream destinations (keys are only checked for presence, never read into the report)
        let st = settings.stream
        var servers: [(host: String, port: Int)] = []
        var dests: [(name: String, url: String, account: String)] = []
        if st.primaryEnabled { dests.append((st.primaryName, st.serverURL, st.keychainAccount)) }
        for d in st.additional where d.enabled { dests.append((d.name, d.serverURL, d.keychainAccount)) }
        f.streamDestinations = dests.count
        for d in dests {
            if SRTURL.isSRT(d.url) {
                // SRT runs over UDP: no connection test without a handshake; the key is optional.
                if (try? SRTURL.parse(d.url)) == nil { f.destinationsMissingURL.append(d.name) }
                continue
            }
            if let u = try? RTMPURL.parse(serverURL: d.url, streamKey: "probe") {
                if !servers.contains(where: { $0.host == u.host && $0.port == u.port }) { servers.append((u.host, u.port)) }
            } else {
                f.destinationsMissingURL.append(d.name)
            }
            if !hasKey(account: d.account) { f.destinationsMissingKey.append(d.name) }
        }
        f.streamVideoKbps = settings.video.bitrateKbps * max(dests.count, 1)
        f.streamAudioKbps = settings.audio.bitrateKbps * max(dests.count, 1)

        // Recording: Program file plus the ISO files
        let folder = recordingFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        f.recordFolderWritable = FileManager.default.isWritableFile(atPath: folder.path)
        f.freeDiskBytes = Self.freeDiskBytes(folder)
        var mbps = settings.recording.estimatedMbps(output: settings.output)
        mbps += settings.multiCorderRecording.estimatedMbps(output: settings.output) * Double(multiCorder.inputs.count)
        f.recordKbps = Int(mbps * 1000)

        // Machine
        f.targetFPS = Double(settings.output.frameRate)
        f.thermalSerious = performance.thermalState == .serious || performance.thermalState == .critical
        f.onBattery = Self.onBatteryPower()
        let dropsBefore = performance.droppedRenderFrames

        // 3 seconds of listening, while the servers are tested.
        var peak: Float = -120
        let sampler = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let m = self?.meters.master else { return }
            peak = max(peak, m.l, m.r)
        }
        RunLoop.main.add(sampler, forMode: .common)
        var reach: [(ok: Bool, ms: Double)] = []
        let group = DispatchGroup()
        if plan.stream {
            for s in servers {
                group.enter()
                Self.tcpProbe(host: s.host, port: s.port) { ok, ms in
                    DispatchQueue.main.async { reach.append((ok, ms)); group.leave() }
                }
            }
        }
        group.enter()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { group.leave() }
        group.notify(queue: .main) { [weak self] in
            sampler.invalidate()
            guard let self else { return }
            f.masterPeakDB = peak
            f.renderFPS = self.performance.renderFPS
            let dropsAfter = self.performance.droppedRenderFrames
            f.droppedFramesRecent = dropsAfter > dropsBefore ? Int(dropsAfter - dropsBefore) : 0
            if !reach.isEmpty {
                f.serverReachable = reach.allSatisfy(\.ok)
                f.serverConnectMs = reach.map(\.ms).max()
            }
            let items = Preflight.check(f)
            FileLog.shared.info("pre-flight: " + items.map { "\($0.level) \($0.key)" }.joined(separator: ", "))
            completion(items)
        }
    }

    /// Opens a TCP connection to the server (no RTMP handshake, no key sent) and times it.
    static func tcpProbe(host: String, port: Int, timeout: Double = 4, completion: @escaping (Bool, Double) -> Void) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { completion(false, 0); return }
        let queue = DispatchQueue(label: "livecore.preflight.probe")
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let start = DispatchTime.now().uptimeNanoseconds
        var finished = false
        let finish: (Bool) -> Void = { ok in
            guard !finished else { return }
            finished = true
            conn.cancel()
            completion(ok, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    static func onBatteryPower() -> Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    /// Localised text of one pre-flight line.
    public static func preflightText(_ item: PreflightItem) -> String {
        String(format: L10n.t(item.key), arguments: item.args.map { $0 as CVarArg })
    }
}
#endif

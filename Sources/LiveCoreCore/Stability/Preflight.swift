/// Pre-flight check before going live: turns what the app knows (settings, permissions, disk,
/// inputs, audio, network test) into a list of OK / warning / problem lines. Pure logic; the UI
/// gathers the facts.
public struct PreflightFacts: Sendable {
    public enum Permission: Sendable { case granted, denied, notAsked }

    public var willStream = false
    public var willRecord = false
    /// Expected length of the event in minutes (disk space estimate).
    public var plannedMinutes = 180.0

    // Stream
    public var streamDestinations = 0
    /// Destinations without a valid rtmp(s):// address or without a key (names).
    public var destinationsMissingURL: [String] = []
    public var destinationsMissingKey: [String] = []
    /// Result of the connection test: nil = not tested, otherwise reachable + time.
    public var serverReachable: Bool?
    public var serverConnectMs: Double?
    public var streamVideoKbps = 4500
    public var streamAudioKbps = 160

    // Recording
    public var recordFolderWritable = true
    public var freeDiskBytes: Int64?
    /// Total recording bitrate (Program + ISO files), kbit/s.
    public var recordKbps = 0

    // Devices and inputs
    public var camera: Permission = .granted
    public var microphone: Permission = .granted
    public var inputCount = 0
    /// Inputs with an error or no signal (names).
    public var inputsWithProblems: [String] = []
    public var programSet = false

    // Audio: loudest master peak during the check (dBFS), and channels routed to Program.
    public var masterPeakDB: Float = -120
    public var programChannels = 0
    public var masterMuted = false

    // Machine
    public var renderFPS = 0.0
    public var targetFPS = 30.0
    public var droppedFramesRecent = 0
    public var thermalSerious = false
    public var onBattery = false

    public init() {}
}

public struct PreflightItem: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case ok, warning, problem
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    public var level: Level
    /// Localisation key (`preflight.*`) and its arguments.
    public var key: String
    public var args: [String]
    public init(_ level: Level, _ key: String, _ args: [String] = []) { self.level = level; self.key = key; self.args = args }
}

public enum Preflight {
    /// Bytes per minute at `kbps`.
    public static func bytesPerMinute(kbps: Int) -> Double { Double(max(kbps, 0)) * 1000 / 8 * 60 }

    public static func check(_ f: PreflightFacts) -> [PreflightItem] {
        var out: [PreflightItem] = []

        // Inputs and Program
        if f.inputCount == 0 { out.append(.init(.problem, "preflight.no_inputs")) }
        else if !f.programSet { out.append(.init(.warning, "preflight.no_program")) }
        else { out.append(.init(.ok, "preflight.inputs_ok", ["\(f.inputCount)"])) }
        for name in f.inputsWithProblems { out.append(.init(.warning, "preflight.input_problem", [name])) }

        // Permissions
        switch f.camera {
        case .denied: out.append(.init(.problem, "preflight.camera_denied"))
        case .notAsked: out.append(.init(.warning, "preflight.camera_not_asked"))
        case .granted: break
        }
        switch f.microphone {
        case .denied: out.append(.init(.problem, "preflight.mic_denied"))
        case .notAsked: out.append(.init(.warning, "preflight.mic_not_asked"))
        case .granted: break
        }

        // Audio
        if f.masterMuted { out.append(.init(.problem, "preflight.master_muted")) }
        else if f.programChannels == 0 { out.append(.init(.warning, "preflight.no_audio_channels")) }
        else if f.masterPeakDB < -60 { out.append(.init(.warning, "preflight.audio_silent")) }
        else if f.masterPeakDB > -0.5 { out.append(.init(.warning, "preflight.audio_clipping")) }
        else { out.append(.init(.ok, "preflight.audio_ok", [String(Int(f.masterPeakDB.rounded()))])) }

        // Stream
        if f.willStream {
            if f.streamDestinations == 0 { out.append(.init(.problem, "preflight.stream_none")) }
            for d in f.destinationsMissingURL { out.append(.init(.problem, "preflight.stream_url", [d])) }
            for d in f.destinationsMissingKey { out.append(.init(.problem, "preflight.stream_key", [d])) }
            switch f.serverReachable {
            case .some(false): out.append(.init(.problem, "preflight.server_unreachable"))
            case .some(true):
                let ms = f.serverConnectMs.map { String(Int($0.rounded())) } ?? "?"
                out.append(.init((f.serverConnectMs ?? 0) > 800 ? .warning : .ok, "preflight.server_ok", [ms]))
            case .none: out.append(.init(.warning, "preflight.server_untested"))
            }
            let total = f.streamVideoKbps + f.streamAudioKbps
            out.append(.init(.ok, "preflight.upload_needed", [format1(Double(total) * 1.5 / 1000)]))
        }

        // Recording and disk
        if f.willRecord {
            if !f.recordFolderWritable { out.append(.init(.problem, "preflight.record_folder")) }
            if let free = f.freeDiskBytes {
                let need = bytesPerMinute(kbps: f.recordKbps) * f.plannedMinutes
                let minutes = f.recordKbps > 0 ? Double(free) / bytesPerMinute(kbps: f.recordKbps) : .infinity
                let freeGB = format1(Double(free) / 1_000_000_000)
                if Double(free) < need { out.append(.init(.problem, "preflight.disk_low", [freeGB, String(Int(minutes))])) }
                else if Double(free) < need * 1.5 { out.append(.init(.warning, "preflight.disk_tight", [freeGB, String(Int(minutes))])) }
                else { out.append(.init(.ok, "preflight.disk_ok", [freeGB, minutes.isFinite ? String(Int(minutes)) : "∞"])) }
            }
        }
        if !f.willStream && !f.willRecord { out.append(.init(.warning, "preflight.nothing_planned")) }

        // Machine
        if f.thermalSerious { out.append(.init(.warning, "preflight.thermal")) }
        if f.onBattery { out.append(.init(.warning, "preflight.battery")) }
        if f.targetFPS > 0, f.renderFPS > 0, f.renderFPS < f.targetFPS * 0.95 {
            out.append(.init(.warning, "preflight.fps_low", [format1(f.renderFPS), String(Int(f.targetFPS))]))
        }
        if f.droppedFramesRecent > 0 { out.append(.init(.warning, "preflight.drops", ["\(f.droppedFramesRecent)"])) }
        return out
    }

    /// Worst level in a list (what the summary shows).
    public static func overall(_ items: [PreflightItem]) -> PreflightItem.Level { items.map(\.level).max() ?? .ok }

    /// One decimal, Foundation-free.
    public static func format1(_ v: Double) -> String {
        guard v.isFinite else { return "∞" }
        let t = (v * 10).rounded()
        let whole = Int(t / 10), frac = Int(abs(t).truncatingRemainder(dividingBy: 10))
        return (t < 0 && whole == 0 ? "-" : "") + "\(whole).\(frac)"
    }
}

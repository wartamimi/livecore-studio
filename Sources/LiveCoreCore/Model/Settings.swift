/// User-editable settings. Codable so the engine can persist them as JSON (UserDefaults / project file).
/// The stream key is intentionally NOT part of these structs: it lives in the Keychain only.
public struct OutputFormat: Codable, Equatable, Sendable, Hashable {
    public var size: PixelSize
    public var frameRate: Int
    public init(size: PixelSize, frameRate: Int) { self.size = size; self.frameRate = frameRate }

    public static let hd720p30 = OutputFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
    public static let hd1080p30 = OutputFormat(size: PixelSize(width: 1920, height: 1080), frameRate: 30)
    public static let hd720p60 = OutputFormat(size: PixelSize(width: 1280, height: 720), frameRate: 60)
    public static let hd1080p25 = OutputFormat(size: PixelSize(width: 1920, height: 1080), frameRate: 25)
    public static let hd1080p60 = OutputFormat(size: PixelSize(width: 1920, height: 1080), frameRate: 60)
    public static let presets: [OutputFormat] = [.hd720p30, .hd720p60, .hd1080p25, .hd1080p30, .hd1080p60]

    public var label: String { "\(min(size.width, size.height))p\(frameRate) (\(size.width)×\(size.height))" }

    // MARK: Canvas (0.26.0)

    public static let minSide = 240
    public static let maxSide = 3840
    public static let frameRates = [24, 25, 30, 50, 60]
    public static let lineChoices = [720, 1080]

    /// 16:9 horizontal, 9:16 portrait (phones, Reels, Shorts, TikTok) or any other size.
    public enum Orientation: String, Codable, Sendable, CaseIterable { case horizontal, portrait, custom }

    /// `lines`: 720 or 1080 (the short side).
    public static func canvas(_ o: Orientation, lines: Int, frameRate: Int) -> OutputFormat {
        let short = lines, long = lines * 16 / 9
        switch o {
        case .horizontal, .custom: return OutputFormat(size: PixelSize(width: long, height: short), frameRate: frameRate)
        case .portrait: return OutputFormat(size: PixelSize(width: short, height: long), frameRate: frameRate)
        }
    }

    /// Any size, made even (H.264) and kept within `minSide...maxSide`.
    public static func custom(width: Int, height: Int, frameRate: Int) -> OutputFormat {
        func side(_ v: Int) -> Int { let c = min(max(v, minSide), maxSide); return c - c % 2 }
        return OutputFormat(size: PixelSize(width: side(width), height: side(height)), frameRate: frameRate)
    }

    public var orientation: Orientation {
        for l in Self.lineChoices {
            if size == Self.canvas(.horizontal, lines: l, frameRate: frameRate).size { return .horizontal }
            if size == Self.canvas(.portrait, lines: l, frameRate: frameRate).size { return .portrait }
        }
        return .custom
    }
}

public enum H264Profile: String, Codable, Sendable, CaseIterable { case baseline, main, high }

public struct VideoEncoderSettings: Codable, Equatable, Sendable {
    public var bitrateKbps: Int = 4500
    public var keyframeIntervalSeconds: Double = 2
    public var profile: H264Profile = .high
    public var preferHardware: Bool = true
    public init() {}
}

public struct AudioEncoderSettings: Codable, Equatable, Sendable {
    public var bitrateKbps: Int = 160
    public var sampleRate: Int = 48000
    public var channels: Int = 2
    public init() {}
}

/// Which mixer bus feeds an output (recording or a stream destination), like vMix's output
/// bus selection: Master (Program mix) or one of the aux buses, e.g. a mix without the music
/// for the recording, or a commentary mix for one platform.
public enum OutputBus: String, Codable, Sendable, CaseIterable, Hashable {
    case master, busA, busB
    /// Index into the mixer's aux buses, nil for Master.
    public var auxIndex: Int? {
        switch self { case .master: return nil; case .busA: return 0; case .busB: return 1 }
    }
}

/// An additional RTMP/RTMPS destination streamed simultaneously with the primary one (same
/// encoded stream, so no extra encoding cost). Its key lives in the Keychain under `keychainAccount`.
public struct StreamDestination: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var serverURL: String
    public var keychainAccount: String
    public var enabled: Bool
    /// Added in 0.9.0; nil (older settings) = Master.
    public var audioBus: OutputBus?
    public var bus: OutputBus { audioBus ?? .master }
    public init(id: String, name: String, serverURL: String = "", enabled: Bool = true) {
        self.id = id; self.name = name; self.serverURL = serverURL
        self.keychainAccount = "dest-\(id)"; self.enabled = enabled
    }
}

public struct StreamSettings: Codable, Equatable, Sendable {
    public static let maxDestinations = 3   // primary + 2 additional

    public var serverURL: String = ""
    public var keychainAccount: String = "default"   // pointer into the Keychain, not the key itself
    public var primaryName: String = "Primary"
    public var primaryEnabled: Bool = true
    public var autoReconnect: Bool = true
    public var reconnect = ExponentialBackoff()
    /// Added in 0.4.0.
    public var additional: [StreamDestination] = []
    /// Added in 0.9.0.
    public var primaryAudioBus: OutputBus = .master
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case serverURL, keychainAccount, primaryName, primaryEnabled, autoReconnect, reconnect, additional, primaryAudioBus
    }

    // Tolerant decoding: settings saved by older versions lack the newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamSettings()
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? d.serverURL
        keychainAccount = try c.decodeIfPresent(String.self, forKey: .keychainAccount) ?? d.keychainAccount
        primaryName = try c.decodeIfPresent(String.self, forKey: .primaryName) ?? d.primaryName
        primaryEnabled = try c.decodeIfPresent(Bool.self, forKey: .primaryEnabled) ?? d.primaryEnabled
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? d.autoReconnect
        reconnect = try c.decodeIfPresent(ExponentialBackoff.self, forKey: .reconnect) ?? d.reconnect
        additional = try c.decodeIfPresent([StreamDestination].self, forKey: .additional) ?? []
        primaryAudioBus = try c.decodeIfPresent(OutputBus.self, forKey: .primaryAudioBus) ?? .master
    }

    /// Problems with the destination list (empty = OK). Keys are checked by the app (Keychain).
    public func destinationErrors() -> [String] {
        var errs: [String] = []
        if 1 + additional.count > Self.maxDestinations {
            errs.append("At most \(Self.maxDestinations) stream destinations are supported.")
        }
        for d in additional where d.enabled && d.serverURL.trimmed.isEmpty {
            errs.append("Destination \"\(d.name)\" is enabled but has no server URL.")
        }
        if Set(additional.map(\.id)).count != additional.count { errs.append("Duplicate destination id.") }
        return errs
    }
}

public enum RecordingContainer: String, Codable, Sendable, CaseIterable {
    case mp4, mov
    public var fileExtension: String { rawValue }
}

/// Video codec of a recording (Recorder and MultiCorder, 0.33.0). H.264 / HEVC use the Mac's
/// hardware encoder at a chosen bitrate; ProRes is intra-frame at a fixed quality (MOV only),
/// encoded by the ProRes engine on Apple silicon that has one (M1 Pro/Max/Ultra, M2 and later).
public enum RecordingCodec: String, Codable, Sendable, CaseIterable {
    case h264, hevc, proRes422Proxy, proRes422LT, proRes422, proRes422HQ

    public var isProRes: Bool { self != .h264 && self != .hevc }
    public var usesBitrate: Bool { !isProRes }

    public var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .proRes422Proxy: return "ProRes 422 Proxy"
        case .proRes422LT: return "ProRes 422 LT"
        case .proRes422: return "ProRes 422"
        case .proRes422HQ: return "ProRes 422 HQ"
        }
    }

    /// Apple's target ProRes data rates at 1920×1080 29.97 fps (Mbps).
    var proResMbps1080p30: Double {
        switch self {
        case .proRes422Proxy: return 45
        case .proRes422LT: return 102
        case .proRes422: return 147
        case .proRes422HQ: return 220
        default: return 0
        }
    }
}

public struct RecordingSettings: Codable, Equatable, Sendable {
    public var folderPath: String = ""      // empty = ~/Movies/LiveCore Studio
    public var fileNamePattern: String = "LiveCore {date} {time}"
    public var container: RecordingContainer = .mp4
    public var bitrateKbps: Int = 12000
    public var minimumFreeBytes: Int64 = 2_000_000_000   // stop safely below 2 GB free
    /// Added in 0.9.0; nil (older settings) = Master.
    public var audioBus: OutputBus?
    public var bus: OutputBus { audioBus ?? .master }
    // Advanced (0.33.0); nil in older settings = the previous behaviour.
    public var codec: RecordingCodec?
    public var keyframeSeconds: Double?
    /// B-frames: smaller files at the same quality, but more encoder work and latency.
    public var frameReordering: Bool?
    public var audioBitrateKbps: Int?
    /// Uncompressed 24-bit PCM audio (MOV only) instead of AAC.
    public var pcmAudio: Bool?
    public init() {}

    public var videoCodec: RecordingCodec { codec ?? .h264 }
    public var keyframeInterval: Double { keyframeSeconds ?? 2 }
    public var bFrames: Bool { frameReordering ?? false }
    public var audioKbps: Int { audioBitrateKbps ?? 192 }
    /// ProRes and PCM audio need MOV.
    public var effectiveContainer: RecordingContainer { videoCodec.isProRes || pcmAudio == true ? .mov : container }
    public var usesPCM: Bool { pcmAudio == true && effectiveContainer == .mov }

    public static let audioBitrates = [128, 160, 192, 256, 320]
    public static let bitrateRange = 2_000...150_000

    /// Problems with these settings (empty = OK).
    public func validationErrors(label: String = "Recording") -> [String] {
        var errs: [String] = []
        if videoCodec.usesBitrate, !Self.bitrateRange.contains(bitrateKbps) {
            errs.append("\(label): video bitrate must be 2–150 Mbps.")
        }
        if !(0.5...10).contains(keyframeInterval) { errs.append("\(label): keyframe interval must be 0.5–10 seconds.") }
        if !Self.audioBitrates.contains(audioKbps) { errs.append("\(label): audio bitrate not supported.") }
        return errs
    }

    /// Approximate data rate of one file (video + audio), for the disk-space estimate.
    public func estimatedMbps(output: OutputFormat) -> Double {
        let audio = usesPCM ? 2.304 : Double(audioKbps) / 1000          // 48 kHz × 24 bit × 2
        guard videoCodec.isProRes else { return Double(bitrateKbps) / 1000 + audio }
        let scale = Double(output.size.width * output.size.height) * Double(output.frameRate) / (1920.0 * 1080 * 29.97)
        return videoCodec.proResMbps1080p30 * scale + audio
    }

    /// Gigabytes per hour for `files` files with these settings.
    public func gigabytesPerHour(output: OutputFormat, files: Int = 1) -> Double {
        estimatedMbps(output: output) * 3600 / 8 / 1000 * Double(max(files, 0))
    }

    /// MultiCorder default: HEVC at 25 Mbps in MOV (the file stays readable if the Mac stops).
    public static var multiCorderDefault: RecordingSettings {
        var r = RecordingSettings()
        r.codec = .hevc
        r.bitrateKbps = 25_000
        r.container = .mov
        return r
    }
}


public struct ProductionSettings: Codable, Equatable, Sendable {
    public var output: OutputFormat = .hd1080p30
    public var video = VideoEncoderSettings()
    public var audio = AudioEncoderSettings()
    public var stream = StreamSettings()
    public var recording = RecordingSettings()
    public var transition: TransitionKind = .dissolve
    public var transitionDuration: Double = 1.0
    /// Shader used when `transition == .custom` (`CustomTransitionSource` id); added in 0.12.0.
    public var customTransition: String?
    /// MultiCorder (ISO) recording profile, separate from the Recorder (0.33.0).
    public var multiCorder: RecordingSettings?
    public var multiCorderRecording: RecordingSettings { multiCorder ?? .multiCorderDefault }
    /// Portrait 9:16 output next to Program (0.42.0).
    public var vertical: VerticalSettings?
    public var verticalOutput: VerticalSettings { vertical ?? VerticalSettings() }
    public init() {}

    /// Validation used before starting outputs. Returns human-readable problems (empty = OK).
    public func validationErrors() -> [String] {
        var errs: [String] = []
        if output.size.width % 2 != 0 || output.size.height % 2 != 0 { errs.append("Output size must be even.") }
        let sides = OutputFormat.minSide...OutputFormat.maxSide
        if !sides.contains(output.size.width) || !sides.contains(output.size.height) {
            errs.append("Canvas width and height must be \(OutputFormat.minSide)–\(OutputFormat.maxSide) pixels.")
        }
        if !(1...120).contains(output.frameRate) { errs.append("Frame rate must be 1–120 fps.") }
        if !(300...50_000).contains(video.bitrateKbps) { errs.append("Video bitrate must be 300–50000 kbps.") }
        if ![64, 96, 128, 160, 192, 256, 320].contains(audio.bitrateKbps) { errs.append("Audio bitrate not supported by AAC encoder.") }
        if ![44100, 48000].contains(audio.sampleRate) { errs.append("Audio sample rate must be 44.1 or 48 kHz.") }
        errs += stream.destinationErrors()
        errs += recording.validationErrors(label: "Recorder")
        errs += multiCorderRecording.validationErrors(label: "ISOCorder")
        return errs
    }
}

/// Builds recording file names from a pattern. Tokens: {date} -> 2026-10-27, {time} -> 14-05-09, {n} -> counter.
public enum FileNaming {
    public static func fileName(pattern: String, year: Int, month: Int, day: Int, hour: Int, minute: Int,
                                second: Int, counter: Int, ext: String) -> String {
        func p2(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        var name = pattern.isEmpty ? "Recording {date} {time}" : pattern
        name = name.replacingAll("{date}", with: "\(year)-\(p2(month))-\(p2(day))")
        name = name.replacingAll("{time}", with: "\(p2(hour))-\(p2(minute))-\(p2(second))")
        name = name.replacingAll("{n}", with: "\(counter)")
        // Strip characters that are illegal or troublesome in macOS file names.
        let illegal: Set<Character> = ["/", ":", "\\", "\0"]
        name = String(name.map { illegal.contains($0) ? "-" : $0 })
        name = name.trimmed
        if name.isEmpty || name.hasPrefix(".") { name = "Recording" + name }
        return "\(name).\(ext)"
    }
}

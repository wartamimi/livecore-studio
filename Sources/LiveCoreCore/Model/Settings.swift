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

    public var label: String { "\(size.height)p\(frameRate) (\(size.width)×\(size.height))" }
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

public struct RecordingSettings: Codable, Equatable, Sendable {
    public var folderPath: String = ""      // empty = ~/Movies/LiveCore Studio
    public var fileNamePattern: String = "LiveCore {date} {time}"
    public var container: RecordingContainer = .mp4
    public var bitrateKbps: Int = 12000
    public var minimumFreeBytes: Int64 = 2_000_000_000   // stop safely below 2 GB free
    /// Added in 0.9.0; nil (older settings) = Master.
    public var audioBus: OutputBus?
    public var bus: OutputBus { audioBus ?? .master }
    public init() {}
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
    public init() {}

    /// Validation used before starting outputs. Returns human-readable problems (empty = OK).
    public func validationErrors() -> [String] {
        var errs: [String] = []
        if output.size.width % 2 != 0 || output.size.height % 2 != 0 { errs.append("Output size must be even.") }
        if !(1...120).contains(output.frameRate) { errs.append("Frame rate must be 1–120 fps.") }
        if !(300...50_000).contains(video.bitrateKbps) { errs.append("Video bitrate must be 300–50000 kbps.") }
        if ![64, 96, 128, 160, 192, 256, 320].contains(audio.bitrateKbps) { errs.append("Audio bitrate not supported by AAC encoder.") }
        if ![44100, 48000].contains(audio.sampleRate) { errs.append("Audio sample rate must be 44.1 or 48 kHz.") }
        errs += stream.destinationErrors()
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

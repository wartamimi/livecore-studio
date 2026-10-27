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

public struct StreamSettings: Codable, Equatable, Sendable {
    public var serverURL: String = ""
    public var keychainAccount: String = "default"   // pointer into the Keychain, not the key itself
    public var autoReconnect: Bool = true
    public var reconnect = ExponentialBackoff()
    public init() {}
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
    public init() {}

    /// Validation used before starting outputs. Returns human-readable problems (empty = OK).
    public func validationErrors() -> [String] {
        var errs: [String] = []
        if output.size.width % 2 != 0 || output.size.height % 2 != 0 { errs.append("Output size must be even.") }
        if !(1...120).contains(output.frameRate) { errs.append("Frame rate must be 1–120 fps.") }
        if !(300...50_000).contains(video.bitrateKbps) { errs.append("Video bitrate must be 300–50000 kbps.") }
        if ![64, 96, 128, 160, 192, 256, 320].contains(audio.bitrateKbps) { errs.append("Audio bitrate not supported by AAC encoder.") }
        if ![44100, 48000].contains(audio.sampleRate) { errs.append("Audio sample rate must be 44.1 or 48 kHz.") }
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

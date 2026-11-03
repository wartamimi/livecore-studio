import Foundation

/// SRT stream received as an input (0.54.0): an encoder (OBS, vMix, Larix on a phone, a hardware
/// encoder) sends MPEG-TS (H.264 / HEVC + AAC) over SRT.
public struct ProjectSRTInput: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case listener, caller }
    /// listener: LiveCore waits on `port`; caller: LiveCore calls `host:port`.
    public var mode: Mode
    public var host: String
    public var port: Int
    /// SRT latency (retransmission window), 20–8000 ms.
    public var latencyMs: Int
    /// Stream ID sent when calling (caller mode); a listener shows the one it receives.
    public var streamID: String?
    /// Put the stream's audio on its own mixer channel (nil = yes).
    public var audio: Bool?

    public init(mode: Mode = .listener, host: String = "", port: Int = 9000, latencyMs: Int = 200,
                streamID: String? = nil, audio: Bool? = nil) {
        self.mode = mode; self.host = host; self.port = port; self.latencyMs = latencyMs
        self.streamID = streamID; self.audio = audio
    }

    public var wantsAudio: Bool { audio ?? true }
    public var clampedLatency: Int { min(max(latencyMs, 20), 8000) }
    public var displayName: String {
        mode == .listener ? "SRT :\(port)" : "SRT \(host):\(port)"
    }
    /// What the encoder should call (listener mode), with this Mac's address filled in by the UI.
    public func callerURL(host: String) -> String {
        "srt://\(host):\(port)?mode=caller&latency=\(clampedLatency * 1000)"
    }

    public enum Problem: Equatable, Sendable { case badPort, missingHost }
    public var problem: Problem? {
        if !(1...65535).contains(port) { return .badPort }
        if mode == .caller && host.trimmingCharacters(in: .whitespaces).isEmpty { return .missingHost }
        return nil
    }

    /// Fills the fields from a pasted srt:// address ("srt://host:port?mode=listener&latency=…").
    public static func parse(_ raw: String) -> ProjectSRTInput? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("srt://") else { return nil }
        var rest = Substring(s.dropFirst(6)), query = Substring("")
        if let q = rest.firstIndex(of: "?") { query = rest[rest.index(after: q)...]; rest = rest[..<q] }
        var host = String(rest), port = 0
        if let colon = host.lastIndex(of: ":"), let p = Int(host[host.index(after: colon)...]) {
            port = p
            host = String(host[..<colon])
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var c = ProjectSRTInput(mode: host.isEmpty ? .listener : .caller, host: host, port: port)
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = kv[0].lowercased(), v = kv.count > 1 ? SRTURL.percentDecode(String(kv[1])) : ""
            switch k {
            case "mode": c.mode = v.lowercased() == "listener" ? .listener : .caller
            case "latency": if let n = Int(v) { c.latencyMs = n > 10_000 ? n / 1000 : n }
            case "streamid": c.streamID = v.isEmpty ? nil : v
            default: break
            }
        }
        // "srt://0.0.0.0:9000" or "srt://:9000" means listen.
        if c.host == "0.0.0.0" || c.host == "::" { c.host = ""; c.mode = .listener }
        return c.port > 0 ? c : nil
    }
}

/// Blackmagic DeckLink / UltraStudio / Intensity capture input (0.54.0), through the installed
/// Blackmagic Desktop Video driver (nothing of the SDK runtime is shipped).
public struct ProjectDeckLink: Codable, Equatable, Sendable {
    /// Display name of the device (e.g. "DeckLink Mini Recorder 4K"); matched first.
    public var deviceName: String
    /// Position in the driver's device list, used when two cards share a name.
    public var deviceIndex: Int
    /// Display mode four-character code (e.g. 'Hp50'); nil = detect the incoming format.
    public var mode: UInt32?
    /// Video connection: nil = the card's current setting, else "sdi", "hdmi", "component",
    /// "composite", "svideo", "optical".
    public var connection: String?
    /// Embedded audio to its own mixer channel (nil = yes).
    public var audio: Bool?

    public init(deviceName: String, deviceIndex: Int = 0, mode: UInt32? = nil, connection: String? = nil, audio: Bool? = nil) {
        self.deviceName = deviceName; self.deviceIndex = deviceIndex; self.mode = mode
        self.connection = connection; self.audio = audio
    }

    public var wantsAudio: Bool { audio ?? true }
    public var displayName: String { deviceName.isEmpty ? "DeckLink" : deviceName }

    /// Four-character code as text ("Hp50"), for logs.
    public static func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Connection names ↔ BMDVideoConnection bits.
    public static let connections: [(name: String, bit: Int64)] = [
        ("sdi", 1 << 0), ("hdmi", 1 << 1), ("optical", 1 << 2), ("component", 1 << 3), ("composite", 1 << 4), ("svideo", 1 << 5),
    ]
    public static func connectionBit(_ name: String?) -> Int64 {
        guard let name else { return 0 }
        return connections.first { $0.name == name }?.bit ?? 0
    }
}

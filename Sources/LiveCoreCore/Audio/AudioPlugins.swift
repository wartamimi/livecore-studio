import Foundation

/// Insert effects (third-party audio plug-ins) inside a mixer channel or the master bus (0.60.0).
/// The channel strip calls `processInserts` on the render thread after the compressor and before
/// the channel limiter and fader. Implementations must not block or allocate there.
public protocol AudioInsertProcessing: AnyObject, Sendable {
    /// Render thread: cheap check whether there is anything to process.
    var insertsActive: Bool { get }
    /// Render thread: processes the stereo block in place.
    func processInserts(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int)
}

/// Plug-in formats LiveCore hosts.
public enum AudioPluginFormat: String, Codable, Sendable, CaseIterable {
    /// Apple Audio Unit (AUv2 and AUv3 app extensions), effect and music-effect types.
    case audioUnit = "au"
    /// Steinberg VST 3 (.vst3 bundles), audio effect classes.
    case vst3

    public var label: String { self == .audioUnit ? "AU" : "VST3" }
}

/// One effect found by the plug-in scan, and what a project stores to find it again.
public struct AudioPluginDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var format: AudioPluginFormat
    /// Audio Unit: "type subtype manufacturer" four-character codes ("aufx dely appl").
    /// VST 3: the class id (32 hex digits).
    public var identifier: String
    /// VST 3 bundle path (nil for Audio Units).
    public var path: String?
    public var name: String
    public var vendor: String
    public var version: String
    /// "Effect", "Music Effect", or the VST 3 sub-categories ("Fx|Dynamics").
    public var category: String
    /// Audio Unit app extension (AUv3).
    public var isV3: Bool?

    public init(format: AudioPluginFormat, identifier: String, path: String? = nil, name: String, vendor: String,
                version: String = "", category: String = "", isV3: Bool? = nil) {
        self.format = format; self.identifier = identifier; self.path = path; self.name = name
        self.vendor = vendor; self.version = version; self.category = category; self.isV3 = isV3
    }

    public var id: String { "\(format.rawValue):\(identifier)" + (path.map { "@\($0)" } ?? "") }
    /// Same plug-in regardless of where its bundle moved (VST 3 matched on class id).
    public func sameClass(as other: AudioPluginDescriptor) -> Bool { format == other.format && identifier == other.identifier }
}

/// An insert slot as stored in a project.
public struct ProjectPluginSlot: Codable, Equatable, Sendable {
    public var plugin: AudioPluginDescriptor
    public var bypassed: Bool
    /// The plug-in's own preset data (Audio Unit full state as a property list, VST 3
    /// component + controller state). nil = factory defaults.
    public var state: Data?
    public init(plugin: AudioPluginDescriptor, bypassed: Bool = false, state: Data? = nil) {
        self.plugin = plugin; self.bypassed = bypassed; self.state = state
    }
}

/// Four-character codes for Audio Unit identifiers.
public enum FourCC {
    public static func string(_ v: UInt32) -> String {
        let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: bytes.map { (32...126).contains($0) ? $0 : 63 }, as: UTF8.self)
    }
    public static func value(_ s: String) -> UInt32? {
        let b = Array(s.utf8)
        guard b.count == 4 else { return nil }
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }
    /// "aufx dely appl" from three codes, and back.
    public static func identifier(type: UInt32, subtype: UInt32, manufacturer: UInt32) -> String {
        "\(string(type)) \(string(subtype)) \(string(manufacturer))"
    }
    public static func parse(identifier: String) -> (type: UInt32, subtype: UInt32, manufacturer: UInt32)? {
        // Codes may contain spaces ("lpas" vs "ap  "): split on fixed positions.
        let c = Array(identifier.utf8)
        guard c.count == 14, c[4] == 32, c[9] == 32,
              let t = value(String(decoding: c[0..<4], as: UTF8.self)),
              let s = value(String(decoding: c[5..<9], as: UTF8.self)),
              let m = value(String(decoding: c[10..<14], as: UTF8.self)) else { return nil }
        return (t, s, m)
    }
}

/// One class in the JSON the VST 3 scanner process prints.
public struct VST3ScanEntry: Codable, Equatable, Sendable {
    public var cid: String
    public var name: String
    public var vendor: String
    public var version: String
    public var subCategories: String

    public func descriptor(path: String) -> AudioPluginDescriptor {
        AudioPluginDescriptor(format: .vst3, identifier: cid, path: path, name: name, vendor: vendor.isEmpty ? "Unknown" : vendor,
                              version: version, category: subCategories)
    }

    /// Parses the scanner's output: the last line that is a JSON array (plug-ins may print
    /// their own messages to stdout while loading).
    public static func parse(scannerOutput: String) -> [VST3ScanEntry]? {
        for line in scannerOutput.split(whereSeparator: \.isNewline).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), let d = t.data(using: .utf8),
                  let v = try? JSONDecoder().decode([VST3ScanEntry].self, from: d) else { continue }
            return v
        }
        return nil
    }
}

/// Why an insert stopped processing (stored in an atomic on the render thread).
public enum PluginFault: Int, Sendable {
    case none = 0
    /// The plug-in returned errors for many blocks in a row (it crashed or stopped responding).
    case renderErrors = 1
    /// Every block took longer than real time for about a second.
    case tooSlow = 2
    /// The plug-in produced NaN / infinite samples.
    case invalidOutput = 3
    /// The out-of-process Audio Unit service ended (the plug-in crashed).
    case crashed = 4
}

/// Real-time watchdog for one insert: counts consecutive failing or slow blocks and decides when
/// the slot must be bypassed. Portable so the thresholds are unit-tested.
public struct PluginWatchdog: Sendable {
    public static let maxConsecutiveErrors = 20
    /// Slow blocks in a row before the plug-in is taken out (≈ 1 s at 48 kHz / 256-frame blocks).
    public static let maxConsecutiveSlow = 200
    public static let maxInvalidBlocks = 3
    private var errors = 0
    private var slow = 0
    private var invalid = 0
    public init() {}

    /// Records one block; returns the fault that should stop the plug-in, if any.
    public mutating func record(ok: Bool, seconds: Double, blockSeconds: Double, finite: Bool) -> PluginFault {
        if !ok { errors += 1 } else { errors = 0 }
        if errors >= Self.maxConsecutiveErrors { return .renderErrors }
        if ok && !finite { invalid += 1 } else if ok { invalid = 0 }
        if invalid >= Self.maxInvalidBlocks { return .invalidOutput }
        if seconds > blockSeconds { slow += 1 } else { slow = 0 }
        if slow >= Self.maxConsecutiveSlow { return .tooSlow }
        return .none
    }
}

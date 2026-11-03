/// MultiCorder (ISO recording): chosen inputs are each recorded to their own file, for editing
/// afterwards. Since 0.33.0 it has its own button and recording profile, separate from RECORD.
/// The selection is saved in the project.
public struct MultiCorderConfig: Codable, Equatable, Sendable {
    /// Each ISO file is one more full-size render and one more H.264 encode.
    public static let maxInputs = 4

    /// Inputs recorded on their own, in the order chosen.
    public private(set) var inputs: [InputID]
    /// Read from 0.32.0 projects (when ISO files followed RECORD); not used since 0.33.0.
    public var enabled: Bool
    /// Audio bus per ISO file (since 0.35.0), keyed by input id; absent = the profile's bus.
    public private(set) var buses: [String: OutputBus] = [:]

    public init(inputs: [InputID] = [], enabled: Bool = true) {
        var seen = Set<InputID>()
        self.inputs = Array(inputs.filter { seen.insert($0).inserted }.prefix(Self.maxInputs))
        self.enabled = enabled
    }

    public func contains(_ id: InputID) -> Bool { inputs.contains(id) }

    /// The bus an ISO file records: its own choice, else the profile's.
    public func bus(for id: InputID, profile: OutputBus) -> OutputBus { buses[id.raw] ?? profile }
    /// The file's own bus choice (nil = follow the profile).
    public func ownBus(_ id: InputID) -> OutputBus? { buses[id.raw] }
    public mutating func setBus(_ bus: OutputBus?, for id: InputID) { buses[id.raw] = bus }
    public var isFull: Bool { inputs.count >= Self.maxInputs }

    /// The inputs the MULTICORDER button records.
    public var active: [InputID] { inputs }

    /// Adds or removes an input; returns false when it cannot be added (already 4 inputs).
    @discardableResult
    public mutating func toggle(_ id: InputID) -> Bool {
        if let i = inputs.firstIndex(of: id) { inputs.remove(at: i); buses[id.raw] = nil; return true }
        guard !isFull else { return false }
        inputs.append(id)
        return true
    }

    /// Drops inputs that no longer exist.
    public func keeping(existing: Set<InputID>) -> MultiCorderConfig {
        var m = MultiCorderConfig(inputs: inputs.filter { existing.contains($0) }, enabled: enabled)
        m.buses = buses.filter { k, _ in m.inputs.contains { $0.raw == k } }
        return m
    }

    // Older projects and settings decode without these keys.
    private enum CodingKeys: String, CodingKey { case inputs, enabled, buses }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(inputs: try c.decodeIfPresent([InputID].self, forKey: .inputs) ?? [],
                  enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
        let b = (try? c.decodeIfPresent([String: OutputBus].self, forKey: .buses)) ?? nil
        buses = (b ?? [:]).filter { k, _ in inputs.contains { $0.raw == k } }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputs, forKey: .inputs)
        try c.encode(enabled, forKey: .enabled)
        if !buses.isEmpty { try c.encode(buses, forKey: .buses) }
    }

    /// " - ISO 2 Kamera Wide": added to the Program file name before the extension.
    public static func fileSuffix(number: Int, name: String) -> String {
        let illegal: Set<Character> = ["/", ":", "\\", "\0"]
        var clean = String(name.map { illegal.contains($0) || $0.isNewline ? "-" : $0 })
        while clean.first == " " || clean.first == "." { clean.removeFirst() }
        while clean.last == " " { clean.removeLast() }
        if clean.count > 60 { clean = String(clean.prefix(60)) }
        return clean.isEmpty ? " - ISO \(number)" : " - ISO \(number) \(clean)"
    }

    /// "Recording 2026-10-28 10-00-00.mp4" + suffix → "Recording 2026-10-28 10-00-00 - ISO 2 Cam.mp4".
    public static func isoFileName(_ programFileName: String, suffix: String) -> String {
        guard let dot = programFileName.lastIndex(of: "."), dot != programFileName.startIndex else { return programFileName + suffix }
        return String(programFileName[..<dot]) + suffix + String(programFileName[dot...])
    }
}

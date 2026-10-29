/// An NDI® source received as an input (since 0.29.0): a camera app on a phone, OBS / vMix on
/// another computer, NDI HX cameras, or another LiveCore.
public struct ProjectNDI: Codable, Equatable, Sendable {
    /// Full NDI name, "<MACHINE> (<source>)".
    public var sourceName: String
    /// Ask the sender for its low-bandwidth preview stream (nil = full quality).
    public var lowBandwidth: Bool?
    /// Put the source's audio on its own mixer channel (nil = yes).
    public var audio: Bool?

    public init(sourceName: String, lowBandwidth: Bool? = nil, audio: Bool? = nil) {
        self.sourceName = sourceName; self.lowBandwidth = lowBandwidth; self.audio = audio
    }

    public var wantsAudio: Bool { audio ?? true }
    public var wantsLowBandwidth: Bool { lowBandwidth ?? false }
    /// Input name: the source part of the NDI name.
    public var displayName: String { NDISourceName.split(sourceName).name }
}

public enum NDISourceName {
    /// "STUDIO-MAC (OBS)" → ("STUDIO-MAC", "OBS"); names without brackets have no machine.
    public static func split(_ full: String) -> (machine: String, name: String) {
        guard full.hasSuffix(")"), let open = full.firstIndex(of: "(") else { return ("", full) }
        let machine = full[..<open].trimmingSpaces
        let name = full[full.index(after: open)..<full.index(before: full.endIndex)].trimmingSpaces
        return name.isEmpty ? ("", full) : (machine, name)
    }

    /// Sources of this app itself ("LiveCore Output N"): receiving them back would loop Program.
    public static func isOwnOutput(_ full: String) -> Bool { split(full).name.hasPrefix("LiveCore Output") }
}

private extension Substring {
    var trimmingSpaces: String {
        var s = self
        while s.first == " " { s.removeFirst() }
        while s.last == " " { s.removeLast() }
        return String(s)
    }
}

/// The four extra outputs (vMix "Outputs"): each takes its own picture, Program, Preview or a
/// single input at full output size, and sends it to a window or full-screen display, to other
/// apps over Syphon, and over the network (or to NDI Virtual Camera) as an NDI® source.

/// Where an output takes its picture from.
public enum OutputSource: Codable, Equatable, Hashable, Sendable {
    case program
    case preview
    case input(InputID)
}

public struct OutputSlot: Codable, Equatable, Sendable {
    /// 1...4.
    public var index: Int
    public var source: OutputSource
    /// Publish this output as a Syphon server ("LiveCore Studio – Output N").
    public var syphon: Bool
    /// Send this output as an NDI source ("<Mac name> (LiveCore Output N)").
    public var ndi: Bool

    public init(index: Int, source: OutputSource = .program, syphon: Bool = false, ndi: Bool = false) {
        self.index = index; self.source = source; self.syphon = syphon; self.ndi = ndi
    }

    private enum CodingKeys: String, CodingKey { case index, source, syphon, ndi }

    /// Projects saved before 0.24.0 have no `ndi` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        source = try c.decode(OutputSource.self, forKey: .source)
        syphon = try c.decodeIfPresent(Bool.self, forKey: .syphon) ?? false
        ndi = try c.decodeIfPresent(Bool.self, forKey: .ndi) ?? false
    }
}

public struct OutputRouting: Codable, Equatable, Sendable {
    public static let count = 4

    public var slots: [OutputSlot]

    public init(slots: [OutputSlot] = OutputRouting.defaultSlots) {
        self.slots = slots
        self = normalized(existing: nil)
    }

    /// Output 1 shows Program, output 2 Preview, outputs 3 and 4 Program (like vMix).
    public static var defaultSlots: [OutputSlot] {
        [OutputSlot(index: 1, source: .program), OutputSlot(index: 2, source: .preview),
         OutputSlot(index: 3, source: .program), OutputSlot(index: 4, source: .program)]
    }

    public func slot(_ index: Int) -> OutputSlot {
        slots.first { $0.index == index } ?? OutputSlot(index: index)
    }

    public mutating func setSource(_ index: Int, _ source: OutputSource) {
        guard let i = slots.firstIndex(where: { $0.index == index }) else { return }
        slots[i].source = source
    }

    public mutating func setSyphon(_ index: Int, _ on: Bool) {
        guard let i = slots.firstIndex(where: { $0.index == index }) else { return }
        slots[i].syphon = on
    }

    public mutating func setNDI(_ index: Int, _ on: Bool) {
        guard let i = slots.firstIndex(where: { $0.index == index }) else { return }
        slots[i].ndi = on
    }

    /// Exactly four slots numbered 1...4, in order. With `existing`, outputs that point at an
    /// input that no longer exists fall back to Program.
    public func normalized(existing: Set<InputID>?) -> OutputRouting {
        var out = self
        out.slots = (1...Self.count).map { n in
            var s = slots.first { $0.index == n } ?? Self.defaultSlots[n - 1]
            s.index = n
            if case let .input(id) = s.source, let existing, !existing.contains(id) { s.source = .program }
            return s
        }
        return out
    }

    /// Inputs that need their own full-size picture this frame, for outputs that are in use.
    /// `active` lists the outputs that have somewhere to go (window or Syphon).
    public func renderedInputs(active: Set<Int>) -> [InputID] {
        var seen = Set<InputID>()
        var list: [InputID] = []
        for s in slots where active.contains(s.index) {
            if case let .input(id) = s.source, seen.insert(id).inserted { list.append(id) }
        }
        return list
    }

    /// True when an active output shows Preview (rendered at full size only then).
    public func needsFullPreview(active: Set<Int>) -> Bool {
        slots.contains { active.contains($0.index) && $0.source == .preview }
    }

    /// Outputs that have a destination: Syphon or NDI on, or shown in `windows`.
    public func activeOutputs(windows: Set<Int>) -> Set<Int> {
        var a = windows
        for s in slots where s.syphon || s.ndi { a.insert(s.index) }
        return a
    }

    /// EXTERNAL turned on. With nothing sending, Output 1 starts sending over Syphon, so other
    /// apps always find at least one source. With `ndi` (the NDI runtime is installed and NDI
    /// was never offered before), Output 1 also starts sending over NDI unless an output already does.
    public func withDefaultSending(ndi: Bool) -> OutputRouting {
        var r = self
        if !slots.contains(where: { $0.syphon || $0.ndi }) { r.setSyphon(1, true) }
        if ndi, !slots.contains(where: \.ndi) { r.setNDI(1, true) }
        return r
    }

    public static func syphonName(_ index: Int) -> String { "Output \(index)" }
    /// NDI source name; receivers show it as "<Mac name> (LiveCore Output N)".
    public static func ndiName(_ index: Int) -> String { "LiveCore Output \(index)" }
}

/// vMix-style "NOT RECORDING" warning that blinks over the Program monitor.
public enum RecordReminderMode: String, Codable, CaseIterable, Sendable {
    case off
    /// Whenever nothing is being recorded.
    case always
    /// Only while streaming without recording (the usual mistake: live but no backup file).
    case whileStreaming
}

public enum RecordReminder {
    /// Whether the warning applies right now.
    public static func applies(mode: RecordReminderMode, recording: Bool, streaming: Bool) -> Bool {
        guard !recording else { return false }
        switch mode {
        case .off: return false
        case .always: return true
        case .whileStreaming: return streaming
        }
    }

    /// Blink phase: visible for the first 60 % of each period (a calm 2-second cycle).
    public static func visible(elapsed: Double, period: Double = 2.0) -> Bool {
        guard period > 0, elapsed.isFinite else { return true }
        var t = elapsed.truncatingRemainder(dividingBy: period)
        if t < 0 { t += period }
        return t < period * 0.6
    }
}

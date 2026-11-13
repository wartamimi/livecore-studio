/// Macros and triggers (0.65.0): a macro is a named list of steps run one after another
/// (switch, overlays, audio on/off, waits, stream / record); a trigger runs a macro by itself
/// when something happens (an input goes to Program, a video ends, the stream starts...).
/// Macros are started from the Macros window, a keyboard shortcut, MIDI or the Web Controller.
/// Portable model (stored in projects); the app runs the steps.

/// What a step does. Raw values are stored in projects.
public enum MacroStepKind: String, Codable, CaseIterable, Sendable {
    case cut, auto
    case preview          // input → Preview
    case program          // input straight to Program (cut)
    case transition       // input → Preview, then AUTO with the current transition
    case overlayOn, overlayOff, overlayToggle
    case audioOn, audioOff   // unmute / mute a mixer channel
    case videoPlay, videoPause, videoRestart
    case wait
    case streamStart, streamStop, recordStart, recordStop
    case snapshot, highlight
    /// 0.71.0: run another macro's steps here (nested, at most `MacroBook.maxNesting` deep).
    case runMacro
    /// 0.71.0: move a mixer channel's fader to `level` dB over `seconds` (does not wait).
    case audioFade

    public var needsInput: Bool {
        switch self {
        case .preview, .program, .transition, .videoPlay, .videoPause, .videoRestart: return true
        default: return false
        }
    }
    public var needsOverlay: Bool { self == .overlayOn || self == .overlayOff || self == .overlayToggle }
    public var needsChannel: Bool { self == .audioOn || self == .audioOff || self == .audioFade }
    /// Steps that start a transition: the next step waits until it has finished.
    public var runsTransition: Bool { self == .auto || self == .transition }
}

/// One step. Unused fields stay nil (flat so it stays editable and the file format is simple).
public struct MacroStep: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: MacroStepKind
    public var input: InputID?
    /// Overlay channel 1...4.
    public var overlay: Int?
    /// Mixer channel id.
    public var channel: String?
    /// Wait length, or the fade time of an audio fade.
    public var seconds: Double?
    /// Macro number (1...) of a "run macro" step (0.71.0).
    public var macro: Int?
    /// Target fader level in dB of an audio fade (0.71.0); -90 or lower = fade out.
    public var level: Double?
    /// The step only runs when this holds (0.71.0); nil = always.
    public var condition: MacroCondition?

    public init(_ kind: MacroStepKind, input: InputID? = nil, overlay: Int? = nil, channel: String? = nil,
                seconds: Double? = nil, macro: Int? = nil, level: Double? = nil, condition: MacroCondition? = nil,
                id: String = MacroBook.newID()) {
        self.id = id; self.kind = kind; self.input = input; self.overlay = overlay; self.channel = channel; self.seconds = seconds
        self.macro = macro; self.level = level; self.condition = condition
    }

    public static let maxFade: Double = 60

    /// Fade time clamped to 0...60 s.
    public var fadeSeconds: Double {
        guard kind == .audioFade, let s = seconds, s.isFinite else { return 0 }
        return min(max(s, 0), Self.maxFade)
    }

    /// Fade target clamped to -90...+10 dB (default 0 dB).
    public var fadeLevelDB: Double {
        guard let l = level, l.isFinite else { return 0 }
        return min(max(l, -90), 10)
    }

    public static let maxWait: Double = 3600

    /// The wait in seconds, clamped to 0...1 h (0 for other steps).
    public var waitSeconds: Double {
        guard kind == .wait, let s = seconds, s.isFinite else { return 0 }
        return min(max(s, 0), Self.maxWait)
    }

    /// Overlay number clamped to 1...4, nil when missing.
    public var overlayIndex: Int? { overlay.flatMap { (1...4).contains($0) ? $0 : nil } }

    /// Whether the step has what it needs to run.
    public var isComplete: Bool {
        if kind.needsInput && input == nil { return false }
        if kind.needsOverlay && overlayIndex == nil { return false }
        if kind.needsChannel && (channel ?? "").isEmpty { return false }
        if kind == .runMacro && !(1...MacroBook.maxNumber).contains(macro ?? 0) { return false }
        if let c = condition, c.kind.needsInput && c.input == nil { return false }
        return true
    }
}

/// A step's condition (0.71.0): checked when the step is reached.
public struct MacroCondition: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case programIs, programIsNot, previewIs, streaming, notStreaming, recording, notRecording
        public var needsInput: Bool { self == .programIs || self == .programIsNot || self == .previewIs }
    }
    public var kind: Kind
    public var input: InputID?
    public init(_ kind: Kind, input: InputID? = nil) { self.kind = kind; self.input = input }

    public func holds(program: InputID?, preview: InputID?, streaming: Bool, recording: Bool) -> Bool {
        switch kind {
        case .programIs: return input != nil && program == input
        case .programIsNot: return input != nil && program != input
        case .previewIs: return input != nil && preview == input
        case .streaming: return streaming
        case .notStreaming: return !streaming
        case .recording: return recording
        case .notRecording: return !recording
        }
    }
}

/// When a trigger fires.
public enum MacroTriggerEvent: String, Codable, CaseIterable, Sendable {
    case programIn        // an input goes on Program
    case programOut       // an input leaves Program
    case previewIn        // an input is put on Preview
    case videoEnded       // a video input's clip plays to its end
    case streamStarted, streamStopped, recordStarted, recordStopped
    /// 0.71.0: every day at the trigger's `time` ("HH:mm", local time) while the app runs.
    case timeOfDay

    /// Events that belong to an input (the trigger can name one, or nil = any input).
    public var hasInput: Bool {
        switch self {
        case .programIn, .programOut, .previewIn, .videoEnded: return true
        default: return false
        }
    }
}

public struct MacroTrigger: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var event: MacroTriggerEvent
    /// The input the event must be about; nil = any input.
    public var input: InputID?
    public var enabled: Bool
    /// "HH:mm" of a time-of-day trigger (0.71.0).
    public var time: String?

    public init(_ event: MacroTriggerEvent, input: InputID? = nil, enabled: Bool = true, time: String? = nil,
                id: String = MacroBook.newID()) {
        self.id = id; self.event = event; self.input = input; self.enabled = enabled; self.time = time
    }

    /// "7:5", "07:05" and "0705" all become "07:05"; nil when it is not a time of day.
    public static func normalizedTime(_ s: String?) -> String? {
        guard let s = s?.trimmed, !s.isEmpty else { return nil }
        let parts: [Substring]
        if s.contains(":") || s.contains(".") { parts = s.split(whereSeparator: { $0 == ":" || $0 == "." }) }
        else if s.count == 4 { parts = [s.prefix(2), s.suffix(2)] } else { return nil }
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h < 10 ? "0" : "") + String(h) + ":" + (m < 10 ? "0" : "") + String(m)
    }

    public func matches(_ e: MacroEvent) -> Bool {
        guard enabled, e.kind == event else { return false }
        if event == .timeOfDay { return Self.normalizedTime(time).map { $0 == e.time } ?? false }
        guard event.hasInput, let want = input else { return true }
        return e.input == want
    }
}

/// Something that happened in the app, checked against the triggers.
public struct MacroEvent: Equatable, Sendable {
    public var kind: MacroTriggerEvent
    public var input: InputID?
    /// "HH:mm" for `.timeOfDay`.
    public var time: String?
    public init(_ kind: MacroTriggerEvent, input: InputID? = nil, time: String? = nil) {
        self.kind = kind; self.input = input; self.time = time
    }

    /// Events of a Program / Preview change (nil = nothing on the bus).
    public static func switching(oldProgram: InputID?, newProgram: InputID?, oldPreview: InputID?, newPreview: InputID?) -> [MacroEvent] {
        var out: [MacroEvent] = []
        if oldProgram != newProgram {
            if let o = oldProgram { out.append(MacroEvent(.programOut, input: o)) }
            if let n = newProgram { out.append(MacroEvent(.programIn, input: n)) }
        }
        if oldPreview != newPreview, let n = newPreview { out.append(MacroEvent(.previewIn, input: n)) }
        return out
    }
}

public struct Macro: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var steps: [MacroStep]
    public var triggers: [MacroTrigger]

    public init(name: String, steps: [MacroStep] = [], triggers: [MacroTrigger] = [], id: String = MacroBook.newID()) {
        self.id = id; self.name = name; self.steps = steps; self.triggers = triggers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? MacroBook.newID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Macro"
        // Steps of a kind this version does not know are dropped instead of failing the project.
        steps = (try? c.decode([Lenient<MacroStep>].self, forKey: .steps))?.compactMap(\.value) ?? []
        triggers = (try? c.decode([Lenient<MacroTrigger>].self, forKey: .triggers))?.compactMap(\.value) ?? []
    }
}

/// Decodes an element or nil (one bad entry does not lose the whole list).
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// All macros of a production, in order (macro 1 is the first; shortcuts, MIDI and the Web
/// Controller address macros by this number).
public struct MacroBook: Codable, Equatable, Sendable {
    public var macros: [Macro] = []
    public init(_ macros: [Macro] = []) { self.macros = macros }

    public static let maxNumber = 16
    /// Macros inside macros go at most this deep (and never into themselves).
    public static let maxNesting = 4

    /// The steps of a macro with every "run macro" step replaced by that macro's steps
    /// (recursively). A condition on a "run macro" step is given to each step it brings in that
    /// has no condition of its own. Loops and nesting past `maxNesting` are dropped.
    public func expandedSteps(_ steps: [MacroStep], visiting: Set<Int> = [], depth: Int = 0) -> [MacroStep] {
        var out: [MacroStep] = []
        for s in steps {
            guard s.kind == .runMacro else { out.append(s); continue }
            guard let n = s.macro, let m = macro(number: n), !visiting.contains(n), depth < Self.maxNesting else { continue }
            var inner = expandedSteps(m.steps, visiting: visiting.union([n]), depth: depth + 1)
            if let c = s.condition {
                for k in inner.indices where inner[k].condition == nil { inner[k].condition = c }
            }
            out += inner
        }
        return out
    }

    /// `expandedSteps` for a whole macro (it cannot run itself).
    public func expandedSteps(of m: Macro) -> [MacroStep] {
        expandedSteps(m.steps, visiting: number(of: m.id).map { [$0] } ?? [])
    }

    public static func newID() -> String { String(UInt64.random(in: 1 ... UInt64.max), radix: 36) }

    public func macro(number n: Int) -> Macro? { macros.indices.contains(n - 1) ? macros[n - 1] : nil }
    public func number(of id: String) -> Int? { macros.firstIndex { $0.id == id }.map { $0 + 1 } }

    /// Macros with a trigger for this event, in order (each at most once).
    public func macros(for e: MacroEvent) -> [Macro] {
        macros.filter { m in m.triggers.contains { $0.matches(e) } }
    }

    /// Removes references to inputs / channels that no longer exist (steps keep their place but
    /// become incomplete so the operator sees them; triggers fall back to "any input" = off).
    public func pruned(inputs: Set<InputID>) -> MacroBook {
        var b = self
        for m in b.macros.indices {
            for s in b.macros[m].steps.indices where b.macros[m].steps[s].input.map({ !inputs.contains($0) }) ?? false {
                b.macros[m].steps[s].input = nil
            }
            for s in b.macros[m].steps.indices where b.macros[m].steps[s].condition?.input.map({ !inputs.contains($0) }) ?? false {
                b.macros[m].steps[s].condition?.input = nil
            }
            for t in b.macros[m].triggers.indices where b.macros[m].triggers[t].input.map({ !inputs.contains($0) }) ?? false {
                b.macros[m].triggers[t].input = nil
                b.macros[m].triggers[t].enabled = false
            }
        }
        return b
    }
}

/// Stops trigger loops (macro A cuts to X, X going on air runs macro B that cuts back...): at
/// most `limit` trigger starts within `window` seconds; past that, triggers pause until the
/// operator re-arms them. A macro that is still running is not started again by a trigger.
public struct MacroTriggerGuard: Sendable {
    public var limit = 12
    public var window: Double = 5
    public private(set) var tripped = false
    private var times: [Double] = []

    public init() {}

    public mutating func allow(now: Double) -> Bool {
        guard !tripped else { return false }
        times.removeAll { now - $0 > window }
        guard times.count < limit else { tripped = true; return false }
        times.append(now)
        return true
    }

    public mutating func rearm() { tripped = false; times.removeAll() }
}

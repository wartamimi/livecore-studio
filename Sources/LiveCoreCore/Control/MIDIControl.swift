/// MIDI remote control: message parsing, trigger matching and the action map.
/// Pure and Foundation-free (unit-tested on Linux); CoreMIDI I/O lives in the engine.

/// A MIDI 1.0 channel voice message reduced to what control surfaces send.
public enum MIDIMessage: Equatable, Sendable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)

    /// Parses a status byte + two data bytes. Note-on with velocity 0 is a note-off.
    /// Returns nil for anything else (clock, sysex, program change...).
    public static func parse(status: UInt8, data1: UInt8, data2: UInt8) -> MIDIMessage? {
        let ch = status & 0x0F
        switch status & 0xF0 {
        case 0x90: return data2 == 0 ? .noteOff(channel: ch, note: data1 & 0x7F) : .noteOn(channel: ch, note: data1 & 0x7F, velocity: data2 & 0x7F)
        case 0x80: return .noteOff(channel: ch, note: data1 & 0x7F)
        case 0xB0: return .controlChange(channel: ch, controller: data1 & 0x7F, value: data2 & 0x7F)
        default: return nil
        }
    }

    /// Parses one 32-bit Universal MIDI Packet word of message type 2 (MIDI 1.0 channel voice).
    public static func parse(umpWord w: UInt32) -> MIDIMessage? {
        guard w >> 28 == 0x2 else { return nil }
        return parse(status: UInt8((w >> 16) & 0xFF), data1: UInt8((w >> 8) & 0xFF), data2: UInt8(w & 0xFF))
    }

    /// Parses a MIDI 1.0 byte stream (running status supported, realtime bytes skipped).
    public static func parse(bytes: [UInt8]) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        var status: UInt8 = 0
        var data: [UInt8] = []
        for b in bytes {
            if b >= 0xF8 { continue }                         // realtime: clock, start/stop...
            if b & 0x80 != 0 { status = b < 0xF0 ? b : 0; data.removeAll(); continue }
            guard status != 0 else { continue }
            data.append(b)
            let needed = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
            if data.count == needed {
                if needed == 2, let m = parse(status: status, data1: data[0], data2: data[1]) { out.append(m) }
                data.removeAll()
            }
        }
        return out
    }

    public var trigger: MIDITrigger {
        switch self {
        case let .noteOn(ch, n, _), let .noteOff(ch, n): return MIDITrigger(kind: .note, channel: ch, number: n)
        case let .controlChange(ch, c, _): return MIDITrigger(kind: .cc, channel: ch, number: c)
        }
    }
}

/// What a mapping listens to: a note or a controller number on a channel (0-based).
public struct MIDITrigger: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable { case note, cc }
    public var kind: Kind
    public var channel: UInt8
    public var number: UInt8
    public init(kind: Kind, channel: UInt8, number: UInt8) { self.kind = kind; self.channel = channel; self.number = number }

    public var description: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        switch kind {
        case .note: return "Note \(names[Int(number) % 12])\(Int(number) / 12 - 1) · ch \(channel + 1)"
        case .cc: return "CC \(number) · ch \(channel + 1)"
        }
    }
}

/// Operator actions that can be bound to MIDI.
public enum ControlAction: Hashable, Codable, Sendable {
    case cut, auto, tbar, streamToggle, recordToggle, snapshot, fullscreenToggle
    case preview(Int)       // input number 1...
    case cutDirect(Int)     // input number 1...
    case overlay(Int)       // overlay channel 1...4

    /// The actions offered in the MIDI settings, in display order.
    public static let catalog: [ControlAction] =
        [.cut, .auto, .tbar, .streamToggle, .recordToggle, .snapshot, .fullscreenToggle]
        + (1...8).map { .preview($0) } + (1...8).map { .cutDirect($0) } + (1...4).map { .overlay($0) }

    /// Continuous actions follow a fader/knob (CC value); the others fire on a press.
    public var isContinuous: Bool { self == .tbar }
}

/// One binding of a trigger to an action.
public struct MIDIMapping: Codable, Equatable, Sendable {
    public var trigger: MIDITrigger
    public var action: ControlAction
    public init(trigger: MIDITrigger, action: ControlAction) { self.trigger = trigger; self.action = action }
}

/// What the app should do in response to a message.
public enum ControlEvent: Equatable, Sendable {
    case fire(ControlAction)
    case set(ControlAction, value: Double)   // 0...1
}

public struct MIDIMap: Codable, Equatable, Sendable {
    public private(set) var mappings: [MIDIMapping] = []
    public init(mappings: [MIDIMapping] = []) { mappings.forEach { bind($0.trigger, to: $0.action) } }

    /// Binds a trigger; a trigger drives one action and an action has one trigger.
    public mutating func bind(_ trigger: MIDITrigger, to action: ControlAction) {
        mappings.removeAll { $0.trigger == trigger || $0.action == action }
        mappings.append(MIDIMapping(trigger: trigger, action: action))
    }

    public mutating func clear(_ action: ControlAction) { mappings.removeAll { $0.action == action } }

    public func trigger(for action: ControlAction) -> MIDITrigger? { mappings.first { $0.action == action }?.trigger }

    /// Buttons fire on note-on, or on a CC crossing to >= 64 (pads that send CC 127/0).
    /// Continuous actions take the CC value (or note velocity) scaled to 0...1.
    public func event(for message: MIDIMessage) -> ControlEvent? {
        guard let m = mappings.first(where: { $0.trigger == message.trigger }) else { return nil }
        switch (message, m.action.isContinuous) {
        case let (.controlChange(_, _, v), true): return .set(m.action, value: Double(v) / 127)
        case let (.noteOn(_, _, v), true): return .set(m.action, value: Double(v) / 127)
        case (.noteOff, true): return nil
        case (.noteOn, false): return .fire(m.action)
        case let (.controlChange(_, _, v), false): return v >= 64 ? .fire(m.action) : nil
        case (.noteOff, false): return nil
        }
    }
}

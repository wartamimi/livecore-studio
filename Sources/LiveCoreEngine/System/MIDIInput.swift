#if os(macOS)
import CoreMIDI
import Foundation
import LiveCoreCore

/// Listens to every MIDI source (USB controllers, network sessions, IAC buses) and delivers
/// parsed channel-voice messages on the main thread. Sources plugged in later are connected
/// automatically.
public final class MIDIInput {
    /// Called on the main thread for every note/CC message.
    public var onMessage: ((MIDIMessage) -> Void)?
    /// Names of the connected sources (main thread).
    public private(set) var sourceNames: [String] = []
    public var onSourcesChange: (() -> Void)?
    public private(set) var error: String?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected = Set<MIDIEndpointRef>()

    public init() {}

    public func start() {
        guard client == 0 else { return }
        var st = MIDIClientCreateWithBlock("LiveCore Studio" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAll() }
            }
        }
        guard st == noErr else { error = "CoreMIDI client error \(st)"; return }
        st = MIDIInputPortCreateWithProtocol(client, "LiveCore In" as CFString, ._1_0, &port) { [weak self] list, _ in
            let messages = MIDIInput.parse(list)
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async { messages.forEach { self?.onMessage?($0) } }
        }
        guard st == noErr else { error = "CoreMIDI port error \(st)"; return }
        connectAll()
    }

    public func stop() {
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        connected.removeAll()
        sourceNames = []
    }

    private func connectAll() {
        guard port != 0 else { return }
        var names: [String] = []
        var present = Set<MIDIEndpointRef>()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            present.insert(src)
            if !connected.contains(src), MIDIPortConnectSource(port, src, nil) == noErr { connected.insert(src) }
            names.append(Self.name(of: src))
        }
        connected = connected.intersection(present)
        sourceNames = names
        onSourcesChange?()
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() else {
            return "MIDI"
        }
        return s as String
    }

    /// Walks a MIDIEventList (MIDI 1.0 protocol: UMP words of type 2).
    private static func parse(_ list: UnsafePointer<MIDIEventList>) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        let count = Int(list.pointee.numPackets)
        guard count > 0, let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet),
              let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) else { return out }
        var packet = (UnsafeRawPointer(list) + packetOffset).assumingMemoryBound(to: MIDIEventPacket.self)
        for i in 0..<count {
            let n = min(Int(packet.pointee.wordCount), 64)
            let words = (UnsafeRawPointer(packet) + wordsOffset).assumingMemoryBound(to: UInt32.self)
            var w = 0
            while w < n {
                let word = words[w]
                if let m = MIDIMessage.parse(umpWord: word) { out.append(m) }
                // UMP message size by type: 0-2 -> 1 word, 3-4 -> 2, 5 -> 4.
                switch word >> 28 {
                case 0x3, 0x4: w += 2
                case 0x5: w += 4
                default: w += 1
                }
            }
            if i < count - 1 { packet = UnsafePointer(MIDIEventPacketNext(packet)) }
        }
        return out
    }
}
#endif

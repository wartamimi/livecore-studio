/// PTZ camera control with VISCA (Sony protocol used by most PTZ cameras: PTZOptics, Avonic,
/// Lumens, BirdDog, AVer, Marshall, many unbranded models). Commands are built here (portable,
/// tested); the macOS engine sends them over the network.
public struct PTZConfig: Codable, Equatable, Sendable {
    public enum Transport: String, Codable, Sendable, CaseIterable {
        /// Sony VISCA over IP: UDP 52381 with the 8-byte VISCA-over-IP header.
        case sonyUDP
        /// Plain VISCA bytes over UDP (often port 1259).
        case udp
        /// Plain VISCA bytes over TCP (often port 5678).
        case tcp

        public var defaultPort: Int {
            switch self { case .sonyUDP: return 52381; case .udp: return 1259; case .tcp: return 5678 }
        }
    }
    public var host: String
    public var port: Int
    public var transport: Transport
    /// VISCA camera address 1...7 (1 for network cameras).
    public var address: Int
    /// Pan/tilt speed for the arrow buttons, 1...24 (tilt is capped at 20).
    public var speed: Int
    /// Optional names for presets 1...8 ("Pengantin", "Podium"...).
    public var presetNames: [String]

    public init(host: String, transport: Transport = .sonyUDP, port: Int? = nil, address: Int = 1, speed: Int = 8,
                presetNames: [String] = []) {
        self.host = host; self.transport = transport; self.port = port ?? transport.defaultPort
        self.address = address; self.speed = speed; self.presetNames = presetNames
    }

    public static let presetCount = 8

    public var clamped: PTZConfig {
        var c = self
        c.port = (1...65_535).contains(port) ? port : transport.defaultPort
        c.address = min(max(address, 1), 7)
        c.speed = min(max(speed, 1), 24)
        c.presetNames = Array(presetNames.prefix(Self.presetCount)).map { String($0.prefix(40)) }
        c.host = host.trimmingWhitespace
        return c
    }

    public func presetName(_ index: Int) -> String {
        index < presetNames.count && !presetNames[index].isEmpty ? presetNames[index] : "\(index + 1)"
    }
}

public enum VISCA {
    public enum Pan: UInt8 { case left = 0x01, right = 0x02, stop = 0x03 }
    public enum Tilt: UInt8 { case up = 0x01, down = 0x02, stop = 0x03 }

    public enum Command: Equatable {
        case panTilt(pan: Pan, tilt: Tilt, panSpeed: Int, tiltSpeed: Int)
        case home
        case zoom(ZoomKind)
        case autoFocus
        case onePushFocus
        case recallPreset(Int)
        case storePreset(Int)

        public enum ZoomKind: Equatable { case stop, tele(Int), wide(Int) }
    }

    /// The VISCA message (header 0x8n … terminator 0xFF).
    public static func bytes(_ command: Command, address: Int = 1) -> [UInt8] {
        let header = UInt8(0x80 | min(max(address, 1), 7))
        let body: [UInt8]
        switch command {
        case let .panTilt(pan, tilt, ps, ts):
            body = [0x01, 0x06, 0x01, UInt8(min(max(ps, 1), 0x18)), UInt8(min(max(ts, 1), 0x14)), pan.rawValue, tilt.rawValue]
        case .home:
            body = [0x01, 0x06, 0x04]
        case let .zoom(z):
            switch z {
            case .stop: body = [0x01, 0x04, 0x07, 0x00]
            case let .tele(s): body = [0x01, 0x04, 0x07, 0x20 | UInt8(min(max(s, 0), 7))]
            case let .wide(s): body = [0x01, 0x04, 0x07, 0x30 | UInt8(min(max(s, 0), 7))]
            }
        case .autoFocus:
            body = [0x01, 0x04, 0x38, 0x02]
        case .onePushFocus:
            body = [0x01, 0x04, 0x18, 0x01]
        case let .recallPreset(n):
            body = [0x01, 0x04, 0x3F, 0x02, UInt8(min(max(n, 0), 127))]
        case let .storePreset(n):
            body = [0x01, 0x04, 0x3F, 0x01, UInt8(min(max(n, 0), 127))]
        }
        return [header] + body + [0xFF]
    }

    /// Sony VISCA over IP packet: payload type 0x0100 (command), length, sequence number, message.
    public static func sonyPacket(_ message: [UInt8], sequence: UInt32) -> [UInt8] {
        let len = UInt16(message.count)
        return [0x01, 0x00, UInt8(len >> 8), UInt8(len & 0xFF),
                UInt8(sequence >> 24), UInt8((sequence >> 16) & 0xFF), UInt8((sequence >> 8) & 0xFF), UInt8(sequence & 0xFF)] + message
    }

    /// Sony VISCA over IP "reset sequence number" control packet (sent once before the first command).
    public static let sonyResetSequence: [UInt8] = [0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01]

    /// What goes on the wire for `config`'s transport.
    public static func packet(_ command: Command, config: PTZConfig, sequence: UInt32) -> [UInt8] {
        let msg = bytes(command, address: config.address)
        return config.transport == .sonyUDP ? sonyPacket(msg, sequence: sequence) : msg
    }
}

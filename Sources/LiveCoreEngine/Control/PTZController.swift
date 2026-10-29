#if os(macOS)
import Foundation
import LiveCoreCore
import Network

/// Sends VISCA commands to one PTZ camera over UDP (Sony VISCA over IP or plain) or TCP.
/// The connection opens on the first command and is reused; replies from the camera are read
/// and ignored (some cameras stop answering when nobody reads them).
public final class PTZController {
    public private(set) var config: PTZConfig
    /// Main thread: last error ("connection refused"...), nil when the last send worked.
    public var onStatus: ((String?) -> Void)?

    private var connection: NWConnection?
    private var sequence: UInt32 = 0
    private let queue = DispatchQueue(label: "livecore.ptz")

    public init(config: PTZConfig) { self.config = config.clamped }

    deinit { connection?.cancel() }

    public func update(_ c: PTZConfig) {
        let new = c.clamped
        if new.host != config.host || new.port != config.port || new.transport != config.transport {
            connection?.cancel()
            connection = nil
        }
        config = new
    }

    public func send(_ command: VISCA.Command) {
        guard !config.host.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(config.port)) else { return }
        if connection == nil {
            let params: NWParameters = config.transport == .tcp ? .tcp : .udp
            let c = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: params)
            c.stateUpdateHandler = { [weak self] state in
                switch state {
                case let .failed(err), let .waiting(err):
                    DispatchQueue.main.async { self?.onStatus?(err.localizedDescription) }
                case .ready:
                    DispatchQueue.main.async { self?.onStatus?(nil) }
                default: break
                }
            }
            c.start(queue: queue)
            connection = c
            receive(on: c)
            if config.transport == .sonyUDP {
                sequence = 0
                c.send(content: Data(VISCA.sonyResetSequence), completion: .contentProcessed { _ in })
            }
        }
        sequence &+= 1
        let bytes = VISCA.packet(command, config: config, sequence: sequence)
        connection?.send(content: Data(bytes), completion: .contentProcessed { [weak self] err in
            guard let err else { return }
            DispatchQueue.main.async { self?.onStatus?(err.localizedDescription) }
        })
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self, weak c] _, _, done, err in
            guard let c, err == nil, !done else { return }
            self?.receive(on: c)
        }
    }

    public func stop() {
        connection?.cancel()
        connection = nil
    }
}
#endif

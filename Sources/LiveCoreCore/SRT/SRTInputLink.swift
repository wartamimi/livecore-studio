#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// UDP transport for `SRTReceiver` (0.54.0): one POSIX socket on its own thread. Listener mode
/// binds the port on every interface and serves one caller at a time (a caller that comes back
/// after a drop is accepted again); caller mode connects out and retries every 2 s.
/// Payloads (MPEG-TS) are handed to `onPayload` on the link thread, already in order and paced
/// by the SRT latency. Portable (Linux + macOS) so it is tested against ffmpeg/libsrt in CI-less
/// Linux runs too.
public final class SRTInputLink: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var role: SRTReceiver.Role
        public var host: String
        public var port: Int
        public var latencyMs: Int
        public var streamID: String?
        public init(role: SRTReceiver.Role, host: String = "", port: Int, latencyMs: Int = 120, streamID: String? = nil) {
            self.role = role; self.host = host; self.port = port; self.latencyMs = latencyMs; self.streamID = streamID
        }
    }

    public enum Event: Equatable, Sendable {
        case waiting(String)
        case connected(peer: String, streamID: String)
        case disconnected(String)
        case failed(String)
    }

    public let config: Config
    /// Test hook: drop this share of incoming data packets (0–100) to exercise NAK recovery.
    public var simulatedLossPercent = 0
    /// Link thread: in-order TS payloads.
    public var onPayload: ((ArraySlice<UInt8>) -> Void)?
    /// Link thread, every loop (≤ 5 ms): lets the consumer pace its output.
    public var onTick: ((Double) -> Void)?
    /// Link thread.
    public var onEvent: ((Event) -> Void)?

    private let lock = NSLock()
    private var running = false
    private var _stats = SRTReceiver.Stats()
    private var _peer = ""
    public var stats: SRTReceiver.Stats { lock.lock(); defer { lock.unlock() }; return _stats }
    public var peer: String { lock.lock(); defer { lock.unlock() }; return _peer }

    public init(config: Config) { self.config = config }

    public static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let t = Thread { [self] in run() }
        t.name = "livecore.srt.input"
        t.qualityOfService = .userInteractive
        t.start()
    }

    public func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    // MARK: Socket helpers

    private static func udpSocket(family: Int32) -> Int32 {
        #if canImport(Glibc)
        return socket(family, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        return socket(family, SOCK_DGRAM, 0)
        #endif
    }

    private static func describe(_ a: sockaddr_storage) -> String {
        var a = a
        var host = [CChar](repeating: 0, count: 64)
        var port: UInt16 = 0
        withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                if sp.pointee.sa_family == sa_family_t(AF_INET) {
                    sp.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s4 in
                        var addr = s4.pointee.sin_addr
                        inet_ntop(AF_INET, &addr, &host, socklen_t(host.count))
                        port = UInt16(bigEndian: s4.pointee.sin_port)
                    }
                } else if sp.pointee.sa_family == sa_family_t(AF_INET6) {
                    sp.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s6 in
                        var addr = s6.pointee.sin6_addr
                        inet_ntop(AF_INET6, &addr, &host, socklen_t(host.count))
                        port = UInt16(bigEndian: s6.pointee.sin6_port)
                    }
                }
            }
        }
        return "\(String(cString: host)):\(port)"
    }

    private static func sameAddress(_ a: sockaddr_storage, _ b: sockaddr_storage) -> Bool {
        describe(a) == describe(b)
    }

    // MARK: Loop

    private func run() {
        while isRunning {
            let reason = session()
            guard isRunning else { break }
            onEvent?(.disconnected(reason))
            // Caller: wait before calling again. Listener: the socket is reopened at once.
            let until = Self.now() + (config.role == .caller ? 2 : 0.2)
            while isRunning && Self.now() < until { usleep(20_000) }
        }
    }

    /// One socket lifetime. Returns why it ended.
    private func session() -> String {
        var target = sockaddr_storage()
        var targetLen = socklen_t(0)
        var family = AF_INET
        if config.role == .caller {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            #if canImport(Glibc)
            hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
            #else
            hints.ai_socktype = SOCK_DGRAM
            #endif
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(config.host, String(config.port), &hints, &res) == 0, let r = res else {
                onEvent?(.failed("Cannot resolve \(config.host)"))
                return "Cannot resolve \(config.host)"
            }
            family = r.pointee.ai_family
            targetLen = r.pointee.ai_addrlen
            withUnsafeMutableBytes(of: &target) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: r.pointee.ai_addr, count: Int(r.pointee.ai_addrlen)))
            }
            freeaddrinfo(res)
        }
        let fd = Self.udpSocket(family: family)
        guard fd >= 0 else { return "Socket error \(errno)" }
        defer { close(fd) }
        var size: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        if config.role == .listener {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: config.port).bigEndian)
            addr.sin_addr = in_addr(s_addr: 0)
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if ok != 0 {
                let msg = errno == EADDRINUSE ? "UDP port \(config.port) is already in use" : "Cannot listen on UDP port \(config.port) (errno \(errno))"
                onEvent?(.failed(msg))
                // Try again a little later (the port may be freed).
                let until = Self.now() + 3
                while isRunning && Self.now() < until { usleep(50_000) }
                return msg
            }
            onEvent?(.waiting("Listening on UDP port \(config.port)"))
        } else {
            onEvent?(.waiting("Calling \(config.host):\(config.port)"))
        }

        let rx = SRTReceiver(role: config.role, latencyMs: config.latencyMs, streamID: config.streamID)
        var peerAddr = target
        var peerLen = targetLen
        var havePeer = config.role == .caller
        var wasConnected = false
        var lastData = Self.now()

        func send(_ d: [UInt8]) {
            guard havePeer else { return }
            _ = d.withUnsafeBytes { b in
                withUnsafePointer(to: &peerAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, b.baseAddress, b.count, 0, $0, peerLen) }
                }
            }
        }

        for d in rx.start(now: Self.now()) { send(d) }
        var buf = [UInt8](repeating: 0, count: 2048)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while isRunning {
            _ = poll(&pfd, 1, 5)
            // Drain the socket.
            while true {
                var from = sockaddr_storage()
                var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = buf.withUnsafeMutableBytes { b in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &fromLen) }
                    }
                }
                if n <= 0 { break }
                let now = Self.now()
                let d = Array(buf[0..<n])
                let isHandshake = n >= 4 && d[0] == 0x80 && d[1] == 0x00 && d[2] == 0x00 && d[3] == 0x00
                if config.role == .listener {
                    if !havePeer || !Self.sameAddress(from, peerAddr) {
                        // Another address: only a handshake, and only when no live session holds the port.
                        guard isHandshake, !rx.isConnected || now - lastData > 1 else { continue }
                        peerAddr = from; peerLen = fromLen; havePeer = true
                    }
                }
                if d[0] & 0x80 == 0 {
                    if simulatedLossPercent > 0, Int.random(in: 0..<100) < simulatedLossPercent { continue }
                    lastData = now
                }
                for out in rx.receive(d, now: now) { send(out) }
            }
            let now = Self.now()
            for out in rx.tick(now: now) { send(out) }
            if rx.isConnected && !wasConnected {
                wasConnected = true
                let p = Self.describe(peerAddr)
                lock.lock(); _peer = p; lock.unlock()
                onEvent?(.connected(peer: p, streamID: rx.stats.peerStreamID))
            }
            for p in rx.deliver(now: now) { onPayload?(p) }
            onTick?(now)
            lock.lock(); _stats = rx.stats; lock.unlock()
            if case let .closed(reason) = rx.state {
                if config.role == .listener {
                    if wasConnected { onEvent?(.disconnected(reason)) }
                    rx.relisten(now: now)
                    wasConnected = false
                    havePeer = false
                    lock.lock(); _peer = ""; lock.unlock()
                    onEvent?(.waiting("Listening on UDP port \(config.port)"))
                    continue
                }
                return reason
            }
        }
        if let bye = rx.close(now: Self.now()) { send(bye) }
        return "stopped"
    }
}

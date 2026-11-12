#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Blocking TCP socket used only by the CLI validation tool (plain rtmp://).
/// The macOS app uses Network.framework (NWConnection) instead, which also provides TLS for rtmps://.
final class POSIXSocket {
    private var fd: Int32 = -1

    enum SocketError: Error, CustomStringConvertible {
        case resolve(String), connect(String), io(String)
        var description: String {
            switch self { case let .resolve(s), let .connect(s), let .io(s): return s }
        }
    }

    init(host: String, port: Int) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { throw SocketError.resolve("cannot resolve \(host): \(String(cString: gai_strerror(rc)))") }
        defer { freeaddrinfo(res) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                if connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { fd = s; break }
                close(s)
            }
            ai = a.pointee.ai_next
        }
        guard fd >= 0 else { throw SocketError.connect("cannot connect to \(host):\(port) (errno \(errno))") }
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { if fd >= 0 { close(fd) } }

    func send(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { buf in
                #if canImport(Glibc)
                Glibc.send(fd, buf.baseAddress, buf.count, Int32(MSG_NOSIGNAL))
                #else
                Darwin.send(fd, buf.baseAddress, buf.count, 0)
                #endif
            }
            if n <= 0 { throw SocketError.io("send failed (errno \(errno))") }
            off += n
        }
    }

    /// Waits up to `timeoutMs` for data. Returns [] on timeout, throws on EOF/error.
    func receive(timeoutMs: Int32) throws -> [UInt8] {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&p, 1, timeoutMs)
        if r == 0 { return [] }
        if r < 0 { throw SocketError.io("poll failed (errno \(errno))") }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n == 0 { throw SocketError.io("connection closed by server") }
        if n < 0 { throw SocketError.io("recv failed (errno \(errno))") }
        return Array(buf[0..<n])
    }
}

/// Connected UDP socket for the SRT mode of the CLI tool.
final class UDPSocket {
    private var fd: Int32 = -1

    init(host: String, port: Int) throws {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
        #else
        hints.ai_socktype = SOCK_DGRAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let a = res else { throw POSIXSocket.SocketError.resolve("cannot resolve \(host)") }
        defer { freeaddrinfo(res) }
        fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
        guard fd >= 0, connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 else {
            throw POSIXSocket.SocketError.connect("cannot open UDP to \(host):\(port)")
        }
    }

    deinit { if fd >= 0 { close(fd) } }

    func send(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { buf in
            #if canImport(Glibc)
            Glibc.send(fd, buf.baseAddress, buf.count, 0)
            #else
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
            #endif
        }
    }

    /// One datagram, [] on timeout (ICMP "port unreachable" errors are ignored: the server may not be up yet).
    func receive(timeoutMs: Int32) -> [UInt8] {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, timeoutMs) > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        return n > 0 ? Array(buf[0..<n]) : []
    }
}

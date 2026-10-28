#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import LiveCoreCore

/// Web Controller HTTP server: a small blocking IPv4 server on its own threads.
/// The page needs no PIN; every /api/ call does (X-LiveCore-PIN header), wrong PINs lock the
/// client out for a while, and only IP / localhost / ".local" Host names are answered.
/// Commands are handed to `onCommand` on `commandQueue` (main by default); the state the page
/// shows is a JSON snapshot the app pushes with `update(state:)`, so a request never waits
/// for the main thread.
public final class RemoteServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case socket(Int32), bind(port: Int, errno: Int32), listen(Int32), badPIN
        public var description: String {
            switch self {
            case let .socket(e): return "Cannot open a network socket (\(String(cString: strerror(e))))."
            case let .bind(p, e) where e == EADDRINUSE: return "Port \(p) is already used by another app."
            case let .bind(p, e): return "Cannot use port \(p) (\(String(cString: strerror(e))))."
            case let .listen(e): return "Cannot listen for connections (\(String(cString: strerror(e))))."
            case .badPIN: return "The PIN must be 4 to 8 digits."
            }
        }
    }

    public static let defaultPort = 8088
    /// Connections served at the same time; more are closed at once.
    public static let maxConnections = 16

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var _pin: String
    private var stateJSON = RemoteState().json
    private var lockout = RemoteLockout()
    private var seen: [String: Double] = [:]          // client address → last signed-in request
    private var frames: [String: [UInt8]] = [:]        // "program" / "preview" → JPEG
    private var lastFrameRequest: Double = -.infinity
    private let requestedPort: Int
    private var boundPort = 0
    private let commandQueue: DispatchQueue
    private let onCommand: (RemoteCommand) -> Void
    private let connections = DispatchQueue(label: "studio.livecore.remote.conn", attributes: .concurrent)
    private let slots = DispatchSemaphore(value: RemoteServer.maxConnections)
    private var acceptThread: Thread?

    public init(port: Int = RemoteServer.defaultPort, pin: String, commandQueue: DispatchQueue = .main,
                onCommand: @escaping (RemoteCommand) -> Void) {
        requestedPort = port
        _pin = pin
        self.commandQueue = commandQueue
        self.onCommand = onCommand
    }

    deinit { stop() }

    /// The port actually listened on (useful with port 0 in tests).
    public var port: Int { lock.sync { boundPort } }
    public var isRunning: Bool { lock.sync { running } }

    public var pin: String {
        get { lock.sync { _pin } }
        set { lock.sync { _pin = newValue; lockout = RemoteLockout() } }
    }

    public func update(state json: String) { lock.sync { stateJSON = json } }

    /// Latest JPEG for "program" or "preview" (served at /api/frame?bus=...).
    public func setFrame(_ jpeg: [UInt8], bus: String) { lock.sync { frames[bus] = jpeg } }

    /// A page asked for a picture in the last `window` seconds, so encoding them is worth it.
    public func wantsFrames(window: Double = 3) -> Bool {
        let now = Self.now()
        return lock.sync { now - lastFrameRequest < window }
    }

    /// Devices that made a signed-in request in the last `window` seconds.
    public func activeClients(window: Double = 10) -> Int {
        let now = Self.now()
        return lock.sync { seen.values.filter { now - $0 < window }.count }
    }

    public func start() throws {
        guard RemoteAuth.isValidPIN(pin) else { throw ServerError.badPIN }
        if isRunning { return }
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw ServerError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(requestedPort).bigEndian)
        addr.sin_addr = in_addr(s_addr: 0)          // INADDR_ANY: every interface
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw ServerError.bind(port: requestedPort, errno: e) }
        guard listen(fd, 32) == 0 else { let e = errno; close(fd); throw ServerError.listen(e) }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        lock.sync {
            listenFD = fd
            boundPort = Int(UInt16(bigEndian: bound.sin_port))
            running = true
        }
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "LiveCore Remote"
        acceptThread = t
        t.start()
    }

    public func stop() {
        let fd: Int32 = lock.sync {
            let f = listenFD
            listenFD = -1
            running = false
            seen = [:]
            frames = [:]
            return f
        }
        if fd >= 0 { close(fd) }   // the accept loop sees running == false within its poll timeout
        acceptThread = nil
    }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 250)
            guard isRunning else { break }
            if r <= 0 { continue }
            var peer = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            if c < 0 { continue }
            let client = Self.address(peer.sin_addr)
            guard slots.wait(timeout: .now()) == .success else { close(c); continue }
            connections.async { [weak self] in
                defer { self?.slots.signal() }
                self?.serve(c, client: client)
            }
        }
    }

    private func serve(_ c: Int32, client: String) {
        defer { close(c) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var buf: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        var response: HTTPResponse
        let deadline = Self.now() + 10                 // a slow client cannot hold a slot
        while true {
            guard Self.now() < deadline else { return }
            let n = chunk.withUnsafeMutableBytes { recv(c, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return }
            buf.append(contentsOf: chunk[0..<n])
            switch HTTPRequest.parse(buf) {
            case .incomplete: continue
            case .invalid: response = .error(400, "bad request")
            case .tooLarge: response = .error(413, "too large")
            case let .request(req, _): response = handle(req, client: client)
                if req.method == "HEAD" { response.body = [] }
            }
            break
        }
        let out = response.serialized()
        var off = 0
        while off < out.count {
            let n = out[off...].withUnsafeBytes { b -> Int in
                #if canImport(Glibc)
                return send(c, b.baseAddress, b.count, Int32(MSG_NOSIGNAL))
                #else
                return send(c, b.baseAddress, b.count, 0)
                #endif
            }
            if n <= 0 { return }
            off += n
        }
    }

    /// Request → response (internal for tests).
    func handle(_ req: HTTPRequest, client: String) -> HTTPResponse {
        guard RemoteAuth.hostAllowed(req.headers["host"]) else { return .error(403, "host not allowed") }
        let route = RemoteRouter.route(req)
        if route.needsPIN {
            let now = Self.now()
            let wait: Double = lock.sync { lockout.waitTime(client, now: now) }
            if wait > 0 { return .error(429, "locked", headers: [("Retry-After", "\(Int(wait.rounded(.up)))")]) }
            let ok: Bool = lock.sync {
                if RemoteAuth.pinMatches(req.headers[RemoteAuth.pinHeader], _pin) {
                    lockout.recordSuccess(client)
                    seen[client] = now
                    return true
                }
                lockout.recordFailure(client, now: now)
                return false
            }
            if !ok {
                let w = lock.sync { lockout.waitTime(client, now: now) }
                return w > 0 ? .error(429, "locked", headers: [("Retry-After", "\(Int(w.rounded(.up)))")])
                             : .error(401, "wrong PIN")
            }
        }
        switch route {
        case .page:
            return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Array(RemotePage.html.utf8),
                                headers: [("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer"),
                                          ("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data: blob:; frame-ancestors 'none'")])
        case .state:
            return .json(lock.sync { stateJSON })
        case .ping:
            return .json("{\"ok\":true}")
        case let .frame(bus):
            let jpeg: [UInt8]? = lock.sync { lastFrameRequest = Self.now(); return frames[bus] }
            guard let jpeg else { return HTTPResponse(status: 204) }
            return HTTPResponse(status: 200, contentType: "image/jpeg", body: jpeg)
        case let .command(cmd):
            let handler = onCommand
            commandQueue.async { handler(cmd) }
            return .json("{\"ok\":true}")
        case .notFound:
            return .error(404, "not found")
        case .methodNotAllowed:
            return .error(405, "method not allowed")
        case let .badRequest(field):
            return .error(400, "bad \(field)")
        }
    }

    // MARK: Helpers

    static func now() -> Double { Date().timeIntervalSinceReferenceDate }

    static func address(_ a: in_addr) -> String {
        let v = UInt32(bigEndian: a.s_addr)
        return "\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)"
    }

    /// IPv4 addresses of this computer's active network interfaces (Wi-Fi, Ethernet), without
    /// loopback and link-local (169.254.x.x) ones; these are the addresses a phone can open.
    public static func lanAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [String] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            let flags = Int32(bitPattern: UInt32(i.pointee.ifa_flags))
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                  let sa = i.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address($0.pointee.sin_addr) }
            if !a.hasPrefix("169.254."), !out.contains(a) { out.append(a) }
        }
        return out
    }
}

extension NSLock {
    /// Runs `body` holding the lock (NSLocking.withLock needs macOS 14).
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

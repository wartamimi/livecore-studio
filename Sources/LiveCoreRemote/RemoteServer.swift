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
    public static let maxConnections = 32

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var _pin: String
    private var stateJSON = RemoteState().json
    private var lockout = RemoteLockout()
    private var seen: [String: Double] = [:]          // client address → last signed-in request
    private var frames: [String: [UInt8]] = [:]        // "program" / "preview" → JPEG
    private var frameSeq: [String: Int] = [:]          // bumps with every new JPEG (0.54.1)
    private var lastFrameRequest: Double = -.infinity
    private var lastLowFrameRequest: Double = -.infinity
    private var lastHighFrameRequest: Double = -.infinity
    /// Open picture streams (0.62.0), at most `maxVideoStreams`.
    private var videoStreams = 0
    public static let maxVideoStreams = 6
    static let videoMarker = "X-LCS-Video-Stream"
    /// Recent command ids (X-LCS-Req, 0.54.2): a page that re-sends a command after a lost reply
    /// (weak network) never makes it run twice.
    private var recentCommands: [String] = []
    /// Audio Monitor (0.50.0): one ring per bus, and when each bus was last asked for.
    private var audioRings: [String: RemoteAudioRing] = [:]
    private var lastListen: [String: Double] = [:]
    private var audioStreams = 0
    /// Open Audio Monitor streams allowed at once (each holds one connection slot).
    public static let maxAudioStreams = 4
    static let streamMarker = "X-LCS-Audio-Stream"
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

    /// LCS Live (0.52.0): when set (before `start`), every request is answered by this handler
    /// instead of the Web Controller routes; the Host guard still applies.
    public var customHandler: ((HTTPRequest, String) -> HTTPResponse)?
    /// Largest accepted request (head + body).
    public var maxRequestSize = 16 * 1024

    /// The port actually listened on (useful with port 0 in tests).
    public var port: Int { lock.sync { boundPort } }
    public var isRunning: Bool { lock.sync { running } }

    public var pin: String {
        get { lock.sync { _pin } }
        set { lock.sync { _pin = newValue; lockout = RemoteLockout() } }
    }

    public func update(state json: String) { lock.sync { stateJSON = json } }

    /// Latest JPEG for "program" or "preview" (served at /api/frame?bus=...).
    public func setFrame(_ jpeg: [UInt8], bus: String) { lock.sync { frames[bus] = jpeg; frameSeq[bus, default: 0] += 1 } }

    /// A page asked for a picture in the last `window` seconds, so encoding them is worth it.
    /// Buses a web page listened to in the last `window` seconds (only those are converted).
    public func listenedBuses(window: Double = 3) -> [String] {
        let now = Self.now()
        return lock.sync { lastListen.filter { now - $0.value < window }.map(\.key) }
    }

    /// Interleaved 16-bit stereo of `bus` at `sampleRate` (audio thread, kept short).
    public func pushAudio(_ interleaved: [Int16], bus: String, sampleRate: Int) {
        lock.sync {
            if audioRings[bus]?.sampleRate != sampleRate { audioRings[bus] = RemoteAudioRing(sampleRate: sampleRate) }
            audioRings[bus]?.append(interleaved)
        }
    }

    /// A page on a weak connection asked for the small pictures (`<bus>-low`, 0.54.2).
    public func wantsLowFrames(window: Double = 3) -> Bool {
        let now = Self.now()
        return lock.sync { now - lastLowFrameRequest < window }
    }

    /// A page asked for the large pictures (`<bus>-high`, ≈1280 px, 0.62.0).
    public func wantsHighFrames(window: Double = 3) -> Bool {
        let now = Self.now()
        return lock.sync { now - lastHighFrameRequest < window }
    }

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
            frameSeq = [:]
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
            guard slots.wait(timeout: .now() + 1) == .success else { close(c); continue }
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
        // 0.54.1: small writes (audio blocks, JSON) go out at once instead of waiting for Nagle +
        // delayed ACK (up to ~200 ms per write, the cause of choppy Audio Monitor sound).
        var nd: Int32 = 1
        setsockopt(c, Int32(IPPROTO_TCP), TCP_NODELAY, &nd, socklen_t(MemoryLayout<Int32>.size))
        var buf: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 8192)
        // 0.54.1: keep-alive. The page polls state and two picture feeds several times a second;
        // a new TCP connection per request (handshake over Wi-Fi, or a new hop through the tunnel)
        // made pictures stutter. One connection now serves up to 500 requests, idle ≤ 5 s.
        var served = 0
        while served < 500 {
            var response: HTTPResponse
            var keepAlive = false
            let deadline = Self.now() + 10                 // a slow client cannot hold a slot
            parsing: while true {
                if case .incomplete = HTTPRequest.parse(buf, maxSize: maxRequestSize) {
                    guard Self.now() < deadline else { return }
                    let n = chunk.withUnsafeMutableBytes { recv(c, $0.baseAddress, $0.count, 0) }
                    if n <= 0 { return }
                    buf.append(contentsOf: chunk[0..<n])
                    continue parsing
                }
                switch HTTPRequest.parse(buf, maxSize: maxRequestSize) {
                case .incomplete: continue parsing
                case .invalid: response = .error(400, "bad request"); buf = []
                case .tooLarge: response = .error(413, "too large"); buf = []
                case let .request(req, consumed):
                    buf.removeFirst(min(consumed, buf.count))
                    response = handle(req, client: client)
                    if req.method == "HEAD" { response.body = [] }
                    keepAlive = (req.headers["connection"] ?? "").lowercased() != "close"
                }
                break parsing
            }
            if let mark = response.headers.first(where: { $0.0 == Self.videoMarker })?.1 {
                streamVideo(c, spec: mark)
                return
            }
            if let mark = response.headers.first(where: { $0.0 == Self.streamMarker })?.1 {
                let low = mark.hasSuffix("|low")
                streamAudio(c, bus: low ? String(mark.dropLast(4)) : mark, low: low)
                return
            }
            served += 1
            keepAlive = keepAlive && served < 500 && isRunning
            guard Self.writeAll(c, response.serialized(keepAlive: keepAlive)), keepAlive else { return }
        }
    }

    /// Audio Monitor push: keeps the connection open and writes each new run of PCM as
    /// [UInt32 LE length][listen body]. An empty body every second doubles as a keep-alive and
    /// is how a closed tab is noticed (the write fails).
    private func streamAudio(_ c: Int32, bus: String, low: Bool = false) {
        defer { lock.sync { audioStreams -= 1 } }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        guard Self.writeAll(c, Array(head.utf8)) else { return }
        var since: UInt32 = 0
        var lastWrite = Self.now()
        let end = Self.now() + 4 * 3600
        while isRunning && Self.now() < end {
            let now = Self.now()
            let r: (next: UInt32, pcm: [Int16], rate: Int)? = lock.sync {
                lastListen[bus] = now
                guard let ring = audioRings[bus] else { return nil }
                let x = ring.read(since: since)
                return (x.next, x.pcm, ring.sampleRate)
            }
            var body: [UInt8]?
            if let r, !r.pcm.isEmpty {
                since = r.next
                if low {
                    // Weak connection (0.54.2): mono at half the rate, a quarter of the data.
                    let (pcm, rate) = Self.lowAudio(r.pcm, rate: r.rate)
                    body = RemoteAudioRing.body(next: r.next, sampleRate: rate, channels: 1, pcm: pcm)
                } else {
                    body = RemoteAudioRing.body(next: r.next, sampleRate: r.rate, channels: 2, pcm: r.pcm)
                }
            } else if now - lastWrite > 1 {
                body = RemoteAudioRing.body(next: since, sampleRate: r?.rate ?? 24_000, channels: 2, pcm: [])
            }
            if let body {
                let n = UInt32(body.count)
                let frame = [UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8(n >> 24)] + body
                guard Self.writeAll(c, frame) else { return }
                lastWrite = now
            }
            // 0.62.0: every 20 ms (was 40) so a block never waits long behind the poll.
            usleep(20_000)
        }
    }

    /// Picture push (0.62.0): instead of one request per picture (a round trip each, so a slow
    /// or far link capped the frame rate and made the picture lag), one long response carries
    /// every new JPEG as [UInt32 LE length][UInt8 bus 0 = Program, 1 = Preview][UInt32 LE seq][JPEG].
    /// Only the newest picture is ever sent: a slow link skips pictures instead of falling behind.
    /// A small send buffer keeps the queue in the network short. An empty record (bus 255) every
    /// second is the keep-alive.
    private func streamVideo(_ c: Int32, spec: String) {
        defer { lock.sync { videoStreams -= 1 } }
        // spec: "program,preview|quality|fpsProgram,fpsPreview"
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let buses = parts[0].split(separator: ",").map(String.init)
        let quality = parts.count > 1 ? parts[1] : "normal"
        let fpsList = (parts.count > 2 ? parts[2] : "").split(separator: ",").compactMap { Double($0) }
        var sndbuf: Int32 = quality == "high" ? 256 * 1024 : 96 * 1024
        setsockopt(c, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\nX-Accel-Buffering: no\r\nConnection: close\r\n\r\n"
        guard Self.writeAll(c, Array(head.utf8)) else { return }
        var sent: [String: Int] = [:]
        var lastSent: [String: Double] = [:]
        var lastWrite = Self.now()
        let end = Self.now() + 4 * 3600
        while isRunning && Self.now() < end {
            let now = Self.now()
            var out: [UInt8] = []
            for (i, bus) in buses.enumerated() {
                let fps = i < fpsList.count ? min(max(fpsList[i], 0.5), 30) : 15
                if now - (lastSent[bus] ?? -1) < 1 / fps - 0.004 { continue }
                let pic: (jpeg: [UInt8], seq: Int)? = lock.sync {
                    lastFrameRequest = now
                    if quality == "low" { lastLowFrameRequest = now }
                    if quality == "high" { lastHighFrameRequest = now }
                    let key = quality == "normal" ? bus : bus + "-" + quality
                    // Until the first small / large picture exists, the normal one is sent.
                    let k = frames[key] != nil ? key : bus
                    guard let j = frames[k], let q = frameSeq[k], q != sent[bus] else { return nil }
                    return (j, q)
                }
                guard let pic else { continue }
                sent[bus] = pic.seq
                lastSent[bus] = now
                out += Self.videoRecord(bus: bus == "program" ? 0 : 1, seq: UInt32(truncatingIfNeeded: pic.seq), jpeg: pic.jpeg)
            }
            if out.isEmpty && now - lastWrite > 1 { out = Self.videoRecord(bus: 255, seq: 0, jpeg: []) }
            if !out.isEmpty {
                guard Self.writeAll(c, out) else { return }
                lastWrite = Self.now()
            }
            usleep(8_000)
        }
    }

    static func videoRecord(bus: UInt8, seq: UInt32, jpeg: [UInt8]) -> [UInt8] {
        let n = UInt32(5 + jpeg.count)
        var r: [UInt8] = [UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8(n >> 24), bus,
                          UInt8(seq & 0xff), UInt8((seq >> 8) & 0xff), UInt8((seq >> 16) & 0xff), UInt8(seq >> 24)]
        r.reserveCapacity(9 + jpeg.count)
        r += jpeg
        return r
    }

    /// Interleaved stereo → mono at half the rate (pairs of frames averaged).
    static func lowAudio(_ stereo: [Int16], rate: Int) -> (pcm: [Int16], rate: Int) {
        let frames = stereo.count / 2
        let n = frames / 2
        var out = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let s = Int(stereo[4 * i]) + Int(stereo[4 * i + 1]) + Int(stereo[4 * i + 2]) + Int(stereo[4 * i + 3])
            out[i] = Int16(clamping: s / 4)
        }
        return (out, rate / 2)
    }

    private static func writeAll(_ c: Int32, _ out: [UInt8]) -> Bool {
        var off = 0
        while off < out.count {
            let n = out[off...].withUnsafeBytes { b -> Int in
                #if canImport(Glibc)
                return send(c, b.baseAddress, b.count, Int32(MSG_NOSIGNAL))
                #else
                return send(c, b.baseAddress, b.count, 0)
                #endif
            }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    /// Request → response (internal for tests).
    func handle(_ req: HTTPRequest, client: String) -> HTTPResponse {
        guard RemoteAuth.hostAllowed(req.headers["host"]) else { return .error(403, "host not allowed") }
        if let custom = customHandler { return custom(req, client) }
        let route = RemoteRouter.route(req)
        if route.needsPIN {
            let now = Self.now()
            let wait: Double = lock.sync { lockout.waitTime(client, now: now) }
            if wait > 0 { return .error(429, "locked", headers: [("Retry-After", "\(Int(wait.rounded(.up)))")]) }
            let ok: Bool = lock.sync {
                if RemoteAuth.pinMatches(req.headers[RemoteAuth.pinHeader] ?? req.query["pin"], _pin) {
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
                                          ("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data: blob:; frame-ancestors 'none'")])
        case .state:
            return .json(lock.sync { stateJSON })
        case .ping:
            return .json("{\"ok\":true}")
        case let .frame(bus):
            // ?since=<seq>: 204 while the picture is unchanged (0.54.1), so a page never downloads
            // the same JPEG twice; the new sequence number comes back in X-Frame-Seq.
            // ?q=low (0.54.2): a page on a weak connection gets the small picture (≈320 px).
            let since = Int(req.query["since"] ?? "")
            let low = req.query["q"] == "low"
            let r: (jpeg: [UInt8]?, seq: Int) = lock.sync {
                lastFrameRequest = Self.now()
                if low { lastLowFrameRequest = lastFrameRequest }
                let key = low ? bus + "-low" : bus
                // Until the first small picture exists, the normal one is served.
                if low, let j = frames[key] { return (j, frameSeq[key] ?? 0) }
                return (frames[bus], frameSeq[bus] ?? 0)
            }
            guard let jpeg = r.jpeg, since != r.seq else { return HTTPResponse(status: 204, headers: [("X-Frame-Seq", "\(r.seq)")]) }
            return HTTPResponse(status: 200, contentType: "image/jpeg", body: jpeg, headers: [("X-Frame-Seq", "\(r.seq)")])
        case let .listen(bus, since):
            let r: (next: UInt32, pcm: [Int16], rate: Int)? = lock.sync {
                lastListen[bus] = Self.now()
                guard let ring = audioRings[bus] else { return nil }
                let x = ring.read(since: since)
                return (x.next, x.pcm, ring.sampleRate)
            }
            guard let r else {
                return HTTPResponse(status: 200, contentType: "application/octet-stream",
                                    body: RemoteAudioRing.body(next: 0, sampleRate: 24_000, channels: 2, pcm: []))
            }
            return HTTPResponse(status: 200, contentType: "application/octet-stream",
                                body: RemoteAudioRing.body(next: r.next, sampleRate: r.rate, channels: 2, pcm: r.pcm))
        case let .listenStream(bus) where req.query["q"] == "low":
            let ok: Bool = lock.sync {
                guard audioStreams < Self.maxAudioStreams else { return false }
                audioStreams += 1
                lastListen[bus] = Self.now()
                return true
            }
            guard ok else { return .error(503, "too many listeners") }
            return HTTPResponse(status: 200, contentType: "application/octet-stream", headers: [(Self.streamMarker, bus + "|low")])
        case let .listenStream(bus):
            let ok: Bool = lock.sync {
                guard audioStreams < Self.maxAudioStreams else { return false }
                audioStreams += 1
                lastListen[bus] = Self.now()
                return true
            }
            guard ok else { return .error(503, "too many listeners") }
            return HTTPResponse(status: 200, contentType: "application/octet-stream", headers: [(Self.streamMarker, bus)])
        case let .videoStream(buses, quality):
            let ok: Bool = lock.sync {
                guard videoStreams < Self.maxVideoStreams else { return false }
                videoStreams += 1
                lastFrameRequest = Self.now()
                return true
            }
            guard ok else { return .error(503, "too many viewers") }
            let fps = (req.query["fps"] ?? "").filter { $0.isNumber || $0 == "," || $0 == "." }
            return HTTPResponse(status: 200, contentType: "application/octet-stream",
                                headers: [(Self.videoMarker, buses.joined(separator: ",") + "|" + quality + "|" + String(fps.prefix(24)))])
        case let .command(cmd):
            if let rid = req.headers["x-lcs-req"], !rid.isEmpty {
                let dup: Bool = lock.sync {
                    if recentCommands.contains(rid) { return true }
                    recentCommands.append(rid)
                    if recentCommands.count > 128 { recentCommands.removeFirst(recentCommands.count - 128) }
                    return false
                }
                if dup { return .json("{\"ok\":true,\"repeat\":true}") }
            }
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

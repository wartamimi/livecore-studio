/// Web Controller (remote control from a phone / tablet browser on the same network).
/// HTTP/1.1 request parsing, routing to operator commands, PIN checks with lockout and the
/// state JSON. Pure and Foundation-free (unit-tested on Linux); the socket server lives in
/// LiveCoreRemote and the page in `RemotePage`.

// MARK: HTTP

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: [UInt8]

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: [UInt8] = []) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }

    public enum Parse: Equatable, Sendable {
        case incomplete
        case invalid
        case tooLarge
        case request(HTTPRequest, consumed: Int)
    }

    /// Parses one request from the start of `bytes`. Bodies need a Content-Length
    /// (chunked uploads are refused); requests over `maxSize` bytes are refused.
    public static func parse(_ bytes: [UInt8], maxSize: Int = 16 * 1024) -> Parse {
        guard let headEnd = find(crlfcrlf, in: bytes) else { return bytes.count > maxSize ? .tooLarge : .incomplete }
        guard headEnd <= maxSize else { return .tooLarge }
        guard let head = String(utf8Bytes: bytes[0..<headEnd]) else { return .invalid }
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return .invalid }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
              requestLine[0].allSatisfy({ $0.isASCII && $0.isUppercase }) else { return .invalid }
        let target = String(requestLine[1])
        guard target.hasPrefix("/") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .invalid }
            headers[name] = trim(String(line[line.index(after: colon)...]))
        }
        if headers["transfer-encoding"] != nil { return .invalid }
        var length = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .invalid }
            length = n
        }
        let bodyStart = headEnd + 4
        guard bodyStart + length <= maxSize else { return .tooLarge }
        guard bytes.count >= bodyStart + length else { return .incomplete }
        let (path, query) = splitTarget(target)
        guard let decodedPath = percentDecode(path) else { return .invalid }
        let req = HTTPRequest(method: String(requestLine[0]), path: decodedPath, query: query,
                              headers: headers, body: Array(bytes[bodyStart..<(bodyStart + length)]))
        return .request(req, consumed: bodyStart + length)
    }

    /// "/api/x?a=1&b=%20" → ("/api/x", ["a": "1", "b": " "]). The fragment is ignored.
    static func splitTarget(_ target: String) -> (String, [String: String]) {
        let noFragment = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = noFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = percentDecode(String(kv[0]).replacingPlus()) ?? ""
                guard !key.isEmpty else { continue }
                query[key] = kv.count == 2 ? percentDecode(String(kv[1]).replacingPlus()) ?? "" : ""
            }
        }
        return (String(parts[0]), query)
    }

    /// Decodes %XX escapes; nil for a broken escape or invalid UTF-8.
    public static func percentDecode(_ s: String) -> String? {
        var out: [UInt8] = []
        var it = Array(s.utf8)[...]
        while let b = it.popFirst() {
            if b == UInt8(ascii: "%") {
                guard it.count >= 2, let hi = hex(it.popFirst()!), let lo = hex(it.popFirst()!) else { return nil }
                out.append(hi << 4 | lo)
            } else {
                out.append(b)
            }
        }
        return String(utf8Bytes: out[...])
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static let crlfcrlf: [UInt8] = [13, 10, 13, 10]

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
        }
        return nil
    }

    private static func trim(_ s: String) -> String {
        var sub = Substring(s)
        while sub.first == " " || sub.first == "\t" { sub.removeFirst() }
        while sub.last == " " || sub.last == "\t" { sub.removeLast() }
        return String(sub)
    }
}

private extension String {
    func replacingPlus() -> String { String(map { $0 == "+" ? " " : $0 }) }
    init?(utf8Bytes bytes: ArraySlice<UInt8>) {
        var s = ""
        var decoder = UTF8()
        var it = bytes.makeIterator()
        loop: while true {
            switch decoder.decode(&it) {
            case let .scalarValue(v): s.unicodeScalars.append(v)
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        self = s
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var contentType: String
    public var body: [UInt8]
    public var headers: [(String, String)]

    public init(status: Int, contentType: String = "text/plain; charset=utf-8", body: [UInt8] = [], headers: [(String, String)] = []) {
        self.status = status; self.contentType = contentType; self.body = body; self.headers = headers
    }

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.contentType == b.contentType && a.body == b.body
            && a.headers.map { $0.0 + ":" + $0.1 } == b.headers.map { $0.0 + ":" + $0.1 }
    }

    public static func json(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: Array(s.utf8))
    }

    public static func error(_ status: Int, _ message: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json; charset=utf-8",
                     body: Array("{\"ok\":false,\"error\":\(JSON.string(message))}".utf8), headers: headers)
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    /// The whole response; every connection is closed after one response.
    public func serialized() -> [UInt8] {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Array(head.utf8) + body
    }
}

// MARK: Commands and routes

/// What a remote can ask the switcher to do.
public enum RemoteCommand: Equatable, Sendable {
    /// cut, auto, snapshot, preview(n), cutDirect(n), overlay(i), replay(seconds).
    case action(ControlAction)
    case tbar(Double)
    /// Start (true) / stop (false). Explicit so a late tap never flips the state the wrong way.
    case stream(Bool)
    case record(Bool)
    /// Transition for AUTO / T-bar: `TransitionKind` raw value and/or duration in seconds.
    case transition(kind: Int?, duration: Double?)
    /// Fader positions 0...1 (the app's fader law), as on the mixer.
    case masterFader(Double)
    case channelFader(id: String, value: Double)
    case channelMute(id: String, on: Bool)
    /// PTZ camera of input `input` (1-based): recall preset 1...8, or home.
    case ptzPreset(input: Int, preset: Int)
    case ptzHome(input: Int)
    /// Title data source of input `input`: next (+1) / previous (-1) row, or row `n` (1-based).
    case dataRow(input: Int, delta: Int)
    case dataRowSet(input: Int, row: Int)
}

public enum RemoteRoute: Equatable, Sendable {
    case page
    case state
    /// Checks the PIN only (the page's sign-in).
    case ping
    /// Latest JPEG of "program" or "preview".
    case frame(String)
    case command(RemoteCommand)
    case notFound
    case methodNotAllowed
    case badRequest(String)

    public var needsPIN: Bool {
        switch self {
        case .state, .ping, .frame, .command: return true
        default: return false
        }
    }
}

public enum RemoteRouter {
    public static let maxInputNumber = 99

    /// GET / (page), GET /api/state, GET /api/ping; commands are POST /api/...
    public static func route(_ r: HTTPRequest) -> RemoteRoute {
        switch r.path {
        case "/", "/index.html":
            return r.method == "GET" || r.method == "HEAD" ? .page : .methodNotAllowed
        case "/api/state":
            return r.method == "GET" ? .state : .methodNotAllowed
        case "/api/ping":
            return r.method == "GET" ? .ping : .methodNotAllowed
        case "/api/frame":
            guard r.method == "GET" else { return .methodNotAllowed }
            guard let bus = r.query["bus"], bus == "program" || bus == "preview" else { return .badRequest("bus") }
            return .frame(bus)
        default:
            break
        }
        guard r.path.hasPrefix("/api/") else { return .notFound }
        let cmd: RemoteCommand
        switch r.path {
        case "/api/cut": cmd = .action(.cut)
        case "/api/auto": cmd = .action(.auto)
        case "/api/snapshot": cmd = .action(.snapshot)
        case "/api/preview", "/api/program":
            guard let n = int(r.query["input"]), (1...maxInputNumber).contains(n) else { return .badRequest("input") }
            cmd = .action(r.path == "/api/preview" ? .preview(n) : .cutDirect(n))
        case "/api/overlay":
            guard let n = int(r.query["n"]), (1...4).contains(n) else { return .badRequest("n") }
            cmd = .action(.overlay(n))
        case "/api/replay":
            guard let s = int(r.query["sec"]), ReplayIndex.lengths.contains(Double(s)) else { return .badRequest("sec") }
            cmd = .action(.replay(s))
        case "/api/tbar":
            guard let s = r.query["value"], let v = Double(s), v.isFinite, (0...1).contains(v) else { return .badRequest("value") }
            cmd = .tbar(v)
        case "/api/stream/start": cmd = .stream(true)
        case "/api/stream/stop": cmd = .stream(false)
        case "/api/record/start": cmd = .record(true)
        case "/api/record/stop": cmd = .record(false)
        case "/api/transition":
            let kind = int(r.query["kind"])
            let duration = r.query["duration"].flatMap(Double.init)
            if r.query["kind"] != nil, kind.map({ !(0...63).contains($0) }) ?? true { return .badRequest("kind") }
            if r.query["duration"] != nil, duration.map({ !$0.isFinite || !(0.1...10).contains($0) }) ?? true { return .badRequest("duration") }
            guard kind != nil || duration != nil else { return .badRequest("kind") }
            cmd = .transition(kind: kind, duration: duration)
        case "/api/audio/master":
            guard let v = unit(r.query["fader"]) else { return .badRequest("fader") }
            cmd = .masterFader(v)
        case "/api/audio/fader":
            guard let id = channelID(r.query["id"]) else { return .badRequest("id") }
            guard let v = unit(r.query["value"]) else { return .badRequest("value") }
            cmd = .channelFader(id: id, value: v)
        case "/api/audio/mute":
            guard let id = channelID(r.query["id"]) else { return .badRequest("id") }
            guard let on = r.query["on"], on == "0" || on == "1" else { return .badRequest("on") }
            cmd = .channelMute(id: id, on: on == "1")
        case "/api/ptz/preset":
            guard let n = int(r.query["input"]), (1...maxInputNumber).contains(n) else { return .badRequest("input") }
            guard let p = int(r.query["preset"]), (1...PTZConfig.presetCount).contains(p) else { return .badRequest("preset") }
            cmd = .ptzPreset(input: n, preset: p)
        case "/api/ptz/home":
            guard let n = int(r.query["input"]), (1...maxInputNumber).contains(n) else { return .badRequest("input") }
            cmd = .ptzHome(input: n)
        case "/api/data/next", "/api/data/previous":
            guard let n = int(r.query["input"]), (1...maxInputNumber).contains(n) else { return .badRequest("input") }
            cmd = .dataRow(input: n, delta: r.path == "/api/data/next" ? 1 : -1)
        case "/api/data/row":
            guard let n = int(r.query["input"]), (1...maxInputNumber).contains(n) else { return .badRequest("input") }
            guard let row = int(r.query["row"]), (1...100_000).contains(row) else { return .badRequest("row") }
            cmd = .dataRowSet(input: n, row: row)
        default: return .notFound
        }
        return r.method == "POST" ? .command(cmd) : .methodNotAllowed
    }

    private static func int(_ s: String?) -> Int? { s.flatMap { Int($0) } }

    /// A finite number in 0...1.
    private static func unit(_ s: String?) -> Double? {
        guard let v = s.flatMap(Double.init), v.isFinite, (0...1).contains(v) else { return nil }
        return v
    }

    /// Mixer channel ids are short printable strings ("mic:...", "ndi:...").
    private static func channelID(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.utf8.count <= 256, !s.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        return s
    }
}

// MARK: Access

public enum RemoteAuth {
    public static let pinHeader = "x-livecore-pin"
    public static let pinLength = 6

    /// 4–8 digits.
    public static func isValidPIN(_ s: String) -> Bool {
        (4...8).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public static func generatePIN<G: RandomNumberGenerator>(using g: inout G) -> String {
        String((0..<pinLength).map { _ in Character(String(Int.random(in: 0...9, using: &g))) })
    }

    public static func generatePIN() -> String {
        var g = SystemRandomNumberGenerator()
        return generatePIN(using: &g)
    }

    /// Compares without stopping at the first different digit.
    public static func pinMatches(_ given: String?, _ pin: String) -> Bool {
        guard let given, !pin.isEmpty else { return false }
        let a = Array(given.utf8), b = Array(pin.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<b.count { diff |= b[i] ^ (i < a.count ? a[i] : 0) }
        return diff == 0
    }

    /// Only IP addresses, localhost and Bonjour ".local" names are answered, so a web page on
    /// another domain that resolves to this Mac (DNS rebinding) cannot read or drive the switcher.
    public static func hostAllowed(_ host: String?) -> Bool {
        guard var h = host?.lowercased(), !h.isEmpty else { return false }
        if h.hasPrefix("[") { return h.contains("]") }                 // IPv6 literal
        if let colon = h.lastIndex(of: ":") {
            guard h[h.index(after: colon)...].allSatisfy(\.isNumber) else { return false }
            h = String(h[..<colon])
        }
        if h == "localhost" || h.hasSuffix(".local") { return !h.hasPrefix(".") }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) && Int(p)! <= 255
        }
    }
}

/// Wrong-PIN lockout per client address: after `maxFailures` wrong PINs the client waits
/// `baseLock` seconds, doubling on each further lock (up to `maxLock`). A right PIN resets it.
public struct RemoteLockout: Sendable {
    public var maxFailures = 5
    public var baseLock: Double = 60
    public var maxLock: Double = 3600
    private var entries: [String: Entry] = [:]
    private struct Entry: Sendable { var failures = 0; var locks = 0; var until: Double = 0; var last: Double = 0 }

    public init() {}

    /// Seconds the client must still wait, or 0.
    public func waitTime(_ client: String, now: Double) -> Double {
        guard let e = entries[client], e.until > now else { return 0 }
        return e.until - now
    }

    public mutating func recordSuccess(_ client: String) { entries[client] = nil }

    /// Returns the lock time started by this failure (0 when not locked yet).
    @discardableResult
    public mutating func recordFailure(_ client: String, now: Double) -> Double {
        prune(now: now)
        var e = entries[client] ?? Entry()
        e.failures += 1
        e.last = now
        var lock: Double = 0
        if e.failures >= maxFailures {
            lock = min(maxLock, baseLock * Double(1 << min(e.locks, 20)))
            e.locks += 1
            e.failures = 0
            e.until = now + lock
        }
        entries[client] = e
        return lock
    }

    /// Forgets clients idle for a day so the table cannot grow without bound.
    private mutating func prune(now: Double) {
        guard entries.count > 256 else { return }
        entries = entries.filter { now - $0.value.last < 86_400 || $0.value.until > now }
    }
}

// MARK: State

/// What the remote page shows; serialized as a small JSON object.
public struct RemoteState: Equatable, Sendable {
    public struct Input: Equatable, Sendable {
        public var number: Int
        public var name: String
        public var kind: String
        public init(number: Int, name: String, kind: String) { self.number = number; self.name = name; self.kind = kind }
    }
    public struct Overlay: Equatable, Sendable {
        public var index: Int
        public var on: Bool
        public var onPreview: Bool
        public var input: Int?
        public init(index: Int, on: Bool, onPreview: Bool, input: Int?) {
            self.index = index; self.on = on; self.onPreview = onPreview; self.input = input
        }
    }

    public struct Choice: Equatable, Sendable {
        public var id: Int
        public var name: String
        public init(id: Int, name: String) { self.id = id; self.name = name }
    }
    /// A mixer strip; meters are peak dBFS (-120 = silence).
    public struct Channel: Equatable, Sendable {
        public var id: String
        public var name: String
        public var fader: Double
        public var muted: Bool
        public var levelL: Double
        public var levelR: Double
        public init(id: String, name: String, fader: Double, muted: Bool, levelL: Double, levelR: Double) {
            self.id = id; self.name = name; self.fader = fader; self.muted = muted; self.levelL = levelL; self.levelR = levelR
        }
    }

    public var title = "LiveCore Studio"
    public var program: Int?
    public var preview: Int?
    public var transitioning = false
    public var transition = ""
    public var transitionKind = 1
    public var transitionDuration: Double = 1
    public var transitions: [Choice] = []
    public var tbar: Double = 0
    public var tbarRest: Double = 0
    public var inputs: [Input] = []
    public var overlays: [Overlay] = []
    public var streaming = false
    public var streamLocked = false
    public var recording = false
    public var recordLocked = false
    public var replayAvailable: Double = 0
    /// Seconds since recording / streaming started (0 when off).
    public var recordTime: Double = 0
    public var streamTime: Double = 0
    public var master = Channel(id: "master", name: "Master", fader: 0.75, muted: false, levelL: -120, levelR: -120)
    public var channels: [Channel] = []
    /// A Program / Preview picture is available at /api/frame.
    public var frames = false

    public init() {}

    private static func render(_ c: Channel) -> String {
        var e = JSON.Object()
        e["id"] = JSON.string(c.id); e["name"] = JSON.string(c.name); e["fader"] = JSON.number(c.fader)
        e["muted"] = JSON.bool(c.muted); e["l"] = JSON.number(max(-120, c.levelL)); e["r"] = JSON.number(max(-120, c.levelR))
        return e.rendered
    }

    public var json: String {
        var o = JSON.Object()
        o["v"] = "1"
        o["title"] = JSON.string(title)
        o["program"] = JSON.int(program)
        o["preview"] = JSON.int(preview)
        o["transitioning"] = JSON.bool(transitioning)
        o["transition"] = JSON.string(transition)
        o["transitionKind"] = "\(transitionKind)"
        o["transitionDuration"] = JSON.number(transitionDuration)
        o["transitions"] = JSON.array(transitions.map { c in
            var e = JSON.Object()
            e["id"] = "\(c.id)"; e["name"] = JSON.string(c.name)
            return e.rendered
        })
        o["tbar"] = JSON.number(tbar)
        o["tbarRest"] = JSON.number(tbarRest)
        o["inputs"] = JSON.array(inputs.map { i in
            var e = JSON.Object()
            e["n"] = "\(i.number)"; e["name"] = JSON.string(i.name); e["kind"] = JSON.string(i.kind)
            return e.rendered
        })
        o["overlays"] = JSON.array(overlays.map { ov in
            var e = JSON.Object()
            e["n"] = "\(ov.index)"; e["on"] = JSON.bool(ov.on); e["preview"] = JSON.bool(ov.onPreview); e["input"] = JSON.int(ov.input)
            return e.rendered
        })
        o["streaming"] = JSON.bool(streaming)
        o["streamLocked"] = JSON.bool(streamLocked)
        o["recording"] = JSON.bool(recording)
        o["recordLocked"] = JSON.bool(recordLocked)
        o["replayAvailable"] = JSON.number(replayAvailable)
        o["replayLengths"] = JSON.array(ReplayIndex.lengths.map { JSON.number($0) })
        o["recordTime"] = JSON.number(recordTime)
        o["streamTime"] = JSON.number(streamTime)
        o["master"] = Self.render(master)
        o["channels"] = JSON.array(channels.map(Self.render))
        o["frames"] = JSON.bool(frames)
        return o.rendered
    }
}

/// Minimal JSON writing (no Foundation).
public enum JSON {
    public static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"      // safe inside HTML too
            case _ where u.value < 0x20:
                let h = String(u.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - h.count) + h
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    public static func bool(_ b: Bool) -> String { b ? "true" : "false" }
    public static func int(_ i: Int?) -> String { i.map { "\($0)" } ?? "null" }

    /// Up to 3 decimals; NaN / infinity become 0.
    public static func number(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        let r = (d * 1000).rounded() / 1000
        if r == r.rounded(), abs(r) < 1e15 { return "\(Int(r))" }
        return "\(r)"
    }

    public static func array(_ items: [String]) -> String { "[" + items.joined(separator: ",") + "]" }

    /// Keys keep insertion order.
    public struct Object {
        private var pairs: [(String, String)] = []
        public init() {}
        public subscript(key: String) -> String? {
            get { pairs.first { $0.0 == key }?.1 }
            set {
                pairs.removeAll { $0.0 == key }
                if let newValue { pairs.append((key, newValue)) }
            }
        }
        public var rendered: String { "{" + pairs.map { JSON.string($0.0) + ":" + $0.1 }.joined(separator: ",") + "}" }
    }
}

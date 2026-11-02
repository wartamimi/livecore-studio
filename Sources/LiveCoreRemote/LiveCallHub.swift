import Foundation
import LiveCoreCore

/// LCS Live signaling (0.52.0): the rooms of the guest links and the HTTP routes the guest page
/// and the app's host page use to swap WebRTC offers and answers. Media never passes through
/// here; it flows peer to peer between the guest's browser and the app (or through TURN).
///
///   GET  /live/host                 host page (loaded by the app's own web view, no data)
///   GET  /live/<key>                guest join page
///   GET  /live/api/<key>/info       title + ICE servers
///   POST /live/api/<key>/offer      {"sdp","name"} → {"seq"}  (a new offer replaces the call)
///   GET  /live/api/<key>/answer?seq=n   200 {"sdp"} · 204 not yet · 409 replaced
///   GET  /live/api/<key>/ping?seq=n     keeps the guest marked present; 409 when replaced
///   POST /live/api/<key>/leave      the guest hung up
///
/// The key (≈128 random bits) is the only credential; an unknown key gets 404.
public final class LiveCallHub: @unchecked Sendable {
    public struct Offer: Equatable, Sendable {
        public let seq: Int
        public let sdp: String
        public let name: String
    }

    public enum GuestEvent: Equatable, Sendable {
        case offer(Offer)
        case left(seq: Int)
    }

    struct Room {
        var title: String
        var iceJSON: String
        var seq = 0
        var answer: (seq: Int, sdp: String)?
        var lastSeen: Double = -.infinity
        var onEvent: (GuestEvent) -> Void
    }

    public static let maxSDP = 48 * 1024
    private let lock = NSLock()
    private var rooms: [String: Room] = [:]

    public init() {}

    /// Opens (or reconfigures) a room. `onEvent` runs on a server thread.
    public func open(key: String, title: String, iceJSON: String, onEvent: @escaping (GuestEvent) -> Void) {
        lock.sync {
            if var r = rooms[key] { r.title = title; r.iceJSON = iceJSON; r.onEvent = onEvent; rooms[key] = r }
            else { rooms[key] = Room(title: title, iceJSON: iceJSON, onEvent: onEvent) }
        }
    }

    public func update(key: String, title: String, iceJSON: String) {
        lock.sync { rooms[key]?.title = title; rooms[key]?.iceJSON = iceJSON }
    }

    public func close(key: String) { lock.sync { _ = rooms.removeValue(forKey: key) } }

    public var openKeys: [String] { lock.sync { Array(rooms.keys) } }

    /// The host's answer for offer `seq` (ignored when a newer offer arrived meanwhile).
    public func setAnswer(key: String, seq: Int, sdp: String) {
        lock.sync { if rooms[key]?.seq == seq { rooms[key]?.answer = (seq, sdp) } }
    }

    /// Seconds since the guest last polled (nil if never).
    public func secondsSinceGuest(key: String, now: Double = LiveCallHub.now()) -> Double? {
        lock.sync { rooms[key].flatMap { $0.lastSeen.isFinite ? now - $0.lastSeen : nil } }
    }

    public static func now() -> Double { Date().timeIntervalSinceReferenceDate }

    // MARK: HTTP

    public func handle(_ req: HTTPRequest, client: String) -> HTTPResponse {
        let parts = req.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "live" else { return .error(404, "not found") }
        if parts.count == 2, parts[1] == "host" {
            guard req.method == "GET" || req.method == "HEAD" else { return .error(405, "method not allowed") }
            return Self.page(LiveCallPages.host, connect: "'self'")
        }
        if parts.count == 2 {
            guard req.method == "GET" || req.method == "HEAD" else { return .error(405, "method not allowed") }
            guard LiveCallKey.isValid(parts[1]), lock.sync({ rooms[parts[1]] != nil }) else {
                return HTTPResponse(status: 404, contentType: "text/html; charset=utf-8", body: Array(LiveCallPages.closed.utf8),
                                    headers: Self.pageHeaders(connect: "'none'"))
            }
            return Self.page(LiveCallPages.guest, connect: "'self'")
        }
        guard parts.count == 4, parts[1] == "api" else { return .error(404, "not found") }
        let key = parts[2]
        let now = Self.now()
        switch (req.method, parts[3]) {
        case ("GET", "info"):
            guard let r = lock.sync({ rooms[key] }) else { return .error(404, "call not open") }
            return Self.json("{\"title\":\(LiveCallJSON.string(r.title)),\"ice\":\(r.iceJSON)}")
        case ("POST", "offer"):
            guard req.body.count <= Self.maxSDP,
                  let obj = try? JSONSerialization.jsonObject(with: Data(req.body)) as? [String: Any],
                  let sdp = obj["sdp"] as? String, sdp.hasPrefix("v=0") else { return .error(400, "bad offer") }
            let name = Self.cleanName(obj["name"] as? String)
            let r: (Int, (GuestEvent) -> Void)? = lock.sync {
                guard var room = rooms[key] else { return nil }
                room.seq += 1; room.answer = nil; room.lastSeen = now
                rooms[key] = room
                return (room.seq, room.onEvent)
            }
            guard let (seq, cb) = r else { return .error(404, "call not open") }
            cb(.offer(Offer(seq: seq, sdp: sdp, name: name)))
            return Self.json("{\"seq\":\(seq)}")
        case ("GET", "answer"), ("GET", "ping"):
            let seq = Int(req.query["seq"] ?? "") ?? -1
            let r: (cur: Int, answer: String?)? = lock.sync {
                guard var room = rooms[key] else { return nil }
                if room.seq == seq { room.lastSeen = now; rooms[key] = room }
                return (room.seq, room.answer.flatMap { $0.seq == seq ? $0.sdp : nil })
            }
            guard let r else { return .error(404, "call not open") }
            if r.cur != seq { return .error(409, "replaced") }
            if parts[3] == "ping" { return Self.json("{\"ok\":true}") }
            guard let sdp = r.answer else { return HTTPResponse(status: 204, headers: Self.noStore) }
            return Self.json("{\"sdp\":\(LiveCallJSON.string(sdp))}")
        case ("POST", "leave"):
            let seq = Int(req.query["seq"] ?? "") ?? -1
            let cb: ((GuestEvent) -> Void)? = lock.sync {
                guard var room = rooms[key], room.seq == seq else { return nil }
                room.answer = nil; room.lastSeen = -.infinity
                rooms[key] = room
                return room.onEvent
            }
            cb?(.left(seq: seq))
            return Self.json("{\"ok\":true}")
        case (_, "info"), (_, "offer"), (_, "answer"), (_, "ping"), (_, "leave"):
            return .error(405, "method not allowed")
        default:
            return .error(404, "not found")
        }
    }

    /// Up to 40 printable characters; empty → "Guest".
    static func cleanName(_ s: String?) -> String {
        let t = String((s ?? "").unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Guest" : String(t.prefix(40))
    }

    static let noStore: [(String, String)] = [("Cache-Control", "no-store")]

    static func json(_ s: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json", body: Array(s.utf8), headers: noStore)
    }

    static func pageHeaders(connect: String) -> [(String, String)] {
        [("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer"), ("Cache-Control", "no-store"),
         ("Permissions-Policy", "camera=(self), microphone=(self), autoplay=(self)"),
         ("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; connect-src \(connect); img-src 'self' data: blob:; media-src 'self' blob: mediastream:; worker-src blob:; frame-ancestors 'none'")]
    }

    static func page(_ html: String, connect: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Array(html.utf8), headers: pageHeaders(connect: connect))
    }
}

/// Zoom Meeting SDK helpers that do not need the SDK: the SDK JWT (HS256, signed with the
/// app's Client Secret on this Mac) and parsing of meeting links. Pure Swift so they are
/// unit-tested on Linux.

/// SHA-256 and HMAC-SHA256 (FIPS 180-4 / RFC 2104). Small inputs only (JWT signing).
public enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var m = message
        let bitLen = UInt64(message.count) &* 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8(truncatingIfNeeded: bitLen >> (UInt64(i) * 8))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for t in 0..<16 {
                let b = chunk + t * 4
                w[t] = UInt32(m[b]) << 24 | UInt32(m[b + 1]) << 16 | UInt32(m[b + 2]) << 8 | UInt32(m[b + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for t in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - UInt32($0) * 8)) } }
    }

    public static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? hash(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let ipad = k.map { $0 ^ 0x36 }, opad = k.map { $0 ^ 0x5c }
        return hash(opad + hash(ipad + message))
    }
}

public enum Base64URL {
    private static let table = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
    /// Unpadded base64url (RFC 4648 §5), as JWTs use.
    public static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var i = 0
        while i + 2 < bytes.count {
            let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
            out += [table[Int(n >> 18 & 63)], table[Int(n >> 12 & 63)], table[Int(n >> 6 & 63)], table[Int(n & 63)]]
            i += 3
        }
        let rest = bytes.count - i
        if rest == 1 {
            let n = UInt32(bytes[i]) << 16
            out += [table[Int(n >> 18 & 63)], table[Int(n >> 12 & 63)]]
        } else if rest == 2 {
            let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8
            out += [table[Int(n >> 18 & 63)], table[Int(n >> 12 & 63)], table[Int(n >> 6 & 63)]]
        }
        return String(decoding: out, as: UTF8.self)
    }
}

public enum ZoomJWT {
    /// The Meeting SDK auth token: HS256 JWT with appKey (Client ID), iat, exp and tokenExp.
    /// `now` is Unix time; tokens live `lifetime` seconds (Zoom allows 30 min to 48 h).
    public static func make(clientID: String, clientSecret: String, now: Int, lifetime: Int = 2 * 3600) -> String {
        let iat = now - 30   // tolerate a slightly fast Mac clock
        let exp = iat + max(1800, min(lifetime, 48 * 3600))
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"appKey":"\#(jsonEscape(clientID))","iat":\#(iat),"exp":\#(exp),"tokenExp":\#(exp)}"#
        let signingInput = Base64URL.encode(Array(header.utf8)) + "." + Base64URL.encode(Array(payload.utf8))
        let sig = SHA256.hmac(key: Array(clientSecret.utf8), message: Array(signingInput.utf8))
        return signingInput + "." + Base64URL.encode(sig)
    }

    static func jsonEscape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if u.value < 0x20 { out += "\\u" + String(repeating: "0", count: 4 - String(u.value, radix: 16).count) + String(u.value, radix: 16) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out
    }
}

/// What the operator typed in the "Join" field: a meeting ID ("812 3456 7890") or an invite
/// link ("https://us05web.zoom.us/j/81234567890?pwd=…").
public struct ZoomJoinInfo: Equatable, Sendable {
    public var meetingNumber: Int64
    /// The `pwd` query value of an invite link (an encoded passcode), if any.
    public var linkPasscode: String?

    public static func parse(_ text: String) -> ZoomJoinInfo? {
        let t = text.trimmingCharacters(in: " \t\n")
        var digits = ""
        var pwd: String?
        if let r = t.find("/j/") ?? t.find("/w/") ?? t.find("/s/") {
            digits = String(t[r.upperBound...].prefix { $0.isNumber })
            if let q = t.find("pwd=") {
                let v = t[q.upperBound...].prefix { $0 != "&" && $0 != "#" }
                if !v.isEmpty { pwd = String(v) }
            }
        } else {
            guard t.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return nil }
            digits = t.filter(\.isNumber)
        }
        guard (9...11).contains(digits.count), let n = Int64(digits) else { return nil }
        return ZoomJoinInfo(meetingNumber: n, linkPasscode: pwd)
    }
}

private extension String {
    /// Range of the first occurrence of `needle` (Foundation-free `range(of:)`).
    func find(_ needle: String) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        var i = startIndex
        while i < endIndex {
            if self[i...].hasPrefix(needle) { return i..<index(i, offsetBy: needle.count) }
            i = index(after: i)
        }
        return nil
    }

    func trimmingCharacters(in set: String) -> String {
        let chars = Set(set)
        var s = Substring(self)
        while let f = s.first, chars.contains(f) { s.removeFirst() }
        while let l = s.last, chars.contains(l) { s.removeLast() }
        return String(s)
    }
}

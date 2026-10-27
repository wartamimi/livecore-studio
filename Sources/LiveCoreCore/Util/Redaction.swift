/// Helpers that keep secrets (stream keys) out of logs and UI error strings.
public enum Redaction {
    /// Masks a stream key for display: keeps at most the first 2 and last 2 characters
    /// when the key is long enough, otherwise masks everything.
    public static func maskKey(_ key: String) -> String {
        guard !key.isEmpty else { return "" }
        if key.count < 10 { return String(repeating: "•", count: 6) }
        return String(key.prefix(2)) + String(repeating: "•", count: 6) + String(key.suffix(2))
    }

    /// Removes every occurrence of `secret` from `text`. Use on any string that may contain a
    /// full publish URL (e.g. server error messages echoing the stream name).
    public static func scrub(_ text: String, secrets: [String]) -> String {
        var out = text
        for s in secrets where s.count >= 4 {
            out = out.replacingAll(s, with: "<redacted>")
        }
        return out
    }
}

extension String {
    /// Foundation-free replace-all (LiveCoreCore avoids Foundation so it stays portable and small).
    func replacingAll(_ target: String, with replacement: String) -> String {
        guard !target.isEmpty else { return self }
        var result = ""
        var remainder = Substring(self)
        while let range = remainder.firstRange(of: target) {
            result += remainder[remainder.startIndex..<range.lowerBound]
            result += replacement
            remainder = remainder[range.upperBound...]
        }
        result += remainder
        return result
    }
}

extension Substring {
    func firstRange(of target: String) -> Range<Substring.Index>? {
        let t = Array(target.utf8)
        let u = self.utf8
        guard !t.isEmpty, u.count >= t.count else { return nil }
        var i = u.startIndex
        while i != u.endIndex {
            var j = i
            var k = 0
            while k < t.count, j != u.endIndex, u[j] == t[k] { j = u.index(after: j); k += 1 }
            if k == t.count { return i..<j }
            i = u.index(after: i)
        }
        return nil
    }
}

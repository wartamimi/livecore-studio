/// Track order rules shared by the music player and video playlists.
public enum PlaylistMath {
    /// Index after `index`, or nil at the end of a non-looping list. With `shuffle`, a random
    /// other track (never the same one twice in a row when there is a choice).
    public static func next(index: Int, count: Int, loop: Bool, shuffle: Bool,
                            random: (Range<Int>) -> Int) -> Int? {
        guard count > 0 else { return nil }
        if shuffle && count > 1 {
            let r = random(0..<(count - 1))
            return r >= index ? r + 1 : r
        }
        if index + 1 < count { return index + 1 }
        return loop ? 0 : nil
    }

    /// Index before `index`, wrapping to the last track.
    public static func previous(index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return index > 0 ? index - 1 : count - 1
    }
}

/// Editing a playlist while one of its items plays: where the playing item ends up.
public enum PlaylistEdit {
    /// After removing item `at`: the index of the item that keeps playing, and whether the playing
    /// item itself was removed (then the returned index is the item that took its place, clamped).
    public static func remove(at: Int, current: Int, count: Int) -> (current: Int, removedCurrent: Bool) {
        guard count > 1, (0..<count).contains(at) else { return (0, at == current) }
        if at == current { return (min(current, count - 2), true) }
        return (at < current ? current - 1 : current, false)
    }

    /// Index of the playing item after moving item `from` to position `to`.
    public static func move(from: Int, to: Int, current: Int) -> Int {
        if from == current { return to }
        if from < current && to >= current { return current - 1 }
        if from > current && to <= current { return current + 1 }
        return current
    }

    public static func moved<T>(_ list: [T], from: Int, to: Int) -> [T] {
        guard list.indices.contains(from), list.indices.contains(to), from != to else { return list }
        var l = list
        let item = l.remove(at: from)
        l.insert(item, at: to)
        return l
    }
}

/// M3U / M3U8 playlists (plain or extended). Paths are returned as written; relative ones are
/// resolved by the caller against the playlist's folder.
public enum M3U {
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            let t = String(line).trimmingSpaces
            guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
            if t.hasPrefix("file://") { return percentDecoded(String(t.dropFirst(7))) }
            return t
        }
    }

    /// Extended M3U with a title line per entry.
    public static func write(paths: [String]) -> String {
        var out = "#EXTM3U\n"
        for p in paths {
            let name = p.split(separator: "/").last.map(String.init) ?? p
            let title = name.split(separator: ".").dropLast().joined(separator: ".")
            out += "#EXTINF:-1,\(title.isEmpty ? name : title)\n\(p)\n"
        }
        return out
    }

    static func percentDecoded(_ s: String) -> String {
        var bytes: [UInt8] = []
        var u = Array(s.utf8)[...]
        while let c = u.first {
            if c == UInt8(ascii: "%"), u.count >= 3,
               let v = UInt8(String(decoding: u.dropFirst().prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(v); u = u.dropFirst(3)
            } else { bytes.append(c); u = u.dropFirst() }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension String {
    /// Leading / trailing spaces and tabs removed (Foundation-free).
    var trimmingSpaces: String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\t" || f == "\u{FEFF}" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return String(s)
    }
}

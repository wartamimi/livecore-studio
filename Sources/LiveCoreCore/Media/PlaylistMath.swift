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

/// Bookkeeping for the instant-replay buffer: Program is recorded into short consecutive
/// segment files; this decides which segments a replay of the last N seconds needs and which
/// ones fell out of the buffer. Times are host-clock seconds.
public struct ReplaySegment: Equatable, Sendable {
    public var id: Int
    public var start: Double
    public var end: Double
    public init(id: Int, start: Double, end: Double) { self.id = id; self.start = start; self.end = end }
    public var duration: Double { end - start }
}

public struct ReplayIndex: Equatable, Sendable {
    public static let segmentSeconds = 2.0
    public static let lengths: [Double] = [5, 10, 20]
    public static let speeds: [Double] = [1, 0.5, 0.25]

    /// How much Program history is kept.
    public var bufferSeconds: Double
    public private(set) var segments: [ReplaySegment] = []

    public init(bufferSeconds: Double = 30) { self.bufferSeconds = max(bufferSeconds, Self.segmentSeconds) }

    /// Seconds of Program available for replay.
    public var available: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Adds a finished segment; returns the segments that are now older than the buffer (their
    /// files can be deleted).
    public mutating func add(_ s: ReplaySegment) -> [ReplaySegment] {
        segments.append(s)
        segments.sort { $0.start < $1.start }
        var dropped: [ReplaySegment] = []
        // Keep one segment beyond the buffer so a full-length replay is always possible.
        while segments.count > 1, available - segments[0].duration >= bufferSeconds {
            dropped.append(segments.removeFirst())
        }
        return dropped
    }

    /// The segments covering the last `seconds`, oldest first, and the offset into the first
    /// one where the replay starts.
    public func clip(lastSeconds seconds: Double) -> (segments: [ReplaySegment], startOffset: Double)? {
        guard let last = segments.last, seconds > 0 else { return nil }
        let from = last.end - seconds
        let used = segments.filter { $0.end > from }
        guard let first = used.first else { return nil }
        return (used, max(0, from - first.start))
    }

    public mutating func removeAll() -> [ReplaySegment] {
        defer { segments = [] }
        return segments
    }
}

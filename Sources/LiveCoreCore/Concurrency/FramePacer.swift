/// Plays frames back on the cadence they were captured at, not the one they arrived at.
/// USB capture cards (e.g. Datavideo CAP-2) deliver frames in bursts; a latest-frame slot then
/// repeats one frame and skips the next on the output clock, which looks choppy. The pacer delays
/// each frame by the recent worst-case arrival lag, so only the jitter is added as latency.
/// Not thread safe: the owner guards it.
public struct FramePacer<Frame> {
    private var queue: [(pts: Double, frame: Frame)] = []
    private var lags: [Double] = []
    private var next = 0
    private let capacity: Int
    private let window = 50
    /// Most latency added on top of the steady lag (a stall must not delay the picture for long).
    private let maxJitter = 0.1

    public init(capacity: Int = 4) { self.capacity = capacity }

    /// `pts`: capture time in seconds; `arrival`: host time when it arrived.
    public mutating func put(_ frame: Frame, pts: Double, arrival: Double) {
        let t = pts.isFinite ? pts : arrival
        if let last = queue.last, t <= last.pts { queue.removeAll(); lags.removeAll(); next = 0 }
        if lags.count < window { lags.append(arrival - t) } else { lags[next] = arrival - t }
        next = (next + 1) % window
        queue.append((t, frame))
        if queue.count > capacity { queue.removeFirst() }
    }

    /// The frame due at host time `now`.
    public mutating func frame(at now: Double) -> Frame? {
        guard let low = lags.min(), let high = lags.max() else { return nil }
        let lag = min(high, low + maxJitter)
        if let i = queue.lastIndex(where: { $0.pts + lag <= now }) { queue.removeFirst(i) }
        return queue.first?.frame
    }
}

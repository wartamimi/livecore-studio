/// Congestion policy between the encoders and a slow network.
///
/// Encoded packets are queued here; the transport drains it. If the queued video spans more
/// than `maxQueuedMs`, the queued video is discarded and sending resumes at the next keyframe
/// (audio is kept: gaps are more noticeable and it is ~5% of the bandwidth). Every dropped
/// video frame is counted so the UI can show "dropped frames".
public struct OutgoingPacket: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case video(keyframe: Bool), audio, metadata, config }
    public var kind: Kind
    public var timestampMs: UInt32
    public var body: [UInt8]
    public init(kind: Kind, timestampMs: UInt32, body: [UInt8]) {
        self.kind = kind; self.timestampMs = timestampMs; self.body = body
    }
}

public struct StreamOutputQueue: Sendable {
    public var maxQueuedMs: UInt32
    public private(set) var packets: [OutgoingPacket] = []
    public private(set) var droppedVideoFrames: UInt64 = 0
    private var waitingForKeyframe = false

    public init(maxQueuedMs: UInt32 = 3000) { self.maxQueuedMs = maxQueuedMs }

    public var queuedBytes: Int { packets.reduce(0) { $0 + $1.body.count } }

    public var queuedDurationMs: UInt32 {
        guard let first = packets.first(where: { if case .video = $0.kind { return true }; return false }),
              let last = packets.last(where: { if case .video = $0.kind { return true }; return false })
        else { return 0 }
        return last.timestampMs &- first.timestampMs
    }

    public mutating func enqueue(_ p: OutgoingPacket) {
        switch p.kind {
        case let .video(keyframe):
            if waitingForKeyframe && !keyframe { droppedVideoFrames += 1; return }
            if keyframe { waitingForKeyframe = false }
            packets.append(p)
            if queuedDurationMs > maxQueuedMs {
                // Over budget: drop every queued video frame except a keyframe that just arrived
                // (decoding can restart from it). Otherwise skip input until the next keyframe.
                let keepIndex = keyframe ? packets.count - 1 : -1
                var kept: [OutgoingPacket] = []
                kept.reserveCapacity(packets.count)
                for (i, q) in packets.enumerated() {
                    if case .video = q.kind, i != keepIndex { droppedVideoFrames += 1; continue }
                    kept.append(q)
                }
                packets = kept
                if !keyframe { waitingForKeyframe = true }
            }
        default:
            packets.append(p)
        }
    }

    public mutating func dequeue() -> OutgoingPacket? {
        packets.isEmpty ? nil : packets.removeFirst()
    }
}

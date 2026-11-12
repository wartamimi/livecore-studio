#if os(macOS)
import Foundation
import LiveCoreCore

/// Line-up tone (sine, 1 kHz at -18 dBFS by default) played into its own mixer channel, e.g. with
/// the Colour Bars input to check levels downstream. A timer keeps the channel's buffer topped up.
public final class TestTone {
    public let id: String
    public let channel: MixerChannel
    public var frequency: Double { get { lock.withLock { gen.frequency } } set { lock.withLock { gen.frequency = newValue } } }
    public var levelDB: Double { get { lock.withLock { gen.levelDB } } set { lock.withLock { gen.levelDB = newValue } } }

    private var gen: ToneGenerator
    private let lock = UnfairLock()
    private let queue = DispatchQueue(label: "livecore.tone", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var bufL = [Float](repeating: 0, count: 480)
    /// Frames kept queued in the channel (50 ms).
    private let target = 2400

    init(id: String, channel: MixerChannel, frequency: Double, levelDB: Double) {
        self.id = id
        self.channel = channel
        gen = ToneGenerator(frequency: frequency, levelDB: levelDB, sampleRate: 48_000)
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.topUp() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }

    private func topUp() {
        while channel.ringL.availableToRead < target {
            let n = bufL.count
            lock.withLock { bufL.withUnsafeMutableBufferPointer { gen.fill($0.baseAddress!, count: n) } }
            bufL.withUnsafeBufferPointer { p in
                _ = channel.ringL.write(p.baseAddress!, count: n)
                _ = channel.ringR.write(p.baseAddress!, count: n)
            }
        }
    }
}
#endif

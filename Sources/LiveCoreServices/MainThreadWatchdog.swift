import Dispatch
import Foundation

/// Notices when the main thread stops answering (a long layout, a blocking call on the UI
/// thread). A background timer posts a ping to `target` every `interval`; when a ping comes back
/// later than `threshold`, `onStall` is called (on the background queue) with the delay in
/// milliseconds. Used to find what makes the show stutter: the result goes into the log file.
public final class MainThreadWatchdog {
    public let interval: Double
    public let threshold: Double
    public var onStall: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "livecore.watchdog", qos: .utility)
    private let target: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var waiting = false
    private var sentAt = 0.0

    public init(target: DispatchQueue = .main, interval: Double = 0.1, threshold: Double = 0.25) {
        self.target = target
        self.interval = interval
        self.threshold = threshold
    }

    public func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.interval, repeating: self.interval)
            t.setEventHandler { [weak self] in self?.ping() }
            self.timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    private func ping() {
        guard !waiting else { return }   // the previous ping has not been answered yet
        waiting = true
        sentAt = Self.now()
        let queue = self.queue
        target.async {
            let answered = Self.now()
            queue.async { [weak self] in
                guard let self else { return }
                self.waiting = false
                let late = answered - self.sentAt
                if late >= self.threshold { self.onStall?(Int((late * 1000).rounded())) }
            }
        }
    }
}

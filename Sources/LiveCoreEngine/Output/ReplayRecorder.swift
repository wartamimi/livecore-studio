#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import LiveCoreCore

/// Instant-replay buffer: Program video is written continuously into short H.264 segment
/// files (2 s) in a temporary folder; only the last `bufferSeconds` are kept on disk. A replay
/// closes the current segment early, then stitches the segments covering the last N seconds
/// into an AVComposition (no re-encode).
///
/// Video only: replays are usually played slowed down, where Program audio would not fit.
public final class ReplayRecorder {
    public struct Clip {
        public let asset: AVAsset
        public let start: CMTime     // where the requested last-N-seconds begin
    }

    /// Seconds currently available (main thread).
    public var onAvailableChange: ((Double) -> Void)?
    /// A segment could not be written (main thread, at most once per start).
    public var onError: ((String) -> Void)?
    private var errorReported = false

    private let queue = DispatchQueue(label: "livecore.replay", qos: .utility)
    private let folder: URL
    private var index: ReplayIndex
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var segStart: Double = 0
    private var lastPTS: Double = 0
    private var nextID = 0
    private var finishing = 0                       // segments still being finalised
    private var waiters: [() -> Void] = []          // run once `finishing` reaches 0
    private var output = OutputFormat.hd1080p30
    public private(set) var isRunning = false

    public init(bufferSeconds: Double = 30) {
        index = ReplayIndex(bufferSeconds: bufferSeconds)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCoreReplay-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    public func start(output: OutputFormat) {
        queue.async {
            guard !self.isRunning else { return }
            self.output = output
            try? FileManager.default.removeItem(at: self.folder)
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            self.isRunning = true
            self.errorReported = false
        }
    }

    public func stop() {
        queue.async {
            self.isRunning = false
            self.writer?.cancelWriting()
            self.writer = nil; self.input = nil; self.adaptor = nil
            _ = self.index.removeAll()
            try? FileManager.default.removeItem(at: self.folder)
            self.publish()
        }
    }

    /// Render queue: one Program frame.
    public func append(_ pb: CVPixelBuffer, hostTime: Double) {
        queue.async {
            guard self.isRunning, hostTime > self.lastPTS else { return }
            if self.writer == nil { self.openSegment(at: hostTime) }
            else if hostTime - self.segStart >= ReplayIndex.segmentSeconds { self.closeSegment(); self.openSegment(at: hostTime) }
            guard let input = self.input, let adaptor = self.adaptor, input.isReadyForMoreMediaData else { return }
            if adaptor.append(pb, withPresentationTime: CMTime(seconds: hostTime, preferredTimescale: 90_000)) {
                self.lastPTS = hostTime
            } else {
                self.report("append failed: \(self.writer?.error?.localizedDescription ?? "status \(self.writer?.status.rawValue ?? -1)")")
            }
        }
    }

    /// The last `seconds` of Program, delivered on the main thread (nil if nothing is buffered).
    public func clip(lastSeconds seconds: Double, completion: @escaping (Clip?) -> Void) {
        queue.async {
            // Close the running segment so the replay reaches up to "now".
            if self.writer != nil { self.closeSegment() }
            self.whenFinished {
                guard let c = self.index.clip(lastSeconds: seconds) else { return DispatchQueue.main.async { completion(nil) } }
                let urls = c.segments.map { self.url($0.id) }
                Self.compose(urls) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case let .success(comp):
                            completion(Clip(asset: comp, start: CMTime(seconds: c.startOffset, preferredTimescale: 600)))
                        case let .failure(error):
                            NSLog("LiveCore replay: clip failed: %@", error.localizedDescription)
                            self.onError?("replay clip failed: " + error.localizedDescription)
                            completion(nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: Segments (queue)

    private func url(_ id: Int) -> URL { folder.appendingPathComponent("seg-\(id).mp4") }

    private func openSegment(at host: Double) {
        let id = nextID
        nextID += 1
        let w: AVAssetWriter
        do { w = try AVAssetWriter(outputURL: url(id), fileType: .mp4) } catch { return report("cannot create segment: \(error.localizedDescription)") }
        let pixels = output.size.width * output.size.height
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: output.size.width,
            AVVideoHeightKey: output.size.height,
            AVVideoCompressionPropertiesKey: [
                // High quality: replays are often slowed down and scrutinised.
                AVVideoAverageBitRateKey: max(8_000_000, pixels * output.frameRate / 3),
                AVVideoMaxKeyFrameIntervalKey: output.frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: output.frameRate,
            ] as [String: Any],
        ])
        v.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else { return report("H.264 input rejected") }
        w.add(v)
        // The adaptor must exist before startWriting(): AVFoundation throws an Objective-C exception
        // (an uncatchable crash in Swift) when it is created on a writer that has already started.
        let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: nil)
        guard w.startWriting() else { return report("cannot start segment: \(w.error?.localizedDescription ?? "unknown")") }
        w.startSession(atSourceTime: CMTime(seconds: host, preferredTimescale: 90_000))
        writer = w; input = v
        adaptor = a
        segStart = host
        segID = id
    }

    private var segID = 0

    private func closeSegment() {
        guard let w = writer, let v = input else { return }
        let seg = ReplaySegment(id: segID, start: segStart, end: lastPTS + 1 / Double(max(output.frameRate, 1)))
        writer = nil; input = nil; adaptor = nil
        guard seg.end > seg.start, lastPTS >= segStart else { w.cancelWriting(); return }
        v.markAsFinished()
        finishing += 1
        w.endSession(atSourceTime: CMTime(seconds: seg.end, preferredTimescale: 90_000))
        w.finishWriting {
            self.queue.async {
                self.finishing -= 1
                if w.status == .completed, self.isRunning {
                    for old in self.index.add(seg) { try? FileManager.default.removeItem(at: self.url(old.id)) }
                } else {
                    if self.isRunning { self.report("segment not finished: \(w.error?.localizedDescription ?? "status \(w.status.rawValue)")") }
                    try? FileManager.default.removeItem(at: w.outputURL)
                }
                self.publish()
                if self.finishing == 0 { let w = self.waiters; self.waiters = []; w.forEach { $0() } }
            }
        }
    }

    private func whenFinished(_ f: @escaping () -> Void) {
        if finishing == 0 { f() } else { waiters.append(f) }
    }

    private func report(_ msg: String) {
        guard !errorReported else { return }
        errorReported = true
        NSLog("LiveCore replay: %@", msg)
        DispatchQueue.main.async { self.onError?(msg) }
    }

    private func publish() {
        let a = index.available
        DispatchQueue.main.async { self.onAvailableChange?(a) }
    }

    /// Joins segment files into one composition (references the files; no re-encode). Track
    /// properties are loaded with the async API; why a segment could not be used is reported
    /// (0.55.2: replays came back empty on macOS with no explanation).
    static func compose(_ urls: [URL], completion: @escaping (Result<AVComposition, Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            do {
                let comp = AVMutableComposition()
                guard let out = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw ReplayError("cannot create composition track")
                }
                var cursor = CMTime.zero
                var problems: [String] = []
                for url in urls {
                    let asset = AVURLAsset(url: url)
                    do {
                        guard let t = try await asset.loadTracks(withMediaType: .video).first else {
                            problems.append("\(url.lastPathComponent): no video track"); continue
                        }
                        let range = try await t.load(.timeRange)
                        guard range.duration.isValid, range.duration > .zero else {
                            problems.append("\(url.lastPathComponent): empty"); continue
                        }
                        try out.insertTimeRange(range, of: t, at: cursor)
                        cursor = cursor + range.duration
                    } catch {
                        problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                guard cursor > .zero else { throw ReplayError(problems.isEmpty ? "no segments" : problems.joined(separator: "; ")) }
                completion(.success(comp))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

struct ReplayError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
#endif

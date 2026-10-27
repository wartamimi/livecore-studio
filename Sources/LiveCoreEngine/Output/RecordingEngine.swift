#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import LiveCoreCore

/// Local recording of the Program output with AVAssetWriter (H.264 + AAC in MP4 or MOV).
///
/// It consumes the same composited program pixel buffers and the same mixed program audio as
/// the streaming engine — there is a single capture/composite/mix pipeline. AVAssetWriter runs
/// its own (hardware) H.264 encode so recording quality/bitrate is independent from the stream.
///
/// Robustness:
///   * free disk space is checked before starting and every 5 s; below the threshold the
///     recording is stopped and finalised cleanly.
///   * writer failures are surfaced with the underlying error.
///   * MOV recordings use movie fragments (every 10 s) so a crash or power loss leaves a
///     playable file up to the last fragment. MP4 is only playable after a clean stop.
public final class RecordingEngine {
    public enum State: Equatable {
        case idle
        case recording(URL)
        case finishing
        case finished(URL, bytes: Int64)
        case failed(String)
    }

    public struct Stats: Equatable {
        public var state: State = .idle
        public var duration: Double = 0
        public var droppedVideoFrames: Int = 0
        public var freeBytes: Int64 = 0
        public var fileBytes: Int64 = 0
        public init() {}
    }

    public var onStats: ((Stats) -> Void)?   // main thread

    private let queue = DispatchQueue(label: "livecore.record", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioFormat: CMAudioFormatDescription?
    private var sessionStart: CMTime?
    private var lastVideoPTS: CMTime = .invalid
    private var stats = Stats()
    private var monitorTimer: DispatchSourceTimer?
    private var settings = RecordingSettings()
    private var url: URL?

    public init() {}

    public static func defaultFolder() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("LiveCore Studio", isDirectory: true)
    }

    public static func freeBytes(at folder: URL) -> Int64 {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: Control

    public func start(settings: RecordingSettings, output: OutputFormat, audio: AudioEncoderSettings) {
        queue.async { self.startOnQueue(settings: settings, output: output, audio: audio) }
    }

    public func stop() {
        queue.async { self.finish(reason: nil) }
    }

    private func startOnQueue(settings: RecordingSettings, output: OutputFormat, audio: AudioEncoderSettings) {
        guard writer == nil else { return }
        self.settings = settings
        stats = Stats()
        let folder = settings.folderPath.isEmpty ? Self.defaultFolder() : URL(fileURLWithPath: settings.folderPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return report(.failed("Cannot create folder \(folder.path): \(error.localizedDescription)"))
        }
        let free = Self.freeBytes(at: folder)
        guard free > settings.minimumFreeBytes else {
            return report(.failed("Not enough disk space (\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free)."))
        }
        // Unique file name.
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        var fileURL: URL
        var n = 1
        repeat {
            let name = FileNaming.fileName(pattern: settings.fileNamePattern, year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                                           hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0, counter: n,
                                           ext: settings.container.fileExtension)
            fileURL = folder.appendingPathComponent(n == 1 ? name : name.replacingOccurrences(of: ".\(settings.container.fileExtension)", with: " (\(n)).\(settings.container.fileExtension)"))
            n += 1
        } while FileManager.default.fileExists(atPath: fileURL.path)

        do {
            let w = try AVAssetWriter(outputURL: fileURL, fileType: settings.container == .mov ? .mov : .mp4)
            if settings.container == .mov { w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600) }
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: output.size.width,
                AVVideoHeightKey: output.size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: settings.bitrateKbps * 1000,
                    AVVideoMaxKeyFrameIntervalKey: output.frameRate * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: output.frameRate,
                ] as [String: Any],
            ])
            v.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVEncoderBitRateKey: max(audio.bitrateKbps, 128) * 1000,
            ])
            a.expectsMediaDataInRealTime = true
            guard w.canAdd(v), w.canAdd(a) else { throw NSError(domain: "LiveCore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Writer rejected inputs"]) }
            w.add(v); w.add(a)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: nil)
            guard w.startWriting() else { throw w.error ?? NSError(domain: "LiveCore", code: 4) }
            writer = w; videoInput = v; audioInput = a; url = fileURL
            audioFormat = Self.makePCMFormat(sampleRate: Double(audio.sampleRate))
            sessionStart = nil
            lastVideoPTS = .invalid
            stats.freeBytes = free
            report(.recording(fileURL))
            startMonitor(folder: folder)
            Log.record.info("recording started: \(fileURL.lastPathComponent, privacy: .public)")
        } catch {
            cleanup()
            report(.failed("Cannot start recording: \(error.localizedDescription)"))
        }
    }

    // MARK: Media (called from render completion / audio pump threads)

    public func append(video pb: CVPixelBuffer, pts: CMTime) {
        queue.async {
            guard let w = self.writer, w.status == .writing, let input = self.videoInput, let adaptor = self.adaptor else { return }
            if self.sessionStart == nil {
                w.startSession(atSourceTime: pts)
                self.sessionStart = pts
            }
            guard CMTimeCompare(pts, self.lastVideoPTS) > 0 || !self.lastVideoPTS.isValid else { return }
            if input.isReadyForMoreMediaData {
                if !adaptor.append(pb, withPresentationTime: pts) { self.checkWriterFailure() }
                self.lastVideoPTS = pts
            } else {
                self.stats.droppedVideoFrames += 1
            }
        }
    }

    public func append(audio chunk: ProgramAudioPump.Chunk) {
        queue.async {
            guard let w = self.writer, w.status == .writing, let start = self.sessionStart, let input = self.audioInput,
                  let fmt = self.audioFormat else { return }
            let pts = CMTime(seconds: chunk.hostTime, preferredTimescale: 48_000)
            guard CMTimeCompare(pts, start) >= 0, input.isReadyForMoreMediaData,
                  let sb = Self.makePCMSampleBuffer(chunk, format: fmt, pts: pts) else { return }
            if !input.append(sb) { self.checkWriterFailure() }
        }
    }

    // MARK: Finalisation

    private func finish(reason: String?) {
        guard let w = writer, let url else { return }
        monitorTimer?.cancel(); monitorTimer = nil
        if w.status != .writing {
            let msg = w.error?.localizedDescription ?? "writer not writing"
            cleanup()
            return report(.failed("Recording failed: \(msg)"))
        }
        report(.finishing)
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        w.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                if w.status == .completed {
                    Log.record.info("recording finished: \(url.lastPathComponent, privacy: .public) \(size) bytes")
                    self.cleanup()
                    if let reason {
                        self.report(.failed("\(reason) Recording was stopped and saved to \(url.lastPathComponent)."))
                    } else {
                        self.report(.finished(url, bytes: size))
                    }
                } else {
                    let msg = w.error?.localizedDescription ?? "unknown error"
                    self.cleanup()
                    self.report(.failed("Recording could not be finalised: \(msg)"))
                }
            }
        }
    }

    private func checkWriterFailure() {
        guard let w = writer, w.status == .failed else { return }
        let msg = w.error?.localizedDescription ?? "unknown writer error"
        Log.record.error("writer failed: \(msg, privacy: .public)")
        monitorTimer?.cancel(); monitorTimer = nil
        cleanup()
        report(.failed("Recording failed (disk full or write error): \(msg)"))
    }

    private func cleanup() {
        writer = nil; videoInput = nil; audioInput = nil; adaptor = nil; sessionStart = nil
    }

    private func startMonitor(folder: URL) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        var tick = 0
        t.setEventHandler { [weak self] in
            guard let self, let w = self.writer, let url = self.url else { return }
            tick += 1
            if let start = self.sessionStart, self.lastVideoPTS.isValid {
                self.stats.duration = CMTimeGetSeconds(CMTimeSubtract(self.lastVideoPTS, start))
            }
            if tick % 5 == 0 {
                self.stats.freeBytes = Self.freeBytes(at: folder)
                self.stats.fileBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                if self.stats.freeBytes < self.settings.minimumFreeBytes / 2 {
                    self.finish(reason: "Disk space is running out.")
                    return
                }
            }
            if w.status == .failed { self.checkWriterFailure(); return }
            self.publish()
        }
        t.resume()
        monitorTimer = t
    }

    private func report(_ s: State) {
        stats.state = s
        publish()
    }

    private func publish() {
        let s = stats
        DispatchQueue.main.async { self.onStats?(s) }
    }

    // MARK: PCM sample buffers

    static func makePCMFormat(sampleRate: Double) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        return fmt
    }

    /// Interleaves a planar chunk into a new CMSampleBuffer (Float32 interleaved stereo).
    static func makePCMSampleBuffer(_ chunk: ProgramAudioPump.Chunk, format: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let frames = chunk.frames
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { interleaved[2 * i] = chunk.left[i]; interleaved[2 * i + 1] = chunk.right[i] }
        let st = interleaved.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard st == kCMBlockBufferNoErr else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                   formatDescription: format, sampleCount: frames,
                                                                   presentationTimeStamp: pts, packetDescriptions: nil,
                                                                   sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
#endif

#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import LiveCoreCore
import VideoToolbox

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
    private let fileLock = UnfairLock()
    private var lastFile: URL?
    /// The file of the current or last recording.
    public var lastFileURL: URL? { fileLock.withLock { lastFile } }

    public init() {}

    public static func defaultFolder() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("LiveCore Studio", isDirectory: true)
    }

    /// Free space on the folder's volume. The "important usage" figure (which counts purgeable
    /// space) is 0 or missing on many external and disk-image volumes (HFS+, exFAT), so fall back
    /// to the plain available capacity there.
    public static func freeBytes(at folder: URL) -> Int64 {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// Free space below which a running recording is closed: half the start minimum, plus four
    /// seconds at the current write rate.
    public static func stopThreshold(minimumFree: Int64, bytesPerSecond: Int64) -> Int64 {
        minimumFree / 2 + 4 * bytesPerSecond
    }

    // MARK: Control

    /// `fileSuffix` (MultiCorder ISO files) goes before the extension; `date` names the file, so
    /// the Program file and its ISO files share one time stamp.
    public func start(settings: RecordingSettings, output: OutputFormat, audio: AudioEncoderSettings,
                      fileSuffix: String? = nil, date: Date = Date()) {
        queue.async { self.startOnQueue(settings: settings, output: output, audio: audio, fileSuffix: fileSuffix, date: date) }
    }

    public func stop() {
        queue.async { self.finish(reason: nil) }
    }

    private func startOnQueue(settings: RecordingSettings, output: OutputFormat, audio: AudioEncoderSettings,
                              fileSuffix: String?, date: Date) {
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
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var fileURL: URL
        var n = 1
        let container = settings.effectiveContainer
        let ext = container.fileExtension
        repeat {
            var name = FileNaming.fileName(pattern: settings.fileNamePattern, year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                                           hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0, counter: n,
                                           ext: ext)
            if let fileSuffix { name = MultiCorderConfig.isoFileName(name, suffix: fileSuffix) }
            fileURL = folder.appendingPathComponent(n == 1 ? name : name.replacingOccurrences(of: ".\(ext)", with: " (\(n)).\(ext)"))
            n += 1
        } while FileManager.default.fileExists(atPath: fileURL.path)

        do {
            let w = try AVAssetWriter(outputURL: fileURL, fileType: container == .mov ? .mov : .mp4)
            if container == .mov { w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600) }
            // Settings the writer refuses would raise an exception in AVAssetWriterInput, so
            // they are checked first and the recording fails with a message instead.
            let videoSettings = Self.videoSettings(settings, output: output)
            guard w.canApply(outputSettings: videoSettings, forMediaType: .video) else {
                throw NSError(domain: "LiveCore", code: 5, userInfo: [NSLocalizedDescriptionKey:
                    "\(settings.videoCodec.label) recording is not supported on this Mac at \(output.size.width)×\(output.size.height)."])
            }
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            v.expectsMediaDataInRealTime = true
            let audioSettings = Self.audioSettings(settings, audio: audio)
            guard w.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw NSError(domain: "LiveCore", code: 6, userInfo: [NSLocalizedDescriptionKey: "Audio format not supported for this file type."])
            }
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            guard w.canAdd(v), w.canAdd(a) else { throw NSError(domain: "LiveCore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Writer rejected inputs"]) }
            w.add(v); w.add(a)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: nil)
            guard w.startWriting() else { throw w.error ?? NSError(domain: "LiveCore", code: 4) }
            writer = w; videoInput = v; audioInput = a; url = fileURL
            fileLock.withLock { lastFile = fileURL }
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

    /// Writer video settings for the chosen codec. H.264 / HEVC: hardware encoder, average
    /// bitrate, keyframe interval in seconds, no B-frames unless asked (less encoder work and
    /// memory per stream, which matters with four MultiCorder files at once).
    static func videoSettings(_ s: RecordingSettings, output: OutputFormat) -> [String: Any] {
        var v: [String: Any] = [AVVideoWidthKey: output.size.width, AVVideoHeightKey: output.size.height]
        switch s.videoCodec {
        case .proRes422Proxy: v[AVVideoCodecKey] = AVVideoCodecType.proRes422Proxy
        case .proRes422LT: v[AVVideoCodecKey] = AVVideoCodecType.proRes422LT
        case .proRes422: v[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .proRes422HQ: v[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        case .h264, .hevc:
            let h264 = s.videoCodec == .h264
            v[AVVideoCodecKey] = h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc
            var c: [String: Any] = [
                AVVideoAverageBitRateKey: s.bitrateKbps * 1000,
                AVVideoMaxKeyFrameIntervalDurationKey: s.keyframeInterval,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int((Double(output.frameRate) * s.keyframeInterval).rounded())),
                AVVideoAllowFrameReorderingKey: s.bFrames,
                AVVideoExpectedSourceFrameRateKey: output.frameRate,
            ]
            if h264 {
                c[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
                c[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            }
            v[AVVideoCompressionPropertiesKey] = c
            v[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
        }
        return v
    }

    static func audioSettings(_ s: RecordingSettings, audio: AudioEncoderSettings) -> [String: Any] {
        if s.usesPCM {
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audio.sampleRate, AVNumberOfChannelsKey: audio.channels,
                    AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false]
        }
        return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audio.sampleRate, AVNumberOfChannelsKey: audio.channels,
                AVEncoderBitRateKey: s.audioKbps * 1000]
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
        var lastFileBytes: Int64 = 0
        t.setEventHandler { [weak self] in
            guard let self, let w = self.writer, let url = self.url else { return }
            if let start = self.sessionStart, self.lastVideoPTS.isValid {
                self.stats.duration = CMTimeGetSeconds(CMTimeSubtract(self.lastVideoPTS, start))
            }
            // Checked every second: at high bitrates (ProRes, or a small drive) a slower check can
            // let the disk fill up between two looks. Keep room for a few seconds of writing plus
            // what the writer still has buffered, so the file is closed before the disk is full.
            self.stats.freeBytes = Self.freeBytes(at: folder)
            self.stats.fileBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            let perSecond = max(0, self.stats.fileBytes - lastFileBytes)
            lastFileBytes = self.stats.fileBytes
            if self.stats.freeBytes < Self.stopThreshold(minimumFree: self.settings.minimumFreeBytes, bytesPerSecond: perSecond) {
                self.finish(reason: "Disk space is running out.")
                return
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

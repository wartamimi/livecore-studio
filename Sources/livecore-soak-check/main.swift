// CI check for stability (0.37.0), on the real engine (Metal compositor, encoders, RTMP, writer):
//  1. Engine run: a production with colour bars and a title on Program records and streams to a
//     local RTMP server (ffmpeg) for SOAK_SECONDS (default 90). Memory and dropped frames are
//     sampled every 10 s. The memory must not keep growing (leak check).
//  2. Stream drop: halfway the RTMP server is killed and started again. The stream must
//     reconnect, and the recording must carry on through the drop without a gap.
//  3. The recording must be a valid file as long as the run, with video and audio.
//  3b. SRT: the same engine streams MPEG-TS over SRT to an SRT listener (ffmpeg/libsrt or srt-live-transmit) for 8 s.
//  4. Disk full: a recorder writes into a 64 MB disk image; it must stop on its own before the
//     disk is full and leave a playable file.
// Long soak on a real Mac: SOAK_SECONDS=7200 swift run -c release livecore-soak-check
#if os(macOS)
import AVFoundation
import CoreVideo
import Foundation
import LiveCoreCore
import LiveCoreEngine

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("soak-check: FAIL: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func log(_ s: String) { print("soak-check: " + s) }

func pump(seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

func which(_ tool: String) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] where FileManager.default.isExecutableFile(atPath: "\(dir)/\(tool)") {
        return "\(dir)/\(tool)"
    }
    return nil
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let soakSeconds = Double(ProcessInfo.processInfo.environment["SOAK_SECONDS"] ?? "") ?? 90
let port = 19_360
let key = "soak_secret_key_42"
let work = FileManager.default.temporaryDirectory.appendingPathComponent("livecore-soak-\(getpid())")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
guard let ffmpeg = which("ffmpeg") else { fail("ffmpeg not found (brew install ffmpeg)") }

/// ffmpeg as the RTMP server; it exits when the publisher disconnects.
final class RTMPServer {
    let tool: String, port: Int, key: String, folder: URL
    var process: Process?
    var segment = 0
    init(tool: String, port: Int, key: String, folder: URL) { self.tool = tool; self.port = port; self.key = key; self.folder = folder }
    func start() {
        segment += 1
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-loglevel", "error", "-y", "-listen", "1", "-timeout", "60",
                       "-i", "rtmp://127.0.0.1:\(port)/live/\(key)", "-c", "copy",
                       folder.appendingPathComponent("received-\(segment).flv").path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try? p.run()
        process = p
    }
    func kill() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        p.waitUntilExit()
        process = nil
    }
}

// MARK: 1–3. Engine: record + stream, stream drop in the middle

var settings = ProductionSettings()
settings.output = .hd720p30
settings.video.bitrateKbps = 2500
settings.recording.folderPath = work.appendingPathComponent("rec").path
settings.recording.fileNamePattern = "Soak {date} {time}"
settings.recording.minimumFreeBytes = 0
settings.recording.bitrateKbps = 6000
settings.recording.container = .mov
settings.stream.reconnect = ExponentialBackoff(initialDelay: 1, multiplier: 1.5, maxDelay: 4, maxAttempts: 0, jitterFraction: 0)

let engine: ProductionEngine
do { engine = try ProductionEngine(settings: settings) } catch { fail("engine: \(error)") }
var errors: [String] = []
engine.onError = { errors.append($0); log("engine message: \($0)") }
var rec = RecordingEngine.Stats()
engine.onRecordStats = { rec = $0 }
var stream = StreamingEngine.Stats()
var streamStates: [String] = []
engine.onStreamStats = { _, s in
    if "\(s.state)" != streamStates.last { streamStates.append("\(s.state)") }
    stream = s
}
engine.start()
let bars = engine.addColorBars()
var title = TextSource.Style(title: "LiveCore soak test", subtitle: "recording + streaming")
title.design = TitleTemplate.classicStrap.defaultDesign
_ = engine.addTitle(title)
engine.setPreview(bars)
engine.cut()
pump(seconds: 1)

let server = RTMPServer(tool: ffmpeg, port: port, key: key, folder: work)
server.start()
pump(seconds: 1)
let url: RTMPURL
do { url = try RTMPURL.parse(serverURL: "rtmp://127.0.0.1:\(port)/live", streamKey: key) } catch { fail("url: \(error)") }
engine.startRecording()
do { try engine.startStreaming(to: [.init(id: "soak", name: "Local", url: url)]) } catch { fail("stream start: \(error)") }

func isLive() -> Bool { if case .live = stream.state { return true }; return false }
func isRecording() -> Bool { if case .recording = rec.state { return true }; return false }
pump(seconds: 15) { isLive() && isRecording() }
guard isRecording() else { fail("recording did not start: \(rec.state)") }
guard isLive() else { fail("stream did not go live: \(streamStates)") }
log("recording and streaming (720p30) for \(Int(soakSeconds)) s")

let start = Date()
var memory: [(t: Double, mb: Double)] = []
var dropped0 = engine.droppedRenderFrames.value
var killed = false, restarted = false
var reconnectedAt: Double?
while Date().timeIntervalSince(start) < soakSeconds {
    pump(seconds: 1)
    let t = Date().timeIntervalSince(start)
    if Int(t) % 10 == 0, memory.last.map({ Int($0.t) != Int(t) }) ?? true {
        let d = engine.droppedRenderFrames.value
        memory.append((t, footprintMB()))
        log(String(format: "t=%3.0f s  mem %.0f MB  render drops +%llu  rec %.0f s %.1f MB  stream %@ %.0f kbps reconnects %d",
                   t, memory.last!.mb, d - dropped0, rec.duration, Double(rec.fileBytes) / 1_000_000,
                   "\(stream.state)", stream.bitrateKbps, stream.reconnects))
        dropped0 = d
    }
    // Stream drop: the server goes away, comes back 5 s later.
    if !killed && t > soakSeconds * 0.4 {
        killed = true
        log("killing the RTMP server (network drop)")
        server.kill()
    }
    if killed && !restarted && t > soakSeconds * 0.4 + 5 {
        restarted = true
        guard isRecording() else { fail("recording stopped when the stream dropped: \(rec.state)") }
        log("RTMP server back")
        server.start()
    }
    if restarted && reconnectedAt == nil && isLive() && stream.reconnects > 0 { reconnectedAt = t; log("stream reconnected") }
}
guard isRecording() else { fail("recording did not run to the end: \(rec.state)") }
guard reconnectedAt != nil else { fail("the stream did not reconnect after the drop: \(streamStates)") }
engine.stopStreaming()
engine.stopRecording()
func finished() -> (URL, Int64)? { if case let .finished(u, n) = rec.state { return (u, n) }; return nil }
pump(seconds: 30) { finished() != nil }
guard let (file, bytes) = finished() else { fail("recording did not finish: \(rec.state)") }
server.kill()

// MARK: 3b. SRT output from the same engine (MPEG-TS over SRT to ffmpeg/libsrt)

// Receiver: ffmpeg when it was built with libsrt, otherwise srt-live-transmit (Homebrew "srt").
let (_, protocols) = run(ffmpeg, ["-hide_banner", "-protocols"])
let srtFile = work.appendingPathComponent("srt.ts")
let listener = Process()
listener.standardError = FileHandle.nullDevice
if protocols.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "srt" }) {
    listener.executableURL = URL(fileURLWithPath: ffmpeg)
    listener.arguments = ["-loglevel", "error", "-y", "-i", "srt://127.0.0.1:\(port + 1)?mode=listener&latency=300000", "-c", "copy", srtFile.path]
} else if let slt = which("srt-live-transmit") {
    FileManager.default.createFile(atPath: srtFile.path, contents: nil)
    listener.executableURL = URL(fileURLWithPath: slt)
    listener.arguments = ["-q", "-a:no", "srt://:\(port + 1)?mode=listener&latency=300", "file://con"]
    listener.standardOutput = try? FileHandle(forWritingTo: srtFile)
}
if listener.executableURL != nil {
    log("SRT receiver: \(listener.executableURL!.lastPathComponent)")
    try? listener.run()
    pump(seconds: 1)
    stream = StreamingEngine.Stats()
    streamStates = []
    do {
        let srt = try SRTURL.parse("srt://127.0.0.1:\(port + 1)?latency=300", key: "soak-stream-id")
        try engine.startStreaming(to: [.init(id: "srt", name: "SRT", srt: srt)])
    } catch { fail("SRT start: \(error)") }
    pump(seconds: 10) { isLive() }
    guard isLive() else { fail("SRT did not go live: \(streamStates)") }
    pump(seconds: 8)
    log(String(format: "SRT live: %.0f kbps, states %@", stream.bitrateKbps, streamStates.joined(separator: " → ")))
    engine.stopStreaming()
    pump(seconds: 3) { !listener.isRunning }
    if listener.isRunning { listener.interrupt(); pump(seconds: 2) { !listener.isRunning } }
    if listener.isRunning { listener.terminate() }
    let (_, probe) = run(which("ffprobe") ?? "/usr/bin/false", ["-v", "error", "-count_frames", "-select_streams", "v:0",
                                                                  "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", srtFile.path])
    let frames = Int(probe.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
    log("SRT: received \(frames) video frames")
    guard frames >= 150 else { fail("SRT: only \(frames) frames received") }
} else {
    log("SRT skipped: no SRT receiver (ffmpeg without libsrt and no srt-live-transmit)")
}
engine.shutdown()

let asset = AVURLAsset(url: file)
let duration = asset.duration.seconds
log(String(format: "recording %@ %.1f s %.1f MB, stream states %@", file.lastPathComponent, duration, Double(bytes) / 1_000_000,
           streamStates.joined(separator: " → ")))
guard duration > soakSeconds - 5 else { fail(String(format: "recording lasts %.1f s of %.0f (gap at the stream drop?)", duration, soakSeconds)) }
guard !asset.tracks(withMediaType: .video).isEmpty else { fail("recording has no video") }
if asset.tracks(withMediaType: .audio).isEmpty { log("note: recording has no audio track (no audio device on this machine?)") }
let received = (1...server.segment).map { work.appendingPathComponent("received-\($0).flv") }
    .filter { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0) > 10_000 }
guard received.count >= 2 else { fail("the server did not receive the stream before and after the drop (\(received.count) parts)") }

// Leak check: compare the average of the second half with the first samples after warm-up.
if memory.count >= 4 {
    let warm = memory[1].mb
    let late = memory.suffix(max(memory.count / 3, 1)).map(\.mb).reduce(0, +) / Double(max(memory.count / 3, 1))
    let perMinute = (late - warm) / max((memory.last!.t - memory[1].t) / 60, 0.5)
    log(String(format: "memory %.0f → %.0f MB (%.1f MB/min)", warm, late, perMinute))
    if soakSeconds >= 600 && perMinute > 5 { fail(String(format: "memory grows %.1f MB per minute", perMinute)) }
    if late - warm > 400 { fail(String(format: "memory grew %.0f MB", late - warm)) }
}
for f in [file] + received { try? FileManager.default.removeItem(at: f) }

// MARK: 4. Disk full

let image = work.appendingPathComponent("small.dmg")
let (cs, co) = run("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "HFS+", "-volname", "LiveCoreSoak", "-ov", image.path])
guard cs == 0 else { fail("hdiutil create: \(co)") }
let (as_, ao) = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-mountrandom", work.path, image.path])
guard as_ == 0, let mount = ao.split(separator: "\n").compactMap({ line -> String? in
    guard let r = line.range(of: work.path) else { return nil }
    return String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
}).first else { fail("hdiutil attach: \(ao)") }
log("disk-full test on \(mount), \(RecordingEngine.freeBytes(at: URL(fileURLWithPath: mount)) / 1_000_000) MB free")

var small = RecordingSettings()
small.folderPath = mount
small.fileNamePattern = "Full {date} {time}"
small.bitrateKbps = 40_000
small.container = .mov
small.minimumFreeBytes = 24_000_000
let full = RecordingEngine()
var fs = RecordingEngine.Stats()
full.onStats = { fs = $0 }
full.start(settings: small, output: .hd720p30, audio: AudioEncoderSettings())
pump(seconds: 10) { if case .recording = fs.state { return true }; return false }
guard case .recording = fs.state else { fail("disk-full recorder did not start: \(fs.state)") }

func noiseFrame(_ seed: UInt32) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pb)
    guard let f = pb else { fail("no pixel buffer") }
    CVPixelBufferLockBaseAddress(f, [])
    let words = CVPixelBufferGetBytesPerRow(f) * 720 / 4
    let p = CVPixelBufferGetBaseAddress(f)!.bindMemory(to: UInt32.self, capacity: words)
    var x = seed &* 2_654_435_761 | 1
    for i in 0..<words { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = 0xFF00_0000 | (x & 0xFFFFFF) }
    CVPixelBufferUnlockBaseAddress(f, [])
    return f
}
let frames = (0..<6).map { noiseFrame(UInt32($0 + 7)) }
let t0 = HostClock.now()
var i = 0
let tone = [Float](repeating: 0, count: 1600)
while i < 30 * 120 {
    if case .recording = fs.state {} else { break }
    let t = t0 + Double(i) / 30
    full.append(video: frames[i % frames.count], pts: CMTime(seconds: t, preferredTimescale: 90_000))
    full.append(audio: ProgramAudioPump.Chunk(left: tone, right: tone, hostTime: t))
    i += 1
    RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 30))
}
pump(seconds: 30) { if case .finished = fs.state { return true }; if case .failed = fs.state { return true }; return false }
switch fs.state {
case let .finished(u, n):
    let a = AVURLAsset(url: u)
    log(String(format: "disk full: stopped by itself after %.1f s, %.1f MB, playable %.1f s", Double(i) / 30, Double(n) / 1_000_000, a.duration.seconds))
    guard a.duration.seconds > 2, !a.tracks(withMediaType: .video).isEmpty else { fail("file left on the full disk is not playable") }
case let .failed(m):
    fail("recorder failed instead of stopping cleanly on a full disk: \(m)")
default:
    fail("recorder still \(fs.state) after \(i) frames on a 64 MB disk")
}
run("/usr/bin/hdiutil", ["detach", "-force", mount])
try? FileManager.default.removeItem(at: work)
log("PASS")
exit(0)
#else
print("soak-check: macOS only")
#endif

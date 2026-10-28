// CI check for MultiCorder (ISO recording):
//  1. A Program recorder and an ISO recorder start with one time stamp, receive 3 seconds of
//     720p30 video (different pictures) and audio at the same time, stop, and both files must
//     exist with the ISO name and play back with video and audio.
//  2. Load test (0.33.0): Program + 4 ISO recorders at 1080p30 for 5 seconds of changing,
//     hard-to-compress pictures in real time, for H.264, HEVC and ProRes 422. Every file must be
//     valid; dropped frames are printed per file. Drops are reported, not failed on: the CI
//     virtual Mac has no media engine, so the numbers only matter on real hardware.
//   swift run livecore-iso-check
#if os(macOS)
import AVFoundation
import CoreVideo
import Foundation
import LiveCoreCore
import LiveCoreEngine

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("iso-check: FAIL: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func frame(_ argb: UInt32) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    guard let f = pb else { fail("no pixel buffer") }
    CVPixelBufferLockBaseAddress(f, [])
    let words = CVPixelBufferGetBytesPerRow(f) * 720 / 4
    let p = CVPixelBufferGetBaseAddress(f)!.bindMemory(to: UInt32.self, capacity: words)
    for i in 0..<words { p[i] = argb }
    CVPixelBufferUnlockBaseAddress(f, [])
    return f
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("livecore-iso-check-\(getpid())")
try? FileManager.default.removeItem(at: folder)
var rs = RecordingSettings()
rs.folderPath = folder.path
rs.fileNamePattern = "Check {date} {time}"
rs.minimumFreeBytes = 0
rs.bitrateKbps = 4000
let output = OutputFormat.hd720p30
let audio = AudioEncoderSettings()

let program = RecordingEngine(), iso = RecordingEngine()
var states: [String: RecordingEngine.State] = [:]
program.onStats = { states["program"] = $0.state }
iso.onStats = { states["iso"] = $0.state }
let date = Date()
program.start(settings: rs, output: output, audio: audio, date: date)
iso.start(settings: rs, output: output, audio: audio, fileSuffix: MultiCorderConfig.fileSuffix(number: 2, name: "Cam: Wide"), date: date)

func pump(until deadline: Date, _ done: () -> Bool) {
    while Date() < deadline, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}
func isRecording(_ k: String) -> Bool { if case .recording? = states[k] { return true }; return false }
pump(until: Date().addingTimeInterval(10)) { isRecording("program") && isRecording("iso") }
guard isRecording("program"), isRecording("iso") else { fail("recorders did not start: \(states)") }

let red = frame(0xFFFF_0000), blue = frame(0xFF00_00FF)
let t0 = HostClock.now()
let tone = (0..<1600).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000) * 0.25) }
for i in 0..<90 {
    let t = t0 + Double(i) / 30
    let pts = CMTime(seconds: t, preferredTimescale: 90_000)
    program.append(video: red, pts: pts)
    iso.append(video: blue, pts: pts)
    let chunk = ProgramAudioPump.Chunk(left: tone, right: tone, hostTime: t)
    program.append(audio: chunk)
    iso.append(audio: chunk)
    RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
}
program.stop(); iso.stop()
func finishedURL(_ k: String) -> URL? { if case let .finished(u, _)? = states[k] { return u }; return nil }
pump(until: Date().addingTimeInterval(20)) { finishedURL("program") != nil && finishedURL("iso") != nil }
guard let pURL = finishedURL("program"), let iURL = finishedURL("iso") else { fail("recorders did not finish: \(states)") }

let expected = MultiCorderConfig.isoFileName(pURL.lastPathComponent, suffix: " - ISO 2 Cam- Wide")
guard iURL.lastPathComponent == expected else { fail("ISO file name \(iURL.lastPathComponent), expected \(expected)") }
for url in [pURL, iURL] {
    let asset = AVURLAsset(url: url)
    let d = asset.duration.seconds
    guard d > 2.5 else { fail("\(url.lastPathComponent) lasts \(d) s") }
    guard !asset.tracks(withMediaType: .video).isEmpty, !asset.tracks(withMediaType: .audio).isEmpty else {
        fail("\(url.lastPathComponent) misses a video or audio track")
    }
    print("iso-check: \(url.lastPathComponent) \(String(format: "%.2f", d)) s video+audio")
}
try? FileManager.default.removeItem(at: folder)

// MARK: - Load test: Program + 4 ISO at 1080p30

/// 1080p frame with a moving gradient plus noise, so the encoder has real work to do.
func busyFrame(seed: UInt32) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    guard let f = pb else { fail("no pixel buffer") }
    CVPixelBufferLockBaseAddress(f, [])
    let row = CVPixelBufferGetBytesPerRow(f) / 4
    let p = CVPixelBufferGetBaseAddress(f)!.bindMemory(to: UInt32.self, capacity: row * 1080)
    var x = seed &* 2_654_435_761 | 1
    for yy in 0..<1080 {
        for xx in 0..<1920 {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            let g = UInt32((xx + yy + Int(seed) * 37) & 0xFF)
            p[yy * row + xx] = 0xFF00_0000 | (g << 16) | ((x & 0x3F) << 8) | ((255 - g) & 0xFF)
        }
    }
    CVPixelBufferUnlockBaseAddress(f, [])
    return f
}

let pool = (0..<8).map { busyFrame(seed: UInt32($0 + 1)) }
let hd = OutputFormat.hd1080p30
var loadFailures: [String] = []

for codec in [RecordingCodec.h264, .hevc, .proRes422] {
    var ls = rs
    ls.codec = codec
    ls.bitrateKbps = codec == .hevc ? 25_000 : 20_000
    ls.container = .mov
    let recs = (0..<5).map { _ in RecordingEngine() }
    var st = [RecordingEngine.Stats](repeating: RecordingEngine.Stats(), count: 5)
    for (k, r) in recs.enumerated() { r.onStats = { st[k] = $0 } }
    let d0 = Date()
    for (k, r) in recs.enumerated() {
        r.start(settings: ls, output: hd, audio: audio, fileSuffix: k == 0 ? nil : MultiCorderConfig.fileSuffix(number: k, name: "Load"), date: d0)
    }
    func started(_ s: RecordingEngine.State) -> Bool { if case .recording = s { return true }; return false }
    func failed(_ s: RecordingEngine.State) -> String? { if case let .failed(m) = s { return m }; return nil }
    pump(until: Date().addingTimeInterval(10)) { st.allSatisfy { started($0.state) || failed($0.state) != nil } }
    if let m = st.lazy.compactMap({ failed($0.state) }).first {
        print("iso-load: \(codec.label) skipped: \(m)")
        recs.forEach { $0.stop() }
        continue
    }
    guard st.allSatisfy({ started($0.state) }) else { loadFailures.append("\(codec.label): recorders did not start"); continue }

    let lt0 = HostClock.now(), wall0 = Date()
    for i in 0..<150 {
        let t = lt0 + Double(i) / 30
        let pts = CMTime(seconds: t, preferredTimescale: 90_000)
        let chunk = ProgramAudioPump.Chunk(left: tone, right: tone, hostTime: t)
        for (k, r) in recs.enumerated() {
            r.append(video: pool[(i + k * 3) % pool.count], pts: pts)
            r.append(audio: chunk)
        }
        RunLoop.main.run(until: wall0.addingTimeInterval(Double(i + 1) / 30))
    }
    let late = Date().timeIntervalSince(wall0) - 5
    recs.forEach { $0.stop() }
    func finished(_ s: RecordingEngine.State) -> (URL, Int64)? { if case let .finished(u, n) = s { return (u, n) }; return nil }
    pump(until: Date().addingTimeInterval(60)) { st.allSatisfy { finished($0.state) != nil || failed($0.state) != nil } }
    var line: [String] = []
    for (k, s) in st.enumerated() {
        let name = k == 0 ? "Program" : "ISO \(k)"
        guard let (url, bytes) = finished(s.state) else { loadFailures.append("\(codec.label) \(name): \(s.state)"); continue }
        let asset = AVURLAsset(url: url)
        let d = asset.duration.seconds
        if d < 4.5 || asset.tracks(withMediaType: .video).isEmpty { loadFailures.append("\(codec.label) \(name): \(String(format: "%.2f", d)) s") }
        line.append("\(name) \(s.droppedVideoFrames) drop \(String(format: "%.1f", Double(bytes) / 1_000_000)) MB")
    }
    print("iso-load: \(codec.label) 1080p30 ×5, feed late \(String(format: "%.2f", max(late, 0))) s: " + line.joined(separator: ", "))
}
try? FileManager.default.removeItem(at: folder)
guard loadFailures.isEmpty else { fail("load test: " + loadFailures.joined(separator: "; ")) }
print("iso-check: PASS")
#else
print("iso-check: macOS only")
#endif

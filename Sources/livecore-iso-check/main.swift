// CI check for MultiCorder (ISO recording): a Program recorder and an ISO recorder start with
// one time stamp, receive 3 seconds of 720p30 video (different pictures) and audio at the same
// time, stop, and both files must exist with the ISO name and play back with video and audio.
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
print("iso-check: PASS")
#else
print("iso-check: macOS only")
#endif

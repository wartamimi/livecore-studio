// CI check for instant replay (0.55.2):
//  1. The replay buffer receives 8 seconds of 1080p30 Program video in real time (a picture that
//     changes every second) and must report several seconds available.
//  2. A 5-second replay is cut, loaded into the Replay input, and that input must become live
//     and deliver a picture, then play forward at 50 %.
//   swift run livecore-replay-check
#if os(macOS)
import AVFoundation
import CoreVideo
import Foundation
import LiveCoreCore
import LiveCoreEngine

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("replay-check: FAIL: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}
func log(_ msg: String) { print("replay-check: " + msg) }

let output = OutputFormat.hd1080p30
func frame(_ argb: UInt32) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                kCVPixelBufferMetalCompatibilityKey as String: true]
    CVPixelBufferCreate(kCFAllocatorDefault, output.size.width, output.size.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    guard let f = pb else { fail("no pixel buffer") }
    CVPixelBufferLockBaseAddress(f, [])
    let words = CVPixelBufferGetBytesPerRow(f) * output.size.height / 4
    let p = CVPixelBufferGetBaseAddress(f)!.bindMemory(to: UInt32.self, capacity: words)
    for i in 0..<words { p[i] = argb }
    CVPixelBufferUnlockBaseAddress(f, [])
    return f
}
func pump(_ seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

let colors: [UInt32] = [0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF, 0xFFFF_FF00]
let frames = colors.map(frame)
let rec = ReplayRecorder()
var available = 0.0
rec.onAvailableChange = { available = $0 }
rec.onError = { log("recorder error: \($0)") }
rec.start(output: output)

let t0 = HostClock.now()
var n = 0
while HostClock.now() - t0 < 8 {
    let t = t0 + Double(n) / 30
    if HostClock.now() >= t {
        rec.append(frames[(n / 30) % frames.count], hostTime: t)
        n += 1
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.003))
}
pump(3) { available >= 5 }
log("frames sent \(n), buffered \(String(format: "%.1f", available)) s")
guard available >= 5 else { fail("only \(available) s buffered after 8 s of Program") }

var clip: ReplayRecorder.Clip?
var answered = false
rec.clip(lastSeconds: 5) { clip = $0; answered = true }
pump(10) { answered }
guard let clip else { fail(answered ? "replay of the last 5 s returned no clip" : "replay clip timed out") }
log("clip duration \(String(format: "%.2f", clip.asset.duration.seconds)) s, start \(String(format: "%.2f", clip.start.seconds)) s")
guard clip.asset.duration.seconds >= 4.5 else { fail("clip too short") }

let src = ReplaySource(id: InputID("replay"))
src.speed = 0.5
src.load(clip)
pump(10) { src.status == .live && src.currentFrame() != nil }
guard src.status == .live else { fail("Replay input status after load: \(src.status)") }
guard src.currentFrame() != nil else { fail("Replay input is live but delivers no picture") }
log("loaded, first frame OK (length \(String(format: "%.1f", src.clipLength)) s)")
src.play()
pump(2)
guard src.isPlaying, src.position > 0.5 else { fail("replay did not play forward (position \(src.position))") }
log("playing at 50 %: position \(String(format: "%.2f", src.position)) s after 2 s")
rec.stop()
pump(1)
log("OK")
exit(0)
#else
print("replay-check: macOS only")
#endif

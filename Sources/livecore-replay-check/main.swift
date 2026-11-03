// CI check for instant replay (0.55.2):
//  1. The replay buffer receives 8 seconds of 1080p30 Program video in real time (a picture that
//     changes every second) and must report several seconds available.
//  2. A 5-second replay is cut, loaded into the Replay input, and that input must become live
//     and deliver a picture, then play forward at 50 %.
//  3. (0.58.0) A QR card reads back, and a highlight video is cut from a test recording.
//   swift run livecore-replay-check
#if os(macOS)
import AVFoundation
import CoreVideo
import CoreImage
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
// 0.58.0: QR code input — the drawn card must read back as the same text (all module shapes).
for shape in QRModuleShape.allCases {
    var d = QRDesign(items: [QRItem(name: "check", kind: .url, text: "livecore.studio/qr-check", title: "Scan", caption: "QR check")])
    d.style.moduleShape = shape
    d.style.anchor = .center
    guard let img = QRRenderer.image(d, width: 1920, height: 1080) else { fail("QR image not drawn (\(shape))") }
    let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let text = det?.features(in: CIImage(cgImage: img)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    guard text == "https://livecore.studio/qr-check" else { fail("QR (\(shape)) reads back as \(text ?? "nothing")") }
}
log("QR card reads back for square, rounded and dots")

// 0.58.0: highlight video — two moments of a 20 s recording, 2 s before and after, 0.5 s crossfade.
func smallFrame(_ argb: UInt32) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pb)
    guard let f = pb else { fail("no small pixel buffer") }
    CVPixelBufferLockBaseAddress(f, [])
    let words = CVPixelBufferGetBytesPerRow(f) * 360 / 4
    let p = CVPixelBufferGetBaseAddress(f)!.bindMemory(to: UInt32.self, capacity: words)
    for i in 0..<words { p[i] = argb }
    CVPixelBufferUnlockBaseAddress(f, [])
    return f
}
let movie = FileManager.default.temporaryDirectory.appendingPathComponent("lc-highlight-src.mov")
try? FileManager.default.removeItem(at: movie)
guard let writer = try? AVAssetWriter(outputURL: movie, fileType: .mov) else { fail("cannot make test movie") }
let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: nil)
writer.add(vin)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let small = colors.map(smallFrame)
for i in 0..<200 {
    while !vin.isReadyForMoreMediaData { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    adaptor.append(small[(i / 10) % small.count], withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
}
vin.markAsFinished()
var written = false
writer.finishWriting { written = true }
pump(20) { written }
guard writer.status == .completed else { fail("test movie not written: \(String(describing: writer.error))") }
var hs = HighlightSettings()
hs.preRoll = 2; hs.postRoll = 2; hs.crossfade = 0.5
let reelMarks = [HighlightMark(offset: 5), HighlightMark(offset: 15)]
for format in HighlightFormat.allCases {
    hs.format = format
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("lc-highlight-\(format.rawValue).mp4")
    final class Box: @unchecked Sendable { var result: Result<Double, Error>? }
    let box = Box(), settings = hs
    Task { do { box.result = .success(try await HighlightReel.build(recording: movie, marks: reelMarks, settings: settings, to: out)) } catch { box.result = .failure(error) } }
    pump(90) { box.result != nil }
    switch box.result {
    case nil: fail("highlight video (\(format)) timed out")
    case let .failure(e)?: fail("highlight video (\(format)): \(e.localizedDescription)")
    case .success?: break
    }
    let made = AVURLAsset(url: out)
    let len = made.duration.seconds
    let size = made.tracks(withMediaType: .video).first?.naturalSize ?? .zero
    log("highlight \(format): \(String(format: "%.2f", len)) s, \(Int(size.width))x\(Int(size.height))")
    guard abs(len - 7.5) < 0.3 else { fail("highlight video length \(len) s, expected 7.5 s") }
    guard format == .landscape ? size.width > size.height : size.height > size.width else { fail("highlight video size \(size)") }
}
log("OK")
exit(0)
#else
print("replay-check: macOS only")
#endif

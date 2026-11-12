// CI check for the NDI outputs: a child process runs LiveCore's NDISender ("LiveCore Output 1
// (check)") sending a red 1280×720 picture and Program-like audio; this process must find the
// source on the network (as NDI Virtual Camera, OBS or vMix do), connect, and receive a red frame.
//   swift run livecore-ndi-check
// Needs the NDI runtime (NDI Tools or http://ndi.link/NDIRedistV6Apple). Without it the check is
// skipped, unless LIVECORE_NDI_REQUIRED=1 (CI) makes that a failure.
#if os(macOS)
import CNDI
import CoreVideo
import Foundation
import LiveCoreCore
import LiveCoreEngine

let sourceName = "LiveCore Output 1 (check)"

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("ndi-check: FAIL: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

guard NDIRuntime.isAvailable else {
    if ProcessInfo.processInfo.environment["LIVECORE_NDI_REQUIRED"] == "1" { fail("NDI runtime not found") }
    print("ndi-check: SKIP: NDI runtime not installed (\(NDIRuntime.downloadURL))")
    exit(0)
}

func serve() -> Never {
    guard let sender = NDISender(name: sourceName, frameRate: 30) else { fail("sender could not be created") }
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    guard let frame = pb else { fail("no pixel buffer") }
    CVPixelBufferLockBaseAddress(frame, [])
    let base = CVPixelBufferGetBaseAddress(frame)!
    let words = CVPixelBufferGetBytesPerRow(frame) * 720 / 4
    let p = base.bindMemory(to: UInt32.self, capacity: words)
    for i in 0..<words { p[i] = 0xFFFF_0000 }   // BGRA little-endian: B=0 G=0 R=255 A=255
    CVPixelBufferUnlockBaseAddress(frame, [])
    let tone = (0..<1600).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000) * 0.25) }
    let end = Date().addingTimeInterval(40)
    while Date() < end {
        sender.send(frame)
        sender.send(left: tone, right: tone, sampleRate: 48000)
        Thread.sleep(forTimeInterval: 1.0 / 30)
    }
    print("ndi-check(serve): receivers at end \(sender.connections), dropped \(sender.droppedFrames.value)")
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "serve" { serve() }

print("ndi-check: runtime \(NDIRuntime.version ?? "?") at \(NDIRuntime.libraryPath ?? "?")")
let child = Process()
child.executableURL = Bundle.main.executableURL
child.arguments = ["serve"]
do { try child.run() } catch { fail("cannot start sender process: \(error)") }
defer { if child.isRunning { child.terminate() } }

var found: String?
var seen: [String] = []
let deadline = Date().addingTimeInterval(20)
while found == nil && Date() < deadline {
    var buf = [CChar](repeating: 0, count: 8192)
    _ = lc_ndi_find_sources(&buf, Int32(buf.count), 1000)
    seen = String(cString: buf).split(separator: "\n").map(String.init)
    found = seen.first { $0.hasSuffix("(\(sourceName))") }
}
print("ndi-check: sources seen: \(seen)")
guard let full = found else { child.terminate(); fail("source \"\(sourceName)\" was never announced") }

guard let receiver = lc_ndi_receiver_create(full) else { child.terminate(); fail("receiver could not be created") }
var width: Int32 = 0, height: Int32 = 0
var fourcc: UInt32 = 0, pixel: UInt32 = 0
var got = false
let frameDeadline = Date().addingTimeInterval(15)
while !got && Date() < frameDeadline {
    got = lc_ndi_receive_video(receiver, 500, &width, &height, &fourcc, &pixel)
}
lc_ndi_receiver_destroy(receiver)
guard got else { child.terminate(); fail("connected to \"\(full)\" but no video frame arrived") }
let cc = String(bytes: withUnsafeBytes(of: fourcc.littleEndian) { Array($0) }, encoding: .ascii) ?? "?"
print("ndi-check: frame \(width)x\(height) FourCC \(cc) centre 0x\(String(pixel, radix: 16))")
guard width == 1280, height == 720 else { fail("wrong size") }
// NDI compresses the picture, so allow a little colour error around pure red.
let r = Int((pixel >> 16) & 0xFF), g = Int((pixel >> 8) & 0xFF), b = Int(pixel & 0xFF)
guard r > 230, g < 25, b < 25 else { child.terminate(); fail("centre pixel is not red") }

// 0.29.0 NDI inputs: LiveCore's own finder lists the source and an NDISource input receives it
// into a BGRA pixel buffer, as an NDI input in the app does.
var finderList: [String] = []
let finder = NDIFinder()
finder.start { finderList = $0 }
let input = NDISource(id: InputID("ndi-check-input"), config: ProjectNDI(sourceName: full, audio: false))
input.start()
var inputFrame: CVPixelBuffer?
let inputDeadline = Date().addingTimeInterval(15)
while (inputFrame == nil || !finderList.contains(full)) && Date() < inputDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    inputFrame = input.currentFrame()
}
input.stop()
finder.stop()
child.terminate()
guard finderList.contains(full) else { fail("NDIFinder did not list \"\(full)\" (saw \(finderList))") }
guard let pb = inputFrame else { fail("NDISource input received no frame (status: \(input.status.label))") }
CVPixelBufferLockBaseAddress(pb, .readOnly)
let iw = CVPixelBufferGetWidth(pb), ih = CVPixelBufferGetHeight(pb)
let ip = CVPixelBufferGetBaseAddress(pb)!.advanced(by: (ih / 2) * CVPixelBufferGetBytesPerRow(pb) + (iw / 2) * 4)
    .assumingMemoryBound(to: UInt8.self)
let (ib, ig, ir, ia) = (Int(ip[0]), Int(ip[1]), Int(ip[2]), Int(ip[3]))
CVPixelBufferUnlockBaseAddress(pb, .readOnly)
print("ndi-check: input frame \(iw)x\(ih) BGRA centre \(ib),\(ig),\(ir),\(ia) format \(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA ? "BGRA" : "?")")
guard iw == 1280, ih == 720, ir > 230, ig < 25, ib < 25, ia == 255 else { fail("NDI input frame is wrong") }
print("ndi-check: PASS")
#else
print("livecore-ndi-check runs on macOS only")
#endif

// CI check for the Syphon outputs: a child process runs a LiveCore Syphon server that publishes a
// red picture; this process must discover it (as OBS's "Syphon Client" does), connect, and read a
// red 1280×720 BGRA frame from the shared IOSurface.
//   swift run livecore-syphon-check
#if os(macOS)
import CoreVideo
import CSyphon
import Foundation
import Metal

let serverName = "Output 1 (check)"

func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("syphon-check: FAIL: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func serve() -> Never {
    guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
    guard let server = LCSyphonServer(name: serverName, device: device) else { fail("server could not start") }
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                kCVPixelBufferMetalCompatibilityKey as String: true]
    CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    guard let frame = pb else { fail("no pixel buffer") }
    CVPixelBufferLockBaseAddress(frame, [])
    let base = CVPixelBufferGetBaseAddress(frame)!
    let words = CVPixelBufferGetBytesPerRow(frame) * 720 / 4
    let p = base.bindMemory(to: UInt32.self, capacity: words)
    for i in 0..<words { p[i] = 0xFFFF_0000 }   // BGRA little-endian: B=0 G=0 R=255 A=255
    CVPixelBufferUnlockBaseAddress(frame, [])
    let end = Date().addingTimeInterval(30)
    while Date() < end {
        server.publishPixelBuffer(frame)
        spin(1.0 / 30)
    }
    server.stop()
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "serve" { serve() }

let child = Process()
child.executableURL = Bundle.main.executableURL
child.arguments = ["serve"]
do { try child.run() } catch { fail("cannot start server process: \(error)") }
defer { if child.isRunning { child.terminate() } }

var probe: LCSyphonProbe?
let deadline = Date().addingTimeInterval(15)
while probe == nil && Date() < deadline {
    spin(0.2)
    probe = LCSyphonProbe(serverNamed: serverName)
}
print("syphon-check: servers seen: \(LCSyphonProbe.serverTitles())")
guard let client = probe else { child.terminate(); fail("server \"\(serverName)\" was never announced") }

var width = 0, height = 0
var format: OSType = 0
var pixel: UInt32 = 0
var read = false
let frameDeadline = Date().addingTimeInterval(10)
while !read && Date() < frameDeadline {
    spin(0.1)
    if client.hasNewFrame {
        read = client.readFrameWidth(&width, height: &height, pixelFormat: &format, centerBGRA: &pixel)
    }
}
client.stop()
child.terminate()
guard read else { fail("connected but no frame arrived (valid: \(client.isValid))") }
print("syphon-check: frame \(width)x\(height) format 0x\(String(format, radix: 16)) centre 0x\(String(pixel, radix: 16))")
guard width == 1280, height == 720 else { fail("wrong size") }
guard format == kCVPixelFormatType_32BGRA else { fail("IOSurface pixel format is not 32BGRA (OBS 32 rejects format 0)") }
guard pixel == 0xFFFF_0000 else { fail("centre pixel is not red") }
print("syphon-check: PASS")
#else
print("livecore-syphon-check runs on macOS only")
#endif

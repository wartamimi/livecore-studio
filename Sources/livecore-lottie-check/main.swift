// Renders a small Lottie animation through LottieSource (the same code path as the app) and checks
// the pixels: content visible, right way up, and animated. Run on macOS CI:
//   swift run livecore-lottie-check
#if os(macOS)
import CoreVideo
import Foundation
import LiveCoreCore
import LiveCoreEngine

// 200x100 composition, 2 s at 30 fps. Red box fills the top-left quadrant for the whole animation;
// a blue box fills the bottom-right quadrant from frame 30 (1 s) on.
func shapeLayer(_ index: Int, _ name: String, color: [Double], center: [Double], inPoint: Int) -> String {
    let static0 = #"{"a":0,"k":0}"#, static100 = #"{"a":0,"k":100}"#
    return """
    {"ddd":0,"ind":\(index),"ty":4,"nm":"\(name)","sr":1,"ao":0,"bm":0,"ip":\(inPoint),"op":60,"st":0,
     "ks":{"o":\(static100),"r":\(static0),"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
     "shapes":[{"ty":"gr","nm":"g","it":[
       {"ty":"rc","nm":"r","d":1,"s":{"a":0,"k":[100,50]},"p":{"a":0,"k":[\(center[0]),\(center[1])]},"r":\(static0)},
       {"ty":"fl","nm":"f","c":{"a":0,"k":[\(color[0]),\(color[1]),\(color[2]),1]},"o":\(static100),"r":1},
       {"ty":"tr","nm":"t","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":\(static0),"o":\(static100),"sk":\(static0),"sa":\(static0)}
     ]}]}
    """
}
let json = """
{"v":"5.7.4","fr":30,"ip":0,"op":60,"w":200,"h":100,"nm":"check","ddd":0,"assets":[],"layers":[
\(shapeLayer(1, "blue", color: [0, 0, 1], center: [150, 75], inPoint: 30)),
\(shapeLayer(2, "red", color: [1, 0, 0], center: [50, 25], inPoint: 0))
]}
"""

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures += 1 }
}

/// (r, g, b, a) at a pixel; row 0 is the top of the picture, as for every video frame.
func pixel(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return (Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3]))   // BGRA
}

func describe(_ pb: CVPixelBuffer) -> String {
    [("TL", 50, 25), ("TR", 150, 25), ("BL", 50, 75), ("BR", 150, 75)]
        .map { "\($0.0)=\(pixel(pb, $0.1, $0.2))" }.joined(separator: " ")
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("livecore-lottie-check-\(getpid())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let url = dir.appendingPathComponent("check.json")
try json.write(to: url, atomically: true, encoding: .utf8)

let source = LottieSource(id: InputID("lottie-check"), url: url)
check(source.status == .live, "loads (status \(source.status))")
check(abs(source.duration - 2) < 0.01, "duration 2 s (got \(source.duration))")
if let pb = source.currentFrame() {
    check(CVPixelBufferGetWidth(pb) == 200 && CVPixelBufferGetHeight(pb) == 100, "frame size 200x100")
    print("t=0   " + describe(pb))
    let tl = pixel(pb, 50, 25), br = pixel(pb, 150, 75), tr = pixel(pb, 150, 25), bl = pixel(pb, 50, 75)
    check(tl.0 > 200 && tl.3 > 200 && tl.2 < 50, "red box visible in the top-left quadrant")
    check(br.3 < 20 && tr.3 < 20 && bl.3 < 20, "rest transparent at t=0 (blue box not yet in)")
} else {
    check(false, "first frame rendered")
}
source.seek(to: 1.5)
if let pb = source.currentFrame() {
    print("t=1.5 " + describe(pb))
    let br = pixel(pb, 150, 75), tl = pixel(pb, 50, 25)
    check(br.2 > 200 && br.3 > 200 && br.0 < 50, "blue box visible in the bottom-right quadrant at t=1.5 s")
    check(tl.0 > 200 && tl.3 > 200, "red box still visible at t=1.5 s")
}
try? FileManager.default.removeItem(at: dir)
if failures > 0 { print("Lottie render check: \(failures) failure(s)"); exit(1) }
print("Lottie render check: OK")
#else
print("livecore-lottie-check runs on macOS only.")
#endif

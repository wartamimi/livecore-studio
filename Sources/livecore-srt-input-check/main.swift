// CI/dev check for the SRT input (0.54.0): receives an SRT stream through LiveCore's own
// SRTInputLink (listener or caller), demuxes the MPEG-TS and reports what arrived.
//   livecore-srt-input-check listen <port> <seconds> [latencyMs]
//   livecore-srt-input-check call <host> <port> <seconds> [latencyMs]
//   livecore-srt-input-check engine            (macOS: ffmpeg → SRTSource, H.264 then HEVC, decoded)
// Exit 0 when H.264/HEVC keyframes with parameter sets and AAC frames were received in order.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if os(macOS)
import CoreVideo
#endif
import LiveCoreCore
#if os(macOS)
import LiveCoreEngine
#endif

let args = CommandLine.arguments
func fail(_ s: String) -> Never { print("FAIL: \(s)"); exit(1) }

#if os(macOS)
/// The app's SRT input end to end: ffmpeg (libsrt) calls an SRTSource listener; the source must
/// decode video (VideoToolbox) and AAC audio and show frames at about the sent rate.
func ffmpegHasSRT(_ ffmpeg: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ffmpeg)
    p.arguments = ["-hide_banner", "-protocols"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return out.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "srt" }
}

func engineCheck() -> Never {
    let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let ffmpeg else { fail("ffmpeg not found") }
    for (i, codec) in ["libx264", "libx265"].enumerated() {
        let port = 9310 + i
        let src = SRTSource(id: InputID("srt-check-\(i)"), config: ProjectSRTInput(mode: .listener, port: port, latencyMs: 200))
        src.audioChannelProvider = { MixerChannel.detached() }
        src.start()
        // Homebrew's ffmpeg may lack libsrt: then ffmpeg writes TS to a pipe and srt-live-transmit
        // (Homebrew "srt") sends it, as the soak check does.
        let encode = "'\(ffmpeg)' -hide_banner -loglevel error -re -f lavfi -i testsrc2=size=1280x720:rate=30 "
            + "-f lavfi -i sine=frequency=1000:sample_rate=48000 -t 8 -c:v \(codec) -preset ultrafast -g 30 -bf 2 "
            + "-c:a aac -ac 2 -f mpegts"
        let target = "srt://127.0.0.1:\(port)?mode=caller&latency=200000&streamid=check\(i)"
        let slt = ["/opt/homebrew/bin/srt-live-transmit", "/usr/local/bin/srt-live-transmit"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        if ffmpegHasSRT(ffmpeg) {
            p.arguments = ["-c", "\(encode) '\(target)'"]
        } else if let slt {
            p.arguments = ["-c", "\(encode) - | '\(slt)' -q -a:no file://con 'srt://127.0.0.1:\(port)?mode=caller&latency=200&streamid=check\(i)'"]
        } else {
            fail("no SRT sender: ffmpeg without libsrt and no srt-live-transmit")
        }
        do { try p.run() } catch { fail("ffmpeg: \(error)") }
        let end = Date().addingTimeInterval(9)
        var sawLive = false
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if src.status == .live { sawLive = true }
        }
        // srt-live-transmit keeps waiting after its input ends: stop the senders, never hang.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "127.0.0.1:\(port)"]
        try? kill.run()
        kill.waitUntilExit()
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        if p.isRunning { p.terminate() }
        let s = src.signal
        print("\(codec): status \(src.status.label), \(s.width)x\(s.height) \(s.videoCodec), frames \(s.frames), audio frames \(s.audioFrames) (\(s.audio)), decode errors \(s.decodeErrors), peer \(s.peer) streamid '\(s.streamID)', lost \(s.srt.lostPackets)")
        src.stop()
        guard sawLive else { fail("\(codec): the input never went live") }
        guard let pb = src.currentFrame(), CVPixelBufferGetWidth(pb) == 1280, CVPixelBufferGetHeight(pb) == 720 else { fail("\(codec): no 1280x720 frame") }
        guard s.frames >= 150 else { fail("\(codec): only \(s.frames) frames shown (expected ~210)") }
        guard s.audioFrames >= 48_000 * 5 else { fail("\(codec): only \(s.audioFrames) audio frames decoded") }
        guard s.decodeErrors == 0 else { fail("\(codec): \(s.decodeErrors) decode errors") }
    }
    print("OK")
    exit(0)
}
if args.count >= 2 && args[1] == "engine" { engineCheck() }
#endif
guard args.count >= 4 else { fail("usage: listen <port> <seconds> [latency] | call <host> <port> <seconds> [latency]") }
let config: SRTInputLink.Config
let seconds: Double
if args[1] == "call" {
    guard args.count >= 5, let port = Int(args[3]), let s = Double(args[4]) else { fail("bad arguments") }
    config = SRTInputLink.Config(role: .caller, host: args[2], port: port, latencyMs: args.count > 5 ? Int(args[5]) ?? 120 : 120)
    seconds = s
} else {
    guard let port = Int(args[2]), let s = Double(args[3]) else { fail("bad arguments") }
    config = SRTInputLink.Config(role: .listener, port: port, latencyMs: args.count > 4 ? Int(args[4]) ?? 120 : 120)
    seconds = s
}

let demux = MPEGTSDemuxer()
let lock = NSLock()
var video = 0, keyframes = 0, withParams = 0, audio = 0, damaged = 0, nonMonotonic = 0
var lastVideoDTS: Int64?
var events: [String] = []
var audioInfo = ""
let link = SRTInputLink(config: config)
link.simulatedLossPercent = Int(ProcessInfo.processInfo.environment["LC_SRT_LOSS"] ?? "") ?? 0
link.onEvent = { e in lock.lock(); events.append("\(e)"); lock.unlock(); print("event: \(e)") }
link.onPayload = { p in
    for au in demux.feed(p) {
        lock.lock(); defer { lock.unlock() }
        if au.damaged { damaged += 1 }
        if au.codec.isVideo {
            video += 1
            if let d = au.dts, let l = lastVideoDTS, d <= l { nonMonotonic += 1 }
            lastVideoDTS = au.dts
            let nals = AVC.splitAnnexB(au.data)
            if au.codec == .h264 {
                let types = Set(nals.compactMap { $0.first.map(AVC.nalType) })
                if types.contains(5) { keyframes += 1; if types.contains(7) && types.contains(8) { withParams += 1 } }
            } else {
                let types = Set(nals.compactMap { $0.first.map(HEVC.nalType) })
                if types.contains(where: HEVC.isKeyframe) { keyframes += 1; if types.contains(HEVC.sps) && types.contains(HEVC.pps) { withParams += 1 } }
            }
        } else if au.codec == .aac {
            let f = ADTS.frames(au.data)
            audio += f.count
            if let first = f.first { audioInfo = "AAC obj \(first.objectType) \(first.sampleRate) Hz \(first.channels) ch" }
        }
    }
}
link.start()
let end = SRTInputLink.now() + seconds
while SRTInputLink.now() < end { usleep(100_000) }
link.stop()
usleep(200_000)
let st = link.stats
lock.lock()
print("video AUs \(video) (\(demux.videoCodec?.name ?? "-")), keyframes \(keyframes) (with parameter sets \(withParams)), audio frames \(audio) \(audioInfo)")
print("SRT: received \(st.receivedPackets), lost \(st.lostPackets), recovered \(st.recoveredPackets), dropped \(st.droppedPackets), rtt \(String(format: "%.1f", st.rttMs)) ms, latency \(st.latencyMs) ms, streamid '\(st.peerStreamID)'")
print("TS continuity errors \(demux.continuityErrors), damaged AUs \(damaged), non-monotonic DTS \(nonMonotonic)")
guard video > 0, keyframes > 0, withParams > 0 else { fail("no decodable video received") }
guard audio > 0 else { fail("no audio received") }
guard nonMonotonic == 0 else { fail("video out of order") }
if link.simulatedLossPercent > 0 { guard damaged == 0, demux.continuityErrors == 0 else { fail("lost packets were not recovered") } }
print("OK")

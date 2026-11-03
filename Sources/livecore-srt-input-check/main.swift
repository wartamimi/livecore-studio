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
    var failures: [String] = []
    // The decoder alone, from a file (no network): tells a transport fault from a decoder fault.
    for (codec, preset) in [("libx264", "ultrafast"), ("libx264", "veryfast")] {
        let file = NSTemporaryDirectory() + "srt-check-\(preset).ts"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-t", "4",
                       "-c:v", codec, "-preset", preset, "-g", "30", "-bf", "2", "-f", "mpegts", file]
        try? p.run(); p.waitUntilExit()
        let bytes = [UInt8]((try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data())
        let r = SRTSource.decodeCheck(bytes)
        print("file \(codec) \(preset): \(bytes.count) bytes, decoded \(r.decoded), errors \(r.errors), first failure: \(r.firstFailure.isEmpty ? "-" : r.firstFailure)")
    }
    // ultrafast x264 = CAVLC with B-pictures; veryfast = CABAC (what OBS and most encoders send).
    // 3 Mb/s, like a real contribution feed: srt-live-transmit (the CI sender when Homebrew's ffmpeg
    // lacks libsrt) loses stdin data at unlimited x264 ultrafast rates (~7 Mb/s bursts) before SRT sees it.
    let cases = [("libx264", "ultrafast"), ("libx264", "veryfast"), ("libx265", "ultrafast")]
    for (i, (codec, preset)) in cases.enumerated() {
        let name = "\(codec) \(preset)"
        let port = 9310 + i
        let src = SRTSource(id: InputID("srt-check-\(i)"), config: ProjectSRTInput(mode: .listener, port: port, latencyMs: 200))
        src.audioChannelProvider = { MixerChannel.detached() }
        src.start()
        // Homebrew's ffmpeg may lack libsrt: then ffmpeg writes TS to a pipe and srt-live-transmit
        // (Homebrew "srt") sends it, as the soak check does.
        let encode = "'\(ffmpeg)' -hide_banner -loglevel error -re -f lavfi -i testsrc2=size=1280x720:rate=30 "
            + "-f lavfi -i sine=frequency=1000:sample_rate=48000 -t 8 -c:v \(codec) -preset \(preset) -b:v 3M -maxrate 3M -bufsize 1500k -g 30 -bf 2 "
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
        var link = SRTReceiver.Stats()
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if src.status == .live { sawLive = true }
            let now = src.signal.srt
            if now.receivedPackets >= link.receivedPackets { link = now }   // the receiver resets when the sender leaves
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
        print("\(name): status \(src.status.label), \(s.width)x\(s.height) \(s.videoCodec), frames \(s.frames), audio frames \(s.audioFrames) (\(s.audio)), decode errors \(s.decodeErrors) (last \(s.lastDecodeError)), decoder dropped \(s.decoderDropped), peer \(s.peer) streamid '\(s.streamID)', SRT received \(link.receivedPackets) lost \(link.lostPackets) recovered \(link.recoveredPackets), decoded \(s.decoded), TS CC errors \(s.continuityErrors), damaged \(s.damagedUnits), SRT dropped \(link.droppedPackets), decoder \(s.decoder), first failure: \(s.firstDecodeFailure.isEmpty ? "-" : s.firstDecodeFailure)")
        src.stop()
        var problems: [String] = []
        if !sawLive { problems.append("never went live") }
        if let pb = src.currentFrame(), CVPixelBufferGetWidth(pb) == 1280, CVPixelBufferGetHeight(pb) == 720 {} else { problems.append("no 1280x720 frame") }
        if s.frames < 150 { problems.append("only \(s.frames) frames shown (expected ~210)") }
        if s.audioFrames < 48_000 * 5 { problems.append("only \(s.audioFrames) audio frames decoded") }
        // A software fallback costs the frames of one GOP; more errors than that is a failure.
        if s.decodeErrors > 30 { problems.append("\(s.decodeErrors) decode errors") }
        failures += problems.map { "\(name): \($0)" }
    }
    if !failures.isEmpty { fail(failures.joined(separator: "; ")) }
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

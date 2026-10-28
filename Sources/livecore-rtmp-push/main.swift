// livecore-rtmp-push — protocol validation tool for the LiveCoreCore RTMP/FLV stack.
//
// Reads an H.264 Annex-B elementary stream and an AAC ADTS stream (e.g. produced by ffmpeg),
// converts them exactly like the app does (AVCC + AVCDecoderConfigurationRecord, raw AAC +
// AudioSpecificConfig), and either publishes them to an RTMP server in real time or writes
// an FLV file. Used by scripts/rtmp_e2e_test.sh. The app itself gets its H.264/AAC from
// VideoToolbox / AVAudioConverter instead of files.
//
// Usage:
//   livecore-rtmp-push --h264 in.h264 --aac in.aac --fps 30 --url rtmp://127.0.0.1:1935/live --key test [--realtime]
//   livecore-rtmp-push --h264 in.h264 --aac in.aac --fps 30 --flv out.flv
//   livecore-rtmp-push --h264 in.h264 --aac in.aac --fps 30 --srt "srt://127.0.0.1:9000?streamid=test"
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import LiveCoreCore

func die(_ msg: String) -> Never {
    var stderr = StandardError()
    print("error: \(msg)", to: &stderr)
    exit(1)
}
struct StandardError: TextOutputStream {
    mutating func write(_ s: String) { fputs(s, Glibc_or_Darwin_stderr()) }
}
@inline(__always) func Glibc_or_Darwin_stderr() -> UnsafeMutablePointer<FILE> {
    #if canImport(Glibc)
    return Glibc.stderr
    #else
    return Darwin.stderr
    #endif
}

func readFile(_ path: String) -> [UInt8] {
    guard let f = fopen(path, "rb") else { die("cannot open \(path)") }
    defer { fclose(f) }
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = fread(&buf, 1, buf.count, f)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

func monotonicMs() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1e6
}

// MARK: Arguments
var args: [String: String] = [:]
var flags = Set<String>()
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a == "--realtime" { flags.insert(a); continue }
    guard a.hasPrefix("--"), let v = it.next() else { die("bad argument \(a)") }
    args[String(a.dropFirst(2))] = v
}
guard let h264Path = args["h264"] else { die("--h264 is required") }
let fps = Double(args["fps"] ?? "30") ?? 30

// MARK: Build access units from Annex-B
struct AccessUnit { var nals: [ArraySlice<UInt8>]; var keyframe: Bool }
let nals = AVC.splitAnnexB(readFile(h264Path))
var sps: [UInt8]?, pps: [UInt8]?
var units: [AccessUnit] = []
var current: [ArraySlice<UInt8>] = []
var currentKey = false
var currentHasSlice = false
for nal in nals {
    guard let first = nal.first else { continue }
    let t = AVC.nalType(first)
    switch t {
    case AVC.NALType.sps.rawValue: sps = Array(nal); continue
    case AVC.NALType.pps.rawValue: pps = Array(nal); continue
    case AVC.NALType.aud.rawValue:
        if currentHasSlice { units.append(AccessUnit(nals: current, keyframe: currentKey)); current = []; currentKey = false; currentHasSlice = false }
        continue
    default: break
    }
    let isSlice = t == AVC.NALType.slice.rawValue || t == AVC.NALType.idr.rawValue
    // first_mb_in_slice == 0 (top bit of next byte set for ue(0)) starts a new picture.
    if isSlice, currentHasSlice, nal.count > 1, nal[nal.startIndex + 1] & 0x80 != 0 {
        units.append(AccessUnit(nals: current, keyframe: currentKey)); current = []; currentKey = false; currentHasSlice = false
    }
    current.append(nal)
    if isSlice { currentHasSlice = true }
    if t == AVC.NALType.idr.rawValue { currentKey = true }
}
if currentHasSlice { units.append(AccessUnit(nals: current, keyframe: currentKey)) }
guard let sps, let pps else { die("no SPS/PPS found in \(h264Path)") }
let dims = AVC.spsDimensions(sps)
print("video: \(units.count) access units, \(units.filter { $0.keyframe }.count) keyframes, SPS size \(dims.map { "\($0.width)x\($0.height)" } ?? "?")")

// MARK: Audio
var aacFrames: [AAC.ADTSFrame] = []
if let aacPath = args["aac"] {
    do { aacFrames = try AAC.parseADTS(readFile(aacPath)) } catch { die("ADTS parse failed: \(error)") }
    print("audio: \(aacFrames.count) AAC frames, \(aacFrames.first?.sampleRate ?? 0) Hz, \(aacFrames.first?.channels ?? 0) ch")
}

// MARK: Interleave by timestamp
var packets: [OutgoingPacket] = []
let avcConfig = AVC.decoderConfigurationRecord(sps: sps, pps: pps)
packets.append(OutgoingPacket(kind: .config, timestampMs: 0, body: FLV.avcVideoBody(keyframe: true, sequenceHeader: true, data: avcConfig)))
if let a = aacFrames.first {
    packets.append(OutgoingPacket(kind: .config, timestampMs: 0,
                                  body: FLV.aacAudioBody(sequenceHeader: true, data: AAC.audioSpecificConfig(sampleRate: a.sampleRate, channels: a.channels))))
}
var media: [OutgoingPacket] = []
for (i, u) in units.enumerated() {
    let ts = UInt32((Double(i) * 1000 / fps).rounded())
    media.append(OutgoingPacket(kind: .video(keyframe: u.keyframe), timestampMs: ts,
                                body: FLV.avcVideoBody(keyframe: u.keyframe, sequenceHeader: false, data: AVC.avcc(from: u.nals))))
}
for (i, f) in aacFrames.enumerated() {
    let ts = UInt32((Double(i) * 1024 * 1000 / Double(f.sampleRate)).rounded())
    media.append(OutgoingPacket(kind: .audio, timestampMs: ts, body: FLV.aacAudioBody(sequenceHeader: false, data: Array(f.payload))))
}
media.sort { $0.timestampMs < $1.timestampMs }
packets += media

let meta = FLV.Metadata(width: dims?.width ?? 0, height: dims?.height ?? 0, frameRate: fps, videoBitrateKbps: 0,
                        audioBitrateKbps: 0, audioSampleRate: aacFrames.first?.sampleRate ?? 48000,
                        audioChannels: aacFrames.first?.channels ?? 2)

// MARK: FLV file mode
if let flvPath = args["flv"] {
    var w = FLVFileWriter(hasAudio: !aacFrames.isEmpty, hasVideo: true)
    w.appendTag(type: .script, timestampMs: 0, body: FLV.onMetaDataBody(meta))
    for p in packets {
        let type: FLV.TagType
        switch p.kind {
        case .audio: type = .audio
        case .video: type = .video
        case .config: type = p.body.first == 0xAF ? .audio : .video
        case .metadata: type = .script
        }
        w.appendTag(type: type, timestampMs: p.timestampMs, body: p.body)
    }
    guard let f = fopen(flvPath, "wb") else { die("cannot write \(flvPath)") }
    _ = w.bytes.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, f) }
    fclose(f)
    print("wrote \(flvPath) (\(w.bytes.count) bytes)")
    exit(0)
}

// MARK: SRT publish mode (MPEG-TS over SRT, caller)
if let srtString = args["srt"] {
    let surl: SRTURL
    do { surl = try SRTURL.parse(srtString, key: args["key"] ?? "") } catch { die("\(error)") }
    let sock: UDPSocket
    do { sock = try UDPSocket(host: surl.host, port: surl.port) } catch { die("\(error)") }
    let caller = SRTCaller(url: surl, socketID: UInt32.random(in: 1...0x3FFF_FFFF), initialSeq: UInt32.random(in: 0...0x3FFF_FFFF))
    func now() -> Double { monotonicMs() / 1000 }
    print("SRT connecting to \(surl.redacted), latency \(surl.latencyMs) ms")
    for d in caller.connect(now: now()) { sock.send(d) }
    while caller.state != .connected {
        if case let .closed(reason) = caller.state { die("SRT connect failed: \(reason)") }
        let d = sock.receive(timeoutMs: 20)
        if !d.isEmpty { for r in caller.receive(d, now: now()) { sock.send(r) } }
        for r in caller.tick(now: now()) { sock.send(r) }
    }
    print("SRT connected (latency \(caller.latencyMs) ms)")
    // Media in timestamp order, muxed to TS exactly like the app.
    struct Item { var ms: Double; var video: Int?; var audio: Int? }
    var items: [Item] = units.indices.map { Item(ms: Double($0) * 1000 / fps, video: $0, audio: nil) }
    if let a = aacFrames.first {
        items += aacFrames.indices.map { Item(ms: Double($0) * 1024 * 1000 / Double(a.sampleRate), video: nil, audio: $0) }
    }
    items.sort { $0.ms < $1.ms }
    let asc = aacFrames.first.map { AAC.audioSpecificConfig(sampleRate: $0.sampleRate, channels: $0.channels) } ?? []
    var mux = MPEGTSMuxer(hasAudio: !aacFrames.isEmpty)
    var packer = SRTPayloadPacker()
    let start = now()
    var sent = 0
    let lossEvery = Int(args["srt-loss"] ?? "") ?? 0
    func service(until t: Double) {
        repeat {
            let d = sock.receive(timeoutMs: Int32(max(0, min(10, (t - now()) * 1000))))
            if !d.isEmpty { for r in caller.receive(d, now: now()) { sock.send(r) } }
            for r in caller.tick(now: now()) { sock.send(r) }
            if case let .closed(reason) = caller.state { die("SRT connection lost: \(reason)") }
        } while now() < t
    }
    for it in items {
        service(until: start + it.ms / 1000)
        let pts = UInt64(it.ms * 90)
        let ts: [UInt8]
        if let v = it.video {
            let u = units[v]
            ts = mux.video(avcc: AVC.avcc(from: u.nals), sps: sps, pps: pps, keyframe: u.keyframe, pts90k: pts)
        } else if let a = it.audio {
            ts = mux.audio(aac: Array(aacFrames[a].payload), audioSpecificConfig: asc, pts90k: pts)
        } else { continue }
        var payloads = packer.add(ts)
        if let rest = packer.flush() { payloads.append(rest) }
        for p in payloads {
            guard let d = caller.send(p, now: now()) else { continue }
            sent += 1
            // --srt-loss N: drop every Nth first transmission to exercise NAK / retransmission.
            if lossEvery > 0, sent % lossEvery == 0 { continue }
            sock.send(d)
        }
    }
    // Let retransmissions finish, then close.
    service(until: now() + Double(caller.latencyMs) / 1000 + 1)
    if let bye = caller.close(now: now()) { sock.send(bye) }
    let s = caller.stats
    print("SRT sent \(sent) packets, \(s.retransmitted) retransmitted, \(s.dropped) dropped, rtt \(s.rttMs) ms")
    exit(0)
}

// MARK: RTMP publish mode
guard let urlString = args["url"] else { die("--url or --flv is required") }
let url: RTMPURL
do { url = try RTMPURL.parse(serverURL: urlString, streamKey: args["key"] ?? "") } catch { die("\(error)") }
if url.useTLS { die("rtmps:// is supported by the macOS app (Network.framework TLS); this CLI only speaks plain rtmp://") }

let sock: POSIXSocket
do { sock = try POSIXSocket(host: url.host, port: url.port) } catch { die("\(error)") }
let session = RTMPPublishSession(url: url)
print("connecting to \(url.tcUrl) (key \(Redaction.maskKey(url.streamKey)))")

func pump(_ events: [RTMPPublishSession.Event]) {
    for e in events {
        switch e {
        case let .send(b): do { try sock.send(b) } catch { die("\(error)") }
        case let .stateChanged(s): print("state: \(s)")
        case let .status(s): print("server: \(s)")
        }
    }
}

pump(session.start())
let deadline = monotonicMs() + 10_000
while session.state != .publishing {
    if case let .failed(reason) = session.state { die("publish failed: \(reason)") }
    if monotonicMs() > deadline { die("timeout waiting for NetStream.Publish.Start (state \(session.state))") }
    do { pump(try session.receive(try sock.receive(timeoutMs: 200))) } catch { die("\(error)") }
}

do {
    try sock.send(try session.metadataPacket(meta))
    let start = monotonicMs()
    var sentBytes = 0
    for p in packets {
        if flags.contains("--realtime") {
            let due = start + Double(p.timestampMs)
            while monotonicMs() < due {
                pump(try session.receive(try sock.receive(timeoutMs: Int32(max(1, min(20, due - monotonicMs()))))))
            }
        }
        let bytes: [UInt8]
        switch p.kind {
        case .audio: bytes = try session.audioPacket(body: p.body, timestampMs: p.timestampMs)
        case .config: bytes = p.body.first == 0xAF ? try session.audioPacket(body: p.body, timestampMs: 0)
                                                   : try session.videoPacket(body: p.body, timestampMs: 0)
        default: bytes = try session.videoPacket(body: p.body, timestampMs: p.timestampMs)
        }
        try sock.send(bytes)
        sentBytes += bytes.count
    }
    let secs = (monotonicMs() - start) / 1000
    print("sent \(packets.count) packets, \(sentBytes) bytes in \(String(format1(secs))) s")
    pump(session.close())
    // Give the server a moment to process FCUnpublish/deleteStream.
    _ = try? sock.receive(timeoutMs: 500)
} catch {
    die("\(error)")
}

func format1(_ v: Double) -> String { let r = (v * 10).rounded() / 10; return "\(r)" }

// CI check for online radio (macOS): a local stream server sends an MP3 (mono, 44.1 kHz) and an
// ADTS AAC (stereo, 48 kHz) tone with ICY song titles, the way Icecast stations do; RadioInput
// must parse, decode, resample to 48 kHz and read the title. Optionally also queries the real
// Radio Browser directory (skipped without network).
#if os(macOS)
import Foundation
import LiveCoreCore
import LiveCoreEngine

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("radio-check: FAIL: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func log(_ s: String) { print("radio-check: " + s) }

func pump(seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

func which(_ tool: String) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] where FileManager.default.isExecutableFile(atPath: "\(dir)/\(tool)") {
        return "\(dir)/\(tool)"
    }
    return nil
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

guard let ffmpeg = which("ffmpeg") else { fail("ffmpeg not found") }
let work = FileManager.default.temporaryDirectory.appendingPathComponent("livecore-radio-\(getpid())")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

// 12 s of 1 kHz at -6 dBFS (peak 0.5).
let mp3 = work.appendingPathComponent("tone.mp3").path
let aac = work.appendingPathComponent("tone.aac").path
for (out, args) in [(mp3, ["-ac", "1", "-ar", "44100", "-c:a", "libmp3lame", "-b:a", "128k"]),
                    (aac, ["-ac", "2", "-ar", "48000", "-c:a", "aac", "-b:a", "128k", "-f", "adts"])] {
    let (st, o) = run(ffmpeg, ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=12",
                               "-af", "volume=-6dB"] + args + [out])
    guard st == 0 else { fail("ffmpeg: \(o)") }
}

// Icecast-like server: ICY metadata every 16000 bytes when the client asks for it.
let server = """
import sys, http.server
title = b"StreamTitle='LiveCore Test - Tone';"
block = bytes([ (len(title) + 15) // 16 ]) + title + b"\\0" * (((len(title) + 15) // 16) * 16 - len(title))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        path = sys.argv[2] + self.path
        try: data = open(path, "rb").read()
        except OSError: self.send_error(404); return
        icy = self.headers.get("Icy-MetaData") == "1"
        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg" if path.endswith(".mp3") else "audio/aac")
        if icy: self.send_header("icy-metaint", "16000")
        self.end_headers()
        if icy:
            out = bytearray()
            for i in range(0, len(data), 16000):
                chunk = data[i:i + 16000]
                out += chunk
                if len(chunk) == 16000: out += block
            data = bytes(out)
        self.wfile.write(data)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
"""
let script = work.appendingPathComponent("server.py")
try? server.write(to: script, atomically: true, encoding: .utf8)
let port = 18_000 + Int(getpid() % 1000)
let python = Process()
python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
python.arguments = ["python3", script.path, String(port), work.path]
do { try python.run() } catch { fail("python3: \(error)") }
defer { python.terminate() }
pump(seconds: 1.5)

let mixer = AudioMixerEngine()
for (file, codec) in [("tone.mp3", "MP3"), ("tone.aac", "AAC")] {
    let station = RadioStation(id: "check-\(codec)", name: "Check \(codec)", streamURL: "http://127.0.0.1:\(port)/\(file)", codec: codec)
    let radio = RadioInput(id: codec.lowercased(), station: station, channel: mixer.addChannel(id: "radio:" + codec, name: codec))
    var states: [String] = []
    radio.onChange = { states.append("\(radio.state)") }
    radio.play()
    pump(seconds: 20) { radio.decodedFrames.value >= 48_000 * 11 && radio.nowPlaying != nil }
    radio.stop()
    pump(seconds: 0.5)
    let frames = radio.decodedFrames.value, peak = radio.peak.value
    log(String(format: "%@: %llu frames at 48 kHz (%.1f s), peak %.3f, title %@, states %@", codec, frames, Double(frames) / 48_000,
               peak, radio.nowPlaying ?? "none", states.joined(separator: " → ")))
    guard frames >= 48_000 * 11 else { fail("\(codec): only \(frames) frames decoded") }
    guard frames <= 48_000 * 40 else { fail("\(codec): \(frames) frames is far more than the stream holds (resampling wrong?)") }
    guard peak > 0.4, peak < 0.65 else { fail("\(codec): peak \(peak), expected about 0.5 (-6 dBFS)") }
    guard radio.nowPlaying == "LiveCore Test - Tone" else { fail("\(codec): ICY title not read: \(radio.nowPlaying ?? "none")") }
    guard states.contains("playing") else { fail("\(codec): never reached playing: \(states)") }
}

// The real directory (informational: the CI network may not reach it).
if let url = RadioBrowser.searchURL(server: RadioBrowser.servers[0], .init(tag: "jazz", limit: 5)) {
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.setValue(RadioBrowser.userAgent, forHTTPHeaderField: "User-Agent")
    var done = false
    URLSession.shared.dataTask(with: req) { data, _, error in
        if let data, let list = try? RadioBrowser.decodeStations(data, limit: 5) {
            log("Radio Browser: \(list.count) playable jazz stations, e.g. \(list.first.map { "\($0.name) (\($0.summary))" } ?? "none")")
        } else {
            log("Radio Browser not reachable from CI (\(error?.localizedDescription ?? "bad response")); skipped")
        }
        done = true
    }.resume()
    pump(seconds: 20) { done }
}
log("PASS")
#else
print("radio-check: macOS only")
#endif

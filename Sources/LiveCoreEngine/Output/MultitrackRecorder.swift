#if os(macOS)
import AVFoundation
import Foundation
import LiveCoreCore
import LiveCoreServices

/// Multitrack audio recording (0.71.0): while the recorder runs, every mixer channel is written
/// to its own WAV file (24-bit stereo, the input before EQ, dynamics and fader), so the event
/// can be mixed again afterwards. All tracks start on the same audio block and stay sample
/// aligned (a channel without audio records silence). Channels added during the recording are
/// not included; a removed channel's file simply ends.
public final class MultitrackRecorder {
    private struct Track {
        let channel: MixerChannel
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
    }

    private let mixer: AudioMixerEngine
    private let queue = DispatchQueue(label: "livecore.multitrack", qos: .utility)
    private var tracks: [Track] = []
    private var timer: DispatchSourceTimer?
    public private(set) var folder: URL?
    /// Called on main with an error text when a file cannot be written.
    public var onError: ((String) -> Void)?

    public init(mixer: AudioMixerEngine) { self.mixer = mixer }

    public var isRunning: Bool { timer != nil }

    /// Starts one file per channel in `folder`. Returns the number of tracks.
    @discardableResult
    public func start(folder: URL) throws -> Int {
        guard timer == nil else { return tracks.count }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rate = mixer.sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return 0 }
        var made: [Track] = []
        var used = Set<String>()
        for (k, ch) in mixer.channelList.enumerated() {
            var name = Self.safeName(ch.name.isEmpty ? ch.id : ch.name)
            if !used.insert(name.lowercased()).inserted { name += " \(k + 1)" }
            let url = folder.appendingPathComponent(String(format: "%02d ", k + 1) + name + ".wav")
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)) else { continue }
            // Old samples from an earlier recording are thrown away before arming.
            _ = ch.trackL.skip(ch.trackL.availableToRead); _ = ch.trackR.skip(ch.trackR.availableToRead)
            ch.trackArmed.value = true
            made.append(Track(channel: ch, file: file, buffer: buf))
        }
        guard !made.isEmpty else { return 0 }
        tracks = made
        self.folder = folder
        mixer.tracksOn.value = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
        FileLog.shared.info("multitrack recording: \(made.count) tracks in \(folder.lastPathComponent)")
        return made.count
    }

    public func stop() {
        guard let t = timer else { return }
        mixer.tracksOn.value = false
        timer = nil
        let finished = tracks
        tracks = []
        queue.async { [weak self] in
            t.cancel()
            self?.drain(finished)
            var overruns: UInt64 = 0
            for tr in finished {
                tr.channel.trackArmed.value = false
                overruns += tr.channel.trackOverruns.value
            }
            if overruns > 0 { FileLog.shared.warning("multitrack recording: \(overruns) blocks lost (disk too slow)") }
            // AVAudioFile closes its file when released.
        }
    }

    private func drain() { drain(tracks) }

    private func drain(_ list: [Track]) {
        for tr in list {
            let ch = tr.channel
            let n = min(ch.trackL.availableToRead, ch.trackR.availableToRead, Int(tr.buffer.frameCapacity))
            guard n > 0, let l = tr.buffer.floatChannelData?[0], let r = tr.buffer.floatChannelData?[1] else { continue }
            _ = ch.trackL.read(into: l, count: n)
            _ = ch.trackR.read(into: r, count: n)
            tr.buffer.frameLength = AVAudioFrameCount(n)
            do { try tr.file.write(from: tr.buffer) } catch {
                let msg = "Multitrack: cannot write \(tr.file.url.lastPathComponent): \(error.localizedDescription)"
                DispatchQueue.main.async { [weak self] in self?.onError?(msg) }
            }
        }
    }

    static func safeName(_ s: String) -> String {
        let bad: Set<Character> = ["/", ":", "\\", "\0", "\n", "\r"]
        let cleaned = String(s.map { bad.contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Track" : cleaned).prefix(60))
    }
}
#endif

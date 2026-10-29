#if os(macOS)
import CoreMedia
import Foundation
import LiveCoreCore

/// The portrait 9:16 output: settings, its own stream (one RTMP/RTMPS destination) and its own
/// recording next to RECORD (0.42.0).
extension ProductionEngine {
    public func setVerticalSettings(_ v: VerticalSettings) {
        settings.vertical = v
        vertical.settings = v
    }

    /// Program format with the vertical size and bitrate, for the encoders.
    var verticalProduction: ProductionSettings {
        var p = settings
        let v = settings.verticalOutput
        p.output = OutputFormat(size: v.size, frameRate: settings.output.frameRate)
        p.video.bitrateKbps = v.bitrateKbps
        p.video.keyframeIntervalSeconds = v.keyframeSeconds
        p.audio.bitrateKbps = v.audioBitrateKbps
        return p
    }

    public var isVerticalStreaming: Bool { vertical.sinks.read { $0.encoder != nil } }

    public func startVerticalStream(url: RTMPURL) throws {
        guard !isVerticalStreaming else { return }
        let p = verticalProduction
        let enc = try H264Encoder(size: p.output.size, frameRate: p.output.frameRate, settings: p.video)
        let aac = try AACEncoder(sampleRate: Double(p.audio.sampleRate), channels: p.audio.channels, bitrateKbps: p.audio.bitrateKbps)
        let s = StreamingEngine()
        s.onStats = { [weak self] st in self?.onVerticalStreamStats?(st) }
        s.encoderStatsProvider = { [weak enc] in (enc?.isHardwareAccelerated ?? false, enc?.droppedFrames.value ?? 0) }
        s.onRequestKeyframe = { [weak enc] in enc?.requestKeyframe() }
        enc.onFrame = { f in s.send(video: f) }
        // Same AAC timing as the main stream (see startStreaming).
        var firstHost: Double?
        var packetIndex: Int64 = 0
        let sr = Double(p.audio.sampleRate)
        audioPump.addSink("vertical-stream") { chunk in
            if firstHost == nil { firstHost = chunk.hostTime }
            guard let base = firstHost else { return }
            let t = base + (Double(packetIndex) * 1024 - Double(AACEncoder.primingFrames)) / sr
            packetIndex += 1
            if let data = try? aac.encode(chunk.bus(.master)) {
                s.send(audio: data, pts: CMTime(seconds: t, preferredTimescale: 48_000))
            }
        }
        verticalStream = (s, aac)
        vertical.sinks.mutate { $0.encoder = enc }
        s.start(url: url, settings: p, audioSpecificConfig: aac.audioSpecificConfig)
    }

    public func stopVerticalStream() {
        let enc: H264Encoder? = vertical.sinks.mutate { k in let e = k.encoder; k.encoder = nil; return e }
        verticalStream?.0.stop()
        verticalStream = nil
        audioPump.removeSink("vertical-stream")
        enc?.onFrame = nil
        renderQueue.async { enc?.invalidate() }
    }

    /// Starts the vertical file with RECORD when the vertical output is on and set to record.
    func startVerticalRecording(date: Date) {
        let v = settings.verticalOutput
        guard v.enabled, v.recordWithProgram, vertical.sinks.read({ $0.recorder == nil }) else { return }
        let r = RecordingEngine()
        r.onStats = { [weak self] s in
            if case let .failed(msg) = s.state { self?.onError?("Vertical recording: \(msg)") }
        }
        let p = verticalProduction
        r.start(settings: settings.recording, output: p.output, audio: settings.audio, fileSuffix: "Vertical", date: date)
        vertical.sinks.mutate { $0.recorder = r }
        let bus = settings.recording.bus
        audioPump.addSink("vertical-record") { [weak r] chunk in r?.append(audio: chunk.bus(bus)) }
    }

    func stopVerticalRecording() {
        let r: RecordingEngine? = vertical.sinks.mutate { k in let x = k.recorder; k.recorder = nil; return x }
        audioPump.removeSink("vertical-record")
        r?.stop()
    }
}
#endif

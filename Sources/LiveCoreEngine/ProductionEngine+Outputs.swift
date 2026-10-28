#if os(macOS)
import AVFoundation
import AppKit
import CoreMedia
import Foundation
import LiveCoreCore

/// Audio inputs, settings, streaming, recording and the MultiCorder (main thread).
extension ProductionEngine {
    // MARK: Audio inputs

    public var audioChannels: [MixerChannel] { mixer.channelList }

    public func addAudioInput(uniqueID: String) {
        guard audioInputs[uniqueID] == nil, let dev = DeviceManager.device(uniqueID: uniqueID) else { return }
        let ch = mixer.addChannel(id: uniqueID, name: dev.localizedName)
        let input = AudioCaptureInput(device: dev, channel: ch)
        input.onStatusChange = { [weak self] s in
            if case let .error(msg) = s { self?.onError?("\(dev.localizedName): \(msg)") }
        }
        audioInputs[uniqueID] = input
        DeviceManager.requestAccess(.audio) { [weak self] ok in
            if !ok { self?.onError?("Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone.") }
            input.start()
        }
    }

    public func removeAudioInput(uniqueID: String) {
        audioInputs[uniqueID]?.stop()
        audioInputs[uniqueID] = nil
        mixer.removeChannel(id: uniqueID)
    }

    public func audioInputStatus(_ uniqueID: String) -> SourceStatus? { audioInputs[uniqueID]?.status }

    // MARK: Settings

    public var isOutputActive: Bool {
        let o = outputs.current
        return o.streamEncoder != nil || o.recording || !o.iso.isEmpty
    }

    /// Applies settings. Output resolution/frame rate changes require all outputs to be stopped.
    @discardableResult
    public func apply(_ new: ProductionSettings) -> [String] {
        let errs = new.validationErrors()
        guard errs.isEmpty else { return errs }
        let formatChanged = new.output != settings.output
        if formatChanged && isOutputActive { return ["Stop streaming and recording before changing resolution or frame rate."] }
        let customChanged = new.customTransition != settings.customTransition
        settings = new
        vertical.settings = new.verticalOutput
        if customChanged, let err = setCustomTransition(new.customTransition) { return ["Custom transition: \(err)"] }
        if formatChanged {
            renderQueue.sync { compositor.configure(outputSize: new.output.size) }
            startRenderLoop()
            // The replay buffer restarts at the new size (older replays are discarded).
            if replaySource != nil { replay.stop(); replay.start(output: new.output) }
        }
        return []
    }

    // MARK: Streaming

    /// A stream destination with its key already resolved (from the Keychain).
    public struct StreamTarget {
        public enum Endpoint { case rtmp(RTMPURL), srt(SRTURL) }
        public var id: String
        public var name: String
        public var endpoint: Endpoint
        public var audioBus: OutputBus
        public init(id: String, name: String, url: RTMPURL, audioBus: OutputBus = .master) {
            self.id = id; self.name = name; self.endpoint = .rtmp(url); self.audioBus = audioBus
        }
        public init(id: String, name: String, srt: SRTURL, audioBus: OutputBus = .master) {
            self.id = id; self.name = name; self.endpoint = .srt(srt); self.audioBus = audioBus
        }
    }

    /// Starts streaming to every target at once. One H.264 and one AAC encode are shared by all
    /// destinations, so each extra destination costs upload bandwidth, not CPU/GPU.
    public func startStreaming(to targets: [StreamTarget]) throws {
        guard outputs.read({ $0.streamEncoder }) == nil else { return }
        guard !targets.isEmpty else {
            throw NSError(domain: "LiveCore", code: 11, userInfo: [NSLocalizedDescriptionKey: "No stream destination is enabled."])
        }
        let errs = settings.validationErrors()
        if !errs.isEmpty { throw NSError(domain: "LiveCore", code: 10, userInfo: [NSLocalizedDescriptionKey: errs.joined(separator: "\n")]) }
        let enc = try H264Encoder(size: settings.output.size, frameRate: settings.output.frameRate, settings: settings.video)
        // One AAC encode per bus in use (destinations on the same bus share it).
        var aacByBus: [OutputBus: AACEncoder] = [:]
        for bus in Set(targets.map(\.audioBus)) {
            aacByBus[bus] = try AACEncoder(sampleRate: Double(settings.audio.sampleRate), channels: settings.audio.channels,
                                           bitrateKbps: settings.audio.bitrateKbps)
        }
        aacEncoders = Array(aacByBus.values)
        streamers.values.forEach { $0.stop() }
        streamers = [:]
        streamTerminal = [:]
        var engines: [StreamOutput] = []
        for t in targets {
            let s: StreamOutput
            switch t.endpoint {
            case .rtmp: s = StreamingEngine()
            case .srt: s = SRTStreamingEngine()
            }
            s.onStats = { [weak self] st in self?.streamStatsChanged(t.id, st) }
            s.encoderStatsProvider = { [weak self] in
                guard let enc = self?.outputs.read({ $0.streamEncoder }) else { return (false, 0) }
                return (enc.isHardwareAccelerated, enc.droppedFrames.value)
            }
            s.onRequestKeyframe = { [weak enc] in enc?.requestKeyframe() }
            streamers[t.id] = s
            streamTerminal[t.id] = false
            engines.append(s)
        }
        enc.onFrame = { f in for s in engines { s.send(video: f) } }
        // AAC timestamps: Apple's AAC encoder has 2112 samples of priming delay. Output packet k
        // carries audio that started at firstHost + (k*1024 - 2112)/sr; stamping it that way keeps
        // lip-sync exact in FLV, which cannot signal priming.
        var firstHost: Double?
        var packetIndex: Int64 = 0
        let sr = Double(settings.audio.sampleRate)
        let groups: [(bus: OutputBus, aac: AACEncoder, engines: [StreamOutput])] = aacByBus.map { bus, aac in
            (bus, aac, zip(engines, targets).filter { $0.1.audioBus == bus }.map(\.0))
        }
        audioPump.addSink("stream") { chunk in
            if firstHost == nil { firstHost = chunk.hostTime }
            guard let base = firstHost else { return }
            let t = base + (Double(packetIndex) * 1024 - Double(AACEncoder.primingFrames)) / sr
            packetIndex += 1
            let pts = CMTime(seconds: t, preferredTimescale: 48_000)
            for g in groups {
                guard let data = try? g.aac.encode(chunk.bus(g.bus)) else { continue }
                for s in g.engines { s.send(audio: data, pts: pts) }
            }
        }
        outputs.mutate { $0.streamEncoder = enc }
        for (s, t) in zip(engines, targets) {
            let asc = aacByBus[t.audioBus]!.audioSpecificConfig
            switch t.endpoint {
            case let .rtmp(url): (s as? StreamingEngine)?.start(url: url, settings: settings, audioSpecificConfig: asc)
            case let .srt(url): (s as? SRTStreamingEngine)?.start(url: url, settings: settings, audioSpecificConfig: asc)
            }
        }
    }

    /// Each destination fails and reconnects on its own; the shared encoders are released only
    /// when every destination has ended permanently.
    func streamStatsChanged(_ id: String, _ s: StreamingEngine.Stats) {
        onStreamStats?(id, s)
        switch s.state {
        case .failed: streamTerminal[id] = true
        case .idle: break
        default: streamTerminal[id] = false
        }
        if !streamTerminal.isEmpty, streamTerminal.values.allSatisfy({ $0 }), outputs.read({ $0.streamEncoder }) != nil {
            streamDidEnd()
        }
    }

    public func stopStreaming() {
        streamers.values.forEach { $0.stop() }
        audioPump.removeSink("stream")
        let enc: H264Encoder? = outputs.mutate { o in let e = o.streamEncoder; o.streamEncoder = nil; return e }
        enc?.onFrame = nil
        renderQueue.async { enc?.invalidate() }
        aacEncoders = []
    }

    /// Called when every destination failed permanently (not while reconnecting) to release the encoder.
    public func streamDidEnd() {
        let enc: H264Encoder? = outputs.mutate { o in let e = o.streamEncoder; o.streamEncoder = nil; return e }
        enc?.onFrame = nil
        audioPump.removeSink("stream")
        renderQueue.async { enc?.invalidate() }
    }

    // MARK: Recording

    public func startRecording() {
        guard !outputs.read({ $0.recording }) else { return }
        recorder.start(settings: settings.recording, output: settings.output, audio: settings.audio)
        outputs.mutate { $0.recording = true }
        let recorder = self.recorder
        let bus = settings.recording.bus
        audioPump.addSink("record") { [weak recorder] chunk in recorder?.append(audio: chunk.bus(bus)) }
        startVerticalRecording(date: Date())
    }

    public func stopRecording() {
        guard outputs.read({ $0.recording }) else { return }
        recorder.stop()
        outputs.mutate { $0.recording = false }
        audioPump.removeSink("record")
        stopVerticalRecording()
    }

    // MARK: MultiCorder

    /// Starts one recorder per chosen input with the MultiCorder profile; files are named
    /// "<pattern> - ISO <number> <name>" with one shared time stamp. Returns the number of files.
    @discardableResult
    public func startMultiCorder() -> Int {
        guard outputs.read({ $0.iso.isEmpty }) else { return 0 }
        let profile = settings.multiCorderRecording
        let iso = startISORecorders(profile: profile, date: Date())
        guard !iso.isEmpty else { return 0 }
        control.mutate { $0.isoInputs = iso.map(\.0) }
        outputs.mutate { $0.iso = iso }
        // Each ISO file records its own bus (Master, Bus A or Bus B); each bus is mixed once.
        let config = multiCorder
        let routed = iso.map { (config.bus(for: $0.0, profile: profile.bus), $0.1) }
        let buses = Array(Set(routed.map(\.0)))
        audioPump.addSink("multicorder") { chunk in
            var mixed: [OutputBus: ProgramAudioPump.Chunk] = [:]
            for b in buses { mixed[b] = chunk.bus(b) }
            for (b, r) in routed { if let c = mixed[b] { r.append(audio: c) } }
        }
        return iso.count
    }

    public func stopMultiCorder() { stopISORecorders() }

    /// A failing ISO file is reported and the others keep recording.
    func startISORecorders(profile: RecordingSettings, date: Date) -> [(InputID, RecordingEngine)] {
        let list = inputs
        isoStats = [:]
        var out: [(InputID, RecordingEngine)] = []
        for id in multiCorder.active {
            guard let info = list.first(where: { $0.id == id }) else { continue }
            let r = RecordingEngine()
            r.onStats = { [weak self] s in
                guard let self else { return }
                let wasFailed: Bool = { if case .failed? = self.isoStats[id]?.state { return true }; return false }()
                if case let .failed(msg) = s.state, !wasFailed { self.onError?("ISO \(info.number) \(info.name): \(msg)") }
                self.isoStats[id] = s
                // Every ISO file failed (disk full, encoder refused...): the MultiCorder stops.
                let running = self.outputs.read { $0.iso.map(\.0) }
                if !running.isEmpty, running.allSatisfy({ i in
                    if case .failed? = self.isoStats[i]?.state { return true }; return false
                }) { self.stopISORecorders() }
                self.onISOStats?(self.isoStats)
            }
            r.start(settings: profile, output: settings.output, audio: settings.audio,
                    fileSuffix: MultiCorderConfig.fileSuffix(number: info.number, name: info.name), date: date)
            out.append((id, r))
        }
        return out
    }

    func stopISORecorders() {
        let iso = outputs.mutate { o -> [(InputID, RecordingEngine)] in let l = o.iso; o.iso = []; return l }
        guard !iso.isEmpty else { return }
        audioPump.removeSink("multicorder")
        for (_, r) in iso { r.stop() }
        control.mutate { $0.isoInputs = [] }
    }

    func recordingEnded(_ s: RecordingEngine.Stats) {
        switch s.state {
        case .failed, .finished, .idle:
            if outputs.read({ $0.recording }) {
                outputs.mutate { $0.recording = false }
                audioPump.removeSink("record")
            }
        default: break
        }
    }
}
#endif

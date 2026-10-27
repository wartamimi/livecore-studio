#if os(macOS)
import AVFoundation
import AppKit
import CoreMedia
import Foundation
import LiveCoreCore

/// Facade that owns every engine and wires the real-time pipeline:
///
///   VideoSources --(latest CVPixelBuffer)--> render tick (DispatchSourceTimer @ fps)
///      --> FramePlanner (switcher + overlays) --> MetalCompositor (GPU)
///      --> Program buffer --> H264Encoder --> StreamingEngine (RTMP/RTMPS)
///                         --> RecordingEngine (AVAssetWriter)
///                         --> Program monitor (main thread)
///   AudioCaptureInputs --> AudioMixerEngine (Core Audio IO thread) --> ProgramAudioPump
///      --> AACEncoder --> StreamingEngine ; --> RecordingEngine
///
/// Threading:
///   * Public API: main thread only.
///   * Control state (switcher, overlays, scene layers, source table) lives in `control`,
///     a lock-protected struct that the render queue snapshots once per frame.
///   * Render queue: one serial queue; GPU completion handlers fan out to encoders.
public final class ProductionEngine {
    public struct InputInfo: Identifiable, Equatable {
        public var id: InputID
        public var name: String
        public var kind: InputKind
        public var status: SourceStatus
        public var number: Int
    }

    // MARK: Callbacks (main thread)
    public var onProgramFrame: ((CVPixelBuffer) -> Void)?
    public var onPreviewFrame: ((CVPixelBuffer) -> Void)?
    public var onThumbnails: (([InputID: CVPixelBuffer]) -> Void)?
    public var onSwitcherChange: ((SwitcherSnapshot) -> Void)?
    public var onInputsChange: (([InputInfo]) -> Void)?
    public var onStreamStats: ((StreamingEngine.Stats) -> Void)?
    public var onRecordStats: ((RecordingEngine.Stats) -> Void)?
    public var onError: ((String) -> Void)?
    /// Mixer channels were added or removed by the engine itself (e.g. a video file's audio).
    public var onAudioChannelsChange: (() -> Void)?

    public private(set) var settings: ProductionSettings
    public let compositor: MetalCompositor
    public let mixer = AudioMixerEngine()
    public let devices = DeviceManager()
    public private(set) lazy var audioPump = ProgramAudioPump(mixer: mixer)
    public let streamer = StreamingEngine()
    public let recorder = RecordingEngine()
    public let performance = PerformanceMonitor()

    private struct ControlState {
        var switcher = Switcher()
        var overlays: [OverlayChannel] = (1...4).map { OverlayChannel(index: $0) }
        var sources: [InputID: VideoSource] = [:]
        var order: [InputID] = []
        var layers: [InputID: [Layer]] = [:]
        var keys: [InputID: ChromaKey] = [:]
    }
    private let control = Locked(ControlState())

    private let renderQueue = DispatchQueue(label: "livecore.render", qos: .userInteractive)
    private var renderTimer: DispatchSourceTimer?
    private var clockStart: Double = 0
    private var lastFrameIndex: Int64 = -1
    private let inFlight = Locked(0)
    private var frameCounter: Int64 = 0
    public let droppedRenderFrames = AtomicCounter()
    private let gpuMsAverage = AtomicFloat(0)
    private let renderedFrames = AtomicCounter()
    private var lastFPSSample: (time: Double, frames: UInt64) = (0, 0)

    private struct Outputs {
        var streamEncoder: H264Encoder?
        var recording = false
    }
    private let outputs = Locked(Outputs())
    private var aacEncoder: AACEncoder?
    private var audioInputs: [String: AudioCaptureInput] = [:]
    private var lastSwitcher = SwitcherSnapshot()
    /// Mixer settings from a loaded project for video-file channels that appear once the file's
    /// audio track has loaded.
    private var pendingFileChannelSettings: [InputID: ProjectAudioChannel] = [:]

    public init(settings: ProductionSettings = ProductionSettings()) throws {
        self.settings = settings
        compositor = try MetalCompositor(outputSize: settings.output.size)
        mixer.onError = { [weak self] msg in DispatchQueue.main.async { self?.onError?(msg) } }
        streamer.onStats = { [weak self] s in
            // Permanent failure (not reconnecting): release the encoder and audio sink.
            if case .failed = s.state { self?.streamDidEnd() }
            self?.onStreamStats?(s)
        }
        streamer.encoderStatsProvider = { [weak self] in
            guard let enc = self?.outputs.read({ $0.streamEncoder }) else { return (false, 0) }
            return (enc.isHardwareAccelerated, enc.droppedFrames.value)
        }
        recorder.onStats = { [weak self] s in
            if case .recording = s.state {} else { self?.recordingEnded(s) }
            self?.onRecordStats?(s)
        }
    }

    // MARK: Lifecycle

    public func start() {
        mixer.start()
        startRenderLoop()
    }

    public func shutdown() {
        stopStreaming()
        stopRecording()
        renderTimer?.cancel()
        renderTimer = nil
        control.read { $0.sources.values.forEach { $0.stop() } }
        audioInputs.values.forEach { $0.stop() }
        mixer.stop()
    }

    private func startRenderLoop() {
        renderTimer?.cancel()
        let fps = Double(settings.output.frameRate)
        clockStart = HostClock.now()
        lastFrameIndex = -1
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
        // Tick at 2x frame rate; the frame index is derived from the host clock, so jitter in the
        // timer never shifts timestamps and late ticks are counted as dropped frames.
        t.schedule(deadline: .now(), repeating: 1.0 / (fps * 2), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.renderTick(fps: fps) }
        t.resume()
        renderTimer = t
    }

    // MARK: Render (render queue)

    private func renderTick(fps: Double) {
        let now = HostClock.now()
        let index = Int64(((now - clockStart) * fps).rounded(.down))
        guard index > lastFrameIndex else { return }
        if lastFrameIndex >= 0 && index > lastFrameIndex + 1 { droppedRenderFrames.add(UInt64(index - lastFrameIndex - 1)) }
        lastFrameIndex = index
        let frameHost = clockStart + Double(index) / fps

        // Snapshot control state and advance transitions.
        var events: [SwitcherEvent] = []
        let (plan, sources, order, snapshot, keys) = control.mutate { st -> (FramePlan, [InputID: VideoSource], [InputID], SwitcherSnapshot, [InputID: ChromaKey]) in
            events = st.switcher.update(now: now)
            let layers = st.layers
            let keys = st.keys.filter { $0.value.enabled }.mapValues { $0.clamped }
            let plan = FramePlanner.plan(snapshot: st.switcher.state, overlays: st.overlays, now: now,
                                         layersFor: { layers[$0] }, keyFor: { keys[$0] })
            return (plan, st.sources, st.order, st.switcher.state, keys)
        }
        if !events.isEmpty || snapshot != lastSwitcher {
            lastSwitcher = snapshot
            DispatchQueue.main.async { [weak self] in self?.onSwitcherChange?(snapshot) }
        }

        guard inFlight.mutate({ n -> Bool in if n >= 2 { return false }; n += 1; return true }) else {
            droppedRenderFrames.add()
            return
        }

        frameCounter += 1
        let thumbs: [InputID] = frameCounter % Int64(max(1, Int(fps / 10))) == 0 ? order : []   // ~10 fps thumbnails (inputs panel + multiview)
        var needed = Set<InputID>(thumbs)
        for c in plan.program + plan.overlays + plan.preview + (plan.transition?.incoming ?? []) { needed.insert(c.source) }
        var frames: [InputID: CVPixelBuffer] = [:]
        for id in needed { if let pb = sources[id]?.currentFrame() { frames[id] = pb } }

        let pts = CMTime(seconds: frameHost, preferredTimescale: 90_000)
        let ok = compositor.render(plan: plan, frames: frames, thumbnailsFor: thumbs, keys: keys) { [weak self] result in
            guard let self else { return }
            self.inFlight.mutate { $0 -= 1 }
            self.renderedFrames.add()
            let avg = self.gpuMsAverage.value
            self.gpuMsAverage.value = avg == 0 ? Float(result.gpuMs) : avg * 0.95 + Float(result.gpuMs) * 0.05
            guard let program = result.program else { self.droppedRenderFrames.add(); return }
            let outs = self.outputs.current
            outs.streamEncoder?.encode(program, pts: pts)
            if outs.recording { self.recorder.append(video: program, pts: pts) }
            let preview = result.preview
            let thumbs = result.thumbnails
            DispatchQueue.main.async {
                self.onProgramFrame?(program)
                if let preview { self.onPreviewFrame?(preview) }
                if !thumbs.isEmpty { self.onThumbnails?(thumbs) }
            }
        }
        if !ok {
            inFlight.mutate { $0 -= 1 }
            droppedRenderFrames.add()
        }
        if frameCounter % Int64(fps) == 0 { compositor.flushCache() }
    }

    // MARK: Inputs (main thread)

    public var inputs: [InputInfo] {
        control.read { st in
            st.order.enumerated().compactMap { i, id in
                guard let s = st.sources[id] else { return nil }
                return InputInfo(id: id, name: s.name, kind: s.kind, status: s.status, number: i + 1)
            }
        }
    }

    @discardableResult
    public func addCamera(uniqueID: String, id: InputID? = nil) -> InputID? {
        guard let dev = DeviceManager.device(uniqueID: uniqueID) else { onError?("Camera not found"); return nil }
        let id = id ?? InputID(UUID().uuidString)
        let src = CameraSource(id: id, device: dev, target: settings.output)
        DeviceManager.requestAccess(.video) { [weak self] ok in
            if !ok { self?.onError?("Camera access denied. Enable it in System Settings › Privacy & Security › Camera.") }
            src.start()
        }
        add(src)
        return id
    }

    @discardableResult
    public func addImage(url: URL, id: InputID? = nil) -> InputID {
        let src = ImageSource(id: id ?? InputID(UUID().uuidString), url: url)
        src.start()
        add(src)
        return src.id
    }

    @discardableResult
    public func addVideoFile(url: URL, id: InputID? = nil, loop: Bool = true) -> InputID {
        let src = VideoFileSource(id: id ?? InputID(UUID().uuidString), url: url)
        src.loop = loop
        let srcID = src.id
        // The file's audio gets its own mixer channel once AVFoundation reports an audio track.
        // AVPlayer taps deliver blocks of up to ~90 ms, so this channel buffers more than a mic.
        src.audioChannelProvider = { [weak self, weak src] in
            guard let self else { return MixerChannel.detached() }
            let ch = self.mixer.addChannel(id: Self.fileChannelID(srcID), name: src?.name ?? "Video",
                                           primeFrames: 4096, maxBufferedFrames: 14_400)
            if let saved = self.pendingFileChannelSettings.removeValue(forKey: srcID) { Self.apply(saved, to: ch.controls) }
            self.onAudioChannelsChange?()
            return ch
        }
        src.start()
        add(src)
        return src.id
    }

    /// Mixer channel id used for the audio of a video-file input.
    public static func fileChannelID(_ id: InputID) -> String { "file:\(id.raw)" }

    @discardableResult
    public func addColor(_ color: NSColor, name: String, id: InputID? = nil) -> InputID {
        let src = ColorSource(id: id ?? InputID(UUID().uuidString), color: color, name: name)
        add(src)
        return src.id
    }

    @discardableResult
    public func addTitle(_ style: TextSource.Style, id: InputID? = nil) -> InputID {
        let src = TextSource(id: id ?? InputID(UUID().uuidString), style: style, outputSize: settings.output.size)
        add(src)
        // Titles default to the lower-third area when used as a layer or overlay.
        control.mutate { $0.layers[src.id] = [Layer(source: src.id, rect: LayoutPreset.lowerThird.rect, scaleMode: .fit)] }
        return src.id
    }

    public func source(_ id: InputID) -> VideoSource? { control.read { $0.sources[id] } }

    private func add(_ src: VideoSource) {
        src.onStatusChange = { [weak self] _ in self?.publishInputs() }
        control.mutate { st in
            st.sources[src.id] = src
            st.order.append(src.id)
            st.layers[src.id] = [Layer(source: src.id)]
            if st.switcher.state.preview == nil { st.switcher.setPreview(src.id) }
        }
        publishInputs()
    }

    public func removeInput(_ id: InputID) {
        let removed: VideoSource? = control.mutate { st in
            st.switcher.inputRemoved(id)
            for i in st.overlays.indices where st.overlays[i].source == id { st.overlays[i].source = nil }
            for key in st.layers.keys { st.layers[key]?.removeAll { $0.source == id && key != id } }
            st.layers[id] = nil
            st.keys[id] = nil
            st.order.removeAll { $0 == id }
            return st.sources.removeValue(forKey: id)
        }
        removed?.stop()
        if removed is VideoFileSource {
            mixer.removeChannel(id: Self.fileChannelID(id))
            onAudioChannelsChange?()
        }
        publishInputs()
    }

    public func renameInput(_ id: InputID, to name: String) {
        control.read { $0.sources[id] }?.name = name
        publishInputs()
    }

    public func moveInput(from: IndexSet, to: Int) {
        control.mutate { st in
            let moving = from.map { st.order[$0] }
            var rest = st.order.enumerated().filter { !from.contains($0.offset) }.map(\.element)
            let insertAt = min(to - from.filter { $0 < to }.count, rest.count)
            rest.insert(contentsOf: moving, at: insertAt)
            st.order = rest
        }
        publishInputs()
    }

    private func publishInputs() {
        let list = inputs
        DispatchQueue.main.async { self.onInputsChange?(list) }
    }

    // MARK: Scene layers (basic composition / PiP on an input)

    public func layers(of id: InputID) -> [Layer] { control.read { $0.layers[id] ?? [] } }

    public func addLayer(to id: InputID, source: InputID, preset: LayoutPreset) {
        control.mutate { st in
            guard st.sources[id] != nil, st.sources[source] != nil, id != source else { return }
            st.layers[id, default: [Layer(source: id)]].append(Layer(source: source, rect: preset.rect, scaleMode: .fill))
        }
    }

    /// Replaces the scene layers of an input (scene editor). Layer 0 must remain the input itself;
    /// layers pointing at unknown inputs are dropped.
    public func setLayers(_ layers: [Layer], of id: InputID) {
        control.mutate { st in
            guard st.sources[id] != nil else { return }
            var l = layers.filter { $0.source != id && st.sources[$0.source] != nil }
            let base = layers.first(where: { $0.source == id }) ?? Layer(source: id)
            l.insert(base, at: 0)
            st.layers[id] = l
        }
    }

    /// Pixel size of an input's current frame (nil until it has produced one).
    public func frameSize(of id: InputID) -> PixelSize? {
        guard let src = source(id) else { return nil }
        // Video files: read the cached frame; pulling from AVPlayerItemVideoOutput is the render queue's job.
        guard let pb = (src as? VideoFileSource)?.lastFrame() ?? src.currentFrame() else { return nil }
        return PixelSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
    }

    public func removeLayer(from id: InputID, at index: Int) {
        control.mutate { st in
            guard var l = st.layers[id], index > 0, index < l.count else { return } // layer 0 = the input itself
            l.remove(at: index)
            st.layers[id] = l
        }
    }

    // MARK: Chroma key

    public func chromaKey(of id: InputID) -> ChromaKey { control.read { $0.keys[id] } ?? ChromaKey() }

    public func setChromaKey(_ key: ChromaKey, for id: InputID) {
        control.mutate { st in
            guard st.sources[id] != nil else { return }
            st.keys[id] = key.clamped
        }
    }

    // MARK: Switching (main thread)

    public var switcherState: SwitcherSnapshot { control.read { $0.switcher.state } }

    public func setPreview(_ id: InputID?) { control.mutate { _ = $0.switcher.setPreview(id) } }
    public func cut() { control.mutate { _ = $0.switcher.cut() } }
    public func auto() {
        let kind = settings.transition, dur = settings.transitionDuration
        control.mutate { _ = $0.switcher.auto(kind: kind, duration: dur, now: HostClock.now()) }
    }
    public func setTBar(_ position: Double) {
        let kind = settings.transition
        control.mutate { _ = $0.switcher.setTBar(position, kind: kind, now: HostClock.now()) }
    }
    /// "Quick play": cut a specific input straight to program.
    public func cutDirect(_ id: InputID) {
        control.mutate { st in _ = st.switcher.setPreview(id); _ = st.switcher.cut() }
    }

    public func setTransition(_ kind: TransitionKind, duration: Double) {
        settings.transition = kind
        settings.transitionDuration = min(max(duration, 0.1), 10)
    }

    // MARK: Overlays

    public var overlays: [OverlayChannel] { control.read { $0.overlays } }

    public func configureOverlay(_ index: Int, source: InputID?, preset: LayoutPreset) {
        control.mutate { st in
            guard let i = st.overlays.firstIndex(where: { $0.index == index }) else { return }
            st.overlays[i].source = source
            st.overlays[i].preset = preset
        }
    }

    public func setOverlay(_ index: Int, on: Bool) {
        let now = HostClock.now()
        control.mutate { st in
            guard let i = st.overlays.firstIndex(where: { $0.index == index }), st.overlays[i].source != nil else { return }
            st.overlays[i].set(on: on, now: now)
        }
    }

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
        return o.streamEncoder != nil || o.recording
    }

    /// Applies settings. Output resolution/frame rate changes require all outputs to be stopped.
    @discardableResult
    public func apply(_ new: ProductionSettings) -> [String] {
        let errs = new.validationErrors()
        guard errs.isEmpty else { return errs }
        let formatChanged = new.output != settings.output
        if formatChanged && isOutputActive { return ["Stop streaming and recording before changing resolution or frame rate."] }
        settings = new
        if formatChanged {
            renderQueue.sync { compositor.configure(outputSize: new.output.size) }
            startRenderLoop()
        }
        return []
    }

    // MARK: Streaming

    public func startStreaming(streamKey: String) throws {
        guard outputs.read({ $0.streamEncoder }) == nil else { return }
        let url = try RTMPURL.parse(serverURL: settings.stream.serverURL, streamKey: streamKey)
        let errs = settings.validationErrors()
        if !errs.isEmpty { throw NSError(domain: "LiveCore", code: 10, userInfo: [NSLocalizedDescriptionKey: errs.joined(separator: "\n")]) }
        let enc = try H264Encoder(size: settings.output.size, frameRate: settings.output.frameRate, settings: settings.video)
        let aac = try AACEncoder(sampleRate: Double(settings.audio.sampleRate), channels: settings.audio.channels,
                                 bitrateKbps: settings.audio.bitrateKbps)
        aacEncoder = aac
        let streamer = self.streamer
        enc.onFrame = { [weak streamer] f in streamer?.send(video: f) }
        streamer.onRequestKeyframe = { [weak enc] in enc?.requestKeyframe() }
        // AAC timestamps: Apple's AAC encoder has 2112 samples of priming delay. Output packet k
        // carries audio that started at firstHost + (k*1024 - 2112)/sr; stamping it that way keeps
        // lip-sync exact in FLV, which cannot signal priming.
        var firstHost: Double?
        var packetIndex: Int64 = 0
        let sr = Double(settings.audio.sampleRate)
        audioPump.addSink("stream") { [weak streamer] chunk in
            if firstHost == nil { firstHost = chunk.hostTime }
            guard let data = try? aac.encode(chunk), let base = firstHost else { return }
            let t = base + (Double(packetIndex) * 1024 - Double(AACEncoder.primingFrames)) / sr
            packetIndex += 1
            streamer?.send(audio: data, pts: CMTime(seconds: t, preferredTimescale: 48_000))
        }
        outputs.mutate { $0.streamEncoder = enc }
        streamer.start(url: url, settings: settings, audioSpecificConfig: aac.audioSpecificConfig)
    }

    public func stopStreaming() {
        streamer.stop()
        audioPump.removeSink("stream")
        let enc: H264Encoder? = outputs.mutate { o in let e = o.streamEncoder; o.streamEncoder = nil; return e }
        renderQueue.async { enc?.invalidate() }
        aacEncoder = nil
    }

    /// Called when the stream fails permanently (not while reconnecting) to release the encoder.
    public func streamDidEnd() {
        let enc: H264Encoder? = outputs.mutate { o in let e = o.streamEncoder; o.streamEncoder = nil; return e }
        audioPump.removeSink("stream")
        renderQueue.async { enc?.invalidate() }
    }

    // MARK: Recording

    public func startRecording() {
        guard !outputs.read({ $0.recording }) else { return }
        recorder.start(settings: settings.recording, output: settings.output, audio: settings.audio)
        outputs.mutate { $0.recording = true }
        let recorder = self.recorder
        audioPump.addSink("record") { [weak recorder] chunk in recorder?.append(audio: chunk) }
    }

    public func stopRecording() {
        guard outputs.read({ $0.recording }) else { return }
        recorder.stop()
        outputs.mutate { $0.recording = false }
        audioPump.removeSink("record")
    }

    private func recordingEnded(_ s: RecordingEngine.Stats) {
        switch s.state {
        case .failed, .finished, .idle:
            if outputs.read({ $0.recording }) {
                outputs.mutate { $0.recording = false }
                audioPump.removeSink("record")
            }
        default: break
        }
    }

    // MARK: Stats

    public func samplePerformance() -> PerformanceSnapshot {
        let now = HostClock.now()
        let frames = renderedFrames.value
        let fps = lastFPSSample.time > 0 ? Double(frames - lastFPSSample.frames) / max(now - lastFPSSample.time, 0.001) : 0
        lastFPSSample = (now, frames)
        return performance.sample(gpuFrameMs: Double(gpuMsAverage.value), renderFPS: fps, dropped: droppedRenderFrames.value)
    }
}

// MARK: - Project save / load

extension ProductionEngine {
    /// Snapshot of the current production as a project document. Media paths are also stored
    /// relative to `projectDirectory` so a copied project folder still finds its files.
    public func exportProject(projectDirectory: URL?) -> ProjectDocument {
        let (order, sources, layers, keys, overlays, sw) = control.read { st in
            (st.order, st.sources, st.layers, st.keys, st.overlays, st.switcher.state)
        }
        var doc = ProjectDocument(settings: settings)
        func rel(_ url: URL) -> String? {
            guard let dir = projectDirectory else { return nil }
            return ProjectPaths.relative(file: url.standardizedFileURL.path, toDirectory: dir.standardizedFileURL.path)
        }
        for id in order {
            guard let src = sources[id] else { continue }
            let ps: ProjectSource
            switch src {
            case let c as CameraSource: ps = .camera(uniqueID: c.deviceUniqueID, deviceName: c.name)
            case let v as VideoFileSource: ps = .videoFile(path: v.url.path, relativePath: rel(v.url), loop: v.loop)
            case let i as ImageSource: ps = .image(path: i.url.path, relativePath: rel(i.url))
            case let c as ColorSource: ps = .color(ProjectColor(c.color))
            case let t as TextSource: ps = .title(ProjectTitleStyle(t.style))
            default: continue
            }
            let key = keys[id]
            doc.inputs.append(ProjectInput(id: id, name: src.name, source: ps, layers: layers[id] ?? [],
                                           chromaKey: key == ChromaKey() ? nil : key))
        }
        doc.overlays = overlays.map { ProjectOverlay(index: $0.index, source: $0.source, preset: $0.preset, fadeDuration: $0.fadeDuration) }
        doc.previewInput = sw.transition == nil ? sw.preview : sw.transition?.from
        doc.programInput = sw.transition?.to ?? sw.program
        doc.audio.masterFaderDB = mixer.master.faderDB.value
        doc.audio.limiterEnabled = mixer.limiterEnabled.value
        doc.audio.monitorVolume = mixer.monitorVolume.value
        doc.audio.syncOffsetMs = Double(audioPump.syncOffsetSeconds.value) * 1000
        for ch in mixer.channelList {
            let isFile = ch.id.hasPrefix("file:")
            var p = ProjectAudioChannel(deviceUniqueID: isFile ? nil : ch.id,
                                        inputID: isFile ? InputID(String(ch.id.dropFirst(5))) : nil, name: ch.name)
            let c = ch.controls
            p.faderDB = c.faderDB.value; p.gainDB = c.gainDB.value; p.pan = c.pan.value
            p.muted = c.muted.value; p.toProgram = c.toProgram.value
            p.compressorEnabled = c.compressorEnabled.value; p.compThresholdDB = c.compThresholdDB.value; p.compRatio = c.compRatio.value
            p.gateEnabled = c.gateEnabled.value; p.gateThresholdDB = c.gateThresholdDB.value
            var eq = ProjectEQ()
            eq.highPassEnabled = c.highPassEnabled.value; eq.highPassHz = c.highPassHz.value
            eq.eqEnabled = c.eqEnabled.value
            eq.lowDB = c.eqLowDB.value; eq.midDB = c.eqMidDB.value; eq.midHz = c.eqMidHz.value; eq.highDB = c.eqHighDB.value
            p.eq = eq
            doc.audio.channels.append(p)
        }
        return doc
    }

    /// Replaces the current production with `document`. Returns warnings for anything that could
    /// not be restored (camera or audio device not connected, missing media file, format locked
    /// while an output is running...). Never throws away the stream key: it is not in projects.
    @discardableResult
    public func loadProject(_ document: ProjectDocument, projectDirectory: URL?) -> [String] {
        var warnings = document.validationIssues()
        let doc = document.sanitized()

        for info in inputs { removeInput(info.id) }
        for uid in Array(audioInputs.keys) { removeAudioInput(uniqueID: uid) }
        pendingFileChannelSettings = [:]

        warnings += apply(doc.settings)

        func mediaURL(_ path: String, _ relative: String?) -> URL {
            let fm = FileManager.default
            if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            if let relative, let dir = projectDirectory {
                let candidate = ProjectPaths.resolve(relative, againstDirectory: dir.standardizedFileURL.path)
                if fm.fileExists(atPath: candidate) { return URL(fileURLWithPath: candidate) }
            }
            warnings.append("Media file not found: \(path)")
            return URL(fileURLWithPath: path)
        }

        var created = Set<InputID>()
        for pi in doc.inputs {
            switch pi.source {
            case let .camera(uid, deviceName):
                guard DeviceManager.device(uniqueID: uid) != nil, addCamera(uniqueID: uid, id: pi.id) != nil else {
                    warnings.append("Camera \"\(deviceName)\" is not connected; input \"\(pi.name)\" was skipped.")
                    continue
                }
            case let .videoFile(path, relative, loop):
                addVideoFile(url: mediaURL(path, relative), id: pi.id, loop: loop)
            case let .image(path, relative):
                addImage(url: mediaURL(path, relative), id: pi.id)
            case let .color(c):
                addColor(c.nsColor, name: pi.name, id: pi.id)
            case let .title(t):
                addTitle(t.textStyle, id: pi.id)
            }
            created.insert(pi.id)
            renameInput(pi.id, to: pi.name)
        }

        control.mutate { st in
            for pi in doc.inputs where created.contains(pi.id) {
                let layers = pi.layers.filter { created.contains($0.source) }
                st.layers[pi.id] = layers.isEmpty ? [Layer(source: pi.id)] : layers
                if let k = pi.chromaKey { st.keys[pi.id] = k.clamped }
            }
            st.overlays = (1...4).map { OverlayChannel(index: $0) }
            for o in doc.overlays {
                guard let i = st.overlays.firstIndex(where: { $0.index == o.index }) else { continue }
                let src = o.source.flatMap { created.contains($0) ? $0 : nil }
                st.overlays[i] = OverlayChannel(index: o.index, source: src, preset: o.preset, fadeDuration: o.fadeDuration)
            }
            st.switcher = Switcher()
            if let p = doc.programInput, created.contains(p) { st.switcher.setPreview(p); st.switcher.cut() }
            st.switcher.setPreview(doc.previewInput.flatMap { created.contains($0) ? $0 : nil })
        }

        mixer.master.faderDB.value = doc.audio.masterFaderDB
        mixer.limiterEnabled.value = doc.audio.limiterEnabled
        mixer.monitorVolume.value = doc.audio.monitorVolume
        audioPump.syncOffsetSeconds.value = Float(doc.audio.syncOffsetMs / 1000)
        for ch in doc.audio.channels {
            if let uid = ch.deviceUniqueID {
                guard DeviceManager.device(uniqueID: uid) != nil else {
                    warnings.append("Audio device \"\(ch.name)\" is not connected; its mixer channel was skipped.")
                    continue
                }
                addAudioInput(uniqueID: uid)
                if let mc = mixer.channelList.first(where: { $0.id == uid }) { Self.apply(ch, to: mc.controls) }
            } else if let iid = ch.inputID, created.contains(iid) {
                if let mc = mixer.channelList.first(where: { $0.id == Self.fileChannelID(iid) }) { Self.apply(ch, to: mc.controls) }
                else { pendingFileChannelSettings[iid] = ch }
            }
        }
        onAudioChannelsChange?()
        publishInputs()
        return warnings
    }

    static func apply(_ p: ProjectAudioChannel, to c: ChannelControls) {
        c.faderDB.value = p.faderDB; c.gainDB.value = p.gainDB; c.pan.value = p.pan
        c.muted.value = p.muted; c.toProgram.value = p.toProgram
        c.compressorEnabled.value = p.compressorEnabled; c.compThresholdDB.value = p.compThresholdDB; c.compRatio.value = p.compRatio
        c.gateEnabled.value = p.gateEnabled; c.gateThresholdDB.value = p.gateThresholdDB
        if let eq = p.eq {
            c.highPassEnabled.value = eq.highPassEnabled; c.highPassHz.value = eq.highPassHz
            c.eqEnabled.value = eq.eqEnabled
            c.eqLowDB.value = eq.lowDB; c.eqMidDB.value = eq.midDB; c.eqMidHz.value = eq.midHz; c.eqHighDB.value = eq.highDB
        }
    }
}

extension ProjectColor {
    public init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }
    public var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
}

extension ProjectTitleStyle {
    public init(_ s: TextSource.Style) {
        self.init(title: s.title, subtitle: s.subtitle, showBar: s.showBar,
                  textColor: ProjectColor(s.textColor), barColor: ProjectColor(s.barColor))
        titleSize = Double(s.titleSize)
        subtitleSize = Double(s.subtitleSize)
        layout = s.layout.rawValue
    }
    public var textStyle: TextSource.Style {
        var s = TextSource.Style(title: title, subtitle: subtitle)
        s.showBar = showBar
        s.textColor = textColor.nsColor
        s.barColor = barColor.nsColor
        if let titleSize { s.titleSize = CGFloat(titleSize) }
        if let subtitleSize { s.subtitleSize = CGFloat(subtitleSize) }
        if let layout, let l = TextSource.Layout(rawValue: layout) { s.layout = l }
        return s
    }
}

extension AACEncoder {
    /// Encoder delay of Apple's AAC-LC encoder (samples), see Apple TN2258.
    public static let primingFrames = 2112
}
#endif

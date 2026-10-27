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
        /// Locked inputs cannot be closed, renamed or edited from the UI (protection on air).
        public var locked: Bool = false
    }

    // MARK: Callbacks (main thread)
    public var onProgramFrame: ((CVPixelBuffer) -> Void)?
    public var onPreviewFrame: ((CVPixelBuffer) -> Void)?
    public var onThumbnails: (([InputID: CVPixelBuffer]) -> Void)?
    /// Full-size picture of `detailInput` (per-input viewer). Main thread.
    public var onDetailFrame: ((InputID, CVPixelBuffer) -> Void)?
    public var onSwitcherChange: ((SwitcherSnapshot) -> Void)?
    public var onInputsChange: (([InputInfo]) -> Void)?
    /// Statistics of one stream destination (destination id, stats). Main thread.
    public var onStreamStats: ((String, StreamingEngine.Stats) -> Void)?
    public var onRecordStats: ((RecordingEngine.Stats) -> Void)?
    public var onError: ((String) -> Void)?
    /// Mixer channels were added or removed by the engine itself (e.g. a video file's audio).
    public var onAudioChannelsChange: (() -> Void)?

    public private(set) var settings: ProductionSettings
    public let compositor: MetalCompositor
    public let mixer = AudioMixerEngine()
    public let devices = DeviceManager()
    public private(set) lazy var audioPump = ProgramAudioPump(mixer: mixer)
    /// One RTMP/RTMPS publisher per destination, all fed by the same encoders. Main thread.
    public private(set) var streamers: [String: StreamingEngine] = [:]
    private var streamTerminal: [String: Bool] = [:]
    public let recorder = RecordingEngine()
    /// Instant replay buffer and its input (nil while replay is off).
    public let replay = ReplayRecorder()
    public private(set) var replaySource: ReplaySource?
    public var onReplayChange: (() -> Void)?
    /// Music inputs (audio-file playlists), each with its own mixer channel. Main thread.
    public private(set) var musicPlayers: [MusicInput] = []
    public private(set) var tones: [TestTone] = []
    public static let toneChannelPrefix = "tone:"
    public var onMusicChange: (() -> Void)?
    public static let musicChannelPrefix = "music:"
    public let performance = PerformanceMonitor()

    private struct ControlState {
        var switcher = Switcher()
        var overlays: [OverlayChannel] = (1...4).map { OverlayChannel(index: $0) }
        var sources: [InputID: VideoSource] = [:]
        var order: [InputID] = []
        var layers: [InputID: [Layer]] = [:]
        var keys: [InputID: ChromaKey] = [:]
        var locked: Set<InputID> = []
        /// Colour correction / flips per input (identity entries are not stored).
        var adjusts: [InputID: InputAdjust] = [:]
        /// Input shown in the per-input viewer window, rendered at full size every frame.
        var detail: InputID?
        var stinger = StingerConfig()
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
        var replay = false
    }
    private let outputs = Locked(Outputs())
    private var aacEncoders: [AACEncoder] = []
    private var audioInputs: [String: AudioCaptureInput] = [:]
    private var lastSwitcher = SwitcherSnapshot()
    /// Mixer settings from a loaded project for video-file channels that appear once the file's
    /// audio track has loaded.
    private var pendingFileChannelSettings: [InputID: ProjectAudioChannel] = [:]

    public init(settings: ProductionSettings = ProductionSettings()) throws {
        self.settings = settings
        compositor = try MetalCompositor(outputSize: settings.output.size)
        mixer.onError = { [weak self] msg in DispatchQueue.main.async { self?.onError?(msg) } }
        recorder.onStats = { [weak self] s in
            if case .recording = s.state {} else { self?.recordingEnded(s) }
            self?.onRecordStats?(s)
        }
    }

    // MARK: Lifecycle

    public func start() {
        if let id = settings.customTransition, let err = setCustomTransition(id) {
            onError?("Custom transition: \(err)")
        }
        mixer.start()
        startRenderLoop()
    }

    public func shutdown() {
        stopStreaming()
        stopRecording()
        renderTimer?.cancel()
        renderTimer = nil
        control.read { $0.sources.values.forEach { $0.stop() } }
        musicPlayers.forEach { $0.stop() }
        tones.forEach { $0.stop() }
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
        frameCounter += 1
        let thumbTick = frameCounter % Int64(max(1, Int(fps / 10))) == 0   // ~10 fps thumbnails (inputs panel + multiview)
        let (plan, sources, snapshot, adjusts) = control.mutate { st -> (FramePlan, [InputID: VideoSource], SwitcherSnapshot, [InputID: InputAdjust]) in
            events = st.switcher.update(now: now)
            let layers = st.layers
            let keys = st.keys.filter { $0.value.enabled }.mapValues { $0.clamped }
            let plan = FramePlanner.plan(snapshot: st.switcher.state, overlays: st.overlays, now: now,
                                         layersFor: { layers[$0] }, keyFor: { keys[$0] },
                                         thumbnailsFor: thumbTick ? st.order : [],
                                         composedThumbnails: thumbTick ? Set(st.sources.filter { $0.value is SceneSource }.keys) : [],
                                         detailInput: st.detail)
            return (plan, st.sources, st.switcher.state, st.adjusts)
        }
        if !events.isEmpty || snapshot != lastSwitcher {
            lastSwitcher = snapshot
            DispatchQueue.main.async { [weak self] in
                self?.applyAutoPlay()
                self?.onSwitcherChange?(snapshot)
            }
        }

        guard inFlight.mutate({ n -> Bool in if n >= 2 { return false }; n += 1; return true }) else {
            droppedRenderFrames.add()
            return
        }

        var needed = Set<InputID>()
        for c in plan.program + plan.overlays + plan.preview + (plan.transition?.incoming ?? []) + (plan.detail ?? []) { needed.insert(c.source) }
        for list in plan.thumbnails.values { for c in list { needed.insert(c.source) } }
        if let s = plan.stinger { needed.insert(s.source) }
        var frames: [InputID: CVPixelBuffer] = [:]
        for id in needed { if let pb = sources[id]?.currentFrame() { frames[id] = pb } }

        let pts = CMTime(seconds: frameHost, preferredTimescale: 90_000)
        let detailID = plan.detail == nil ? nil : control.read { $0.detail }
        let ok = compositor.render(plan: plan, frames: frames, adjusts: adjusts) { [weak self] result in
            guard let self else { return }
            self.inFlight.mutate { $0 -= 1 }
            self.renderedFrames.add()
            let avg = self.gpuMsAverage.value
            self.gpuMsAverage.value = avg == 0 ? Float(result.gpuMs) : avg * 0.95 + Float(result.gpuMs) * 0.05
            guard let program = result.program else { self.droppedRenderFrames.add(); return }
            let outs = self.outputs.current
            outs.streamEncoder?.encode(program, pts: pts)
            if outs.recording { self.recorder.append(video: program, pts: pts) }
            if outs.replay { self.replay.append(program, hostTime: pts.seconds) }
            let preview = result.preview
            let thumbs = result.thumbnails
            let detail = result.detail
            DispatchQueue.main.async {
                if let detail, let detailID { self.onDetailFrame?(detailID, detail) }
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
                return InputInfo(id: id, name: s.name, kind: s.kind, status: s.status, number: i + 1,
                                 locked: st.locked.contains(id))
            }
        }
    }

    @discardableResult
    public func addCamera(uniqueID: String, id: InputID? = nil, config: CaptureConfig = CaptureConfig()) -> InputID? {
        guard let dev = DeviceManager.device(uniqueID: uniqueID) else { onError?("Camera not found"); return nil }
        let id = id ?? InputID(UUID().uuidString)
        let src = CameraSource(id: id, device: dev, target: settings.output, config: config)
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
        addVideoFile(urls: [url], id: id, loop: loop)
    }

    /// A video input; several URLs make a playlist played in order.
    @discardableResult
    public func addVideoFile(urls: [URL], id: InputID? = nil, loop: Bool = true, autoPlay: VideoFileSource.AutoPlay = .off) -> InputID {
        let src = VideoFileSource(id: id ?? InputID(UUID().uuidString), urls: urls)
        src.loop = loop
        src.autoPlay = autoPlay
        let srcID = src.id
        // The file's audio gets its own mixer channel once AVFoundation reports an audio track.
        // AVPlayer taps deliver blocks of up to ~90 ms, so this channel buffers more than a mic.
        src.audioChannelProvider = { [weak self, weak src] in
            guard let self else { return MixerChannel.detached() }
            let ch = self.mixer.addChannel(id: Self.fileChannelID(srcID), name: src?.name ?? "Video",
                                           primeFrames: 4096, maxBufferedFrames: 14_400)
            if let saved = self.pendingFileChannelSettings.removeValue(forKey: srcID) { self.restore(saved, to: ch) }
            self.applyAFV()
            self.onAudioChannelsChange?()
            return ch
        }
        src.start()
        add(src)
        return src.id
    }

    /// Adds a test tone generator (1 kHz, -18 dBFS by default) in its own mixer channel.
    @discardableResult
    public func addTone(frequency: Double = 1000, levelDB: Double = -18, id: String? = nil, name: String = "Tone") -> TestTone {
        let tid = id ?? String(UUID().uuidString.prefix(8)).lowercased()
        let ch = mixer.addChannel(id: Self.toneChannelPrefix + tid, name: name)
        let t = TestTone(id: tid, channel: ch, frequency: frequency, levelDB: levelDB)
        t.start()
        tones.append(t)
        onAudioChannelsChange?()
        return t
    }

    public func removeTone(id: String) {
        guard let i = tones.firstIndex(where: { $0.id == id }) else { return }
        tones.remove(at: i).stop()
        mixer.removeChannel(id: Self.toneChannelPrefix + id)
        afvLinks[Self.toneChannelPrefix + id] = nil
        onAudioChannelsChange?()
    }

    public func tone(channelID: String) -> TestTone? {
        guard channelID.hasPrefix(Self.toneChannelPrefix) else { return nil }
        return tones.first { Self.toneChannelPrefix + $0.id == channelID }
    }

    /// Adds a music input playing `urls` into a new mixer channel (paused until Play).
    @discardableResult
    public func addMusic(urls: [URL], name: String? = nil, id: String? = nil) -> MusicInput {
        let mid = id ?? String(UUID().uuidString.prefix(8)).lowercased()
        let title = name ?? (urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Music")
        // Same buffering as video-file audio: AVPlayer taps deliver large blocks.
        let ch = mixer.addChannel(id: Self.musicChannelPrefix + mid, name: title, primeFrames: 4096, maxBufferedFrames: 14_400)
        let m = MusicInput(id: mid, name: title, tracks: urls, channel: ch)
        m.onChange = { [weak self] in self?.onMusicChange?() }
        musicPlayers.append(m)
        onAudioChannelsChange?()
        onMusicChange?()
        return m
    }

    public func removeMusic(id: String) {
        guard let i = musicPlayers.firstIndex(where: { $0.id == id }) else { return }
        let m = musicPlayers.remove(at: i)
        m.stop()
        mixer.removeChannel(id: Self.musicChannelPrefix + id)
        onAudioChannelsChange?()
        onMusicChange?()
    }

    public func musicPlayer(channelID: String) -> MusicInput? {
        guard channelID.hasPrefix(Self.musicChannelPrefix) else { return nil }
        return musicPlayers.first { Self.musicChannelPrefix + $0.id == channelID }
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
    public func addColorBars(id: InputID? = nil, name: String = "Colour Bars") -> InputID {
        let src = ColorBarsSource(id: id ?? InputID(UUID().uuidString), size: settings.output.size, name: name)
        add(src)
        return src.id
    }

    /// Empty scene: a transparent canvas to build a layout on (layers added in the scene editor).
    @discardableResult
    public func addScene(name: String, id: InputID? = nil) -> InputID {
        let src = SceneSource(id: id ?? InputID(UUID().uuidString), name: name)
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

    /// Web page input. Titles-like default placement: full screen (overlay pages are made for it).
    @discardableResult
    public func addBrowser(_ config: ProjectBrowser, id: InputID? = nil) -> InputID {
        var c = config
        c.fps = BrowserURLPolicy.clampFPS(c.fps)
        let src = BrowserSource(id: id ?? InputID(UUID().uuidString), config: c)
        add(src)
        src.start()
        return src.id
    }

    /// Window/display capture (Zoom, Teams...). Its audio, when captured, gets a mixer channel.
    @discardableResult
    public func addScreenCapture(_ config: ProjectScreenCapture, id: InputID? = nil) -> InputID {
        var c = config
        c.fps = ProjectScreenCapture.clampFPS(c.fps)
        let src = ScreenCaptureSource(id: id ?? InputID(UUID().uuidString), config: c)
        let srcID = src.id
        src.audioChannelProvider = { [weak self, weak src] in
            guard let self else { return MixerChannel.detached() }
            let chID = Self.screenChannelID(srcID)
            if let existing = self.mixer.channelList.first(where: { $0.id == chID }) { return existing }
            let ch = self.mixer.addChannel(id: chID, name: src?.name ?? "Capture", primeFrames: 2048, maxBufferedFrames: 9600)
            if let saved = self.pendingFileChannelSettings.removeValue(forKey: srcID) { self.restore(saved, to: ch) }
            self.applyAFV()
            self.onAudioChannelsChange?()
            return ch
        }
        add(src)
        src.start()
        return src.id
    }

    public static func screenChannelID(_ id: InputID) -> String { "screen:\(id.raw)" }

    /// The input a mixer channel belongs to (video file or capture audio), nil for devices/music.
    public static func inputOfChannel(_ channelID: String) -> InputID? {
        for prefix in ["file:", "screen:"] where channelID.hasPrefix(prefix) { return InputID(String(channelID.dropFirst(prefix.count))) }
        return nil
    }

    @discardableResult
    public func addTimer(_ config: TimerConfig, id: InputID? = nil) -> InputID {
        let src = TimerSource(id: id ?? InputID(UUID().uuidString), config: config, outputSize: settings.output.size)
        add(src)
        src.start()
        control.mutate { $0.layers[src.id] = [Layer(source: src.id, rect: TimerSource.defaultRect, scaleMode: .fit)] }
        return src.id
    }

    /// Running-text band; placed at the bottom of the picture when used as a layer or overlay.
    @discardableResult
    public func addTicker(_ config: TickerConfig, id: InputID? = nil) -> InputID {
        let src = TickerSource(id: id ?? InputID(UUID().uuidString), config: config, outputSize: settings.output.size)
        add(src)
        src.start()
        control.mutate { $0.layers[src.id] = [Layer(source: src.id, rect: config.layerRect, scaleMode: .fit)] }
        return src.id
    }

    @discardableResult
    public func addSlideshow(urls: [URL], interval: Double, fade: Double, loop: Bool, kenBurns: Bool = false,
                             folder: URL? = nil, id: InputID? = nil) -> InputID {
        let src = SlideshowSource(id: id ?? InputID(UUID().uuidString), urls: urls, interval: interval, fade: fade,
                                  loop: loop, kenBurns: kenBurns, folder: folder, outputSize: settings.output.size)
        add(src)
        src.start()
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
            st.locked.remove(id)
            st.adjusts[id] = nil
            if st.detail == id { st.detail = nil }
            if st.stinger.source == id { st.stinger.source = nil }
            st.order.removeAll { $0 == id }
            return st.sources.removeValue(forKey: id)
        }
        removed?.stop()
        if let r = removed, r === replaySource { replayRemoved() }
        if removed is VideoFileSource || removed is ScreenCaptureSource {
            mixer.removeChannel(id: Self.fileChannelID(id))
            mixer.removeChannel(id: Self.screenChannelID(id))
            onAudioChannelsChange?()
        }
        // Channels that followed this input are no longer gated.
        afvLinks = afvLinks.filter { $0.value != id && Self.inputOfChannel($0.key) != id }
        applyAFV()
        publishInputs()
    }

    /// New format / options for a camera or capture-card input (applied without removing it).
    public func updateCamera(_ id: InputID, config: CaptureConfig) {
        (source(id) as? CameraSource)?.apply(config)
    }

    public func setInputLocked(_ id: InputID, _ locked: Bool) {
        control.mutate { st in
            guard st.sources[id] != nil else { return }
            if locked { st.locked.insert(id) } else { st.locked.remove(id) }
        }
        publishInputs()
    }

    /// Colour correction and flips of an input (applied live).
    public func setAdjust(_ id: InputID, _ adjust: InputAdjust) {
        control.mutate { st in st.adjusts[id] = adjust.isIdentity ? nil : adjust.clamped }
    }
    public func adjust(of id: InputID) -> InputAdjust { control.read { $0.adjusts[id] } ?? InputAdjust() }

    /// Input rendered at full size for the per-input viewer (nil = none).
    public func setDetailInput(_ id: InputID?) { control.mutate { $0.detail = id } }

    public func isInputLocked(_ id: InputID) -> Bool { control.read { $0.locked.contains(id) } }

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
        // Rotated 90° / 270° inputs are composited with width and height swapped.
        let r = adjust(of: id).outputSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        return PixelSize(width: r.width, height: r.height)
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
    public func cut() {
        let now = HostClock.now()
        control.mutate { st in
            _ = st.switcher.cut()
            for i in st.overlays.indices { st.overlays[i].takeToProgram(now: now) }
        }
        applyAutoPlay()
    }
    public func auto() {
        let kind = settings.transition, dur = settings.transitionDuration
        var stinger: StingerParams?
        if kind == .stinger {
            guard !control.read({ $0.switcher.isTransitioning }) else { return }
            let cfg = self.stinger
            guard let id = cfg.source, let clip = source(id) as? VideoFileSource else {
                onError?("Stinger: choose a video file input as the stinger clip first (transition settings).")
                return
            }
            guard let p = cfg.params(clipDuration: clip.duration ?? 0) else {
                onError?("Stinger: \"\(clip.name)\" is not ready yet or has no duration.")
                return
            }
            stinger = p
            clip.restart()
        }
        let now = HostClock.now()
        control.mutate { st in
            _ = st.switcher.auto(kind: kind, duration: dur, now: now, stinger: stinger)
            // Overlays waiting on Preview go to Program together with the transition.
            if st.switcher.isTransitioning { for i in st.overlays.indices { st.overlays[i].takeToProgram(now: now) } }
        }
        applyAutoPlay()
    }
    public func setTBar(_ position: Double) {
        let kind = settings.transition
        let now = HostClock.now()
        control.mutate { st in
            _ = st.switcher.setTBar(position, kind: kind, now: now)
            if st.switcher.isTransitioning { for i in st.overlays.indices { st.overlays[i].takeToProgram(now: now) } }
        }
    }
    /// "Quick play": cut a specific input straight to program.
    public func cutDirect(_ id: InputID) {
        control.mutate { st in _ = st.switcher.setPreview(id); _ = st.switcher.cut() }
    }

    // MARK: Auto play (vMix-style)

    private var autoPlayOnAir = Set<InputID>()
    private var onAirInputs = Set<InputID>()

    // MARK: Audio follow video (vMix AFV)

    /// Mixer channel id -> the input it follows. Main thread.
    public private(set) var afvLinks: [String: InputID] = [:]

    /// Links a mixer channel to an input (nil = off): the channel is heard only while that
    /// input is on air (Program, transition, scene layer or on-air overlay).
    public func setAudioFollowVideo(channelID: String, input: InputID?) {
        afvLinks[channelID] = input
        applyAutoPlay()   // recomputes what is on air, then applies AFV
    }

    private func applyAFV() {
        let (sw, layers, overlays) = control.read { ($0.switcher.state, $0.layers, $0.overlays) }
        let heard = OnAir.audioInputs(switcher: sw, layers: layers, overlays: overlays)
        let fade = Float(OnAir.audioFadeSeconds(switcher: sw))
        for ch in mixer.channelList {
            let open = OnAir.audioOpen(link: afvLinks[ch.id], visible: heard)
            if ch.controls.afvClosed.value == open {
                ch.controls.afvFadeSeconds.value = fade
                ch.controls.afvClosed.value = !open
            }
        }
    }

    /// Starts video inputs set to auto play when they become visible on Program (directly, as a
    /// scene layer, as an on-air overlay or as either side of a transition) and pauses them when
    /// they leave. Main thread.
    public func applyAutoPlay() {
        let (sw, layers, overlays, sources, stingerID) = control.read { st in
            (st.switcher.state, st.layers, st.overlays, st.sources, st.stinger.source)
        }
        let visible = OnAir.visibleInputs(switcher: sw, layers: layers, overlays: overlays)
        onAirInputs = visible
        applyAFV()
        // The replay input plays when it goes on air and returns to its start when it leaves.
        if let r = replaySource {
            let was = autoPlayOnAir.contains(r.id), now = visible.contains(r.id)
            if now && !was && r.hasClip { r.play() }
            if !now && was { r.cue() }
        }
        for (id, src) in sources {
            guard let v = src as? VideoFileSource, v.autoPlay != .off, id != stingerID else { continue }
            let was = autoPlayOnAir.contains(id), now = visible.contains(id)
            if now && !was { v.autoPlay == .restartPause ? v.restart() : v.play() }
            if !now && was { v.pause() }
        }
        autoPlayOnAir = visible
    }

    /// Changes a video input's auto play mode; an input set to auto play that is not on air pauses.
    public func setAutoPlay(_ mode: VideoFileSource.AutoPlay, for id: InputID) {
        guard let v = source(id) as? VideoFileSource else { return }
        v.autoPlay = mode
        autoPlayOnAir.remove(id)
        if mode != .off { v.pause() }
        applyAutoPlay()
    }

    // MARK: Instant replay

    /// Turns the replay buffer on (adds the "Replay" input) or off (removes it, deletes the buffer).
    public func setReplayEnabled(_ on: Bool) {
        if on {
            guard replaySource == nil else { return }
            let src = ReplaySource(id: InputID("replay"))
            src.onChange = { [weak self] in self?.onReplayChange?() }
            replaySource = src
            add(src)
            replay.start(output: settings.output)
            outputs.mutate { $0.replay = true }
        } else if let src = replaySource {
            removeInput(src.id)   // also stops the buffer
        }
        onReplayChange?()
    }

    private func replayRemoved() {
        outputs.mutate { $0.replay = false }
        replay.stop()
        replaySource = nil
        onReplayChange?()
    }

    /// Loads the last `seconds` of Program into the Replay input and puts it on Preview, ready
    /// for CUT/AUTO (it starts playing when it goes on air). `completion(false)` if the buffer
    /// is still empty.
    public func replayLast(_ seconds: Double, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let src = replaySource else { return completion(false) }
        replay.clip(lastSeconds: seconds) { [weak self] clip in
            guard let self, let clip, self.replaySource === src else { return completion(false) }
            src.load(clip)
            if self.switcherState.program != src.id { self.setPreview(src.id) }
            completion(true)
        }
    }

    // MARK: Stinger

    public var stinger: StingerConfig { control.read { $0.stinger } }

    /// Selects the stinger clip and cut point. The clip stops looping and waits on its first frame;
    /// a previously selected clip goes back to looping.
    public func setStinger(_ cfg: StingerConfig) {
        let old = control.mutate { st -> StingerConfig in let o = st.stinger; st.stinger = cfg; return o }
        if old.source != cfg.source, let id = old.source, let prev = source(id) as? VideoFileSource {
            prev.loop = true
            prev.play()
        }
        if let id = cfg.source, let clip = source(id) as? VideoFileSource, old.source != cfg.source {
            clip.loop = false
            clip.cue()
        }
    }

    public func setTransition(_ kind: TransitionKind, duration: Double) {
        settings.transition = kind
        settings.transitionDuration = min(max(duration, 0.1), 10)
    }

    /// Selects and compiles the shader `TransitionKind.custom` uses (`CustomTransitionLibrary` id).
    /// Returns the problem, or nil when it compiled; until a shader compiles, `.custom` dissolves.
    @discardableResult
    public func setCustomTransition(_ id: String?) -> String? {
        settings.customTransition = id
        guard let id else { compositor.clearCustomTransition(); return nil }
        guard let code = CustomTransitionLibrary.code(for: id) else {
            compositor.clearCustomTransition()
            return "Transition shader not found (\(id))."
        }
        if let err = compositor.loadCustomTransition(code: code) {
            compositor.clearCustomTransition()
            return err
        }
        return nil
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

    /// In / out animation and its duration (0.1...5 s) of an overlay channel.
    public func setOverlayAnimation(_ index: Int, animation: OverlayAnimation, duration: Double) {
        control.mutate { st in
            guard let i = st.overlays.firstIndex(where: { $0.index == index }) else { return }
            st.overlays[i].animation = animation
            st.overlays[i].fadeDuration = min(max(duration, 0.1), 5)
        }
    }

    public func setOverlay(_ index: Int, on: Bool) {
        let now = HostClock.now()
        control.mutate { st in
            guard let i = st.overlays.firstIndex(where: { $0.index == index }), st.overlays[i].source != nil else { return }
            st.overlays[i].set(on: on, now: now)
            if on { st.overlays[i].onPreview = false }
        }
        applyAutoPlay()
    }

    /// Shows or hides an overlay on Preview only; CUT/AUTO then takes it to Program.
    public func setOverlayPreview(_ index: Int, on: Bool) {
        control.mutate { st in
            guard let i = st.overlays.firstIndex(where: { $0.index == index }), st.overlays[i].source != nil else { return }
            st.overlays[i].onPreview = on
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
        let customChanged = new.customTransition != settings.customTransition
        settings = new
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
        public var id: String
        public var name: String
        public var url: RTMPURL
        public var audioBus: OutputBus
        public init(id: String, name: String, url: RTMPURL, audioBus: OutputBus = .master) {
            self.id = id; self.name = name; self.url = url; self.audioBus = audioBus
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
        var engines: [StreamingEngine] = []
        for t in targets {
            let s = StreamingEngine()
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
        let groups: [(bus: OutputBus, aac: AACEncoder, engines: [StreamingEngine])] = aacByBus.map { bus, aac in
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
            s.start(url: t.url, settings: settings, audioSpecificConfig: aacByBus[t.audioBus]!.audioSpecificConfig)
        }
    }

    /// Each destination fails and reconnects on its own; the shared encoders are released only
    /// when every destination has ended permanently.
    private func streamStatsChanged(_ id: String, _ s: StreamingEngine.Stats) {
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
        let (order, sources, layers, keys, overlays, sw, locked) = control.read { st in
            (st.order, st.sources, st.layers, st.keys, st.overlays, st.switcher.state, st.locked)
        }
        let adjusts = control.read { $0.adjusts }
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
            case let v as VideoFileSource:
                ps = v.isPlaylist ? .videoPlaylist(tracks: v.urls.map { ProjectMediaRef(path: $0.path, relativePath: rel($0)) }, loop: v.loop)
                    : .videoFile(path: v.url.path, relativePath: rel(v.url), loop: v.loop)
            case let i as ImageSource: ps = .image(path: i.url.path, relativePath: rel(i.url))
            case let c as ColorSource: ps = .color(ProjectColor(c.color))
            case is ColorBarsSource: ps = .colorBars
            case is SceneSource: ps = .scene
            case let t as TextSource: ps = .title(ProjectTitleStyle(t.style))
            case let b as BrowserSource: ps = .browser(b.config)
            case let t as TimerSource: ps = .timer(t.config, nil)
            case let t as TickerSource: ps = .ticker(t.config)
            case let sl as SlideshowSource:
                ps = .slideshow(ProjectSlideshow(images: sl.urls.map { ProjectMediaRef(path: $0.path, relativePath: rel($0)) },
                                                 interval: sl.interval, fade: sl.fade, loop: sl.loop,
                                                 kenBurns: sl.kenBurns ? true : nil,
                                                 folder: sl.folder.map { ProjectMediaRef(path: $0.path, relativePath: rel($0)) }))
            case let c as ScreenCaptureSource: ps = .screen(c.config)
            default: continue
            }
            let key = keys[id]
            var pi = ProjectInput(id: id, name: src.name, source: ps, layers: layers[id] ?? [],
                                  chromaKey: key == ChromaKey() ? nil : key)
            if let v = src as? VideoFileSource, v.autoPlay != .off { pi.autoPlay = v.autoPlay.rawValue }
            if locked.contains(id) { pi.locked = true }
            if let c = src as? CameraSource, c.config != CaptureConfig() { pi.capture = c.config }
            pi.adjust = adjusts[id]
            doc.inputs.append(pi)
        }
        doc.stinger = control.read { $0.stinger.source == nil && $0.stinger.cutPoint == nil ? nil : $0.stinger }
        doc.overlays = overlays.map { ProjectOverlay(index: $0.index, source: $0.source, preset: $0.preset, fadeDuration: $0.fadeDuration,
                                                     animation: $0.animation == .fade ? nil : $0.animation) }
        doc.previewInput = sw.transition == nil ? sw.preview : sw.transition?.from
        doc.programInput = sw.transition?.to ?? sw.program
        doc.audio.masterFaderDB = mixer.master.faderDB.value
        doc.audio.limiterEnabled = mixer.limiterEnabled.value
        doc.audio.monitorVolume = mixer.monitorVolume.value
        doc.audio.syncOffsetMs = Double(audioPump.syncOffsetSeconds.value) * 1000
        doc.audio.aux = mixer.aux.indices.map { i in
            ProjectAuxBus(faderDB: mixer.aux[i].faderDB.value, muted: mixer.aux[i].muted.value, outputDeviceUID: auxOutputUID(i))
        }
        doc.audio.tones = tones.isEmpty ? nil : tones.map { t in
            var pc = Self.projectChannel(t.channel, deviceUniqueID: nil, inputID: nil)
            pc.afvInput = afvLinks[t.channel.id]
            return ProjectTone(id: t.id, frequency: t.frequency, levelDB: t.levelDB, channel: pc)
        }
        for ch in mixer.channelList where !ch.id.hasPrefix(Self.musicChannelPrefix) && !ch.id.hasPrefix(Self.toneChannelPrefix) {
            let owner = Self.inputOfChannel(ch.id)
            var pc = Self.projectChannel(ch, deviceUniqueID: owner == nil ? ch.id : nil, inputID: owner)
            pc.afvInput = afvLinks[ch.id]
            doc.audio.channels.append(pc)
        }
        doc.audio.music = musicPlayers.isEmpty ? nil : musicPlayers.map { m in
            ProjectMusic(id: m.id, name: m.name,
                         tracks: m.tracks.map { ProjectMediaRef(path: $0.path, relativePath: rel($0)) },
                         loop: m.loopPlaylist, shuffle: m.shuffle,
                         channel: { var pc = Self.projectChannel(m.channel, deviceUniqueID: nil, inputID: nil)
                                    pc.afvInput = afvLinks[m.channel.id]; return pc }(),
                         fadeSeconds: m.fadeSeconds > 0 ? m.fadeSeconds : nil)
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
        afvLinks = [:]

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
                guard DeviceManager.device(uniqueID: uid) != nil,
                      addCamera(uniqueID: uid, id: pi.id, config: pi.capture ?? CaptureConfig()) != nil else {
                    warnings.append("Camera \"\(deviceName)\" is not connected; input \"\(pi.name)\" was skipped.")
                    continue
                }
            case let .videoFile(path, relative, loop):
                addVideoFile(urls: [mediaURL(path, relative)], id: pi.id, loop: loop,
                             autoPlay: pi.autoPlay.flatMap(VideoFileSource.AutoPlay.init(rawValue:)) ?? .off)
            case let .videoPlaylist(tracks, loop):
                guard !tracks.isEmpty else { continue }
                addVideoFile(urls: tracks.map { mediaURL($0.path, $0.relativePath) }, id: pi.id, loop: loop,
                             autoPlay: pi.autoPlay.flatMap(VideoFileSource.AutoPlay.init(rawValue:)) ?? .off)
            case let .image(path, relative):
                addImage(url: mediaURL(path, relative), id: pi.id)
            case .lottie:
                // Lottie inputs were removed in 0.15.0.
                warnings.append("Input \"\(pi.name)\" is a Lottie animation; Lottie is no longer supported and it was skipped.")
                continue
            case let .color(c):
                addColor(c.nsColor, name: pi.name, id: pi.id)
            case .colorBars:
                addColorBars(id: pi.id, name: pi.name)
            case .scene:
                addScene(name: pi.name, id: pi.id)
            case let .title(t):
                addTitle(t.textStyle, id: pi.id)
            case let .browser(b):
                addBrowser(b, id: pi.id)
            case let .timer(t, _):
                addTimer(t, id: pi.id)
            case let .ticker(t):
                addTicker(t, id: pi.id)
            case let .slideshow(sl):
                // A watched folder that moved with the project is found next to it like the photos.
                let folder = sl.folder.map { f -> URL in
                    if FileManager.default.fileExists(atPath: f.path) { return URL(fileURLWithPath: f.path, isDirectory: true) }
                    if let r = f.relativePath, let dir = projectDirectory {
                        return URL(fileURLWithPath: ProjectPaths.resolve(r, againstDirectory: dir.standardizedFileURL.path), isDirectory: true)
                    }
                    return URL(fileURLWithPath: f.path, isDirectory: true)
                }
                let photos = folder.map { SlideshowSource.images(inFolder: $0) }.flatMap { $0.isEmpty ? nil : $0 }
                addSlideshow(urls: photos ?? sl.images.map { mediaURL($0.path, $0.relativePath) }, interval: sl.interval,
                             fade: sl.fade, loop: sl.loop, kenBurns: sl.kenBurns ?? false, folder: folder, id: pi.id)
            case let .screen(c):
                addScreenCapture(c, id: pi.id)
            }
            created.insert(pi.id)
            renameInput(pi.id, to: pi.name)
        }

        control.mutate { st in
            for pi in doc.inputs where created.contains(pi.id) {
                let layers = pi.layers.filter { created.contains($0.source) }
                st.layers[pi.id] = layers.isEmpty ? [Layer(source: pi.id)] : layers
                if let k = pi.chromaKey { st.keys[pi.id] = k.clamped }
                if pi.locked == true { st.locked.insert(pi.id) }
                if let a = pi.adjust, !a.isIdentity { st.adjusts[pi.id] = a.clamped }
            }
            st.overlays = (1...4).map { OverlayChannel(index: $0) }
            for o in doc.overlays {
                guard let i = st.overlays.firstIndex(where: { $0.index == o.index }) else { continue }
                let src = o.source.flatMap { created.contains($0) ? $0 : nil }
                st.overlays[i] = OverlayChannel(index: o.index, source: src, preset: o.preset, fadeDuration: o.fadeDuration)
                st.overlays[i].animation = o.animation ?? .fade
            }
            st.switcher = Switcher()
            if let p = doc.programInput, created.contains(p) { st.switcher.setPreview(p); st.switcher.cut() }
            st.switcher.setPreview(doc.previewInput.flatMap { created.contains($0) ? $0 : nil })
        }

        mixer.master.faderDB.value = doc.audio.masterFaderDB
        mixer.limiterEnabled.value = doc.audio.limiterEnabled
        mixer.monitorVolume.value = doc.audio.monitorVolume
        audioPump.syncOffsetSeconds.value = Float(doc.audio.syncOffsetMs / 1000)
        for i in mixer.aux.indices {
            let bus = doc.audio.aux.flatMap { i < $0.count ? $0[i] : nil } ?? ProjectAuxBus()
            mixer.aux[i].faderDB.value = bus.faderDB
            mixer.aux[i].muted.value = bus.muted
            if let msg = setAuxOutput(i, uid: bus.outputDeviceUID) { warnings.append(msg) }
        }
        for m in musicPlayers.map(\.id) { removeMusic(id: m) }
        for pm in doc.audio.music ?? [] {
            let urls = pm.tracks.map { mediaURL($0.path, $0.relativePath) }
            let m = addMusic(urls: urls, name: pm.name, id: pm.id)
            m.loopPlaylist = pm.loop
            m.shuffle = pm.shuffle
            m.fadeSeconds = pm.fadeSeconds ?? 0
            if let ch = pm.channel { restore(ch, to: m.channel) }
        }
        for t in tones.map(\.id) { removeTone(id: t) }
        for pt in doc.audio.tones ?? [] {
            let t = addTone(frequency: pt.frequency, levelDB: pt.levelDB, id: pt.id, name: pt.channel?.name ?? "Tone")
            if let ch = pt.channel { restore(ch, to: t.channel) }
        }
        for ch in doc.audio.channels {
            if let uid = ch.deviceUniqueID {
                guard DeviceManager.device(uniqueID: uid) != nil else {
                    warnings.append("Audio device \"\(ch.name)\" is not connected; its mixer channel was skipped.")
                    continue
                }
                addAudioInput(uniqueID: uid)
                if let mc = mixer.channelList.first(where: { $0.id == uid }) { restore(ch, to: mc) }
            } else if let iid = ch.inputID, created.contains(iid) {
                if let mc = mixer.channelList.first(where: { $0.id == Self.fileChannelID(iid) || $0.id == Self.screenChannelID(iid) }) { restore(ch, to: mc) }
                else { pendingFileChannelSettings[iid] = ch }
            }
        }
        setStinger(StingerConfig())
        if let s = doc.stinger {
            setStinger(StingerConfig(source: s.source.flatMap { created.contains($0) ? $0 : nil }, cutPoint: s.cutPoint))
        }
        onAudioChannelsChange?()
        publishInputs()
        return warnings
    }

    /// Applies saved channel settings, including the AFV link.
    private func restore(_ p: ProjectAudioChannel, to ch: MixerChannel) {
        Self.apply(p, to: ch.controls)
        if !p.name.isEmpty { ch.name = p.name }
        afvLinks[ch.id] = p.afvInput.flatMap { source($0) != nil ? $0 : nil }
        applyAFV()
    }

    /// Mixer settings of a channel as stored in projects.
    static func projectChannel(_ ch: MixerChannel, deviceUniqueID: String?, inputID: InputID?) -> ProjectAudioChannel {
        var p = ProjectAudioChannel(deviceUniqueID: deviceUniqueID, inputID: inputID, name: ch.name)
        let c = ch.controls
        p.faderDB = c.faderDB.value; p.gainDB = c.gainDB.value; p.pan = c.pan.value
        p.muted = c.muted.value; p.toProgram = c.toProgram.value
        p.toBusA = c.toBusA.value; p.toBusB = c.toBusB.value
        p.compressorEnabled = c.compressorEnabled.value; p.compThresholdDB = c.compThresholdDB.value; p.compRatio = c.compRatio.value
        p.gateEnabled = c.gateEnabled.value; p.gateThresholdDB = c.gateThresholdDB.value
        p.gateRangeDB = c.gateRangeDB.value; p.compMakeupDB = c.compMakeupDB.value
        p.compAttackMs = c.compAttackMs.value; p.compReleaseMs = c.compReleaseMs.value
        if c.mode != .stereo { p.channelMode = c.mode.rawValue }
        if c.invertPhase.value { p.invertPhase = true }
        if c.delayMs.value > 0 { p.delayMs = c.delayMs.value }
        var eq = ProjectEQ()
        eq.highPassEnabled = c.highPassEnabled.value; eq.highPassHz = c.highPassHz.value
        eq.eqEnabled = c.eqEnabled.value
        eq.lowDB = c.eqLowDB.value; eq.midDB = c.eqMidDB.value; eq.midHz = c.eqMidHz.value; eq.highDB = c.eqHighDB.value
        p.eq = eq
        return p
    }

    /// Core Audio UID of the device aux bus `index` plays on, nil if none.
    public func auxOutputUID(_ index: Int) -> String? {
        guard mixer.auxDeviceIDs.indices.contains(index), let id = mixer.auxDeviceIDs[index] else { return nil }
        return AudioDevices.info(id)?.uid
    }

    /// Plays aux bus `index` on the output device with this UID (nil = off). Returns a warning.
    @discardableResult
    public func setAuxOutput(_ index: Int, uid: String?) -> String? {
        guard let uid, !uid.isEmpty else { return mixer.setAuxOutput(index, deviceID: nil) }
        guard let dev = AudioDevices.outputs().first(where: { $0.uid == uid }) else {
            mixer.setAuxOutput(index, deviceID: nil)
            return "Aux \(index == 0 ? "A" : "B") output device is not connected; the bus is not played anywhere."
        }
        return mixer.setAuxOutput(index, deviceID: dev.id)
    }

    static func apply(_ p: ProjectAudioChannel, to c: ChannelControls) {
        c.faderDB.value = p.faderDB; c.gainDB.value = p.gainDB; c.pan.value = p.pan
        c.muted.value = p.muted; c.toProgram.value = p.toProgram
        c.toBusA.value = p.toBusA ?? false; c.toBusB.value = p.toBusB ?? false
        c.compressorEnabled.value = p.compressorEnabled; c.compThresholdDB.value = p.compThresholdDB; c.compRatio.value = p.compRatio
        c.gateEnabled.value = p.gateEnabled; c.gateThresholdDB.value = p.gateThresholdDB
        if let v = p.gateRangeDB { c.gateRangeDB.value = v }
        if let v = p.compMakeupDB { c.compMakeupDB.value = v }
        if let v = p.compAttackMs { c.compAttackMs.value = v }
        if let v = p.compReleaseMs { c.compReleaseMs.value = v }
        c.mode = p.channelMode.flatMap(ChannelMode.init(rawValue:)) ?? .stereo
        c.invertPhase.value = p.invertPhase ?? false
        c.delayMs.value = p.delayMs ?? 0
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

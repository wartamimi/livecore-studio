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
        /// Presentation inputs: slide on air (1-based) and slide count; 0 slides while converting.
        public var slide: (index: Int, count: Int, converting: Bool)? = nil

        public static func == (l: InputInfo, r: InputInfo) -> Bool {
            l.id == r.id && l.name == r.name && l.kind == r.kind && l.status == r.status && l.number == r.number
                && l.locked == r.locked && l.slide?.index == r.slide?.index && l.slide?.count == r.slide?.count
                && l.slide?.converting == r.slide?.converting
        }
    }

    // MARK: Callbacks (main thread)
    public var onProgramFrame: ((CVPixelBuffer) -> Void)?
    public var onPreviewFrame: ((CVPixelBuffer) -> Void)?
    public var onThumbnails: (([InputID: CVPixelBuffer]) -> Void)?
    /// Full-size picture of `detailInput` (per-input viewer). Main thread.
    public var onDetailFrame: ((InputID, CVPixelBuffer) -> Void)?
    /// Every rendered frame for the extra outputs, called on the GPU completion thread (not the
    /// main thread) so Syphon and the virtual camera get frames without a main-thread hop.
    /// Set it before `start()`.
    public var outputFrameHandler: ((OutputFrames) -> Void)?
    public struct OutputFrames {
        public var program: CVPixelBuffer
        /// Preview at full output size; nil unless `setOutputRendering(fullPreview: true)`.
        public var preview: CVPixelBuffer?
        public var inputs: [InputID: CVPixelBuffer]
        public var pts: CMTime
    }
    public var onSwitcherChange: ((SwitcherSnapshot) -> Void)?
    public var onInputsChange: (([InputInfo]) -> Void)?
    /// Statistics of one stream destination (destination id, stats). Main thread.
    public var onStreamStats: ((String, StreamingEngine.Stats) -> Void)?
    public var onRecordStats: ((RecordingEngine.Stats) -> Void)?
    /// MultiCorder file states, per ISO input (main thread).
    public var onISOStats: (([InputID: RecordingEngine.Stats]) -> Void)?
    /// Inputs the MultiCorder records to their own files (main thread; applies at the next start).
    public var multiCorder = MultiCorderConfig()
    public var isMultiCorderRunning: Bool { !outputs.read { $0.iso.isEmpty } }
    public internal(set) var isoStats: [InputID: RecordingEngine.Stats] = [:]
    public var onError: ((String) -> Void)?
    /// Mixer channels were added or removed by the engine itself (e.g. a video file's audio).
    public var onAudioChannelsChange: (() -> Void)?

    public internal(set) var settings: ProductionSettings
    public let compositor: MetalCompositor
    public let mixer = AudioMixerEngine()
    public let devices = DeviceManager()
    public internal(set) lazy var audioPump = ProgramAudioPump(mixer: mixer)
    /// One RTMP/RTMPS publisher per destination, all fed by the same encoders. Main thread.
    public internal(set) var streamers: [String: StreamingEngine] = [:]
    var streamTerminal: [String: Bool] = [:]
    public let recorder = RecordingEngine()
    /// Instant replay buffer and its input (nil while replay is off).
    public let replay = ReplayRecorder()
    public internal(set) var replaySource: ReplaySource?
    public var onReplayChange: (() -> Void)?
    /// Music inputs (audio-file playlists), each with its own mixer channel. Main thread.
    public internal(set) var musicPlayers: [MusicInput] = []
    public internal(set) var tones: [TestTone] = []
    public static let toneChannelPrefix = "tone:"
    public var onMusicChange: (() -> Void)?
    public static let musicChannelPrefix = "music:"
    public let performance = PerformanceMonitor()

    struct ControlState {
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
        /// Inputs rendered at full size for the extra outputs, and whether Preview is too.
        var extraInputs: [InputID] = []
        var fullPreview = false
        /// Inputs being recorded to their own files (MultiCorder), also rendered at full size.
        var isoInputs: [InputID] = []
        var stinger = StingerConfig()
        /// Layer Designer edits not yet on air, per input: Preview shows the draft of its input;
        /// everything else (Program, overlays, other inputs) keeps the committed layers.
        var drafts: [InputID: [Layer]] = [:]

        /// The input about to go on air (the one on Preview / being transitioned in) takes its
        /// draft with it: Layer Designer edits reach Program only through a transition.
        mutating func commitDraftOfIncoming() {
            guard let id = switcher.state.transition?.to ?? switcher.state.preview else { return }
            commitDraft(of: id)
        }

        mutating func commitDraft(of id: InputID) {
            guard let d = drafts.removeValue(forKey: id), sources[id] != nil else { return }
            layers[id] = d
        }

        /// Layer 0 stays the input itself; layers of unknown inputs are dropped.
        func sanitized(_ list: [Layer], of id: InputID) -> [Layer] {
            var l = list.filter { $0.source != id && sources[$0.source] != nil }
            l.insert(list.first(where: { $0.source == id }) ?? Layer(source: id), at: 0)
            return l
        }
    }
    let control = Locked(ControlState())

    let renderQueue = DispatchQueue(label: "livecore.render", qos: .userInteractive)
    var renderTimer: DispatchSourceTimer?
    var clockStart: Double = 0
    var lastFrameIndex: Int64 = -1
    let inFlight = Locked(0)
    var frameCounter: Int64 = 0
    public let droppedRenderFrames = AtomicCounter()
    let gpuMsAverage = AtomicFloat(0)
    let renderedFrames = AtomicCounter()
    var lastFPSSample: (time: Double, frames: UInt64) = (0, 0)

    struct Outputs {
        var streamEncoder: H264Encoder?
        var recording = false
        var replay = false
        /// MultiCorder: one recorder per ISO input while it runs.
        var iso: [(InputID, RecordingEngine)] = []
    }
    let outputs = Locked(Outputs())
    var aacEncoders: [AACEncoder] = []
    var audioInputs: [String: AudioCaptureInput] = [:]
    var lastSwitcher = SwitcherSnapshot()
    /// Mixer settings from a loaded project for video-file channels that appear once the file's
    /// audio track has loaded.
    var pendingFileChannelSettings: [InputID: ProjectAudioChannel] = [:]
    /// Sound of the web inputs (macOS 14.2+; a `WebAudioCapture`) and its saved mixer settings.
    var webAudio: AnyObject?
    var pendingWebAudioSettings: ProjectAudioChannel?
    /// The one mixer channel all web inputs play into.
    public static let webAudioChannelID = "webaudio"

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

    func startRenderLoop() {
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

    func renderTick(fps: Double) {
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
            let draft = st.drafts
            let plan = FramePlanner.plan(snapshot: st.switcher.state, overlays: st.overlays, now: now,
                                         layersFor: { layers[$0] }, keyFor: { keys[$0] },
                                         thumbnailsFor: thumbTick ? st.order : [],
                                         composedThumbnails: thumbTick ? Set(st.sources.filter { $0.value is SceneSource }.keys) : [],
                                         detailInput: st.detail,
                                         extraInputs: st.extraInputs + st.isoInputs.filter { !st.extraInputs.contains($0) },
                                         fullPreview: st.fullPreview,
                                         previewLayers: draft)
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
        for list in plan.allCommandLists { for c in list { needed.insert(c.source) } }
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
            for (id, r) in outs.iso { if let pb = result.extra[id] { r.append(video: pb, pts: pts) } }
            if outs.replay { self.replay.append(program, hostTime: pts.seconds) }
            self.outputFrameHandler?(OutputFrames(program: program, preview: result.fullPreview, inputs: result.extra, pts: pts))
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

    // MARK: State used by the extension files

    /// Auto play (vMix-style): inputs whose media plays while on air, and the inputs on air now.
    var autoPlayOnAir = Set<InputID>()
    var onAirInputs = Set<InputID>()
    /// Audio follow video (vMix AFV): mixer channel id -> the input it follows. Main thread.
    public internal(set) var afvLinks: [String: InputID] = [:]

    // MARK: Stats

    public func samplePerformance() -> PerformanceSnapshot {
        let now = HostClock.now()
        let frames = renderedFrames.value
        let fps = lastFPSSample.time > 0 ? Double(frames - lastFPSSample.frames) / max(now - lastFPSSample.time, 0.001) : 0
        lastFPSSample = (now, frames)
        return performance.sample(gpuFrameMs: Double(gpuMsAverage.value), renderFPS: fps, dropped: droppedRenderFrames.value)
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
        design = s.design
    }
    public var textStyle: TextSource.Style {
        var s = TextSource.Style(title: title, subtitle: subtitle)
        s.showBar = showBar
        s.textColor = textColor.nsColor
        s.barColor = barColor.nsColor
        if let titleSize { s.titleSize = CGFloat(titleSize) }
        if let subtitleSize { s.subtitleSize = CGFloat(subtitleSize) }
        if let layout, let l = TextSource.Layout(rawValue: layout) { s.layout = l }
        s.design = design
        return s
    }
}

extension AACEncoder {
    /// Encoder delay of Apple's AAC-LC encoder (samples), see Apple TN2258.
    public static let primingFrames = 2112
}
#endif

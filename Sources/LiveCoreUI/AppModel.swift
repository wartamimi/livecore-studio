#if os(macOS)
import AppKit
import AVFoundation
import Combine
import CoreImage
import ImageIO
import LiveCoreCore
import LiveCoreEngine
import LiveCoreRemote
import SwiftUI
import UniformTypeIdentifiers

/// UI state holder. All members are used on the main thread only; engine callbacks are
/// delivered on main by the engine. Video frames bypass SwiftUI entirely (`FrameFeed`).
public final class AppModel: ObservableObject {
    // Engine
    public private(set) var engine: ProductionEngine?
    @Published public var startupError: String?

    // Inputs & switching
    @Published public var inputs: [ProductionEngine.InputInfo] = []
    @Published public var switcher = SwitcherSnapshot()
    @Published public var transitionKind: TransitionKind = .dissolve
    @Published public private(set) var stinger = StingerConfig()
    @Published public var transitionDuration: Double = 1.0
    /// Custom shader transitions: available shaders, the selected one, and its last compile problem.
    @Published public private(set) var customTransitions: [CustomTransitionLibrary.Entry] = []
    @Published public private(set) var customTransitionID: String?
    @Published public private(set) var customTransitionError: String?
    @Published public var tbar: Double = 0
    /// Instant replay: seconds buffered, and the speed new replays play at.
    @Published public var replayAvailable: Double = 0
    @Published public var replaySpeed: Double = 0.5 { didSet { engine?.replaySource?.speed = replaySpeed } }
    @Published public var overlays: [OverlayChannel] = []
    public let programFeed = FrameFeed()
    public let previewFeed = FrameFeed()
    public let programOutputFeed = FrameFeed()   // external-display window
    /// Layer Designer › saved layouts.
    @Published public internal(set) var layoutTemplates: [LayoutTemplate] = AppModel.loadLayoutTemplates()
    /// Outputs the top-bar FULLSCREEN button opens on their displays (Output 1 by default).
    @Published public internal(set) var fullscreenOutputs: Set<Int> = [1]
    public private(set) var thumbnailFeeds: [InputID: FrameFeed] = [:]
    /// The four extra outputs: one feed per output window / full-screen display.
    public let outputFeeds: [Int: FrameFeed] = Dictionary(uniqueKeysWithValues: (1...OutputRouting.count).map { ($0, FrameFeed()) })
    public private(set) lazy var outputFullscreens: [Int: FullscreenOutput] = makeOutputFullscreens()
    @Published public internal(set) var outputRouting = OutputRouting()
    /// EXTERNAL button: the Syphon and NDI outputs are sending.
    @Published public internal(set) var externalActive = false
    /// Output index → an app is connected to its Syphon server (only outputs that send).
    @Published public internal(set) var syphonStatus: [Int: Bool] = [:]
    /// Output index → receivers connected to its NDI source (only outputs that send).
    @Published public internal(set) var ndiStatus: [Int: Int] = [:]
    /// The NDI runtime (NDI Tools / NDI Runtime) was found when the outputs started.
    @Published public internal(set) var ndiAvailable = false
    public internal(set) var outputRouter: OutputRouter?
    var outputWindows: Set<Int> = []

    // Devices
    @Published public var videoDevices: [DeviceManager.Device] = []
    @Published public var audioDevices: [DeviceManager.Device] = []
    @Published public var outputDevices: [AudioDeviceInfo] = []
    @Published public var monitorDeviceUID: String = ""
    /// Aux buses A and B (created once the engine runs).
    @Published public private(set) var auxBuses: [AuxBusVM] = []
    /// Last Program snapshot saved with `saveSnapshot()`.
    @Published public private(set) var lastSnapshotURL: URL?
    var lastProgramFrame: CVPixelBuffer?
    var lastPreviewFrame: CVPixelBuffer?
    private var lastMusicError: String?

    // Audio
    @Published public var audioChannels: [ChannelVM] = []
    public let meters = MeterModel()
    @Published public var syncOffsetMs: Double = 0 { didSet { engine?.audioPump.syncOffsetSeconds.value = Float(syncOffsetMs / 1000) } }
    @Published public var masterFader: Double = 0.75 { didSet { engine?.mixer.master.faderDB.value = FaderLaw.db(forPosition: masterFader) } }
    @Published public var limiterEnabled = true { didSet { engine?.mixer.limiterEnabled.value = limiterEnabled } }
    @Published public var monitorVolume: Double = 1 { didSet { engine?.mixer.monitorVolume.value = Float(monitorVolume) } }

    // Project
    @Published public private(set) var projectURL: URL?

    // Outputs
    @Published public var settings = ProductionSettings()
    /// Live statistics per stream destination ("primary" or a StreamDestination id).
    @Published public var destinationStats: [String: StreamingEngine.Stats] = [:]
    /// Destinations of the current/last stream session, in display order.
    @Published public private(set) var streamTargets: [(id: String, name: String)] = []
    @Published public var recordStats = RecordingEngine.Stats()
    /// MultiCorder: inputs recorded to their own files (own button and profile), and those files' states.
    @Published public internal(set) var multiCorder = MultiCorderConfig() { didSet { engine?.multiCorder = multiCorder } }
    @Published public internal(set) var isoStats: [InputID: RecordingEngine.Stats] = [:]
    /// Inputs panel: colour labels (groups), minimized tiles, group names, colour filter.
    @Published public internal(set) var inputTags: [InputID: InputColorTag] = [:]
    @Published public internal(set) var minimizedInputs: Set<InputID> = []
    @Published public internal(set) var groupNames: [InputColorTag: String] = [:]
    @Published public var inputFilter: InputColorTag?
    @Published public var hasStreamKey = false
    @Published public var performance = PerformanceSnapshot.zero
    @Published public var shortcuts = ShortcutSettings.load()

    // Web Controller (remote control from a browser on the same network; off by default)
    @Published public internal(set) var remoteEnabled = false
    @Published public internal(set) var remotePort = RemoteServer.defaultPort
    /// Shown in Settings › Remote; kept in the Keychain, never in preferences or projects.
    @Published public internal(set) var remotePIN = ""
    @Published public internal(set) var remoteError: String?
    @Published public internal(set) var remoteClients = 0
    @Published public internal(set) var remoteAddresses: [String] = []
    var remoteServer: RemoteServer?

    // Errors
    @Published public var errors: [ErrorItem] = []
    public struct ErrorItem: Identifiable, Equatable { public let id = UUID(); public let message: String }

    private var statsTimer: Timer?

    public init() {}

    public func start() {
        if let data = UserDefaults.standard.data(forKey: "settings"),
           let s = try? JSONDecoder().decode(ProductionSettings.self, from: data) {
            settings = s
        }
        // Every launch starts on Dissolve (a project file can still bring its own transition).
        settings.transition = .dissolve
        transitionKind = .dissolve
        transitionDuration = settings.transitionDuration
        customTransitionID = settings.customTransition
        customTransitions = CustomTransitionLibrary.entries()
        do {
            let e = try ProductionEngine(settings: settings)
            engine = e
            wire(e)
            startOutputs(e)
            e.start()
            refreshDevices()
            hasStreamKey = ((try? KeychainStore.load(account: settings.stream.keychainAccount)) ?? nil)?.isEmpty == false
            overlays = e.overlays
            syncAuxFromEngine()
            startMIDI()
            startRemoteIfEnabled()
        } catch {
            startupError = error.localizedDescription
            return
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }

    public func shutdown() {
        statsTimer?.invalidate()
        outputRouter?.stopAll()
        midi.stop()
        remoteServer?.stop()
        engine?.shutdown()
    }

    public func confirmQuit() -> Bool {
        let active = streamStats.state == .live || isRecording
        guard active else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.t("quit.live")
        alert.addButton(withTitle: L10n.t("quit.confirm"))
        alert.addButton(withTitle: L10n.t("settings.cancel"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func wire(_ e: ProductionEngine) {
        e.onProgramFrame = { [weak self] pb in
            self?.lastProgramFrame = pb
            self?.programFeed.push(pb); self?.programOutputFeed.push(pb)
        }
        e.onPreviewFrame = { [weak self] pb in self?.lastPreviewFrame = pb; self?.previewFeed.push(pb) }
        e.onThumbnails = { [weak self] thumbs in
            guard let self else { return }
            for (id, pb) in thumbs { self.feed(for: id).push(pb) }
        }
        e.onDetailFrame = { [weak self] id, pb in
            guard let self, self.viewerInput == id else { return }
            self.viewerFeed.push(pb)
        }
        e.onSwitcherChange = { [weak self] s in self?.switcher = s; if s.transition == nil { self?.tbar = s.tbarRest } }
        e.onInputsChange = { [weak self] list in
            guard let self else { return }
            self.inputs = list
            let ids = Set(list.map(\.id))
            self.thumbnailFeeds = self.thumbnailFeeds.filter { ids.contains($0.key) }
            self.outputInputsChanged()
            self.overlays = e.overlays
        }
        e.onStreamStats = { [weak self] id, s in self?.destinationStats[id] = s }
        e.onRecordStats = { [weak self] s in self?.recordStats = s }
        e.onISOStats = { [weak self] s in self?.isoStats = s }
        e.onError = { [weak self] msg in self?.report(msg) }
        e.onAudioChannelsChange = { [weak self] in self?.reloadAudioChannels() }
        e.replay.onAvailableChange = { [weak self] a in self?.replayAvailable = a }
        e.onReplayChange = { [weak self] in self?.objectWillChange.send() }
        e.onMusicChange = { [weak self] in
            self?.objectWillChange.send()
            if let err = e.musicPlayers.compactMap(\.error).first, self?.lastMusicError != err { self?.lastMusicError = err; self?.report(err) }
        }
        e.devices.onChange = { [weak self] in self?.refreshDevices() }
    }

    public func feed(for id: InputID) -> FrameFeed {
        if let f = thumbnailFeeds[id] { return f }
        let f = FrameFeed()
        thumbnailFeeds[id] = f
        return f
    }

    public func report(_ message: String) {
        Log.app.error("\(message, privacy: .public)")
        if errors.last?.message == message { return }
        errors.append(ErrorItem(message: message))
        if errors.count > 5 { errors.removeFirst() }
    }

    public func dismissError(_ e: ErrorItem) { errors.removeAll { $0.id == e.id } }

    // MARK: Ticks (30 Hz meters, 1 Hz performance)

    private var tickCount = 0
    private func tick() {
        guard let e = engine else { return }
        meters.update(channels: e.audioChannels, master: e.mixer.master, aux: e.mixer.aux)
        tickCount += 1
        if tickCount % 30 == 0 { performance = e.samplePerformance(); refreshExternalStatus() }
        if remoteServer != nil, tickCount % 3 == 0 { pushRemoteState(clients: tickCount % 30 == 0) }
        if remoteServer != nil, tickCount % 10 == 0 { pushRemoteFrames() }
    }

    // MARK: Devices

    public func refreshDevices() {
        guard let e = engine else { return }
        e.devices.refresh()
        videoDevices = e.devices.videoDevices
        audioDevices = e.devices.audioDevices
        outputDevices = AudioDevices.outputs()
        reloadAudioChannels()
    }

    // MARK: Inputs

    public func addCamera(_ d: DeviceManager.Device) {
        guard !rejectDuplicateCamera(d.id) else { return }
        engine?.addCamera(uniqueID: d.id)
    }

    /// "<number> <name>" of the input already using this camera (one device = one input).
    public func cameraInUse(_ uniqueID: String) -> String? {
        engine?.inputUsingCamera(uniqueID).flatMap(inputLabel)
    }

    /// "<number> <name>" of the input already capturing this window / display.
    public func captureInUse(_ c: ProjectScreenCapture, except: InputID? = nil) -> String? {
        engine?.inputCapturing(c, except: except).flatMap(inputLabel)
    }

    private func inputLabel(_ id: InputID) -> String? {
        inputs.first { $0.id == id }.map { "\($0.number) \($0.name)" }
    }

    private func rejectDuplicateCamera(_ uniqueID: String) -> Bool {
        guard let used = cameraInUse(uniqueID) else { return false }
        report(L10n.f("inputs.already_used", used))
        return true
    }

    /// Camera / capture card with the format and options chosen in the capture settings sheet;
    /// optionally adds the device's own audio (capture cards) to the mixer.
    @discardableResult
    public func addCamera(uniqueID: String, config: CaptureConfig, audioUID: String?) -> InputID? {
        guard !rejectDuplicateCamera(uniqueID) else { return nil }
        let id = engine?.addCamera(uniqueID: uniqueID, config: config)
        if let audioUID, let d = audioDevices.first(where: { $0.id == audioUID }) { addAudioInput(d) }
        return id
    }

    /// Capture-card signal fixes (level range, deinterlace) kept with the input's colour settings.
    public func setSignalFixes(_ id: InputID, range: InputAdjust.RangeFix, deinterlace: Bool) {
        var a = adjust(of: id)
        a.range = range; a.deinterlace = deinterlace
        setAdjust(id, a)
    }
    public func updateCamera(_ id: InputID, config: CaptureConfig) { engine?.updateCamera(id, config: config) }
    public func cameraSource(_ id: InputID) -> CameraSource? { engine?.source(id) as? CameraSource }
    public func captureFormats(uniqueID: String) -> [CaptureFormatCandidate] {
        DeviceManager.device(uniqueID: uniqueID).map(CameraSource.formats(of:)) ?? []
    }
    public var outputFormat: OutputFormat { settings.output }
    /// Width / height of the canvas, for the monitors (16:9 when unknown).
    public var canvasAspect: Double { let a = settings.output.size.aspect; return a > 0 ? a : 16 / 9 }

    public func addColorBars() { engine?.addColorBars(name: L10n.t("inputs.colorbars")) }

    /// New empty scene (transparent canvas); opens nothing, the operator edits it from the tile.
    @discardableResult
    public func addScene() -> InputID? {
        let n = inputs.filter { $0.kind == .scene }.count + 1
        return engine?.addScene(name: L10n.f("scene.default_name", n))
    }

    // MARK: Per-input viewer (fullscreen button on the tiles)

    @Published public private(set) var viewerInput: InputID?
    public let viewerFeed = FrameFeed()
    public func openViewer(_ id: InputID) {
        viewerFeed.clear()
        viewerInput = id
        engine?.setDetailInput(id)
    }
    public func closeViewer() {
        viewerInput = nil
        engine?.setDetailInput(nil)
        viewerFeed.clear()
    }

    public func addImage() {
        pickFile(types: ["public.image"]) { [weak self] url in self?.engine?.addImage(url: url) }
    }

    /// Media files: video or audio. Several can be picked at once.
    private func pickMedia() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio]
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func isAudioOnly(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .audio) && !t.conforms(to: .movie)
    }

    /// "Add Media": every picked file becomes its own input. Video files become video inputs
    /// (with their audio in the mixer); audio files become music inputs (a mixer channel with
    /// transport controls).
    public func addMedia() {
        guard let e = engine else { return }
        for url in pickMedia() {
            if Self.isAudioOnly(url) { e.addMusic(urls: [url]) } else { e.addVideoFile(url: url) }
        }
        reloadAudioChannels()
    }

    /// "Add Media Playlist": one input that plays the picked files in order. Only audio files ->
    /// a music playlist; any video file -> a video playlist (audio-only clips show black).
    public func addMediaPlaylist() {
        let urls = pickMedia()
        guard !urls.isEmpty, let e = engine else { return }
        if urls.allSatisfy(Self.isAudioOnly) { e.addMusic(urls: urls) } else { e.addVideoFile(urls: urls) }
        reloadAudioChannels()
    }


    public func addClips(to id: InputID) {
        guard let v = videoFile(id) else { return }
        let urls = pickMedia()
        guard !urls.isEmpty else { return }
        v.appendClips(urls)
        objectWillChange.send()
        if v.isPlaylist, v.name == v.urls.first?.deletingPathExtension().lastPathComponent { rename(id, "Playlist") }
    }

    public func setAutoPlay(_ mode: VideoFileSource.AutoPlay, for id: InputID) {
        engine?.setAutoPlay(mode, for: id)
        objectWillChange.send()
    }

    public func addColor(_ c: NSColor, name: String) { engine?.addColor(c, name: name) }

    public func addTitle(_ style: TextSource.Style) { engine?.addTitle(style) }

    public func updateTitle(_ id: InputID, style: TextSource.Style) {
        guard let src = engine?.source(id) as? TextSource else { return }
        src.update(style)
        engine?.renameInput(id, to: src.name)
    }

    public func remove(_ id: InputID) {
        guard !isLocked(id) else { report(L10n.t("lock.input_locked")); return }
        engine?.removeInput(id)
    }

    // MARK: Locks (protection against accidental changes)

    public func isLocked(_ id: InputID) -> Bool { inputs.first { $0.id == id }?.locked ?? false }
    public func toggleLock(_ id: InputID) { engine?.setInputLocked(id, !isLocked(id)) }
    public func lockAllInputs(_ locked: Bool) { for i in inputs { engine?.setInputLocked(i.id, locked) } }

    /// While locked, the stream / recording cannot be started or stopped (buttons, menu, shortcuts).
    @Published public var streamLocked = false
    @Published public var recordLocked = false

    /// Stop Streaming / Stop Recording waiting for the operator's confirmation.
    public enum StopRequest: String, Identifiable { case stream, record, multicorder; public var id: String { rawValue } }
    @Published public var pendingStop: StopRequest?
    /// Start recording automatically when streaming starts (and stop it with the stream).
    @Published public var recordWithStream = UserDefaults.standard.bool(forKey: "recordWithStream") {
        didSet { UserDefaults.standard.set(recordWithStream, forKey: "recordWithStream") }
    }
    private var recordingStartedWithStream = false

    /// Button / menu / shortcut entry points: starting is immediate, stopping asks first.
    public func requestToggleStream() {
        guard !streamLocked else { report(L10n.t("lock.stream_locked")); return }
        if isStreamingActive { pendingStop = .stream } else { toggleStream() }
    }

    public func requestToggleRecord() {
        guard !recordLocked else { report(L10n.t("lock.record_locked")); return }
        if isRecording { pendingStop = .record } else { toggleRecord() }
    }

    public func confirmStop(_ r: StopRequest) {
        pendingStop = nil
        switch r {
        case .stream: if isStreamingActive { toggleStream() }
        case .record: if isRecording { toggleRecord() }
        case .multicorder: if isMultiCorderRunning { toggleMultiCorder() }
        }
    }

    // MARK: Browser & timer inputs

    /// Adds a web page input; returns an error message if the address is not allowed.
    public func addBrowser(url: String, width: Int, height: Int, fps: Int, transparent: Bool) -> String? {
        if case let .rejected(reason) = BrowserURLPolicy.check(url) { return reason }
        engine?.addBrowser(ProjectBrowser(url: url, width: width, height: height, fps: fps, transparent: transparent))
        return nil
    }

    public func updateBrowser(_ id: InputID, url: String, width: Int, height: Int, fps: Int, transparent: Bool) -> String? {
        if case let .rejected(reason) = BrowserURLPolicy.check(url) { return reason }
        browserSource(id)?.update(ProjectBrowser(url: url, width: width, height: height, fps: fps, transparent: transparent))
        return nil
    }

    public func browserSource(_ id: InputID) -> BrowserSource? { engine?.source(id) as? BrowserSource }
    public func captureSource(_ id: InputID) -> ScreenCaptureSource? { engine?.source(id) as? ScreenCaptureSource }
    public func addCapture(_ c: ProjectScreenCapture) {
        if let used = captureInUse(c) { report(L10n.f("inputs.already_used", used)); return }
        engine?.addScreenCapture(c)
    }
    public func updateCapture(_ id: InputID, _ c: ProjectScreenCapture) {
        guard let src = captureSource(id) else { return }
        if src.name == src.config.displayName { rename(id, c.displayName) }
        src.reconfigure(c)
    }
    // MARK: NDI inputs

    public func ndiSource(_ id: InputID) -> NDISource? { engine?.source(id) as? NDISource }
    /// "<number> <name>" of the input already receiving this NDI source.
    public func ndiInUse(_ sourceName: String, except: InputID? = nil) -> String? {
        engine?.inputReceivingNDI(sourceName, except: except).flatMap(inputLabel)
    }
    public func addNDI(_ c: ProjectNDI) {
        if let used = ndiInUse(c.sourceName) { report(L10n.f("inputs.already_used", used)); return }
        engine?.addNDI(c)
    }
    public func updateNDI(_ id: InputID, _ c: ProjectNDI) {
        guard let src = ndiSource(id) else { return }
        if let used = ndiInUse(c.sourceName, except: id) { report(L10n.f("inputs.already_used", used)); return }
        if src.name == src.config.displayName { rename(id, c.displayName) }
        src.reconfigure(c)
    }

    public func timerSource(_ id: InputID) -> TimerSource? { engine?.source(id) as? TimerSource }
    public func tickerSource(_ id: InputID) -> TickerSource? { engine?.source(id) as? TickerSource }
    public func addTicker(_ c: TickerConfig) { engine?.addTicker(c) }
    public func updateTicker(_ id: InputID, _ c: TickerConfig) { tickerSource(id)?.update(c); objectWillChange.send() }
    public func slideshowSource(_ id: InputID) -> SlideshowSource? { engine?.source(id) as? SlideshowSource }
    public func addSlideshow(urls: [URL], interval: Double, fade: Double, loop: Bool, kenBurns: Bool, folder: URL?) {
        engine?.addSlideshow(urls: urls, interval: interval, fade: fade, loop: loop, kenBurns: kenBurns, folder: folder)
    }
    func pickTextFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText]
        return panel.runModal() == .OK ? panel.url : nil
    }
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    func pickImages() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.urls : []
    }
    public func addTimer(_ config: TimerConfig) { engine?.addTimer(config) }
    public func updateTimer(_ id: InputID, _ config: TimerConfig) {
        guard let t = timerSource(id) else { return }
        t.update(config)
        objectWillChange.send()
    }
    public func timerControl(_ id: InputID, _ action: String) {
        guard let t = timerSource(id) else { return }
        switch action {
        case "play": t.play()
        case "pause": t.pause()
        default: t.reset()
        }
        objectWillChange.send()
    }

    // MARK: Key colour eyedropper

    /// A still of an input's current picture (before keying), small enough to sample on the main thread.
    public struct InputStill {
        public let image: CGImage
        public let pixels: [UInt8]   // BGRA, premultiplied
        public let width: Int, height: Int
        public func sample(nx: Double, ny: Double) -> ChromaKey.RGB? {
            pixels.withUnsafeBufferPointer { p in
                ChromaKey.sampleColor(bgra: p.baseAddress!, width: width, height: height, bytesPerRow: width * 4,
                                      x: Int(nx * Double(width)), y: Int(ny * Double(height)))
            }
        }
    }

    public func inputStill(_ id: InputID, maxWidth: Int = 640) -> InputStill? {
        guard let src = engine?.source(id),
              let pb = (src as? VideoFileSource)?.lastFrame() ?? src.currentFrame() else { return nil }
        var ci = CIImage(cvPixelBuffer: pb)
        let scale = min(1, Double(maxWidth) / ci.extent.width)
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let img = CIContext(options: [.workingColorSpace: space]).createCGImage(ci, from: ci.extent) else { return nil }
        // Pixels for sampling: the same still drawn into a BGRA bitmap (row 0 = top of the picture).
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return InputStill(image: img, pixels: px, width: w, height: h)
    }

    // MARK: Snapshot

    /// Saves the current Program frame as a PNG in the recording folder.
    public func saveSnapshot() {
        guard let pb = lastProgramFrame else { report("No Program frame to save yet."); return }
        let folder = settings.recording.folderPath.isEmpty ? RecordingEngine.defaultFolder()
            : URL(fileURLWithPath: settings.recording.folderPath, isDirectory: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = folder.appendingPathComponent("Snapshot \(f.string(from: Date())).png")
        let ci = CIImage(cvPixelBuffer: pb)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let cg = CIContext().createCGImage(ci, from: ci.extent),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                report("Cannot create snapshot image."); return
            }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { report("Cannot write snapshot to \(url.path)."); return }
            lastSnapshotURL = url
        } catch {
            report("Cannot save snapshot: \(error.localizedDescription)")
        }
    }

    // MARK: Chroma key

    public func chromaKey(_ id: InputID) -> ChromaKey { engine?.chromaKey(of: id) ?? ChromaKey() }
    public func setChromaKey(_ key: ChromaKey, for id: InputID) { engine?.setChromaKey(key, for: id) }
    public func rename(_ id: InputID, _ name: String) {
        guard !isLocked(id) else { report(L10n.t("lock.input_locked")); return }
        engine?.renameInput(id, to: name)
    }
    public func layers(of id: InputID) -> [Layer] { engine?.layers(of: id) ?? [] }
    public func setLayers(_ layers: [Layer], of id: InputID) { engine?.setLayers(layers, of: id) }
    /// Layer Designer: edits shown on Preview only until committed (see ProductionEngine.setDraftLayers).
    public func setDraftLayers(_ layers: [Layer], of id: InputID) { engine?.setDraftLayers(layers, of: id) }
    public func draftLayers(of id: InputID) -> [Layer]? { engine?.draftLayers(of: id) }
    public func frameSize(_ id: InputID) -> PixelSize? { engine?.frameSize(of: id) }

    public func addPiP(source: InputID, preset: LayoutPreset) {
        guard let target = switcher.preview, target != source else { return }
        engine?.addLayer(to: target, source: source, preset: preset)
    }

    public func videoFile(_ id: InputID) -> VideoFileSource? { engine?.source(id) as? VideoFileSource }
    public func textSource(_ id: InputID) -> TextSource? { engine?.source(id) as? TextSource }

    private func pickFile(types: [String], _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types.compactMap { UTType($0) }
        if panel.runModal() == .OK, let url = panel.url { done(url) }
    }

    // MARK: Switching

    public func preview(_ id: InputID) { engine?.setPreview(id) }
    public func cut() { engine?.cut() }
    public func auto() {
        engine?.setTransition(transitionKind, duration: transitionDuration)
        engine?.auto()
    }
    public func setTBar(_ v: Double) {
        engine?.setTransition(transitionKind, duration: transitionDuration)
        tbar = v
        engine?.setTBar(v)
    }
    public func cutDirect(_ id: InputID) { engine?.cutDirect(id) }

    // MARK: Custom transitions

    /// Uses the shader `id` for AUTO / T-bar (compiles it now; problems show under the picker).
    public func selectCustomTransition(_ id: String) {
        transitionKind = .custom
        customTransitionID = id
        customTransitionError = engine?.setCustomTransition(id)
        settings.customTransition = id
        settings.transition = .custom
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    /// Re-reads the folder and recompiles the selected shader (after editing a file).
    public func reloadCustomTransitions() {
        customTransitions = CustomTransitionLibrary.entries()
        if let id = customTransitionID { selectCustomTransition(id) }
    }

    public func importCustomTransition() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let metal = UTType(filenameExtension: "metal") { panel.allowedContentTypes = [metal, .plainText] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let id = try CustomTransitionLibrary.importFile(url)
            customTransitions = CustomTransitionLibrary.entries()
            selectCustomTransition(id)
        } catch {
            report("Cannot import transition: \(error.localizedDescription)")
        }
    }

    /// Creates a new shader file from the template and opens it in the default editor.
    public func newCustomTransition() {
        do {
            let url = try CustomTransitionLibrary.createFromTemplate()
            customTransitions = CustomTransitionLibrary.entries()
            selectCustomTransition(CustomTransitionSource.fileID(url.lastPathComponent))
            if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch {
            report("Cannot create transition: \(error.localizedDescription)")
        }
    }

    public func revealCustomTransitionsFolder() {
        let dir = CustomTransitionLibrary.folder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    public func setStinger(source: InputID?, cutPoint: Double?) {
        let cfg = StingerConfig(source: source, cutPoint: cutPoint)
        engine?.setStinger(cfg)
        stinger = engine?.stinger ?? cfg
    }

    /// Length of the selected stinger clip, nil until the file is ready.
    public var stingerDuration: Double? {
        guard let id = stinger.source else { return nil }
        return (engine?.source(id) as? VideoFileSource)?.duration
    }
    public func previewNumber(_ n: Int) {
        guard n >= 1, n <= inputs.count else { return }
        preview(inputs[n - 1].id)
    }

    // MARK: MIDI control

    public let midi = MIDIInput()
    @Published public var midiMap = AppModel.loadMIDIMap() { didSet { saveMIDIMap() } }
    /// Action waiting for the next MIDI message to be bound to it (Learn).
    @Published public var midiLearning: ControlAction?
    @Published public private(set) var midiSources: [String] = []
    @Published public private(set) var lastMIDI: String = ""

    private func startMIDI() {
        midi.onSourcesChange = { [weak self] in self?.midiSources = self?.midi.sourceNames ?? [] }
        midi.onMessage = { [weak self] m in self?.handleMIDI(m) }
        midi.start()
        if let err = midi.error { report(err) }
    }

    private func handleMIDI(_ m: MIDIMessage) {
        lastMIDI = m.trigger.description
        if let action = midiLearning {
            // Learn on a press or a fader move; ignore the release that follows a press.
            if case .noteOff = m { return }
            midiMap.bind(m.trigger, to: action)
            midiLearning = nil
            return
        }
        switch midiMap.event(for: m) {
        case let .fire(a)?: perform(a)
        case let .set(.tbar, v)?: setTBar(v)
        default: break
        }
    }

    public func perform(_ a: ControlAction) {
        switch a {
        case .cut: cut()
        case .auto: auto()
        case .tbar: break
        case .streamToggle: requestToggleStream()
        case .recordToggle: requestToggleRecord()
        case .snapshot: saveSnapshot()
        case .fullscreenToggle: toggleFullscreen()
        case let .replay(sec): replayLast(Double(sec))
        case let .preview(n): previewNumber(n)
        case let .cutDirect(n): if n >= 1, n <= inputs.count { cutDirect(inputs[n - 1].id) }
        case let .overlay(i): toggleOverlay(i)
        }
    }

    public static func actionName(_ a: ControlAction) -> String {
        switch a {
        case .cut: return "CUT"
        case .auto: return "AUTO"
        case .tbar: return "T-bar"
        case .streamToggle: return L10n.t("midi.stream")
        case .recordToggle: return L10n.t("midi.record")
        case .snapshot: return "Snapshot"
        case .fullscreenToggle: return L10n.t("midi.fullscreen")
        case let .replay(sec): return L10n.f("replay.last", sec)
        case let .preview(n): return L10n.f("midi.preview", n)
        case let .cutDirect(n): return L10n.f("midi.cut_direct", n)
        case let .overlay(i): return "Overlay \(i)"
        }
    }

    private static func loadMIDIMap() -> MIDIMap {
        guard let d = UserDefaults.standard.data(forKey: "midiMap"), let m = try? JSONDecoder().decode(MIDIMap.self, from: d) else { return MIDIMap() }
        return m
    }

    private func saveMIDIMap() {
        if let d = try? JSONEncoder().encode(midiMap) { UserDefaults.standard.set(d, forKey: "midiMap") }
    }

    // MARK: Overlays

    public func setOverlayAnimation(_ index: Int, animation: OverlayAnimation, duration: Double) {
        engine?.setOverlayAnimation(index, animation: animation, duration: duration)
        overlays = engine?.overlays ?? []
    }

    public func configureOverlay(_ index: Int, source: InputID?, preset: LayoutPreset) {
        engine?.configureOverlay(index, source: source, preset: preset)
        overlays = engine?.overlays ?? []
    }

    /// Overlay number under an input tile: uses overlay channel `index` for this input (full
    /// screen, fade), then shows / hides it on Preview (click) or Program (secondary click).
    /// A channel showing another input switches to this one and stays on.
    public func overlayFromTile(_ index: Int, input: InputID, toProgram: Bool) {
        guard let e = engine, let ch = e.overlays.first(where: { $0.index == index }) else { return }
        if ch.source != input {
            e.configureOverlay(index, source: input, preset: .fullScreen)
            e.setOverlayAnimation(index, animation: .fade, duration: ch.fadeDuration)
            if ch.isOn || ch.onPreview {
                overlays = e.overlays
                return
            }
        }
        if toProgram { toggleOverlay(index) } else { toggleOverlayPreview(index) }
    }

    /// Click (one finger): show / hide the overlay on Preview only; CUT/AUTO takes it to Program.
    public func toggleOverlayPreview(_ index: Int) {
        guard let e = engine, let ch = e.overlays.first(where: { $0.index == index }) else { return }
        if ch.isOn {
            // Already on Program: a click takes it off air (same as vMix's overlay button).
            e.setOverlay(index, on: false)
        } else {
            e.setOverlayPreview(index, on: !ch.onPreview)
        }
        overlays = e.overlays
    }

    /// Secondary click (two fingers): straight to / off Program.
    public func toggleOverlay(_ index: Int) {
        guard let e = engine, let ch = e.overlays.first(where: { $0.index == index }) else { return }
        e.setOverlay(index, on: !ch.isOn)
        overlays = e.overlays
    }

    // MARK: Audio

    public func addAudioInput(_ d: DeviceManager.Device) {
        engine?.addAudioInput(uniqueID: d.id)
        reloadAudioChannels()
    }

    // MARK: Music

    private func pickAudioFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        return panel.runModal() == .OK ? panel.urls : []
    }

    public func addTracks(toMusic channelID: String) {
        guard let m = engine?.musicPlayer(channelID: channelID) else { return }
        let urls = pickAudioFiles()
        guard !urls.isEmpty else { return }
        m.appendTracks(urls)
    }

    // MARK: Instant replay

    public var replayEnabled: Bool { engine?.replaySource != nil }
    public var replaySource: ReplaySource? { engine?.replaySource }

    public func setReplayEnabled(_ on: Bool) {
        engine?.setReplayEnabled(on)
        engine?.replaySource?.speed = replaySpeed
        if !on { replayAvailable = 0 }
    }

    /// Loads the last `seconds` into the Replay input and puts it on Preview.
    public func replayLast(_ seconds: Double) {
        guard let e = engine else { return }
        if !replayEnabled { setReplayEnabled(true); report(L10n.t("replay.started")); return }
        e.replaySource?.speed = replaySpeed
        e.replayLast(seconds) { [weak self] ok in if !ok { self?.report(L10n.t("replay.empty")) } }
    }

    // MARK: Audio follow video

    public func afvLink(_ channelID: String) -> InputID? { engine?.afvLinks[channelID] }

    public func setAFV(_ channelID: String, input: InputID?) {
        engine?.setAudioFollowVideo(channelID: channelID, input: input)
        objectWillChange.send()
    }

    public func musicPlayer(_ channelID: String) -> MusicInput? { engine?.musicPlayer(channelID: channelID) }
    public var musicInputs: [MusicInput] { engine?.musicPlayers ?? [] }

    /// Media files listed in an M3U / M3U8 playlist the user picks (missing files are reported and skipped).
    func importM3U() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let dir = url.deletingLastPathComponent()
        var found: [URL] = [], missing = 0
        for p in M3U.parse(text) {
            let u = p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)
            if FileManager.default.fileExists(atPath: u.path) { found.append(u.standardizedFileURL) } else { missing += 1 }
        }
        if missing > 0 { report(L10n.f("playlist.m3u_missing", "\(missing)")) }
        return found
    }

    func exportM3U(_ urls: [URL]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText]
        panel.nameFieldStringValue = "Playlist.m3u8"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try M3U.write(paths: urls.map(\.path)).write(to: url, atomically: true, encoding: .utf8) }
        catch { report("Cannot save playlist: \(error.localizedDescription)") }
    }

    public func removeMusic(_ channelID: String) {
        guard let m = engine?.musicPlayer(channelID: channelID) else { return }
        engine?.removeMusic(id: m.id)
        reloadAudioChannels()
    }

    /// Closes a mixer channel the way its source is removed: device / tone channels are removed,
    /// a music input is removed, and audio that belongs to an input (video file, capture) removes
    /// that input. Locked channels (and locked inputs) are kept.
    public func closeAudioChannel(_ id: String) {
        guard let vm = audioChannels.first(where: { $0.id == id }) else { return }
        guard !vm.locked else { report(L10n.t("lock.audio_locked")); return }
        if let input = ProductionEngine.inputOfChannel(id) { remove(input); return }
        if vm.isMusicChannel { removeMusic(id) } else { removeAudioInput(id) }
    }

    public func lockAllAudio(_ locked: Bool) { for vm in audioChannels { vm.locked = locked } }

    public func removeAudioInput(_ id: String) {
        if let t = engine?.tone(channelID: id) { engine?.removeTone(id: t.id) } else { engine?.removeAudioInput(uniqueID: id) }
        reloadAudioChannels()
    }

    // MARK: Test tone

    public func addTone() {
        engine?.addTone(name: L10n.t("tone.name"))
        reloadAudioChannels()
    }
    public func tone(_ channelID: String) -> TestTone? { engine?.tone(channelID: channelID) }

    // MARK: Input colour correction / orientation

    public func adjust(of id: InputID) -> InputAdjust { engine?.adjust(of: id) ?? InputAdjust() }
    public func setAdjust(_ id: InputID, _ a: InputAdjust) { engine?.setAdjust(id, a) }

    /// Rebuilds channel view models, keeping existing ones so open popovers stay bound.
    public func reloadAudioChannels() {
        let existing = Dictionary(uniqueKeysWithValues: audioChannels.map { ($0.id, $0) })
        audioChannels = engine?.audioChannels.map { ch in
            if let vm = existing[ch.id], vm.channel === ch { return vm }
            return ChannelVM(channel: ch)
        } ?? []
    }

    /// Re-reads master/monitor values from the engine (after a project load).
    private func syncMasterFromEngine() {
        guard let m = engine?.mixer else { return }
        masterFader = FaderLaw.position(forDB: m.master.faderDB.value)
        limiterEnabled = m.limiterEnabled.value
        syncAuxFromEngine()
        monitorVolume = Double(m.monitorVolume.value)
        syncOffsetMs = Double(engine?.audioPump.syncOffsetSeconds.value ?? 0) * 1000
    }

    /// Plays an aux bus on an output device ("" = off).
    public func setAuxDevice(_ index: Int, uid: String) {
        guard let e = engine, auxBuses.indices.contains(index) else { return }
        if let msg = e.setAuxOutput(index, uid: uid.isEmpty ? nil : uid) { report(msg) }
        auxBuses[index].deviceUID = e.auxOutputUID(index) ?? ""
    }

    /// Mix-minus helper: every channel except `excluded` goes to the bus (e.g. a remote caller
    /// hears everyone but themselves).
    public func makeMixMinus(bus index: Int, excluding excluded: String) {
        for ch in audioChannels {
            if index == 0 { ch.toBusA = ch.id != excluded } else { ch.toBusB = ch.id != excluded }
        }
    }

    private func syncAuxFromEngine() {
        guard let e = engine else { return }
        auxBuses = e.mixer.aux.indices.map { i in AuxBusVM(index: i, controls: e.mixer.aux[i], deviceUID: e.auxOutputUID(i) ?? "") }
    }

    public func setMonitorDevice(uid: String) {
        monitorDeviceUID = uid
        engine?.mixer.setMonitorDevice(outputDevices.first { $0.uid == uid }?.id)
    }

    // MARK: Stream

    public static let primaryDestinationID = "primary"

    private static func isActive(_ s: StreamingEngine.Stats) -> Bool {
        switch s.state {
        case .idle, .failed: return false
        default: return true
        }
    }

    /// Aggregate status across destinations: live if any is live (bitrate summed), otherwise
    /// the first destination that is connecting/reconnecting/failed, otherwise idle.
    public var streamStats: StreamingEngine.Stats {
        let all = streamTargets.compactMap { destinationStats[$0.id] }
        let live = all.filter { $0.state == .live }
        if var first = live.first {
            first.bitrateKbps = live.reduce(0) { $0 + $1.bitrateKbps }
            first.droppedVideoFrames = live.reduce(0) { $0 + $1.droppedVideoFrames }
            first.uptime = live.map(\.uptime).max() ?? first.uptime
            return first
        }
        return all.first { Self.isActive($0) } ?? all.first { if case .failed = $0.state { return true }; return false } ?? StreamingEngine.Stats()
    }

    public var isStreamingActive: Bool { streamTargets.contains { destinationStats[$0.id].map(Self.isActive) ?? true } }

    /// Whether a key exists in the Keychain for an account (never returns the key itself).
    public func hasKey(account: String) -> Bool {
        ((try? KeychainStore.load(account: account)) ?? nil)?.isEmpty == false
    }

    /// Saves or (when empty) deletes the key of an additional destination.
    public func saveKey(_ key: String, account: String) {
        do {
            if key.isEmpty { try KeychainStore.delete(account: account) }
            else { try KeychainStore.save(streamKey: key, account: account) }
        } catch {
            report(error.localizedDescription)
        }
    }

    /// Number of destinations that would go live now (enabled, URL set, key saved).
    public var readyDestinationCount: Int {
        var n = settings.stream.primaryEnabled && !settings.stream.serverURL.isEmpty && hasStreamKey ? 1 : 0
        n += settings.stream.additional.filter { $0.enabled && !$0.serverURL.isEmpty && hasKey(account: $0.keychainAccount) }.count
        return n
    }

    public func saveStreamKey(_ key: String) {
        do {
            if key.isEmpty { try KeychainStore.delete(account: settings.stream.keychainAccount) }
            else { try KeychainStore.save(streamKey: key, account: settings.stream.keychainAccount) }
            hasStreamKey = !key.isEmpty
        } catch {
            report(error.localizedDescription)
        }
    }

    public func toggleStream() {
        guard let e = engine else { return }
        guard !streamLocked else { report(L10n.t("lock.stream_locked")); return }
        if isStreamingActive {
            e.stopStreaming()
            if recordingStartedWithStream, isRecording, !recordLocked { e.stopRecording() }
            recordingStartedWithStream = false
            return
        }
        var targets: [ProductionEngine.StreamTarget] = []
        let st = settings.stream
        var candidates: [(id: String, name: String, url: String, account: String, bus: OutputBus)] = []
        if st.primaryEnabled { candidates.append((Self.primaryDestinationID, st.primaryName, st.serverURL, st.keychainAccount, st.primaryAudioBus)) }
        for d in st.additional where d.enabled { candidates.append((d.id, d.name, d.serverURL, d.keychainAccount, d.bus)) }
        for c in candidates {
            let label = c.name.isEmpty ? c.id : c.name
            do {
                guard !c.url.isEmpty else { report(L10n.f("stream.dest_no_url", label)); continue }
                guard let key = try KeychainStore.load(account: c.account), !key.isEmpty else {
                    report(L10n.f("stream.dest_no_key", label)); continue
                }
                targets.append(.init(id: c.id, name: label, url: try RTMPURL.parse(serverURL: c.url, streamKey: key), audioBus: c.bus))
            } catch let err as RTMPURL.ParseError {
                report("\(label): \(err.description)")
            } catch {
                report("\(label): \(error.localizedDescription)")
            }
        }
        guard !targets.isEmpty else { report(L10n.t("stream.no_destination")); return }
        destinationStats = [:]
        streamTargets = targets.map { ($0.id, $0.name) }
        do {
            try e.startStreaming(to: targets)
            if recordWithStream, !isRecording, !recordLocked {
                e.startRecording()
                recordingStartedWithStream = true
            }
        } catch {
            streamTargets = []
            report(error.localizedDescription)
        }
    }

    // MARK: Record

    public var isRecording: Bool {
        switch recordStats.state {
        case .recording, .finishing: return true
        default: return false
        }
    }

    public func toggleRecord() {
        guard let e = engine else { return }
        guard !recordLocked else { report(L10n.t("lock.record_locked")); return }
        recordingStartedWithStream = false
        if isRecording { e.stopRecording() } else { e.startRecording() }
    }

    // MARK: Settings

    public func apply(_ s: ProductionSettings) -> [String] {
        guard let e = engine else { return ["Engine not running"] }
        let errs = e.apply(s)
        if errs.isEmpty {
            settings = e.settings
            if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
        }
        return errs
    }

    public func saveShortcuts(_ s: ShortcutSettings) { shortcuts = s; s.save() }

    // MARK: Project files (.livecore, JSON)

    public func newProject() {
        guard let e = engine else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("project.new_confirm")
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("settings.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var doc = ProjectDocument(settings: settings)
        doc.audio = ProjectAudio()
        let warnings = e.loadProject(doc, projectDirectory: nil)
        warnings.forEach(report)
        projectURL = nil
        afterProjectLoad()
        setOutputRouting(OutputRouting())
        multiCorder = MultiCorderConfig()
        applyInputGroups(from: doc)
    }

    public func openProject() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [Self.projectType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    public func openProject(at url: URL) {
        guard let e = engine else { return }
        do {
            let data = try Data(contentsOf: url)
            let doc = try JSONDecoder().decode(ProjectDocument.self, from: data)
            let warnings = e.loadProject(doc, projectDirectory: url.deletingLastPathComponent())
            projectURL = url
            afterProjectLoad()
            setOutputRouting(doc.sanitized().outputs ?? OutputRouting())
            multiCorder = doc.sanitized().multiCorder ?? MultiCorderConfig()
            applyInputGroups(from: doc)
            if !warnings.isEmpty { report("\(L10n.t("project.warnings")): " + warnings.joined(separator: " · ")) }
        } catch {
            report("Cannot open project: \(error.localizedDescription)")
        }
    }

    public func saveProject() {
        if let url = projectURL { writeProject(to: url) } else { saveProjectAs() }
    }

    public func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? "Untitled.\(ProjectDocument.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeProject(to: url)
    }

    private func writeProject(to url: URL) {
        guard let e = engine else { return }
        var doc = e.exportProject(projectDirectory: url.deletingLastPathComponent())
        doc.outputs = outputRouting
        doc.multiCorder = multiCorder
        storeInputGroups(in: &doc)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(doc).write(to: url, options: .atomic)
            projectURL = url
        } catch {
            report("Cannot save project: \(error.localizedDescription)")
        }
    }

    private func afterProjectLoad() {
        guard let e = engine else { return }
        settings = e.settings
        transitionKind = settings.transition
        transitionDuration = settings.transitionDuration
        customTransitionID = settings.customTransition
        customTransitions = CustomTransitionLibrary.entries()
        overlays = e.overlays
        stinger = e.stinger
        reloadAudioChannels()
        syncMasterFromEngine()
    }

    /// Project files are JSON with their own extension (declared dynamically, no Info.plist UTI needed).
    static let projectType: UTType = UTType(filenameExtension: ProjectDocument.fileExtension, conformingTo: .json) ?? .json
}

/// Per-channel view model (controls are lock-free atomics shared with the render thread).
public final class ChannelVM: ObservableObject, Identifiable {
    public let channel: MixerChannel
    public var id: String { channel.id }
    @Published public var fader: Double { didSet { channel.controls.faderDB.value = FaderLaw.db(forPosition: fader) } }
    @Published public var gainDB: Double { didSet { channel.controls.gainDB.value = Float(gainDB) } }
    @Published public var pan: Double { didSet { channel.controls.pan.value = Float(pan) } }
    @Published public var muted: Bool { didSet { channel.controls.muted.value = muted } }
    @Published public var solo: Bool { didSet { channel.controls.solo.value = solo } }
    @Published public var toProgram: Bool { didSet { channel.controls.toProgram.value = toProgram } }
    @Published public var toBusA: Bool { didSet { channel.controls.toBusA.value = toBusA } }
    @Published public var toBusB: Bool { didSet { channel.controls.toBusB.value = toBusB } }
    @Published public var compressor: Bool { didSet { channel.controls.compressorEnabled.value = compressor } }
    @Published public var compThreshold: Double { didSet { channel.controls.compThresholdDB.value = Float(compThreshold) } }
    @Published public var compRatio: Double { didSet { channel.controls.compRatio.value = Float(compRatio) } }
    @Published public var gate: Bool { didSet { channel.controls.gateEnabled.value = gate } }
    @Published public var gateThreshold: Double { didSet { channel.controls.gateThresholdDB.value = Float(gateThreshold) } }
    @Published public var gateRange: Double { didSet { channel.controls.gateRangeDB.value = Float(gateRange) } }
    @Published public var highPass: Bool { didSet { channel.controls.highPassEnabled.value = highPass } }
    @Published public var highPassHz: Double { didSet { channel.controls.highPassHz.value = Float(highPassHz) } }
    @Published public var eq: Bool { didSet { channel.controls.eqEnabled.value = eq } }
    @Published public var eqLow: Double { didSet { channel.controls.eqLowDB.value = Float(eqLow) } }
    @Published public var eqMid: Double { didSet { channel.controls.eqMidDB.value = Float(eqMid) } }
    @Published public var eqMidHz: Double { didSet { channel.controls.eqMidHz.value = Float(eqMidHz) } }
    @Published public var eqHigh: Double { didSet { channel.controls.eqHighDB.value = Float(eqHigh) } }
    // Audio properties (0.15.0)
    @Published public var name: String { didSet { channel.name = name } }
    @Published public var compMakeup: Double { didSet { channel.controls.compMakeupDB.value = Float(compMakeup) } }
    @Published public var compAttack: Double { didSet { channel.controls.compAttackMs.value = Float(compAttack) } }
    @Published public var compRelease: Double { didSet { channel.controls.compReleaseMs.value = Float(compRelease) } }
    @Published public var mode: ChannelMode { didSet { channel.controls.mode = mode } }
    @Published public var invertPhase: Bool { didSet { channel.controls.invertPhase.value = invertPhase } }
    @Published public var delayMs: Double { didSet { channel.controls.delayMs.value = Float(delayMs) } }
    @Published public var locked: Bool { didSet { channel.locked = locked } }
    /// Audio of a video-file input (removed together with the input, not from the mixer).
    /// Audio that belongs to an input (video file or window/display capture).
    public var isFileChannel: Bool { ProductionEngine.inputOfChannel(channel.id) != nil }
    /// Channel of a music input (removed with the music input).
    public var isMusicChannel: Bool { channel.id.hasPrefix(ProductionEngine.musicChannelPrefix) }

    public init(channel: MixerChannel) {
        self.channel = channel
        let c = channel.controls
        locked = channel.locked
        name = channel.name
        compMakeup = Double(c.compMakeupDB.value)
        compAttack = Double(c.compAttackMs.value)
        compRelease = Double(c.compReleaseMs.value)
        mode = c.mode
        invertPhase = c.invertPhase.value
        delayMs = Double(c.delayMs.value)
        fader = FaderLaw.position(forDB: c.faderDB.value)
        gainDB = Double(c.gainDB.value)
        pan = Double(c.pan.value)
        muted = c.muted.value
        solo = c.solo.value
        toProgram = c.toProgram.value
        toBusA = c.toBusA.value
        toBusB = c.toBusB.value
        compressor = c.compressorEnabled.value
        compThreshold = Double(c.compThresholdDB.value)
        compRatio = Double(c.compRatio.value)
        gate = c.gateEnabled.value
        gateThreshold = Double(c.gateThresholdDB.value)
        gateRange = Double(c.gateRangeDB.value)
        highPass = c.highPassEnabled.value
        highPassHz = Double(c.highPassHz.value)
        eq = c.eqEnabled.value
        eqLow = Double(c.eqLowDB.value)
        eqMid = Double(c.eqMidDB.value)
        eqMidHz = Double(c.eqMidHz.value)
        eqHigh = Double(c.eqHighDB.value)
    }
}

/// Aux bus A/B view model (fader and mute are atomics shared with the render thread).
public final class AuxBusVM: ObservableObject, Identifiable {
    public let index: Int
    public let controls: ChannelControls
    public var id: Int { index }
    public var name: String { index == 0 ? "AUX A" : "AUX B" }
    @Published public var fader: Double { didSet { controls.faderDB.value = FaderLaw.db(forPosition: fader) } }
    @Published public var muted: Bool { didSet { controls.muted.value = muted } }
    @Published public var deviceUID: String

    init(index: Int, controls: ChannelControls, deviceUID: String) {
        self.index = index; self.controls = controls; self.deviceUID = deviceUID
        fader = FaderLaw.position(forDB: controls.faderDB.value)
        muted = controls.muted.value
    }
}

/// Meter levels refreshed at 30 Hz. Kept separate so only meter views re-render.
public final class MeterModel: ObservableObject {
    public struct Level: Equatable {
        public var l: Float; public var r: Float; public var holdL: Float; public var holdR: Float; public var gr: Float
        public var gate: Float = 0
    }
    @Published public var levels: [String: Level] = [:]
    @Published public var master = Level(l: -120, r: -120, holdL: -120, holdR: -120, gr: 0)
    @Published public var aux: [Level] = []
    private var ballistics: [String: (MeterBallistics, MeterBallistics)] = [:]
    private var lastTime = HostClockUI.now()

    func update(channels: [MixerChannel], master m: ChannelControls, aux auxControls: [ChannelControls] = []) {
        let now = HostClockUI.now()
        let dt = now - lastTime
        lastTime = now
        var out: [String: Level] = [:]
        func step(_ key: String, _ c: ChannelControls) -> Level {
            var (bl, br) = ballistics[key] ?? (MeterBallistics(), MeterBallistics())
            bl.update(peakLinear: c.peakL.exchange(0), dt: dt, now: now)
            br.update(peakLinear: c.peakR.exchange(0), dt: dt, now: now)
            ballistics[key] = (bl, br)
            return Level(l: bl.levelDB, r: br.levelDB, holdL: bl.peakHoldDB, holdR: br.peakHoldDB, gr: c.gainReductionDB.value,
                         gate: c.gateReductionDB.value)
        }
        for ch in channels { out[ch.id] = step(ch.id, ch.controls) }
        let mm = step("__master", m)
        if out != levels { levels = out }
        if mm != master { master = mm }
        let ax = auxControls.enumerated().map { step("__aux\($0.offset)", $0.element) }
        if ax != aux { aux = ax }
    }
}

enum HostClockUI {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}
#endif

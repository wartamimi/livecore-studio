#if os(macOS)
import AppKit
import AVFoundation
import Combine
import CoreImage
import ImageIO
import LiveCoreCore
import LiveCoreEngine
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
    @Published public var tbar: Double = 0
    @Published public var overlays: [OverlayChannel] = []
    public let programFeed = FrameFeed()
    public let previewFeed = FrameFeed()
    public let programOutputFeed = FrameFeed()   // external-display window
    public private(set) var thumbnailFeeds: [InputID: FrameFeed] = [:]

    // Devices
    @Published public var videoDevices: [DeviceManager.Device] = []
    @Published public var audioDevices: [DeviceManager.Device] = []
    @Published public var outputDevices: [AudioDeviceInfo] = []
    @Published public var monitorDeviceUID: String = ""
    /// Aux buses A and B (created once the engine runs).
    @Published public private(set) var auxBuses: [AuxBusVM] = []
    /// Last Program snapshot saved with `saveSnapshot()`.
    @Published public private(set) var lastSnapshotURL: URL?
    private var lastProgramFrame: CVPixelBuffer?
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
    @Published public var hasStreamKey = false
    @Published public var performance = PerformanceSnapshot.zero
    @Published public var shortcuts = ShortcutSettings.load()

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
        transitionKind = settings.transition
        transitionDuration = settings.transitionDuration
        do {
            let e = try ProductionEngine(settings: settings)
            engine = e
            wire(e)
            e.start()
            refreshDevices()
            hasStreamKey = ((try? KeychainStore.load(account: settings.stream.keychainAccount)) ?? nil)?.isEmpty == false
            overlays = e.overlays
            syncAuxFromEngine()
            startMIDI()
        } catch {
            startupError = error.localizedDescription
            return
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }

    public func shutdown() {
        statsTimer?.invalidate()
        midi.stop()
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
        e.onPreviewFrame = { [weak self] pb in self?.previewFeed.push(pb) }
        e.onThumbnails = { [weak self] thumbs in
            guard let self else { return }
            for (id, pb) in thumbs { self.feed(for: id).push(pb) }
        }
        e.onSwitcherChange = { [weak self] s in self?.switcher = s; if s.transition == nil { self?.tbar = 0 } }
        e.onInputsChange = { [weak self] list in
            guard let self else { return }
            self.inputs = list
            let ids = Set(list.map(\.id))
            self.thumbnailFeeds = self.thumbnailFeeds.filter { ids.contains($0.key) }
            self.overlays = e.overlays
        }
        e.onStreamStats = { [weak self] id, s in self?.destinationStats[id] = s }
        e.onRecordStats = { [weak self] s in self?.recordStats = s }
        e.onError = { [weak self] msg in self?.report(msg) }
        e.onAudioChannelsChange = { [weak self] in self?.reloadAudioChannels() }
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
        if tickCount % 30 == 0 { performance = e.samplePerformance() }
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

    public func addCamera(_ d: DeviceManager.Device) { engine?.addCamera(uniqueID: d.id) }

    public func addImage() {
        pickFile(types: ["public.image"]) { [weak self] url in self?.engine?.addImage(url: url) }
    }

    public func addVideo() {
        pickFile(types: ["public.movie"]) { [weak self] url in self?.engine?.addVideoFile(url: url) }
    }

    private func pickMovies() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie]
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// One input that plays several clips in order.
    public func addVideoPlaylist() {
        let urls = pickMovies()
        guard !urls.isEmpty else { return }
        engine?.addVideoFile(urls: urls)
    }

    public func addClips(to id: InputID) {
        guard let v = videoFile(id) else { return }
        let urls = pickMovies()
        guard !urls.isEmpty else { return }
        v.setURLs(v.urls + urls)
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

    public func remove(_ id: InputID) { engine?.removeInput(id) }

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
    public func timerSource(_ id: InputID) -> TimerSource? { engine?.source(id) as? TimerSource }
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
    public func rename(_ id: InputID, _ name: String) { engine?.renameInput(id, to: name) }
    public func layers(of id: InputID) -> [Layer] { engine?.layers(of: id) ?? [] }
    public func setLayers(_ layers: [Layer], of id: InputID) { engine?.setLayers(layers, of: id) }
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
        case .streamToggle: toggleStream()
        case .recordToggle: toggleRecord()
        case .snapshot: saveSnapshot()
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

    public func configureOverlay(_ index: Int, source: InputID?, preset: LayoutPreset) {
        engine?.configureOverlay(index, source: source, preset: preset)
        overlays = engine?.overlays ?? []
    }

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

    /// Adds a music input with one or more audio files (one mixer channel, plays as a playlist).
    public func addMusic() {
        let urls = pickAudioFiles()
        guard !urls.isEmpty, let e = engine else { return }
        e.addMusic(urls: urls)
        reloadAudioChannels()
    }

    public func addTracks(toMusic channelID: String) {
        guard let m = engine?.musicPlayer(channelID: channelID) else { return }
        let urls = pickAudioFiles()
        guard !urls.isEmpty else { return }
        m.setTracks(m.tracks + urls)
    }

    public func musicPlayer(_ channelID: String) -> MusicInput? { engine?.musicPlayer(channelID: channelID) }

    public func removeMusic(_ channelID: String) {
        guard let m = engine?.musicPlayer(channelID: channelID) else { return }
        engine?.removeMusic(id: m.id)
        reloadAudioChannels()
    }

    public func removeAudioInput(_ id: String) {
        engine?.removeAudioInput(uniqueID: id)
        reloadAudioChannels()
    }

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
        if isStreamingActive { e.stopStreaming(); return }
        var targets: [ProductionEngine.StreamTarget] = []
        let st = settings.stream
        var candidates: [(id: String, name: String, url: String, account: String)] = []
        if st.primaryEnabled { candidates.append((Self.primaryDestinationID, st.primaryName, st.serverURL, st.keychainAccount)) }
        for d in st.additional where d.enabled { candidates.append((d.id, d.name, d.serverURL, d.keychainAccount)) }
        for c in candidates {
            let label = c.name.isEmpty ? c.id : c.name
            do {
                guard !c.url.isEmpty else { report(L10n.f("stream.dest_no_url", label)); continue }
                guard let key = try KeychainStore.load(account: c.account), !key.isEmpty else {
                    report(L10n.f("stream.dest_no_key", label)); continue
                }
                targets.append(.init(id: c.id, name: label, url: try RTMPURL.parse(serverURL: c.url, streamKey: key)))
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
        let doc = e.exportProject(projectDirectory: url.deletingLastPathComponent())
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
    /// Audio of a video-file input (removed together with the input, not from the mixer).
    public var isFileChannel: Bool { channel.id.hasPrefix("file:") }
    /// Channel of a music input (removed with the music input).
    public var isMusicChannel: Bool { channel.id.hasPrefix(ProductionEngine.musicChannelPrefix) }

    public init(channel: MixerChannel) {
        self.channel = channel
        let c = channel.controls
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

#if os(macOS)
import AppKit
import AVFoundation
import Combine
import CoreImage
import ImageIO
import LiveCoreCore
import LiveCoreEngine
import LiveCoreRemote
import LiveCoreServices
import SwiftUI
import UniformTypeIdentifiers

/// UI state holder. All members are used on the main thread only; engine callbacks are
/// delivered on main by the engine. Video frames bypass SwiftUI entirely (`FrameFeed`).
public final class AppModel: ObservableObject {
    // Engine
    public internal(set) var engine: ProductionEngine?
    @Published public var startupError: String?

    // Inputs & switching
    @Published public var inputs: [ProductionEngine.InputInfo] = []
    @Published public var switcher = SwitcherSnapshot()
    @Published public var transitionKind: TransitionKind = .dissolve
    @Published public internal(set) var stinger = StingerConfig()
    @Published public var transitionDuration: Double = 1.0
    /// Custom shader transitions: available shaders, the selected one, and its last compile problem.
    @Published public internal(set) var customTransitions: [CustomTransitionLibrary.Entry] = []
    @Published public internal(set) var customTransitionID: String?
    @Published public internal(set) var customTransitionError: String?
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
    public internal(set) var thumbnailFeeds: [InputID: FrameFeed] = [:]
    /// The four extra outputs: one feed per output window / full-screen display.
    public let outputFeeds: [Int: FrameFeed] = Dictionary(uniqueKeysWithValues: (1...OutputRouting.count).map { ($0, FrameFeed()) })
    public internal(set) lazy var outputFullscreens: [Int: FullscreenOutput] = makeOutputFullscreens()
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
    @Published public internal(set) var auxBuses: [AuxBusVM] = []
    /// Last Program snapshot saved with `saveSnapshot()`.
    @Published public internal(set) var lastSnapshotURL: URL?
    /// Time of the last PHOTO saved, for the confirmation on the Program monitor.
    @Published public internal(set) var lastSnapshotAt: Date?
    var lastProgramFrame: CVPixelBuffer?
    var lastPreviewFrame: CVPixelBuffer?
    var lastMusicError: String?

    // Audio
    @Published public var audioChannels: [ChannelVM] = []
    public let meters = MeterModel()
    @Published public var syncOffsetMs: Double = 0 { didSet { engine?.audioPump.syncOffsetSeconds.value = Float(syncOffsetMs / 1000) } }
    @Published public var masterFader: Double = 0.75 { didSet { engine?.mixer.master.faderDB.value = FaderLaw.db(forPosition: masterFader) } }
    @Published public var limiterEnabled = true { didSet { engine?.mixer.limiterEnabled.value = limiterEnabled } }
    @Published public var monitorVolume: Double = 1 { didSet { engine?.mixer.monitorVolume.value = Float(monitorVolume) } }

    // Project
    @Published public internal(set) var projectURL: URL?

    // Outputs
    @Published public var settings = ProductionSettings()
    /// Live statistics per stream destination ("primary" or a StreamDestination id).
    @Published public var destinationStats: [String: StreamingEngine.Stats] = [:]
    /// Destinations of the current/last stream session, in display order.
    @Published public internal(set) var streamTargets: [(id: String, name: String)] = []
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

    var statsTimer: Timer?

    public init() {}

    public func start() {
        FontInstaller.registerAll()
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
            startAutosave()
        } catch {
            startupError = error.localizedDescription
            return
        }
        // Common modes: meters and stats keep moving while a menu is open.
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        statsTimer = t
        startStutterLog()
    }

    public func shutdown() {
        statsTimer?.invalidate()
        watchdog.stop()
        endAutosaveSession()
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

    func wire(_ e: ProductionEngine) {
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
        e.onSwitcherChange = { [weak self] s in self?.receiveSwitcher(s) }
        e.onInputsChange = { [weak self] list in
            guard let self else { return }
            self.inputs = list
            self.noteInputsChanged(list)
            let ids = Set(list.map(\.id))
            self.thumbnailFeeds = self.thumbnailFeeds.filter { ids.contains($0.key) }
            self.outputInputsChanged()
            self.overlays = e.overlays
        }
        e.onStreamStats = { [weak self] id, s in self?.destinationStats[id] = s }
        e.onVerticalStreamStats = { [weak self] s in DispatchQueue.main.async { self?.verticalStreamStats = s } }
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
        e.onRadioChange = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            for r in e.radios {
                if case let .failed(reason) = r.state, self.lastRadioErrors[r.id] != reason {
                    self.lastRadioErrors[r.id] = reason
                    self.report(L10n.f("radio.error", r.station.name, reason))
                    FileLog.shared.warning("online radio \(r.station.name) failed: \(reason)")
                } else if r.state == .playing {
                    self.lastRadioErrors[r.id] = nil
                }
            }
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
        FileLog.shared.error(message)
        if errors.last?.message == message { return }
        errors.append(ErrorItem(message: message))
        if errors.count > 5 { errors.removeFirst() }
    }

    public func dismissError(_ e: ErrorItem) { errors.removeAll { $0.id == e.id } }

    // MARK: Ticks (30 Hz meters, 1 Hz performance)

    var tickCount = 0
    // Switcher updates arrive every rendered frame during a transition; the UI takes at most
    // 30 per second of them (the whole window redraws on each), the last one always delivered.
    private var lastSwitcherPublish: CFTimeInterval = 0
    private var pendingSwitcher: SwitcherSnapshot?
    private var switcherFlushScheduled = false

    func receiveSwitcher(_ s: SwitcherSnapshot) {
        let now = CACurrentMediaTime()
        if s.transition != nil, switcher.transition != nil, now - lastSwitcherPublish < 1.0 / 30 {
            pendingSwitcher = s
            if !switcherFlushScheduled {
                switcherFlushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
                    guard let self else { return }
                    self.switcherFlushScheduled = false
                    if let p = self.pendingSwitcher { self.publishSwitcher(p) }
                }
            }
            return
        }
        publishSwitcher(s)
    }

    private func publishSwitcher(_ s: SwitcherSnapshot) {
        pendingSwitcher = nil
        lastSwitcherPublish = CACurrentMediaTime()
        if s != switcher { switcher = s }
        if s.transition == nil, tbar != s.tbarRest { tbar = s.tbarRest }
    }
    let watchdog = MainThreadWatchdog()
    var lastRadioErrors: [String: String] = [:]
    var lastDropCounts: (late: UInt64, busy: UInt64, failed: UInt64) = (0, 0, 0)
    func tick() {
        guard let e = engine else { return }
        meters.update(channels: e.audioChannels, master: e.mixer.master, aux: e.mixer.aux)
        tickCount += 1
        if tickCount % 3 == 0 { meters.updateLoudness(e.mixer) }
        if tickCount % 30 == 0 { performance = e.samplePerformance(); refreshExternalStatus(); logRenderDrops(e) }
        if remoteServer != nil, tickCount % 3 == 0 { pushRemoteState(clients: tickCount % 30 == 0) }
        if remoteServer != nil, tickCount % 2 == 0 { pushRemoteFrames() }
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

    // MARK: State used by the extension files

    /// Per-input viewer (fullscreen button on the tiles).
    @Published public internal(set) var viewerInput: InputID?
    public let viewerFeed = FrameFeed()

    /// While locked, the stream / recording cannot be started or stopped (buttons, menu, shortcuts).
    @Published public var streamLocked = false
    @Published public var recordLocked = false
    /// Stop Streaming / Stop Recording waiting for the operator's confirmation.
    @Published public var pendingStop: StopRequest?
    /// Start recording automatically when streaming starts (and stop it with the stream).
    @Published public var recordWithStream = UserDefaults.standard.bool(forKey: "recordWithStream") {
        didSet { UserDefaults.standard.set(recordWithStream, forKey: "recordWithStream") }
    }
    var recordingStartedWithStream = false

    /// MIDI control: the input, the action map, Learn, and what was received.
    public let midi = MIDIInput()
    @Published public var midiMap = AppModel.loadMIDIMap() { didSet { saveMIDIMap() } }
    /// Action waiting for the next MIDI message to be bound to it (Learn).
    @Published public var midiLearning: ControlAction?
    @Published public internal(set) var midiSources: [String] = []
    @Published public internal(set) var lastMIDI: String = ""

    /// Autosave / crash recovery (0.37.0).
    var autosave: AutosaveStore?
    var autosaveTimer: Timer?
    let launchUptime = ProcessInfo.processInfo.systemUptime
    /// Undo / redo of input changes, and the inputs known before the last change.
    var undoSteps: [InputUndo] = []
    var redoSteps: [InputUndo] = []
    var undoSuspended = 0
    var knownInputs: Set<InputID> = []
    /// The open editor's undo (Layer Designer), used by Edit › Undo.
    public var editorUndo: EditorUndo?
    /// Operator (show) or Advanced (set-up) screen.
    @Published public internal(set) var uiMode: UIMode = AppModel.loadUIMode()
    /// Title data sources: loaded tables, load errors and link refresh timers, per title input.
    @Published public internal(set) var dataTables: [InputID: CSVTable] = [:]
    @Published public internal(set) var dataErrors: [InputID: String] = [:]
    var dataTimers: [InputID: Timer] = [:]
    /// PTZ: last connection problem per camera input (nil = fine).
    @Published public internal(set) var ptzStatus: [InputID: String] = [:]
    /// Panels opened from the menus.
    @Published public var showPreflight = false
    // Vertical 9:16 output and event rundown (0.42.0).
    @Published public var verticalStreamStats: StreamingEngine.Stats?
    @Published public var rundown = Rundown()
    @Published public var rundownIndex: Int?
    @Published public var rundownStart: Date?
    var rundownTimer: Timer?
    /// Chapters (rundown segments) and highlights marked during the show (0.43.0).
    @Published public var showMarks: [ShowMark] = []
    @Published public var packageProgress: String?
    @Published public var showOutputsPanel = false
    @Published public var showTemplates = false
    /// True while the crash-recovery question is pending (the welcome screen waits for it).
    public internal(set) var recoveryPending = false
}
#endif

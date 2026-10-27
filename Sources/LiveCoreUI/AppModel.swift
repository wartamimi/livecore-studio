#if os(macOS)
import AppKit
import AVFoundation
import Combine
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

    // Audio
    @Published public var audioChannels: [ChannelVM] = []
    public let meters = MeterModel()
    @Published public var syncOffsetMs: Double = 0 { didSet { engine?.audioPump.syncOffsetSeconds.value = Float(syncOffsetMs / 1000) } }

    // Outputs
    @Published public var settings = ProductionSettings()
    @Published public var streamStats = StreamingEngine.Stats()
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
        } catch {
            startupError = error.localizedDescription
            return
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }

    public func shutdown() {
        statsTimer?.invalidate()
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
        e.onProgramFrame = { [weak self] pb in self?.programFeed.push(pb); self?.programOutputFeed.push(pb) }
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
        e.onStreamStats = { [weak self] s in self?.streamStats = s }
        e.onRecordStats = { [weak self] s in self?.recordStats = s }
        e.onError = { [weak self] msg in self?.report(msg) }
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
        meters.update(channels: e.audioChannels, master: e.mixer.master)
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
        audioChannels = e.audioChannels.map { ChannelVM(channel: $0) }
    }

    // MARK: Inputs

    public func addCamera(_ d: DeviceManager.Device) { engine?.addCamera(uniqueID: d.id) }

    public func addImage() {
        pickFile(types: ["public.image"]) { [weak self] url in self?.engine?.addImage(url: url) }
    }

    public func addVideo() {
        pickFile(types: ["public.movie"]) { [weak self] url in self?.engine?.addVideoFile(url: url) }
    }

    public func addColor(_ c: NSColor, name: String) { engine?.addColor(c, name: name) }

    public func addTitle(title: String, subtitle: String, bar: Bool) {
        var style = TextSource.Style(title: title, subtitle: subtitle)
        style.showBar = bar
        engine?.addTitle(style)
    }

    public func updateTitle(_ id: InputID, title: String, subtitle: String, bar: Bool) {
        guard let src = engine?.source(id) as? TextSource else { return }
        var st = src.style
        st.title = title; st.subtitle = subtitle; st.showBar = bar
        src.update(st)
        engine?.renameInput(id, to: src.name)
    }

    public func remove(_ id: InputID) { engine?.removeInput(id) }
    public func rename(_ id: InputID, _ name: String) { engine?.renameInput(id, to: name) }
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
    public func previewNumber(_ n: Int) {
        guard n >= 1, n <= inputs.count else { return }
        preview(inputs[n - 1].id)
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
        audioChannels = engine?.audioChannels.map { ChannelVM(channel: $0) } ?? []
    }

    public func removeAudioInput(_ id: String) {
        engine?.removeAudioInput(uniqueID: id)
        audioChannels = engine?.audioChannels.map { ChannelVM(channel: $0) } ?? []
    }

    public func setMonitorDevice(uid: String) {
        monitorDeviceUID = uid
        engine?.mixer.setMonitorDevice(outputDevices.first { $0.uid == uid }?.id)
    }

    // MARK: Stream

    public var isStreamingActive: Bool {
        switch streamStats.state {
        case .idle, .failed: return false
        default: return true
        }
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
        do {
            guard let key = try KeychainStore.load(account: settings.stream.keychainAccount), !key.isEmpty else {
                report("Enter a stream key in Settings › Stream first."); return
            }
            try e.startStreaming(streamKey: key)
        } catch let err as RTMPURL.ParseError {
            report(err.description)
        } catch {
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
    @Published public var compressor: Bool { didSet { channel.controls.compressorEnabled.value = compressor } }
    @Published public var compThreshold: Double { didSet { channel.controls.compThresholdDB.value = Float(compThreshold) } }
    @Published public var compRatio: Double { didSet { channel.controls.compRatio.value = Float(compRatio) } }

    public init(channel: MixerChannel) {
        self.channel = channel
        let c = channel.controls
        fader = FaderLaw.position(forDB: c.faderDB.value)
        gainDB = Double(c.gainDB.value)
        pan = Double(c.pan.value)
        muted = c.muted.value
        solo = c.solo.value
        toProgram = c.toProgram.value
        compressor = c.compressorEnabled.value
        compThreshold = Double(c.compThresholdDB.value)
        compRatio = Double(c.compRatio.value)
    }
}

/// Meter levels refreshed at 30 Hz. Kept separate so only meter views re-render.
public final class MeterModel: ObservableObject {
    public struct Level: Equatable { public var l: Float; public var r: Float; public var holdL: Float; public var holdR: Float; public var gr: Float }
    @Published public var levels: [String: Level] = [:]
    @Published public var master = Level(l: -120, r: -120, holdL: -120, holdR: -120, gr: 0)
    private var ballistics: [String: (MeterBallistics, MeterBallistics)] = [:]
    private var lastTime = HostClockUI.now()

    func update(channels: [MixerChannel], master m: ChannelControls) {
        let now = HostClockUI.now()
        let dt = now - lastTime
        lastTime = now
        var out: [String: Level] = [:]
        func step(_ key: String, _ c: ChannelControls) -> Level {
            var (bl, br) = ballistics[key] ?? (MeterBallistics(), MeterBallistics())
            bl.update(peakLinear: c.peakL.exchange(0), dt: dt, now: now)
            br.update(peakLinear: c.peakR.exchange(0), dt: dt, now: now)
            ballistics[key] = (bl, br)
            return Level(l: bl.levelDB, r: br.levelDB, holdL: bl.peakHoldDB, holdR: br.peakHoldDB, gr: c.gainReductionDB.value)
        }
        for ch in channels { out[ch.id] = step(ch.id, ch.controls) }
        let mm = step("__master", m)
        if out != levels { levels = out }
        if mm != master { master = mm }
    }
}

enum HostClockUI {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}
#endif

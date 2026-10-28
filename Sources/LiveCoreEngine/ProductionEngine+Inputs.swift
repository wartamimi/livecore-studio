#if os(macOS)
import AVFoundation
import AppKit
import CoreMedia
import Foundation
import LiveCoreCore

/// Inputs, scene layers, Layer Designer drafts and chroma keys (main thread).
extension ProductionEngine {
    // MARK: Inputs (main thread)

    public var inputs: [InputInfo] {
        control.read { st in
            st.order.enumerated().compactMap { i, id in
                guard let s = st.sources[id] else { return nil }
                var info = InputInfo(id: id, name: s.name, kind: s.kind, status: s.status, number: i + 1,
                                     locked: st.locked.contains(id))
                if let p = s as? PresentationSource { info.slide = (p.slide + 1, p.slideCount, p.isConverting) }
                return info
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
    public func addVideoFile(url: URL, id: InputID? = nil, loop: Bool = true, autoPlay: VideoFileSource.AutoPlay = .off) -> InputID {
        addVideoFile(urls: [url], id: id, loop: loop, autoPlay: autoPlay)
    }

    /// A video input; several URLs make a playlist played in order.
    @discardableResult
    public func addVideoFile(urls: [URL], id: InputID? = nil, loop: Bool = true, autoPlay: VideoFileSource.AutoPlay = .off,
                             autoRestart: Bool = true) -> InputID {
        let src = VideoFileSource(id: id ?? InputID(UUID().uuidString), urls: urls)
        src.loop = loop
        src.autoPlay = autoPlay
        src.autoRestart = autoRestart
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
        // Auto play inputs wait on their first frame until they go on Program.
        if src.autoPlayEnabled { src.cue() }
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

    /// Adds an online radio station in a new mixer channel (stopped until Play).
    @discardableResult
    public func addRadio(_ station: RadioStation, id: String? = nil) -> RadioInput {
        let rid = id ?? String(UUID().uuidString.prefix(8)).lowercased()
        let ch = mixer.addChannel(id: Self.radioChannelPrefix + rid, name: station.name)
        let r = RadioInput(id: rid, station: station, channel: ch)
        r.onChange = { [weak self] in self?.onRadioChange?() }
        radios.append(r)
        onAudioChannelsChange?()
        onRadioChange?()
        return r
    }

    public func removeRadio(id: String) {
        guard let i = radios.firstIndex(where: { $0.id == id }) else { return }
        radios.remove(at: i).stop()
        mixer.removeChannel(id: Self.radioChannelPrefix + id)
        afvLinks[Self.radioChannelPrefix + id] = nil
        onAudioChannelsChange?()
        onRadioChange?()
    }

    public func radio(channelID: String) -> RadioInput? {
        guard channelID.hasPrefix(Self.radioChannelPrefix) else { return nil }
        return radios.first { Self.radioChannelPrefix + $0.id == channelID }
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
        // Classic titles default to the lower-third area when used as a layer or overlay;
        // template titles cover the whole output and place themselves.
        control.mutate { $0.layers[src.id] = [Self.titleLayer(src)] }
        return src.id
    }

    static func titleLayer(_ src: TextSource) -> Layer {
        Layer(source: src.id, rect: src.isFullCanvas ? .full : LayoutPreset.lowerThird.rect, scaleMode: .fit)
    }

    /// Changes a title's text and design. When a classic title becomes a template title (or
    /// back), its own layer and the overlays showing it switch between lower third and full screen.
    public func updateTitle(_ id: InputID, style: TextSource.Style) {
        guard let src = source(id) as? TextSource else { return }
        let wasFull = src.isFullCanvas
        src.update(style)
        if wasFull != src.isFullCanvas {
            control.mutate { st in
                var layers = st.layers[id] ?? []
                if layers.isEmpty { layers = [Self.titleLayer(src)] } else { layers[0].rect = Self.titleLayer(src).rect }
                st.layers[id] = layers
                for i in st.overlays.indices where st.overlays[i].source == id {
                    if src.isFullCanvas, st.overlays[i].preset == .lowerThird { st.overlays[i].preset = .fullScreen }
                }
            }
        }
        renameInput(id, to: src.name)
    }

    /// Web page input. Titles-like default placement: full screen (overlay pages are made for it).
    @discardableResult
    public func addBrowser(_ config: ProjectBrowser, id: InputID? = nil) -> InputID {
        var c = config
        c.fps = BrowserURLPolicy.clampFPS(c.fps)
        let src = BrowserSource(id: id ?? InputID(UUID().uuidString), config: c)
        add(src)
        src.start()
        updateWebAudio()
        return src.id
    }

    /// Starts the Web audio channel while there are web inputs and removes it when the last goes.
    func updateWebAudio() {
        let browsers = control.read { st in st.order.compactMap { st.sources[$0] as? BrowserSource } }
        guard #available(macOS 14.2, *) else { return }
        if browsers.isEmpty {
            (webAudio as? WebAudioCapture)?.stop()
            webAudio = nil
            if mixer.channelList.contains(where: { $0.id == Self.webAudioChannelID }) {
                mixer.removeChannel(id: Self.webAudioChannelID)
                afvLinks[Self.webAudioChannelID] = nil
                onAudioChannelsChange?()
            }
            return
        }
        guard webAudio == nil else { return }
        let ch = mixer.addChannel(id: Self.webAudioChannelID, name: "Web audio", primeFrames: 2048, maxBufferedFrames: 9600)
        if let saved = pendingWebAudioSettings { restore(saved, to: ch); pendingWebAudioSettings = nil }
        let cap = WebAudioCapture(channel: ch)
        cap.knownPIDs = { [weak self] in
            guard let self else { return [] }
            return self.control.read { st in st.order.compactMap { st.sources[$0] as? BrowserSource } }.flatMap(\.webKitProcessIDs)
        }
        cap.onError = { [weak self] msg in self?.onError?(msg) }
        cap.start()
        webAudio = cap
        applyAFV()
        onAudioChannelsChange?()
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
    public static func ndiChannelID(_ id: InputID) -> String { "ndi:\(id.raw)" }

    /// The input a mixer channel belongs to (video file, capture or NDI audio), nil for devices/music.
    public static func inputOfChannel(_ channelID: String) -> InputID? {
        for prefix in ["file:", "screen:", "ndi:"] where channelID.hasPrefix(prefix) { return InputID(String(channelID.dropFirst(prefix.count))) }
        return nil
    }

    /// NDI® source from the network as an input; its audio (if any) gets a mixer channel.
    @discardableResult
    public func addNDI(_ config: ProjectNDI, id: InputID? = nil) -> InputID {
        let src = NDISource(id: id ?? InputID(UUID().uuidString), config: config)
        let srcID = src.id
        src.audioChannelProvider = { [weak self, weak src] in
            guard let self else { return MixerChannel.detached() }
            let chID = Self.ndiChannelID(srcID)
            if let existing = self.mixer.channelList.first(where: { $0.id == chID }) { return existing }
            let ch = self.mixer.addChannel(id: chID, name: src?.name ?? "NDI", primeFrames: 2048, maxBufferedFrames: 9600)
            if let saved = self.pendingFileChannelSettings.removeValue(forKey: srcID) { self.restore(saved, to: ch) }
            self.applyAFV()
            self.onAudioChannelsChange?()
            return ch
        }
        add(src)
        src.start()
        return src.id
    }

    /// The input already receiving this NDI source, if any.
    public func inputReceivingNDI(_ sourceName: String, except: InputID? = nil) -> InputID? {
        control.read { st in
            st.order.first { id in id != except && (st.sources[id] as? NDISource)?.config.sourceName == sourceName }
        }
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

    /// New text / style for a running text; its band moves when the height or position changed.
    public func updateTicker(_ id: InputID, _ config: TickerConfig) {
        guard let src = source(id) as? TickerSource else { return }
        let oldRect = src.config.layerRect
        src.update(config)
        let rect = config.clamped.layerRect
        guard rect != oldRect else { return }
        control.mutate { st in
            var layers = st.layers[id] ?? []
            if layers.isEmpty { layers = [Layer(source: id, rect: rect, scaleMode: .fit)] }
            else if layers[0].rect == oldRect { layers[0].rect = rect }
            st.layers[id] = layers
        }
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

    /// PowerPoint / Keynote / OpenDocument / PDF slides (0.35.0).
    @discardableResult
    public func addPresentation(url: URL, slide: Int = 0, background: ProjectColor? = nil, live: Bool = false,
                                id: InputID? = nil) -> InputID {
        let src = PresentationSource(id: id ?? InputID(UUID().uuidString), url: url, slide: slide,
                                     background: background, live: live, outputSize: settings.output.size)
        let srcID = src.id
        src.onChange = { [weak self] in self?.publishInputs() }
        // Live mode: the slide show's sound (embedded video, narration) gets a mixer channel.
        src.audioChannelProvider = { [weak self, weak src] in
            guard let self else { return MixerChannel.detached() }
            let chID = Self.screenChannelID(srcID)
            if let existing = self.mixer.channelList.first(where: { $0.id == chID }) { return existing }
            let ch = self.mixer.addChannel(id: chID, name: src?.name ?? "PowerPoint", primeFrames: 2048, maxBufferedFrames: 9600)
            if let saved = self.pendingFileChannelSettings.removeValue(forKey: srcID) { self.restore(saved, to: ch) }
            self.applyAFV()
            self.onAudioChannelsChange?()
            return ch
        }
        add(src)
        src.start()
        return src.id
    }

    /// Camera frame: the frame picture plus `camera` in its window (second layer).
    @discardableResult
    public func addFrame(_ design: FrameDesign, camera: InputID? = nil, id: InputID? = nil) -> InputID {
        let src = FrameSource(id: id ?? InputID(UUID().uuidString), design: design, outputSize: settings.output.size)
        add(src)
        setFrameCamera(src.id, camera)
        return src.id
    }

    /// Imported vMix GT title (.gtzip).
    @discardableResult
    public func addGTTitle(url: URL, template: GTTemplate, fields: [String: String] = [:], id: InputID? = nil) -> InputID {
        let src = GTTitleSource(id: id ?? InputID(UUID().uuidString), url: url, template: template, fields: fields,
                                outputSize: settings.output.size)
        add(src)
        return src.id
    }

    public func updateGTTitle(_ id: InputID, fields: [String: String]) {
        (source(id) as? GTTitleSource)?.setFields(fields)
    }

    /// New design (and camera) for a frame input; the camera layer follows the template's window.
    public func updateFrame(_ id: InputID, _ design: FrameDesign, camera: InputID?) {
        guard let f = source(id) as? FrameSource else { return }
        f.update(design)
        f.name = design.title.isEmpty ? "Frame" : "Frame – \(design.title)"
        setFrameCamera(id, camera)
        publishInputs()
    }

    /// The input shown in a frame's window (nil = none).
    public func frameCamera(_ id: InputID) -> InputID? {
        control.read { st in (st.layers[id] ?? []).dropFirst().first?.source }
    }

    func setFrameCamera(_ id: InputID, _ camera: InputID?) {
        guard let f = source(id) as? FrameSource else { return }
        let l = f.layout
        control.mutate { st in
            var layers = [st.layers[id]?.first ?? Layer(source: id)]
            // Layer 0 (the frame picture) is drawn first; the camera fills the window over it.
            if let cam = camera, cam != id, st.sources[cam] != nil, !(st.sources[cam] is FrameSource) {
                layers.append(Layer(source: cam, rect: l.camera, scaleMode: .fill,
                                    style: l.cameraStyle(accent: f.design.accent)))
            }
            st.layers[id] = st.sanitized(layers, of: id)
        }
    }

    public func source(_ id: InputID) -> VideoSource? { control.read { $0.sources[id] } }

    /// The input that already uses this camera / capture card, if any.
    public func inputUsingCamera(_ uniqueID: String) -> InputID? {
        control.read { st in st.order.first { (st.sources[$0] as? CameraSource)?.deviceUniqueID == uniqueID } }
    }

    /// The input (other than `except`) that already captures this window or display, if any.
    public func inputCapturing(_ c: ProjectScreenCapture, except: InputID? = nil) -> InputID? {
        control.read { st in
            st.order.first { id in
                id != except && (st.sources[id] as? ScreenCaptureSource)?.config.sameTarget(as: c) == true
            }
        }
    }

    func add(_ src: VideoSource) {
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
            st.drafts[id] = nil
            for key in st.drafts.keys { st.drafts[key]?.removeAll { $0.source == id && key != id } }
            st.keys[id] = nil
            st.locked.remove(id)
            st.adjusts[id] = nil
            if st.detail == id { st.detail = nil }
            if st.stinger.source == id { st.stinger.source = nil }
            st.order.removeAll { $0 == id }
            return st.sources.removeValue(forKey: id)
        }
        removed?.stop()
        ptzConfigs[id] = nil
        if let r = removed, r === replaySource { replayRemoved() }
        if removed is BrowserSource { updateWebAudio() }
        if removed is VideoFileSource || removed is ScreenCaptureSource || removed is PresentationSource {
            mixer.removeChannel(id: Self.fileChannelID(id))
            mixer.removeChannel(id: Self.screenChannelID(id))
            mixer.removeChannel(id: Self.ndiChannelID(id))
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

    /// Which pictures the extra outputs need besides Program (see `OutputRouting.renderedInputs`).
    public func setOutputRendering(inputs: [InputID], fullPreview: Bool) {
        control.mutate { $0.extraInputs = inputs; $0.fullPreview = fullPreview }
    }

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

    func publishInputs() {
        let list = inputs
        DispatchQueue.main.async { self.onInputsChange?(list) }
    }

    // MARK: Scene layers (basic composition / PiP on an input)

    public func layers(of id: InputID) -> [Layer] { control.read { $0.layers[id] ?? [] } }

    public func addLayer(to id: InputID, source: InputID, preset: LayoutPreset) {
        control.mutate { st in
            guard st.sources[id] != nil, st.sources[source] != nil, id != source else { return }
            let layer = Layer(source: source, rect: preset.rect, scaleMode: .fill)
            st.layers[id, default: [Layer(source: id)]].append(layer)
            st.drafts[id]?.append(layer)   // also visible while the Layer Designer has a draft
        }
    }

    /// Replaces the scene layers of an input (scene editor). Layer 0 must remain the input itself;
    /// layers pointing at unknown inputs are dropped.
    public func setLayers(_ layers: [Layer], of id: InputID) {
        control.mutate { st in
            guard st.sources[id] != nil else { return }
            st.drafts[id] = nil
            st.layers[id] = st.sanitized(layers, of: id)
        }
    }

    // MARK: Layer Designer draft (Preview only until a transition)

    /// Layer Designer edits of `id`: drawn on Preview (and outputs showing Preview) only. They go
    /// on air when that input is taken to Program (CUT, AUTO, T-bar, quick play). Each input keeps
    /// its own draft, so moving Preview elsewhere and back does not lose or publish the edits.
    public func setDraftLayers(_ layers: [Layer], of id: InputID) {
        control.mutate { st in
            guard st.sources[id] != nil else { return }
            st.drafts[id] = st.sanitized(layers, of: id)
        }
    }

    /// The uncommitted Layer Designer layers of `id`, if any.
    public func draftLayers(of id: InputID) -> [Layer]? { control.read { $0.drafts[id] } }

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
            let removed = l.remove(at: index)
            st.layers[id] = l
            if let i = st.drafts[id]?.firstIndex(where: { $0.source == removed.source }), i > 0 { st.drafts[id]?.remove(at: i) }
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
}
#endif

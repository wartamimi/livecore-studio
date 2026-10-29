#if os(macOS)
import AVFoundation
import AppKit
import CoreMedia
import Foundation
import LiveCoreCore
import LiveCoreServices

// MARK: - Project save / load

extension ProductionEngine {
    /// Snapshot of the current production as a project document. Media paths are also stored
    /// relative to `projectDirectory` so a copied project folder still finds its files.
    public func exportProject(projectDirectory: URL?) -> ProjectDocument {
        let (order, sources, layers, keys, overlays, sw, locked) = control.read { st in
            // Layer Designer drafts are saved too: the project keeps the layout being worked on.
            (st.order, st.sources, st.layers.merging(st.drafts) { $1 }, st.keys, st.overlays, st.switcher.state, st.locked)
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
                var show = ProjectSlideshow(images: sl.urls.map { ProjectMediaRef(path: $0.path, relativePath: rel($0)) },
                                            interval: sl.interval, fade: sl.fade, loop: sl.loop,
                                            kenBurns: sl.kenBurns ? true : nil,
                                            folder: sl.folder.map { ProjectMediaRef(path: $0.path, relativePath: rel($0)) })
                show.look = sl.look == SlideshowLook() ? nil : sl.look
                ps = .slideshow(show)
            case let c as ScreenCaptureSource: ps = .screen(c.config)
            case let n as NDISource: ps = .ndi(n.config)
            case let f as FrameSource: ps = .frame(f.design)
            case let sub as SubtitleSource: ps = .subtitles(sub.style)
            case let g as GTTitleSource:
                ps = .gtTitle(ProjectGTTitle(file: ProjectMediaRef(path: g.url.path, relativePath: rel(g.url)), fields: g.fields,
                                              overrides: g.overrides.isEmpty ? nil : g.overrides, speed: g.speed == 1 ? nil : g.speed))
            case let p as PresentationSource:
                ps = .presentation(ProjectPresentation(file: ProjectMediaRef(path: p.url.path, relativePath: rel(p.url)),
                                                       slide: p.slide, background: p.background, live: p.prefersLive ? true : nil))
            default: continue
            }
            let key = keys[id]
            var pi = ProjectInput(id: id, name: src.name, source: ps, layers: layers[id] ?? [],
                                  chromaKey: key == ChromaKey() ? nil : key)
            let ai = inputAI(id)
            if ai.isActive { pi.ai = ai }
            if let v = src as? VideoFileSource {
                if v.autoPlay != .off { pi.autoPlay = v.autoPlay.rawValue }
                pi.autoRestart = v.autoRestart ? nil : false
            }
            if locked.contains(id) { pi.locked = true }
            if let c = src as? CameraSource, c.config != CaptureConfig() { pi.capture = c.config }
            pi.adjust = adjusts[id]
            pi.ptz = ptzConfigs[id]
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
        let ducking = mixer.ducking.settings
        doc.audio.ducking = ducking == DuckingSettings() ? nil : ducking
        doc.audio.aux = mixer.aux.indices.map { i in
            ProjectAuxBus(faderDB: mixer.aux[i].faderDB.value, muted: mixer.aux[i].muted.value, outputDeviceUID: auxOutputUID(i))
        }
        doc.audio.tones = tones.isEmpty ? nil : tones.map { t in
            var pc = Self.projectChannel(t.channel, deviceUniqueID: nil, inputID: nil)
            pc.afvInput = afvLinks[t.channel.id]
            return ProjectTone(id: t.id, frequency: t.frequency, levelDB: t.levelDB, channel: pc)
        }
        doc.audio.radios = radios.isEmpty ? nil : radios.map { r in
            var pc = Self.projectChannel(r.channel, deviceUniqueID: nil, inputID: nil)
            pc.afvInput = afvLinks[r.channel.id]
            return ProjectRadio(id: r.id, station: r.station, channel: pc)
        }
        for ch in mixer.channelList where !ch.id.hasPrefix(Self.musicChannelPrefix) && !ch.id.hasPrefix(Self.toneChannelPrefix)
            && !ch.id.hasPrefix(Self.radioChannelPrefix) {
            let owner = Self.inputOfChannel(ch.id)
            var pc = Self.projectChannel(ch, deviceUniqueID: owner == nil ? ch.id : nil, inputID: owner)
            pc.afvInput = afvLinks[ch.id]
            doc.audio.channels.append(pc)
        }
        doc.audio.music = musicPlayers.isEmpty ? nil : musicPlayers.map { m in
            var pm = ProjectMusic(id: m.id, name: m.name,
                         tracks: m.tracks.map { ProjectMediaRef(path: $0.path, relativePath: rel($0)) },
                         loop: m.loopPlaylist, shuffle: m.shuffle,
                         channel: { var pc = Self.projectChannel(m.channel, deviceUniqueID: nil, inputID: nil)
                                    pc.afvInput = afvLinks[m.channel.id]; return pc }(),
                         fadeSeconds: m.fadeSeconds > 0 ? m.fadeSeconds : nil)
            pm.repeatOne = m.repeatOne ? true : nil
            return pm
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
            Self.resolveMedia(path, relative, projectDirectory: projectDirectory, warnings: &warnings)
        }

        var created = Set<InputID>()
        for pi in doc.inputs {
            guard createInput(pi, projectDirectory: projectDirectory, warnings: &warnings) else { continue }
            created.insert(pi.id)
            renameInput(pi.id, to: pi.name)
        }

        aiProcessors.mutate { $0 = [:] }
        for pi in doc.inputs where created.contains(pi.id) { if let ai = pi.ai { setInputAI(pi.id, ai) } }
        control.mutate { st in
            st.drafts = [:]
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
        mixer.ducking.settings = doc.audio.ducking ?? DuckingSettings()
        ptzConfigs = [:]
        for pi in doc.inputs where created.contains(pi.id) { if let p = pi.ptz { ptzConfigs[pi.id] = p.clamped } }
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
            m.repeatOne = pm.repeatOne ?? false
            if let ch = pm.channel { restore(ch, to: m.channel) }
        }
        for r in radios.map(\.id) { removeRadio(id: r) }
        for pr in doc.audio.radios ?? [] {
            let r = addRadio(pr.station, id: pr.id)
            if let ch = pr.channel { restore(ch, to: r.channel) }
        }
        for t in tones.map(\.id) { removeTone(id: t) }
        for pt in doc.audio.tones ?? [] {
            let t = addTone(frequency: pt.frequency, levelDB: pt.levelDB, id: pt.id, name: pt.channel?.name ?? "Tone")
            if let ch = pt.channel { restore(ch, to: t.channel) }
        }
        for ch in doc.audio.channels {
            if ch.deviceUniqueID == Self.webAudioChannelID {
                if let mc = mixer.channelList.first(where: { $0.id == Self.webAudioChannelID }) { restore(ch, to: mc) }
                else { pendingWebAudioSettings = ch }
                continue
            }
            if let uid = ch.deviceUniqueID {
                guard DeviceManager.device(uniqueID: uid) != nil else {
                    warnings.append("Audio device \"\(ch.name)\" is not connected; its mixer channel was skipped.")
                    continue
                }
                addAudioInput(uniqueID: uid)
                if let mc = mixer.channelList.first(where: { $0.id == uid }) { restore(ch, to: mc) }
            } else if let iid = ch.inputID, created.contains(iid) {
                if let mc = mixer.channelList.first(where: { [Self.fileChannelID(iid), Self.screenChannelID(iid), Self.ndiChannelID(iid)].contains($0.id) }) { restore(ch, to: mc) }
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

    /// Media path from a project: the saved absolute path, else the path relative to the project folder.
    static func resolveMedia(_ path: String, _ relative: String?, projectDirectory: URL?, warnings: inout [String]) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        if let relative, let dir = projectDirectory {
            let candidate = ProjectPaths.resolve(relative, againstDirectory: dir.standardizedFileURL.path)
            if fm.fileExists(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        warnings.append("Media file not found: \(path)")
        return URL(fileURLWithPath: path)
    }

    /// Creates the source of a project input with its saved id (project load, undo of a removal).
    /// Returns false when it cannot be made (camera not connected, Lottie...), with a warning.
    func createInput(_ pi: ProjectInput, projectDirectory: URL?, warnings: inout [String]) -> Bool {
        var found: [String] = []
        func mediaURL(_ path: String, _ relative: String?) -> URL {
            Self.resolveMedia(path, relative, projectDirectory: projectDirectory, warnings: &found)
        }
        defer { warnings += found }
        switch pi.source {
        case let .camera(uid, deviceName):
            guard DeviceManager.device(uniqueID: uid) != nil,
                  addCamera(uniqueID: uid, id: pi.id, config: pi.capture ?? CaptureConfig()) != nil else {
                found.append("Camera \"\(deviceName)\" is not connected; input \"\(pi.name)\" was skipped.")
                return false
            }
        case let .videoFile(path, relative, loop):
            addVideoFile(urls: [mediaURL(path, relative)], id: pi.id, loop: loop,
                         autoPlay: pi.autoPlay.flatMap(VideoFileSource.AutoPlay.init(rawValue:)) ?? .off,
                         autoRestart: pi.autoRestart ?? true)
        case let .videoPlaylist(tracks, loop):
            guard !tracks.isEmpty else { return false }
            addVideoFile(urls: tracks.map { mediaURL($0.path, $0.relativePath) }, id: pi.id, loop: loop,
                         autoPlay: pi.autoPlay.flatMap(VideoFileSource.AutoPlay.init(rawValue:)) ?? .off,
                         autoRestart: pi.autoRestart ?? true)
        case let .image(path, relative):
            addImage(url: mediaURL(path, relative), id: pi.id)
        case .lottie:
            // Lottie inputs were removed in 0.15.0.
            found.append("Input \"\(pi.name)\" is a Lottie animation; Lottie is no longer supported and it was skipped.")
            return false
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
            let sid = addSlideshow(urls: photos ?? sl.images.map { mediaURL($0.path, $0.relativePath) }, interval: sl.interval,
                                   fade: sl.fade, loop: sl.loop, kenBurns: sl.kenBurns ?? false, folder: folder, id: pi.id)
            if let look = sl.look { (source(sid) as? SlideshowSource)?.look = look }
        case let .screen(c):
            addScreenCapture(c, id: pi.id)
        case let .ndi(n):
            addNDI(n, id: pi.id)
        case let .frame(d):
            addFrame(d, id: pi.id)
        case let .subtitles(st):
            addSubtitles(st, id: pi.id)
        case let .gtTitle(g):
            // A missing or broken .gtzip keeps its place as an empty title.
            let url = mediaURL(g.file.path, g.file.relativePath)
            addGTTitle(url: url, template: (try? GTReader.template(at: url)) ?? GTTemplate(width: 1920, height: 1080),
                       fields: g.fields, overrides: g.overrides ?? [:], speed: g.speed ?? 1, id: pi.id)
        case let .presentation(p):
            addPresentation(url: mediaURL(p.file.path, p.file.relativePath), slide: p.slide, background: p.background,
                            live: p.live ?? false, id: pi.id)
        }
        return true
    }

    /// Applies saved channel settings, including the AFV link.
    func restore(_ p: ProjectAudioChannel, to ch: MixerChannel) {
        Self.apply(p, to: ch.controls)
        ch.locked = p.locked ?? false
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
        if ch.locked { p.locked = true }
        if c.duckTrigger.value { p.duckTrigger = true }
        if c.duckTarget.value { p.duckTarget = true }
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
        c.duckTrigger.value = p.duckTrigger ?? false
        c.duckTarget.value = p.duckTarget ?? false
        if let eq = p.eq {
            c.highPassEnabled.value = eq.highPassEnabled; c.highPassHz.value = eq.highPassHz
            c.eqEnabled.value = eq.eqEnabled
            c.eqLowDB.value = eq.lowDB; c.eqMidDB.value = eq.midDB; c.eqMidHz.value = eq.midHz; c.eqHighDB.value = eq.highDB
        }
    }
}
#endif

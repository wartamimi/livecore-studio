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

/// Inputs: adding and editing them, the per-input viewer, locks, chroma key and snapshots.
extension AppModel {
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

    func inputLabel(_ id: InputID) -> String? {
        inputs.first { $0.id == id }.map { "\($0.number) \($0.name)" }
    }

    func rejectDuplicateCamera(_ uniqueID: String) -> Bool {
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

    /// An image file (e.g. a PHOTO just taken) as a new input.
    public func addImageInput(_ url: URL) { engine?.addImage(url: url) }

    /// Media files: video or audio. Several can be picked at once.
    func pickMedia() -> [URL] {
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
            // New media inputs play from the start when they go on Program (vMix Auto Play + Auto Restart).
            if Self.isAudioOnly(url) { e.addMusic(urls: [url]) } else { e.addVideoFile(url: url, autoPlay: .restartPause) }
        }
        reloadAudioChannels()
    }

    /// "Add Media Playlist": one input that plays the picked files in order. Only audio files ->
    /// a music playlist; any video file -> a video playlist (audio-only clips show black).
    public func addMediaPlaylist() {
        let urls = pickMedia()
        guard !urls.isEmpty, let e = engine else { return }
        if urls.allSatisfy(Self.isAudioOnly) { e.addMusic(urls: urls) } else { e.addVideoFile(urls: urls, autoPlay: .restartPause) }
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

    /// Tile buttons: AUTO (play on Program) and ↺ (start from the beginning each time).
    public func setAutoPlayEnabled(_ on: Bool, for id: InputID) {
        guard let v = videoFile(id) else { return }
        setAutoPlay(on ? (v.autoRestart ? .restartPause : .playPause) : .off, for: id)
    }

    public func setAutoRestart(_ on: Bool, for id: InputID) {
        engine?.setAutoRestart(on, for: id)
        objectWillChange.send()
    }

    public func setAutoPlay(_ mode: VideoFileSource.AutoPlay, for id: InputID) {
        engine?.setAutoPlay(mode, for: id)
        objectWillChange.send()
    }

    public func addColor(_ c: NSColor, name: String) { engine?.addColor(c, name: name) }

    public func addTitle(_ style: TextSource.Style) { engine?.addTitle(style) }

    public func updateTitle(_ id: InputID, style: TextSource.Style) { engine?.updateTitle(id, style: style) }

    public func remove(_ id: InputID) {
        guard !isLocked(id) else { report(L10n.t("lock.input_locked")); return }
        engine?.removeInput(id)
    }

    // MARK: Locks (protection against accidental changes)

    public func isLocked(_ id: InputID) -> Bool { inputs.first { $0.id == id }?.locked ?? false }
    public func toggleLock(_ id: InputID) { engine?.setInputLocked(id, !isLocked(id)) }
    public func lockAllInputs(_ locked: Bool) { for i in inputs { engine?.setInputLocked(i.id, locked) } }

    /// Stop Streaming / Stop Recording waiting for the operator's confirmation.
    public enum StopRequest: String, Identifiable { case stream, record, multicorder; public var id: String { rawValue } }

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
    public func addBrowser(_ config: ProjectBrowser) -> String? {
        if case let .rejected(reason) = BrowserURLPolicy.check(config.url) { return reason }
        engine?.addBrowser(config)
        reloadAudioChannels()
        return nil
    }

    public func updateBrowser(_ id: InputID, _ config: ProjectBrowser) -> String? {
        if case let .rejected(reason) = BrowserURLPolicy.check(config.url) { return reason }
        browserSource(id)?.update(config)
        return nil
    }

    public func browserSource(_ id: InputID) -> BrowserSource? { engine?.source(id) as? BrowserSource }

    /// Opens a web input's page in a window to click and type in; "Done" shows it again.
    public func editBrowserPage(_ id: InputID) {
        guard let b = browserSource(id) else { return }
        b.onEditingChange = { [weak self] _ in self?.objectWillChange.send() }
        let name = inputs.first { $0.id == id }?.name ?? b.name
        b.beginEditing(doneTitle: L10n.t("browser.edit_done"), windowTitle: L10n.f("browser.edit_window", name))
    }
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
    public func updateTicker(_ id: InputID, _ c: TickerConfig) { engine?.updateTicker(id, c); objectWillChange.send() }
    public func slideshowSource(_ id: InputID) -> SlideshowSource? { engine?.source(id) as? SlideshowSource }
    public func presentationSource(_ id: InputID) -> PresentationSource? { engine?.source(id) as? PresentationSource }
    public func frameSource(_ id: InputID) -> FrameSource? { engine?.source(id) as? FrameSource }

    /// Next / previous slide of the presentation on Program, else on Preview, else the first one
    /// (presentation clickers: Page Down / Page Up).
    public func presentationStep(forward: Bool) {
        let decks = inputs.filter { $0.kind == .presentation }.map(\.id)
        let target = [switcher.program, switcher.preview].compactMap { $0 }.first { decks.contains($0) } ?? decks.first
        guard let id = target, let p = presentationSource(id) else { return }
        forward ? p.next() : p.previous()
    }
    public func frameCamera(_ id: InputID) -> InputID? { engine?.frameCamera(id) }
    public func addFrame(_ d: FrameDesign, camera: InputID?) { engine?.addFrame(d, camera: camera) }
    public func updateFrame(_ id: InputID, _ d: FrameDesign, camera: InputID?) { engine?.updateFrame(id, d, camera: camera) }

    /// PowerPoint, Keynote, OpenDocument or PDF slides; one input per file.
    public func addPresentation() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = PresentationFiles.all.sorted().compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let e = engine else { return }
        let installed = PresentationConverter.installed()
        for url in panel.urls {
            let ext = url.pathExtension.lowercased()
            if PresentationFiles.needsConversion(ext), PresentationFiles.converter(for: ext, installed: installed) == nil {
                report(L10n.f("presentation.no_converter", ext))
                continue
            }
            // With PowerPoint installed, decks play live (animations, transitions, video) like vMix.
            e.addPresentation(url: url, live: PresentationSource.canPlayLive(url))
        }
        reloadAudioChannels()
    }
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
            lastSnapshotAt = Date()
            NSSound(named: "Grab")?.play()
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

    func pickFile(types: [String], _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types.compactMap { UTType($0) }
        if panel.runModal() == .OK, let url = panel.url { done(url) }
    }
}
#endif

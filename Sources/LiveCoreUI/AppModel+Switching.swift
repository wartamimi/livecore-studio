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

/// Switching, custom transitions, MIDI control and overlays.
extension AppModel {
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

    func startMIDI() {
        midi.onSourcesChange = { [weak self] in self?.midiSources = self?.midi.sourceNames ?? [] }
        midi.onMessage = { [weak self] m in self?.handleMIDI(m) }
        midi.start()
        if let err = midi.error { report(err) }
    }

    func handleMIDI(_ m: MIDIMessage) {
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

    static func loadMIDIMap() -> MIDIMap {
        guard let d = UserDefaults.standard.data(forKey: "midiMap"), let m = try? JSONDecoder().decode(MIDIMap.self, from: d) else { return MIDIMap() }
        return m
    }

    func saveMIDIMap() {
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
}
#endif

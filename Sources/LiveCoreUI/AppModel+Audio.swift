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

/// Audio: music, replay, AFV, test tone, aux buses and input colour correction.
extension AppModel {
    // MARK: Audio

    public func addAudioInput(_ d: DeviceManager.Device) {
        engine?.addAudioInput(uniqueID: d.id)
        reloadAudioChannels()
    }

    // MARK: Music

    func pickAudioFiles() -> [URL] {
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
    func syncMasterFromEngine() {
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

    func syncAuxFromEngine() {
        guard let e = engine else { return }
        auxBuses = e.mixer.aux.indices.map { i in AuxBusVM(index: i, controls: e.mixer.aux[i], deviceUID: e.auxOutputUID(i) ?? "") }
    }

    public func setMonitorDevice(uid: String) {
        monitorDeviceUID = uid
        engine?.mixer.setMonitorDevice(outputDevices.first { $0.uid == uid }?.id)
    }
}
#endif

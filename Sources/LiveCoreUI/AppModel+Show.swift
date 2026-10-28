#if os(macOS)
import AppKit
import CoreImage
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices

/// Vertical 9:16 output and the event rundown (0.42.0).
extension AppModel {
    // MARK: Vertical output

    public var verticalSettings: VerticalSettings { settings.verticalOutput }

    public func setVertical(_ v: VerticalSettings) {
        settings.vertical = v
        engine?.setVerticalSettings(v)
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    public var isVerticalStreaming: Bool { engine?.isVerticalStreaming ?? false }

    public func hasVerticalKey() -> Bool { ((try? KeychainStore.load(account: verticalSettings.keychainAccount)) ?? nil)?.isEmpty == false }

    public func saveVerticalKey(_ key: String) {
        do { try KeychainStore.save(streamKey: key, account: verticalSettings.keychainAccount) } catch {
            report("Keychain: \(error.localizedDescription)")
        }
        objectWillChange.send()
    }

    public func toggleVerticalStream() {
        guard let e = engine else { return }
        if e.isVerticalStreaming {
            e.stopVerticalStream()
            verticalStreamStats = nil
        } else {
            do {
                guard let key = try KeychainStore.load(account: verticalSettings.keychainAccount), !key.isEmpty else {
                    report(L10n.t("vertical.no_key")); return
                }
                try e.startVerticalStream(url: RTMPURL.parse(serverURL: verticalSettings.streamURL, streamKey: key))
            } catch {
                report(L10n.f("vertical.stream_failed", "\(error.localizedDescription)"))
            }
        }
        objectWillChange.send()
    }

    // MARK: Rundown

    public func setRundown(_ r: Rundown) {
        rundown = r
        if let i = rundownIndex, i >= r.segments.count { rundownIndex = nil }
    }

    /// Starts segment `i`: Program, title overlay and music as the segment says.
    public func goToSegment(_ i: Int) {
        guard let e = engine, rundown.segments.indices.contains(i) else { return }
        let prev = rundownIndex.flatMap { rundown.segments.indices.contains($0) ? rundown.segments[$0] : nil }
        for a in Rundown.actions(from: prev, to: rundown.segments[i]) {
            switch a {
            case let .program(id, useAuto):
                guard e.source(id) != nil else { continue }
                e.setPreview(id)
                useAuto ? auto() : cut()
            case let .overlayOff(n):
                if e.overlays.first(where: { $0.index == n })?.isOn == true { e.setOverlay(n, on: false) }
            case let .overlayOn(n, id):
                guard e.source(id) != nil else { continue }
                if e.overlays.first(where: { $0.index == n })?.isOn == true { e.setOverlay(n, on: false) }
                e.configureOverlay(n, source: id, preset: .fullScreen)
                e.setOverlay(n, on: true)
            case let .musicStop(m):
                e.musicPlayers.first { $0.id == m }?.pause()
            case let .musicPlay(m):
                e.musicPlayers.first { $0.id == m }?.play()
            }
        }
        overlays = e.overlays
        rundownIndex = i
        rundownStart = Date()
        startRundownTimer()
        FileLog.shared.info("rundown: segment \(i + 1) \(rundown.segments[i].title)")
    }

    public func nextSegment() { goToSegment((rundownIndex ?? -1) + 1) }
    public func previousSegment() { if let i = rundownIndex, i > 0 { goToSegment(i - 1) } }

    public func endRundown() {
        rundownIndex = nil
        rundownStart = nil
        rundownTimer?.invalidate()
        rundownTimer = nil
    }

    /// Ticks once a second: refreshes the countdown and starts the next segment when an
    /// auto-next segment runs out.
    func startRundownTimer() {
        rundownTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let i = self.rundownIndex, let start = self.rundownStart,
                  self.rundown.segments.indices.contains(i) else { return }
            self.objectWillChange.send()
            let seg = self.rundown.segments[i]
            if seg.autoNext, let left = Rundown.remaining(seg, elapsed: Date().timeIntervalSince(start)), left <= 0,
               i + 1 < self.rundown.segments.count {
                self.goToSegment(i + 1)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        rundownTimer = t
    }
}
#endif

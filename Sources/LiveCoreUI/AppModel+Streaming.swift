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

/// Stream, record and settings.
extension AppModel {
    // MARK: Stream

    public static let primaryDestinationID = "primary"

    static func isActive(_ s: StreamingEngine.Stats) -> Bool {
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
}
#endif

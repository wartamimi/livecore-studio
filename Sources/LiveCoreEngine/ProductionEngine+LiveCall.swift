#if os(macOS)
import Foundation
import LiveCoreCore

/// LCS Live remote guests (0.52.0).
extension ProductionEngine {
    public static func liveChannelID(_ id: InputID) -> String { "live:\(id.raw)" }

    public func liveCallSource(_ id: InputID) -> LiveCallSource? { source(id) as? LiveCallSource }

    /// A guest call input. Its sound gets a mixer channel the first time the guest is heard.
    @discardableResult
    public func addLiveCall(_ config: ProjectLiveCall, id: InputID? = nil) -> InputID {
        let src = LiveCallSource(id: id ?? InputID(UUID().uuidString), config: config,
                                 sampleRate: Double(settings.audio.sampleRate))
        let srcID = src.id
        src.audioChannelProvider = { [weak self, weak src] in
            guard let self else { return MixerChannel.detached() }
            let chID = Self.liveChannelID(srcID)
            if let existing = self.mixer.channelList.first(where: { $0.id == chID }) { return existing }
            let ch = self.mixer.addChannel(id: chID, name: src?.name ?? "LCS Live", primeFrames: 2048, maxBufferedFrames: 9600)
            if let saved = self.pendingFileChannelSettings.removeValue(forKey: srcID) { self.restore(saved, to: ch) }
            self.applyAFV()
            self.onAudioChannelsChange?()
            return ch
        }
        add(src)
        liveCallConnector?(src)
        src.start()
        return src.id
    }
}
#endif

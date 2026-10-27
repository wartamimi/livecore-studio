#if os(macOS)
import AVFoundation
import LiveCoreCore

/// Music input: a playlist of audio files (MP3, AAC/M4A, WAV, AIFF, FLAC, ALAC... anything
/// AVFoundation decodes) played into its own mixer channel. Like video-file audio, the decoded
/// PCM is copied into the channel by an MTAudioProcessingTap and the player's own output is
/// silenced, so music is heard only through the mixer (fader, mute, routing, meters).
///
/// Main thread only.
public final class MusicPlayer {
    public let id: String
    public var name: String
    public let channel: MixerChannel
    public private(set) var tracks: [URL]
    public private(set) var index = 0
    public var loopPlaylist = true
    public var shuffle = false
    public private(set) var isPlaying = false
    public private(set) var error: String?
    /// Something visible changed (track, play state, error).
    public var onChange: (() -> Void)?

    private let player = AVPlayer()
    private var tapContext: FileAudioTapContext?
    private var endObserver: NSObjectProtocol?
    private var loadToken = 0
    private var failures = 0

    public init(id: String, name: String, tracks: [URL], channel: MixerChannel) {
        self.id = id; self.name = name; self.tracks = tracks; self.channel = channel
        player.isMuted = false
        player.volume = 1
        player.actionAtItemEnd = .pause
        if !tracks.isEmpty { load(0, autoplay: false) }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        tapContext?.active.value = false
        player.pause()
    }

    public var currentTitle: String {
        tracks.indices.contains(index) ? tracks[index].deletingPathExtension().lastPathComponent : "—"
    }
    /// Seconds into the current track and its length (nil until known).
    public var position: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    public var duration: Double? {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return nil }
        return d
    }

    public func play() {
        guard !tracks.isEmpty else { return }
        tapContext?.active.value = true
        player.play()
        isPlaying = true
        onChange?()
    }

    public func pause() {
        player.pause()
        isPlaying = false
        onChange?()
    }

    public func togglePlay() { isPlaying ? pause() : play() }

    public func next() {
        guard let n = PlaylistMath.next(index: index, count: tracks.count, loop: true, shuffle: shuffle, random: Int.random(in:)) else { return }
        load(n, autoplay: isPlaying)
    }

    public func previous() {
        // Like most players: restart the track unless we are in its first 3 seconds.
        if position > 3 { player.seek(to: .zero); return }
        load(PlaylistMath.previous(index: index, count: tracks.count), autoplay: isPlaying)
    }

    public func select(_ i: Int) {
        guard tracks.indices.contains(i) else { return }
        load(i, autoplay: true)
    }

    public func setTracks(_ urls: [URL]) {
        let wasPlaying = isPlaying
        tracks = urls
        if urls.isEmpty { pause(); player.replaceCurrentItem(with: nil); index = 0; onChange?(); return }
        load(0, autoplay: wasPlaying)
    }

    public func stop() {
        pause()
        tapContext?.active.value = false
    }

    /// Builds the item only after its audio track is known, so the tap is in place before the
    /// first sample plays (nothing reaches the speakers outside the mixer).
    private func load(_ i: Int, autoplay: Bool) {
        guard tracks.indices.contains(i) else { return }
        index = i
        loadToken += 1
        let token = loadToken
        error = nil
        player.pause()
        let asset = AVURLAsset(url: tracks[i])
        asset.loadTracks(withMediaType: .audio) { [weak self] audioTracks, err in
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                guard let track = audioTracks?.first else {
                    self.error = "Cannot play \(self.currentTitle): \(err?.localizedDescription ?? "no audio track")"
                    self.onChange?()
                    self.failures += 1
                    if autoplay, self.tracks.count > 1, self.failures < self.tracks.count { self.next() }
                    return
                }
                self.install(asset: asset, track: track, autoplay: autoplay)
            }
        }
        onChange?()
    }

    private func install(asset: AVURLAsset, track: AVAssetTrack, autoplay: Bool) {
        failures = 0
        tapContext?.active.value = false
        let ctx = FileAudioTapContext(channel: channel)
        guard let tap = FileAudioTapContext.makeTap(ctx) else {
            error = "Cannot attach audio tap"
            onChange?()
            return
        }
        tapContext = ctx
        let item = AVPlayerItem(asset: asset)
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in self?.trackEnded() }
        player.replaceCurrentItem(with: item)
        if autoplay { play() } else { isPlaying = false; onChange?() }
    }

    private func trackEnded() {
        if let n = PlaylistMath.next(index: index, count: tracks.count, loop: loopPlaylist, shuffle: shuffle, random: Int.random(in:)) {
            load(n, autoplay: true)
        } else {
            isPlaying = false
            player.seek(to: .zero)
            onChange?()
        }
    }
}
#endif

#if os(macOS)
import AVFoundation
import LiveCoreCore

/// Music input: a playlist of audio files (MP3, AAC/M4A, WAV, AIFF, FLAC, ALAC... anything
/// AVFoundation decodes) played into its own mixer channel. Like video-file audio, the decoded
/// PCM is copied into the channel by an MTAudioProcessingTap and the player's own output is
/// silenced, so music is heard only through the mixer (fader, mute, routing, meters).
///
/// Main thread only.
public final class MusicInput {
    public let id: String
    public var name: String
    public let channel: MixerChannel
    public private(set) var tracks: [URL]
    public private(set) var index = 0
    public var loopPlaylist = false   // repeat is off by default (0.45.0)
    public var shuffle = false
    /// Repeat One: the current song starts again when it ends.
    public var repeatOne = false
    /// One-shot: when the current song ends, stop (the next song is cued, not played).
    public var stopAfterCurrent = false
    public var repeatMode: RepeatMode {
        get { RepeatMode(loop: loopPlaylist, one: repeatOne) }
        set { repeatOne = newValue == .one; loopPlaylist = newValue != .off }
    }
    public private(set) var isPlaying = false
    /// Fade-out at the end and fade-in at the start of each song, in seconds (0 = off).
    public var fadeSeconds: Double = 0 { didSet { fadeSeconds = min(max(fadeSeconds, MusicFade.range.lowerBound), MusicFade.range.upperBound) } }
    private var fadeTimer: Timer?
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
        // 20 Hz fade envelope; the tap ramps between updates so steps are not audible.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.updateFade() }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    private func updateFade() {
        guard let ctx = tapContext else { return }
        let g = Float(MusicFade.gain(position: position, duration: duration, fade: fadeSeconds))
        if ctx.gain.value != g { ctx.gain.value = g }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        fadeTimer?.invalidate()
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

    public func seek(to seconds: Double) { player.seek(to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600)) }

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

    /// Removes one song; the song that plays keeps playing (if it is the one removed, the next
    /// one takes over in the same play / pause state).
    public func removeTrack(at i: Int) {
        guard tracks.indices.contains(i) else { return }
        if tracks.count == 1 { setTracks([]); return }
        let r = PlaylistEdit.remove(at: i, current: index, count: tracks.count)
        tracks.remove(at: i)
        if r.removedCurrent { load(r.current, autoplay: isPlaying) } else { index = r.current; onChange?() }
    }

    /// Reorders the list without interrupting the song that plays.
    public func moveTrack(from: Int, to: Int) {
        guard tracks.indices.contains(from), tracks.indices.contains(to), from != to else { return }
        index = PlaylistEdit.move(from: from, to: to, current: index)
        tracks = PlaylistEdit.moved(tracks, from: from, to: to)
        onChange?()
    }

    /// Adds songs at the end without interrupting the one that plays.
    public func appendTracks(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let wasEmpty = tracks.isEmpty
        tracks += urls
        if wasEmpty { load(0, autoplay: false) } else { onChange?() }
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
        // With fades on, a new song starts silent and fades in (no click at the start).
        let ctx = FileAudioTapContext(channel: channel, initialGain: fadeSeconds > 0 ? 0 : 1)
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
        if stopAfterCurrent {
            stopAfterCurrent = false
            // Cue the song that would have come next, ready for ▶.
            if let n = PlaylistMath.afterEnd(index: index, count: tracks.count, repeat: repeatMode, shuffle: shuffle,
                                             random: Int.random(in:)), n != index {
                load(n, autoplay: false)
                return
            }
            isPlaying = false
            player.seek(to: .zero)
            onChange?()
            return
        }
        if let n = PlaylistMath.afterEnd(index: index, count: tracks.count, repeat: repeatMode, shuffle: shuffle,
                                         random: Int.random(in:)) {
            load(n, autoplay: true)
        } else {
            isPlaying = false
            player.seek(to: .zero)
            onChange?()
        }
    }
}
#endif

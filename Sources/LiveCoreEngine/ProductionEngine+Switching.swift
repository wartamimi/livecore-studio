#if os(macOS)
import AVFoundation
import AppKit
import CoreMedia
import Foundation
import LiveCoreCore

/// Switching, auto play, audio follow video, replay, stinger and overlays (main thread).
extension ProductionEngine {
    // MARK: Switching (main thread)

    public var switcherState: SwitcherSnapshot { control.read { $0.switcher.state } }

    public func setPreview(_ id: InputID?) {
        control.mutate { st in _ = st.switcher.setPreview(id) }
    }
    public func cut() {
        let now = HostClock.now()
        control.mutate { st in
            st.commitDraftOfIncoming()
            _ = st.switcher.cut()
            for i in st.overlays.indices { st.overlays[i].takeToProgram(now: now) }
        }
        applyAutoPlay()
    }
    public func auto() {
        let kind = settings.transition, dur = settings.transitionDuration
        var stinger: StingerParams?
        if kind == .stinger {
            guard !control.read({ $0.switcher.isTransitioning }) else { return }
            let cfg = self.stinger
            guard let id = cfg.source, let clip = source(id) as? VideoFileSource else {
                onError?("Stinger: choose a video file input as the stinger clip first (transition settings).")
                return
            }
            guard let p = cfg.params(clipDuration: clip.duration ?? 0) else {
                onError?("Stinger: \"\(clip.name)\" is not ready yet or has no duration.")
                return
            }
            stinger = p
            clip.restart()
        }
        let now = HostClock.now()
        control.mutate { st in
            st.commitDraftOfIncoming()
            _ = st.switcher.auto(kind: kind, duration: dur, now: now, stinger: stinger)
            // Overlays waiting on Preview go to Program together with the transition.
            if st.switcher.isTransitioning { for i in st.overlays.indices { st.overlays[i].takeToProgram(now: now) } }
        }
        applyAutoPlay()
    }
    public func setTBar(_ position: Double) {
        let kind = settings.transition
        let now = HostClock.now()
        control.mutate { st in
            if position > 0.001 && position < 0.999 { st.commitDraftOfIncoming() }
            _ = st.switcher.setTBar(position, kind: kind, now: now)
            if st.switcher.isTransitioning { for i in st.overlays.indices { st.overlays[i].takeToProgram(now: now) } }
        }
    }
    /// "Quick play": cut a specific input straight to program.
    public func cutDirect(_ id: InputID) {
        control.mutate { st in st.commitDraft(of: id); _ = st.switcher.setPreview(id); _ = st.switcher.cut() }
    }

    /// Links a mixer channel to an input (nil = off): the channel is heard only while that
    /// input is on air (Program, transition, scene layer or on-air overlay).
    public func setAudioFollowVideo(channelID: String, input: InputID?) {
        afvLinks[channelID] = input
        applyAutoPlay()   // recomputes what is on air, then applies AFV
    }

    func applyAFV() {
        let (sw, layers, overlays) = control.read { ($0.switcher.state, $0.layers, $0.overlays) }
        let heard = OnAir.audioInputs(switcher: sw, layers: layers, overlays: overlays)
        let fade = Float(OnAir.audioFadeSeconds(switcher: sw))
        for ch in mixer.channelList {
            let open = OnAir.audioOpen(link: afvLinks[ch.id], visible: heard)
            if ch.controls.afvClosed.value == open {
                ch.controls.afvFadeSeconds.value = fade
                ch.controls.afvClosed.value = !open
            }
        }
    }

    /// Starts video inputs set to auto play when they become visible on Program (directly, as a
    /// scene layer, as an on-air overlay or as either side of a transition) and pauses them when
    /// they leave. Main thread.
    public func applyAutoPlay() {
        let (sw, layers, overlays, sources, stingerID) = control.read { st in
            (st.switcher.state, st.layers, st.overlays, st.sources, st.stinger.source)
        }
        let visible = OnAir.visibleInputs(switcher: sw, layers: layers, overlays: overlays)
        onAirInputs = visible
        applyAFV()
        // The replay input plays when it goes on air and returns to its start when it leaves.
        if let r = replaySource {
            let was = autoPlayOnAir.contains(r.id), now = visible.contains(r.id)
            if now && !was && r.hasClip { r.play() }
            if !now && was { r.cue() }
        }
        // Titles with a letter-by-letter animation play it each time they go on air.
        for (id, src) in sources {
            guard let t = src as? TextSource, let d = t.style.design, d.textAnimation != .off else { continue }
            let was = autoPlayOnAir.contains(id), now = visible.contains(id)
            if now && !was { t.playTextAnimation() }
            if !now && was { t.finishTextAnimation() }
        }
        for (id, src) in sources {
            guard let v = src as? VideoFileSource, v.autoPlay != .off, id != stingerID else { continue }
            let was = autoPlayOnAir.contains(id), now = visible.contains(id)
            if now && !was { v.autoRestart ? v.restart() : v.play() }
            // Leaving Program: pause; with auto restart also back to the first frame, so the
            // next CUT / AUTO (and Preview meanwhile) starts clean.
            if !now && was { v.autoRestart ? v.cue() : v.pause() }
        }
        autoPlayOnAir = visible
    }

    /// Auto restart on/off (kept while auto play is off).
    public func setAutoRestart(_ on: Bool, for id: InputID) {
        guard let v = source(id) as? VideoFileSource else { return }
        v.autoRestart = on
    }

    /// Changes a video input's auto play mode; an input set to auto play that is not on air pauses.
    public func setAutoPlay(_ mode: VideoFileSource.AutoPlay, for id: InputID) {
        guard let v = source(id) as? VideoFileSource else { return }
        v.autoPlay = mode
        autoPlayOnAir.remove(id)
        if mode != .off { v.pause() }
        applyAutoPlay()
    }

    // MARK: Instant replay

    /// Turns the replay buffer on (adds the "Replay" input) or off (removes it, deletes the buffer).
    public func setReplayEnabled(_ on: Bool) {
        if on {
            guard replaySource == nil else { return }
            let src = ReplaySource(id: InputID("replay"))
            src.onChange = { [weak self] in self?.onReplayChange?() }
            replaySource = src
            add(src)
            replay.start(output: settings.output)
            outputs.mutate { $0.replay = true }
        } else if let src = replaySource {
            removeInput(src.id)   // also stops the buffer
        }
        onReplayChange?()
    }

    func replayRemoved() {
        outputs.mutate { $0.replay = false }
        replay.stop()
        replaySource = nil
        onReplayChange?()
    }

    /// Loads the last `seconds` of Program into the Replay input and puts it on Preview, ready
    /// for CUT/AUTO (it starts playing when it goes on air). `completion(false)` if the buffer
    /// is still empty.
    public func replayLast(_ seconds: Double, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let src = replaySource else { return completion(false) }
        replay.clip(lastSeconds: seconds) { [weak self] clip in
            guard let self, let clip, self.replaySource === src else { return completion(false) }
            src.load(clip)
            if self.switcherState.program != src.id { self.setPreview(src.id) }
            completion(true)
        }
    }

    // MARK: Stinger

    public var stinger: StingerConfig { control.read { $0.stinger } }

    /// Selects the stinger clip and cut point. The clip stops looping and waits on its first frame;
    /// a previously selected clip goes back to looping.
    public func setStinger(_ cfg: StingerConfig) {
        let old = control.mutate { st -> StingerConfig in let o = st.stinger; st.stinger = cfg; return o }
        if old.source != cfg.source, let id = old.source, let prev = source(id) as? VideoFileSource {
            prev.loop = true
            prev.play()
        }
        if let id = cfg.source, let clip = source(id) as? VideoFileSource, old.source != cfg.source {
            clip.loop = false
            clip.cue()
        }
    }

    public func setTransition(_ kind: TransitionKind, duration: Double) {
        settings.transition = kind
        settings.transitionDuration = min(max(duration, 0.1), 10)
    }

    /// Selects and compiles the shader `TransitionKind.custom` uses (`CustomTransitionLibrary` id).
    /// Returns the problem, or nil when it compiled; until a shader compiles, `.custom` dissolves.
    @discardableResult
    public func setCustomTransition(_ id: String?) -> String? {
        settings.customTransition = id
        guard let id else { compositor.clearCustomTransition(); return nil }
        guard let code = CustomTransitionLibrary.code(for: id) else {
            compositor.clearCustomTransition()
            return "Transition shader not found (\(id))."
        }
        if let err = compositor.loadCustomTransition(code: code) {
            compositor.clearCustomTransition()
            return err
        }
        return nil
    }

    // MARK: Overlays

    public var overlays: [OverlayChannel] { control.read { $0.overlays } }

    public func configureOverlay(_ index: Int, source: InputID?, preset: LayoutPreset) {
        control.mutate { st in
            guard let i = st.overlays.firstIndex(where: { $0.index == index }) else { return }
            st.overlays[i].source = source
            // A template title already covers the whole output and a running-text band has its
            // own position; full screen shows them as on Program instead of squeezing them
            // into the lower-third box.
            if preset == .lowerThird, let id = source,
               (st.sources[id] as? TextSource)?.isFullCanvas == true || st.sources[id] is TickerSource {
                st.overlays[i].preset = .fullScreen
            } else {
                st.overlays[i].preset = preset
            }
        }
    }

    /// In / out animation and its duration (0.1...5 s) of an overlay channel.
    public func setOverlayAnimation(_ index: Int, animation: OverlayAnimation, duration: Double) {
        control.mutate { st in
            guard let i = st.overlays.firstIndex(where: { $0.index == index }) else { return }
            st.overlays[i].animation = animation
            st.overlays[i].fadeDuration = min(max(duration, 0.1), 5)
        }
    }

    /// The in / out motion a template title or running text asks for (nil = the channel's own).
    static func sourceAnimation(_ src: VideoSource?) -> (OverlayAnimation, Double)? {
        if let t = src as? TextSource, let d = t.style.design, !d.useOverlayAnimation { return (d.animation, d.animationDuration) }
        if let k = src as? TickerSource, let a = k.config.animation { return (a, k.config.animationDuration ?? 0.5) }
        return nil
    }

    public func setOverlay(_ index: Int, on: Bool) {
        let now = HostClock.now()
        control.mutate { st in
            guard let i = st.overlays.firstIndex(where: { $0.index == index }), let id = st.overlays[i].source else { return }
            // Pressing the overlay number plays the title's own animation (vMix title In/Out).
            if on, !st.overlays[i].isOn, let (a, d) = Self.sourceAnimation(st.sources[id]) {
                st.overlays[i].animation = a
                st.overlays[i].fadeDuration = d
            }
            st.overlays[i].set(on: on, now: now)
            if on { st.overlays[i].onPreview = false }
        }
        applyAutoPlay()
    }

    /// Shows or hides an overlay on Preview only; CUT/AUTO then takes it to Program.
    public func setOverlayPreview(_ index: Int, on: Bool) {
        control.mutate { st in
            guard let i = st.overlays.firstIndex(where: { $0.index == index }), let id = st.overlays[i].source else { return }
            // The next CUT / AUTO brings it in with the title's own animation.
            if on, let (a, d) = Self.sourceAnimation(st.sources[id]) {
                st.overlays[i].animation = a
                st.overlays[i].fadeDuration = d
            }
            st.overlays[i].onPreview = on
        }
    }
}
#endif

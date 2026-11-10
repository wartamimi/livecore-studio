#if os(macOS)
import AppKit
import Foundation
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices

/// Macros and triggers (0.65.0): runs a macro's steps in order on the main thread. A wait step
/// pauses; AUTO / transition steps let the transition finish before the next step. Triggers
/// start macros when inputs go on air, a video ends, or the stream / recording starts or stops.
extension AppModel {
    static func macroTitle(_ n: Int) -> String { L10n.f("macro.number", n) }

    // MARK: Running

    /// Macro `n` (1...) as shortcuts, MIDI and the Web Controller number them.
    public func runMacro(number n: Int) {
        guard let m = macroBook.macro(number: n) else { report(L10n.f("macro.missing", n)); return }
        runMacro(m.id)
    }

    /// Starts a macro. A macro that is still running is not started a second time.
    public func runMacro(_ id: String) {
        guard let m = macroBook.macros.first(where: { $0.id == id }), !runningMacros.contains(id) else { return }
        macroTokenCounter += 1
        let token = macroTokenCounter
        macroRunTokens[id] = token
        runningMacros.insert(id)
        FileLog.shared.info("macro \"\(m.name)\" started (\(m.steps.count) steps)")
        let steps = m.steps
        // Never inside the caller (a switcher update or a key press): the first step runs next.
        DispatchQueue.main.async { [weak self] in self?.macroStep(id, steps, 0, token) }
    }

    /// Runs steps that are not a saved macro (the AI Assistant, 0.66.0) under `runID`; they stop
    /// with `stopMacro(runID)` like a macro.
    func runSteps(_ steps: [MacroStep], runID: String) {
        macroTokenCounter += 1
        let token = macroTokenCounter
        macroRunTokens[runID] = token
        runningMacros.insert(runID)
        DispatchQueue.main.async { [weak self] in self?.macroStep(runID, steps, 0, token) }
    }

    public func stopMacro(_ id: String) {
        macroRunTokens[id] = nil
        runningMacros.remove(id)
    }

    public func stopAllMacros() {
        macroRunTokens.removeAll()
        if !runningMacros.isEmpty { runningMacros.removeAll() }
    }

    private func macroStep(_ id: String, _ steps: [MacroStep], _ k: Int, _ token: Int) {
        guard macroRunTokens[id] == token else { return }
        guard k < steps.count else {
            macroRunTokens[id] = nil
            runningMacros.remove(id)
            return
        }
        let s = steps[k]
        let next: () -> Void = { [weak self] in self?.macroStep(id, steps, k + 1, token) }
        if s.kind == .wait {
            DispatchQueue.main.asyncAfter(deadline: .now() + s.waitSeconds, execute: next)
            return
        }
        guard s.isComplete else {
            FileLog.shared.warning("macro step \(k + 1) (\(s.kind.rawValue)) skipped: not set up")
            DispatchQueue.main.async(execute: next)
            return
        }
        performMacroStep(s)
        if s.kind.runsTransition {
            waitForTransitionEnd(deadline: CACurrentMediaTime() + transitionDuration + 2, then: next)
        } else {
            DispatchQueue.main.async(execute: next)
        }
    }

    private func waitForTransitionEnd(deadline: CFTimeInterval, then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            if self.switcher.transition == nil || CACurrentMediaTime() > deadline { then() } else {
                self.waitForTransitionEnd(deadline: deadline, then: then)
            }
        }
    }

    func performMacroStep(_ s: MacroStep) {
        switch s.kind {
        case .cut: cut()
        case .auto: auto()
        case .preview: if let i = s.input { preview(i) }
        case .program: if let i = s.input { cutDirect(i) }
        case .transition:
            guard let i = s.input else { return }
            if switcher.program == i { return }
            preview(i)
            auto()
        case .overlayOn, .overlayOff:
            guard let e = engine, let n = s.overlayIndex else { return }
            e.setOverlay(n, on: s.kind == .overlayOn)
            overlays = e.overlays
        case .overlayToggle: if let n = s.overlayIndex { toggleOverlay(n) }
        case .audioOn, .audioOff:
            guard let vm = audioChannels.first(where: { $0.id == s.channel }) else {
                FileLog.shared.warning("macro: audio channel \(s.channel ?? "") not found"); return
            }
            vm.muted = s.kind == .audioOff
        case .videoPlay, .videoPause, .videoRestart:
            guard let i = s.input, let v = engine?.source(i) as? VideoFileSource else { return }
            switch s.kind {
            case .videoPlay: v.play()
            case .videoPause: v.pause()
            default: v.restart()
            }
        case .streamStart: if !streamLocked, !isStreamingActive { toggleStream() }
        case .streamStop: if !streamLocked, isStreamingActive { toggleStream() }
        case .recordStart: if !recordLocked, !isRecording { toggleRecord() }
        case .recordStop: if !recordLocked, isRecording { toggleRecord() }
        case .snapshot: saveSnapshot(confirm: false)
        case .highlight: markHighlight()
        case .wait: break
        }
    }

    // MARK: Triggers

    func installMacroObservers() {
        guard macroVideoEndObserver == nil else { return }
        macroVideoEndObserver = NotificationCenter.default.addObserver(forName: VideoFileSource.clipEndedNotification, object: nil,
                                                                       queue: .main) { [weak self] note in
            guard let self, let src = note.object as? VideoFileSource else { return }
            self.fireMacroEvents([MacroEvent(.videoEnded, input: src.id)])
        }
        macroLastStreaming = isStreamingActive
        macroLastRecording = isRecording
    }

    /// Stream / record started or stopped (checked 5 times a second).
    func checkMacroOutputEvents() {
        let s = isStreamingActive, r = isRecording
        var events: [MacroEvent] = []
        if s != macroLastStreaming { macroLastStreaming = s; events.append(MacroEvent(s ? .streamStarted : .streamStopped)) }
        if r != macroLastRecording { macroLastRecording = r; events.append(MacroEvent(r ? .recordStarted : .recordStopped)) }
        fireMacroEvents(events)
    }

    /// Runs the macros whose triggers match (each at most once per event batch).
    func fireMacroEvents(_ events: [MacroEvent]) {
        guard !events.isEmpty, macroTriggersEnabled, !macroBook.macros.isEmpty, !macroGuard.tripped,
              CACurrentMediaTime() >= macroTriggersQuietUntil else { return }
        var started = Set<String>()
        for e in events {
            for m in macroBook.macros(for: e) where !runningMacros.contains(m.id) && !started.contains(m.id) {
                guard macroGuard.allow(now: CACurrentMediaTime()) else {
                    macroTriggersTripped = true
                    FileLog.shared.warning("macro triggers paused: too many trigger starts (loop?)")
                    report(L10n.t("macro.loop_stopped"))
                    return
                }
                FileLog.shared.info("trigger \(e.kind.rawValue) → macro \"\(m.name)\"")
                started.insert(m.id)
                runMacro(m.id)
            }
        }
    }

    public func rearmMacroTriggers() {
        macroGuard.rearm()
        macroTriggersTripped = false
    }

    /// A project being opened switches Program / Preview by itself: no triggers for 2 s.
    func quietMacroTriggers() {
        macroTriggersQuietUntil = CACurrentMediaTime() + 2
        macroLastStreaming = isStreamingActive
        macroLastRecording = isRecording
    }

    // MARK: Editing

    @discardableResult
    public func addMacro() -> String {
        let m = Macro(name: L10n.f("macro.number", macroBook.macros.count + 1))
        macroBook.macros.append(m)
        return m.id
    }

    public func deleteMacro(_ id: String) {
        stopMacro(id)
        macroBook.macros.removeAll { $0.id == id }
    }

    public func duplicateMacro(_ id: String) {
        guard let k = macroBook.macros.firstIndex(where: { $0.id == id }) else { return }
        var m = macroBook.macros[k]
        m.id = MacroBook.newID()
        m.name += " copy"
        m.steps = m.steps.map { var s = $0; s.id = MacroBook.newID(); return s }
        m.triggers = m.triggers.map { var t = $0; t.id = MacroBook.newID(); t.enabled = false; return t }
        macroBook.macros.insert(m, at: k + 1)
    }

    public func moveMacro(_ id: String, by delta: Int) {
        guard let k = macroBook.macros.firstIndex(where: { $0.id == id }) else { return }
        let j = k + delta
        guard macroBook.macros.indices.contains(j) else { return }
        macroBook.macros.swapAt(k, j)
    }
}
#endif

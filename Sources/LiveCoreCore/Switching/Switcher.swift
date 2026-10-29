/// Preview/Program switcher state machine.
///
/// Thread model: not thread-safe by itself. The engine owns one instance and mutates it only
/// on its control queue; the render loop receives immutable `SwitcherSnapshot` values.
///
/// Semantics (vMix-like):
///   * `setPreview` arms the next input.
///   * `cut()` swaps preview and program instantly.
///   * `auto(...)` runs the selected transition; when it completes, preview and program swap.
///   * Removing an input that is on air puts black on that bus; it never crashes the pipeline.
public struct SwitcherSnapshot: Equatable, Sendable {
    public var preview: InputID?
    public var program: InputID?
    public var transition: ActiveTransition?
    /// After a T-bar transition completes at one end, the bar stays there and the next
    /// transition runs the other way (vMix). True when the bar's rest position is the far end.
    public var tbarReversed = false

    public init(preview: InputID? = nil, program: InputID? = nil, transition: ActiveTransition? = nil) {
        self.preview = preview; self.program = program; self.transition = transition
    }

    /// Physical T-bar position (0...1) that means "no transition".
    public var tbarRest: Double { tbarReversed ? 1 : 0 }
}

public enum SwitcherEvent: Equatable, Sendable {
    case previewChanged(InputID?)
    case programChanged(InputID?)
    case transitionStarted(TransitionKind)
    case transitionCompleted
}

public final class Switcher {
    public private(set) var state = SwitcherSnapshot()
    /// Swap preview/program after a transition (vMix default). If false, preview keeps its input.
    public var swapPreviewAfterTransition = true

    public init() {}

    public var isTransitioning: Bool { state.transition != nil }

    @discardableResult
    public func setPreview(_ id: InputID?) -> [SwitcherEvent] {
        guard state.transition == nil else {
            // Changing preview mid-transition would change the incoming picture; ignore.
            return []
        }
        guard state.preview != id else { return [] }
        state.preview = id
        return [.previewChanged(id)]
    }

    /// Instant switch. If a transition is running it is completed immediately.
    @discardableResult
    public func cut() -> [SwitcherEvent] {
        if state.transition != nil { return complete() }
        let oldProgram = state.program
        state.program = state.preview
        if swapPreviewAfterTransition { state.preview = oldProgram }
        return [.programChanged(state.program), .previewChanged(state.preview)]
    }

    /// Starts an automatic transition of `duration` seconds. `.cut` or duration <= 0 behaves like `cut()`.
    /// A `.stinger` transition runs for the clip's length and needs `stinger`; without it, it cuts.
    @discardableResult
    public func auto(kind: TransitionKind, duration: Double, now: Double, stinger: StingerParams? = nil) -> [SwitcherEvent] {
        if state.transition != nil { return [] } // AUTO while running is ignored (press CUT to finish)
        var duration = duration
        if kind == .stinger {
            guard let stinger else { return cut() }
            duration = stinger.clipDuration
        }
        if kind == .cut || duration <= 0 { return cut() }
        state.transition = ActiveTransition(kind: kind, from: state.program, to: state.preview,
                                            startTime: now, duration: duration, manualPosition: nil,
                                            stinger: kind == .stinger ? stinger : nil)
        return [.transitionStarted(kind)]
    }

    /// Manual T-bar, `position` = physical bar position 0...1. The bar starts at its rest end
    /// (`tbarRest`); moving it to the other end completes the transition, after which that end
    /// becomes the rest position, so the bar never has to jump back (no glitch when the user
    /// keeps holding it at the end). Moving back to the rest end aborts.
    @discardableResult
    public func setTBar(_ position: Double, kind: TransitionKind, now: Double) -> [SwitcherEvent] {
        let x = min(max(position, 0), 1)
        var p = state.tbarReversed ? 1 - x : x
        // Snap within half a percent of the ends (faders and sliders rarely report exact values).
        if p >= 0.995 { p = 1 } else if p <= 0.005 { p = 0 }
        var events: [SwitcherEvent] = []
        if state.transition == nil {
            guard p > 0 else { return [] }
            // The T-bar cannot scrub a stinger clip: it dissolves instead.
            let k: TransitionKind = kind == .cut || kind == .stinger ? .dissolve : kind
            state.transition = ActiveTransition(kind: k, from: state.program, to: state.preview,
                                                startTime: now, duration: 0, manualPosition: p)
            events.append(.transitionStarted(k))
        } else if state.transition?.manualPosition == nil {
            return []   // an AUTO transition is running; the bar does not take it over
        } else {
            state.transition?.manualPosition = p
        }
        if p >= 1 {
            events += complete()
            state.tbarReversed.toggle()
        } else if p <= 0 { state.transition = nil; events.append(.transitionCompleted) } // aborted back
        return events
    }

    /// Advances time-based transitions. Call once per rendered frame before building the frame plan.
    @discardableResult
    public func update(now: Double) -> [SwitcherEvent] {
        guard let t = state.transition, t.manualPosition == nil else { return [] }
        if t.progress(at: now) >= 1 { return complete() }
        return []
    }

    /// Handles input removal without leaving dangling references.
    @discardableResult
    public func inputRemoved(_ id: InputID) -> [SwitcherEvent] {
        var events: [SwitcherEvent] = []
        if let t = state.transition, t.from == id || t.to == id {
            state.transition = nil
            events.append(.transitionCompleted)
        }
        if state.program == id { state.program = nil; events.append(.programChanged(nil)) }
        if state.preview == id { state.preview = nil; events.append(.previewChanged(nil)) }
        return events
    }

    private func complete() -> [SwitcherEvent] {
        guard let t = state.transition else { return [] }
        state.transition = nil
        state.program = t.to
        if swapPreviewAfterTransition { state.preview = t.from }
        return [.transitionCompleted, .programChanged(state.program), .previewChanged(state.preview)]
    }
}

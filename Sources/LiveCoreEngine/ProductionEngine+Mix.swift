#if os(macOS)
import Foundation
import LiveCoreCore

// MARK: - Mix inputs (0.79.0)

extension ProductionEngine {
    @discardableResult
    public func addMix(name: String, mix: ProjectMix = ProjectMix(), id: InputID? = nil) -> InputID {
        let src = SceneSource(id: id ?? InputID(UUID().uuidString), name: name, kind: .mix)
        control.mutate { $0.mixes[src.id] = MixBus(mix) }
        add(src)
        return src.id
    }

    public func mixState(_ id: InputID) -> SwitcherSnapshot? { control.read { $0.mixes[id]?.switcher.state } }

    func mixProject(_ id: InputID) -> ProjectMix { control.read { $0.mixes[id]?.project ?? ProjectMix() } }

    public func mixDuration(_ id: InputID) -> Double { control.read { $0.mixes[id]?.duration ?? 0.5 } }

    public func setMixDuration(_ id: InputID, _ seconds: Double) { control.mutate { $0.mixes[id]?.duration = seconds } }

    /// A Mix shows normal inputs only: never itself or another Mix (no loops).
    public func mixPreview(_ id: InputID, input: InputID?) {
        control.mutate { st in
            guard let m = st.mixes[id], input.map({ st.sources[$0] != nil && st.mixes[$0] == nil }) ?? true else { return }
            m.switcher.setPreview(input)
        }
    }

    public func mixCut(_ id: InputID) { control.mutate { _ = $0.mixes[id]?.switcher.cut() } }

    public func mixFade(_ id: InputID) {
        let now = HostClock.now()
        control.mutate { $0.mixes[id]?.fade(now: now) }
    }
}
#endif

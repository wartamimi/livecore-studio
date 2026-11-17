#if os(macOS)
import Foundation
import LiveCoreCore
import LiveCoreEngine

/// Mix inputs (0.79.0): a second switcher whose Program can go to any output.
extension AppModel {
    public func addMix() -> InputID? {
        let n = inputs.filter { $0.kind == .mix }.count + 1
        return engine?.addMix(name: L10n.f("mix.default_name", n))
    }

    public func mixPreview(_ mix: InputID, _ input: InputID) { engine?.mixPreview(mix, input: input) }
    public func mixCut(_ mix: InputID) { engine?.mixCut(mix) }
    public func mixFade(_ mix: InputID) { engine?.mixFade(mix) }

    /// Inputs a Mix can show: everything except Mix inputs.
    public var mixableInputs: [ProductionEngine.InputInfo] { inputs.filter { $0.kind != .mix } }
}
#endif

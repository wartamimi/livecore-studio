#if os(macOS)
import AVFoundation
import AppKit
import CoreMedia
import Foundation
import LiveCoreCore

/// Undo of "close input" and PTZ camera control (main thread).
extension ProductionEngine {
    /// Everything needed to put a closed input back exactly as it was.
    public struct RemovedInput {
        public let input: ProjectInput
        public let index: Int
        public let channel: ProjectAudioChannel?
        public let overlays: [ProjectOverlay]
        /// Layers of other inputs (scenes, PiP) that showed this input.
        public let dependents: [InputID: [Layer]]
        public let wasStinger: Bool
        public let wasPreview: Bool
    }

    /// Call just before `removeInput` to be able to undo it.
    public func removalSnapshot(_ id: InputID) -> RemovedInput? {
        let doc = exportProject(projectDirectory: nil)
        guard let pi = doc.inputs.first(where: { $0.id == id }),
              let index = control.read({ $0.order.firstIndex(of: id) }) else { return nil }
        var dependents: [InputID: [Layer]] = [:]
        for other in doc.inputs where other.id != id && other.layers.contains(where: { $0.source == id }) {
            dependents[other.id] = other.layers
        }
        return RemovedInput(input: pi, index: index, channel: doc.audio.channels.first { $0.inputID == id },
                            overlays: doc.overlays.filter { $0.source == id }, dependents: dependents,
                            wasStinger: doc.stinger?.source == id, wasPreview: switcherState.preview == id)
    }

    /// Re-creates a closed input with its id, place in the list, layers, key, colour, lock, audio
    /// settings, overlay channels and the layers of other inputs that showed it. Returns warnings
    /// (a camera that was unplugged meanwhile cannot come back).
    @discardableResult
    public func restoreInput(_ r: RemovedInput) -> [String] {
        var warnings: [String] = []
        let pi = r.input
        guard source(pi.id) == nil, createInput(pi, projectDirectory: nil, warnings: &warnings) else { return warnings }
        renameInput(pi.id, to: pi.name)
        control.mutate { st in
            st.layers[pi.id] = st.sanitized(pi.layers, of: pi.id)
            if let k = pi.chromaKey { st.keys[pi.id] = k.clamped }
            if pi.locked == true { st.locked.insert(pi.id) }
            if let a = pi.adjust, !a.isIdentity { st.adjusts[pi.id] = a.clamped }
            for (other, layers) in r.dependents where st.sources[other] != nil {
                st.layers[other] = st.sanitized(layers, of: other)
            }
            if let from = st.order.firstIndex(of: pi.id) {
                st.order.remove(at: from)
                st.order.insert(pi.id, at: min(r.index, st.order.count))
            }
            if r.wasStinger { st.stinger.source = pi.id }
            if r.wasPreview { _ = st.switcher.setPreview(pi.id) }
        }
        for o in r.overlays {
            configureOverlay(o.index, source: pi.id, preset: o.preset)
            setOverlayAnimation(o.index, animation: o.animation ?? .fade, duration: o.fadeDuration)
        }
        if let ch = r.channel {
            if let mc = mixer.channelList.first(where: { [Self.fileChannelID(pi.id), Self.screenChannelID(pi.id), Self.ndiChannelID(pi.id)].contains($0.id) }) {
                restore(ch, to: mc)
            } else {
                pendingFileChannelSettings[pi.id] = ch
            }
        }
        if let p = pi.ptz { ptzConfigs[pi.id] = p.clamped }
        publishInputs()
        return warnings
    }

    // MARK: PTZ

    public func setPTZ(_ config: PTZConfig?, for id: InputID) {
        ptzConfigs[id] = config?.clamped
        if let c = config { ptzControllers[id]?.update(c) }
    }

    /// Sends a VISCA command to the input's PTZ camera; `onStatus` reports connection errors.
    public func ptz(_ command: VISCA.Command, input id: InputID, onStatus: ((String?) -> Void)? = nil) {
        guard let config = ptzConfigs[id] else { return }
        let c = ptzControllers[id] ?? {
            let n = PTZController(config: config)
            ptzControllers[id] = n
            return n
        }()
        if let onStatus { c.onStatus = onStatus }
        c.send(command)
    }
}
#endif

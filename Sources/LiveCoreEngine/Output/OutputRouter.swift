#if os(macOS)
import CoreMedia
import CoreVideo
import CSyphon
import Foundation
import LiveCoreCore
import Metal

/// The four extra outputs: picks each output's picture from the rendered frames and sends it
/// to its Syphon server, the virtual camera and (on the main thread) its window.
/// Configuration on the main thread; `handle` runs on the GPU completion thread.
public final class OutputRouter {
    public private(set) var routing = OutputRouting()
    /// Outputs shown in a window or on a full-screen display (set by the UI).
    public private(set) var windows: Set<Int> = []
    /// EXTERNAL on: Syphon servers run for the outputs that have Syphon on, and the virtual
    /// camera (when connected) gets its output. Off: nothing leaves the app.
    public private(set) var external = false
    public let virtualCamera = VirtualCameraSender()
    /// A frame for output N's window. Main thread.
    public var onWindowFrame: ((Int, CVPixelBuffer) -> Void)?
    /// A Syphon server could not be started (output index). Main thread.
    public var onError: ((String) -> Void)?

    private struct Live {
        var routing = OutputRouting()
        var windows: Set<Int> = []
        var syphon: [Int: LCSyphonServer] = [:]
        var cameraOutput: Int?
    }
    private let live = Locked(Live())
    private weak var engine: ProductionEngine?
    private let device: MTLDevice

    public init(engine: ProductionEngine) {
        self.engine = engine
        device = engine.compositor.device
        engine.outputFrameHandler = { [weak self] frames in self?.handle(frames) }
    }

    public func setRouting(_ r: OutputRouting) {
        routing = r.normalized(existing: engine.map { Set($0.inputs.map(\.id)) })
        apply()
    }

    public func setExternal(_ on: Bool) {
        external = on
        if !on { virtualCamera.disconnect() }
        apply()
    }

    public func setWindow(_ index: Int, open: Bool) {
        if open { windows.insert(index) } else { windows.remove(index) }
        apply()
    }

    /// Starts sending to the virtual camera (if its extension is active). Returns the state.
    @discardableResult
    public func startVirtualCamera() -> VirtualCameraSender.State {
        let s = virtualCamera.connect()
        apply()
        return s
    }

    public func stopVirtualCamera() {
        virtualCamera.disconnect()
        apply()
    }

    public func stopAll() {
        virtualCamera.disconnect()
        live.mutate { l in
            l.syphon.values.forEach { $0.stop() }
            l.syphon = [:]
        }
    }

    /// Re-checks inputs that were removed (falls back to Program) and refreshes rendering.
    public func inputsChanged() {
        let n = routing.normalized(existing: engine.map { Set($0.inputs.map(\.id)) })
        if n != routing { routing = n }
        apply()
    }

    private func apply() {
        var r = routing
        if !external { for i in r.slots.indices { r.slots[i].syphon = false } }
        // Syphon servers: one per output with Syphon on, named after the output.
        var servers = live.current.syphon
        for s in r.slots {
            if s.syphon, servers[s.index] == nil {
                if let srv = LCSyphonServer(name: OutputRouting.syphonName(s.index), device: device) {
                    servers[s.index] = srv
                } else {
                    onError?("Syphon output \(s.index) could not be started.")
                }
            } else if !s.syphon, let srv = servers[s.index] {
                srv.stop()
                servers[s.index] = nil
            }
        }
        let cam = external && virtualCamera.isRunning ? r.virtualCameraOutput : nil
        let w = windows
        live.mutate { l in
            l.routing = r
            l.windows = w
            l.syphon = servers
            l.cameraOutput = cam
        }
        let active = r.activeOutputs(windows: w, virtualCameraRunning: cam != nil)
        engine?.setOutputRendering(inputs: r.renderedInputs(active: active), fullPreview: r.needsFullPreview(active: active))
    }

    private func handle(_ frames: ProductionEngine.OutputFrames) {
        let l = live.current
        var toWindows: [(Int, CVPixelBuffer)] = []
        for s in l.routing.slots {
            let wantsWindow = l.windows.contains(s.index)
            let syphon = l.syphon[s.index]
            let camera = l.cameraOutput == s.index
            guard wantsWindow || syphon != nil || camera else { continue }
            let pb: CVPixelBuffer?
            switch s.source {
            case .program: pb = frames.program
            case .preview: pb = frames.preview
            case let .input(id): pb = frames.inputs[id]
            }
            guard let pb else { continue }
            syphon?.publishPixelBuffer(pb)
            if camera { virtualCamera.send(pb, pts: frames.pts) }
            if wantsWindow { toWindows.append((s.index, pb)) }
        }
        if !toWindows.isEmpty {
            DispatchQueue.main.async { [weak self] in
                for (i, pb) in toWindows { self?.onWindowFrame?(i, pb) }
            }
        }
    }
}
#endif

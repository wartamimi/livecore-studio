#if os(macOS)
import Foundation
import LiveCoreCore
import LiveCoreEngine

extension AppModel {
    /// Runs one AI Assistant app_action (0.69.0) through the same paths as shortcuts and the
    /// Web Controller, so locks set in the app still apply.
    func performAIAction(_ a: AIAppAction) {
        switch a {
        case .previewNext: runShortcut(.previewNext)
        case .previewPrevious: runShortcut(.previewPrevious)
        case let .overlayPreview(n): runShortcut(.overlayPreview(n))
        case let .replay(s): runShortcut(.replay(s))
        case .presentationNext: runShortcut(.presentationNext)
        case .presentationPrevious: runShortcut(.presentationPrevious)
        case let .tbar(v): handleRemote(.tbar(v))
        case let .ptzPreset(i, p): handleRemote(.ptzPreset(input: i, preset: p))
        case let .ptzHome(i): handleRemote(.ptzHome(input: i))
        case let .dataRow(i, d): handleRemote(.dataRow(input: i, delta: d))
        case let .dataRowSet(i, r): handleRemote(.dataRowSet(input: i, row: r))
        case let .qrItem(i, d): handleRemote(.qrItem(input: i, delta: d))
        case let .qrItemSet(i, n): handleRemote(.qrItemSet(input: i, item: n))
        case let .qrShow(i): handleRemote(.qrShow(input: i))
        case .fullscreen: handleRemote(.fullscreen)
        case .openWindow: break   // opened by the AI panel
        }
    }
}

extension AppModel {
    /// get_app_details (0.70.0): readings and settings as JSON for the AI Assistant.
    func aiAppDetails() -> String {
        let p = performance
        let thermal: String
        switch p.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let r = recordStats
        var streams: [[String: Any]] = []
        for t in streamTargets {
            let st = destinationStats[t.id] ?? StreamingEngine.Stats()
            streams.append(["name": t.name, "state": "\(st.state)", "bitrateKbps": Int(st.bitrateKbps),
                            "uptimeSeconds": Int(st.uptime), "reconnects": st.reconnects,
                            "droppedVideoFrames": Int(st.droppedVideoFrames), "queuedMs": Int(st.queuedMs),
                            "hardwareEncoder": st.encoderHardware])
        }
        let details: [String: Any] = [
            "performance": ["cpuPercentOfMachine": Int(p.cpuPercentOfMachine.rounded()), "memoryMB": Int(p.memoryMB),
                            "gpuFrameMs": (p.gpuFrameMs * 10).rounded() / 10, "renderFPS": (p.renderFPS * 10).rounded() / 10,
                            "droppedRenderFrames": Int(p.droppedRenderFrames), "thermal": thermal,
                            "cores": ProcessInfo.processInfo.activeProcessorCount,
                            "machineMemoryGB": Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)],
            "output": ["format": settings.output.label, "frameRate": settings.output.frameRate],
            "recording": ["active": isRecording, "state": "\(r.state)", "seconds": Int(r.duration),
                          "fileMB": Int(r.fileBytes / 1_048_576), "freeDiskGB": Int(r.freeBytes / 1_073_741_824),
                          "locked": recordLocked],
            "stream": ["active": isStreamingActive, "locked": streamLocked, "destinations": streams],
            "transition": ["kind": "\(transitionKind)", "seconds": transitionDuration],
            "inputs": inputs.map { ["number": $0.number, "name": $0.name, "type": $0.kind.rawValue, "health": $0.status.label] },
            "macros": macroBook.macros.enumerated().map { "\($0.offset + 1) \($0.element.name)" },
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
#endif

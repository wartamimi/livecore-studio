#if os(macOS)
import Foundation
import LiveCoreCore

/// On-device AI effects per input and live subtitles (0.43.0).
extension ProductionEngine {
    public func inputAI(_ id: InputID) -> InputAI { aiProcessors.read { $0[id]?.settings } ?? InputAI() }

    /// Turns background removal / auto-framing on or off for an input. Ignored on Intel Macs.
    public func setInputAI(_ id: InputID, _ ai: InputAI) {
        guard AISupport.isAvailable else { return }
        aiProcessors.mutate { p in
            if !ai.isActive { p[id] = nil }
            else if let x = p[id] { x.settings = ai }
            else { p[id] = AIProcessor(id: id, settings: ai) }
        }
    }

    @discardableResult
    public func addSubtitles(_ style: SubtitleStyle, id: InputID? = nil) -> InputID {
        let src = SubtitleSource(id: id ?? InputID(UUID().uuidString), style: style, outputSize: settings.output.size,
                                 sampleRate: Double(settings.audio.sampleRate))
        add(src)
        let key = "subtitles-\(src.id)"
        audioPump.addSink(key) { [weak src] chunk in src?.append(chunk.bus(.master)) }
        src.onRemove = { [weak self] in self?.audioPump.removeSink(key) }
        src.start()
        return src.id
    }
}
#endif

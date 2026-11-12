#if os(macOS)
import AVFoundation
import CoreGraphics
import LiveCoreCore

/// Builds the highlight video (0.58.0): the marked moments of a recording, each with its pre-
/// and post-roll, one after another with crossfades (picture and sound) and an optional fade
/// from / to black, as 16:9 or a centre 9:16 crop.
public enum HighlightReel {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Writes the video to `out` (.mp4) and returns its length in seconds.
    @discardableResult
    public static func build(recording: URL, marks: [HighlightMark], settings: HighlightSettings, to out: URL,
                             progress: @escaping (Double) -> Void = { _ in }) async throws -> Double {
        let s = settings.clamped
        let asset = AVURLAsset(url: recording)
        let duration = try await asset.load(.duration).seconds
        let ranges = HighlightPlan.ranges(marks, duration: duration, settings: s)
        guard !ranges.isEmpty else { throw Failure(message: "No marked moments inside this recording.") }
        guard let vSrc = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(message: "The recording has no video track.")
        }
        let aSrc = try await asset.loadTracks(withMediaType: .audio).first
        let natural = try await vSrc.load(.naturalSize)
        let fps = try await vSrc.load(.nominalFrameRate)
        let segs = HighlightPlan.timeline(ranges, crossfade: s.crossfade)
        let total = HighlightPlan.totalDuration(segs)

        let comp = AVMutableComposition()
        var vTracks: [AVMutableCompositionTrack] = []
        var aTracks: [AVMutableCompositionTrack] = []
        for _ in 0..<2 {
            guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Failure(message: "Cannot make the video timeline.")
            }
            vTracks.append(v)
            if aSrc != nil, let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                aTracks.append(a)
            }
        }
        func t(_ x: Double) -> CMTime { CMTime(seconds: x, preferredTimescale: 600) }
        func range(_ a: Double, _ b: Double) -> CMTimeRange { CMTimeRange(start: t(a), end: t(b)) }
        for (i, seg) in segs.enumerated() {
            let src = range(seg.source.lowerBound, seg.source.upperBound)
            try vTracks[i % 2].insertTimeRange(src, of: vSrc, at: t(seg.start))
            if let aSrc, aTracks.count == 2 { try aTracks[i % 2].insertTimeRange(src, of: aSrc, at: t(seg.start)) }
        }
        // One moment: the second pair of tracks stays empty and is left out.
        if segs.count == 1 {
            comp.removeTrack(vTracks[1])
            if aTracks.count == 2 { comp.removeTrack(aTracks[1]); aTracks = [aTracks[0]] }
        }
        // Overlap with the next segment (the crossfade actually used).
        let fades: [Double] = segs.indices.map { i in i + 1 < segs.count ? max(0, segs[i].end - segs[i + 1].start) : 0 }

        // Picture
        let vertical = s.format == .vertical
        let render = vertical ? CGSize(width: 1080, height: 1920) : natural
        var transform = CGAffineTransform.identity
        if vertical, natural.height > 0 {
            let sc = render.height / natural.height
            transform = CGAffineTransform(scaleX: sc, y: sc)
                .concatenating(CGAffineTransform(translationX: -(natural.width * sc - render.width) / 2, y: 0))
        }
        let endFade = s.fadeEnds ? min(0.6, total / 4) : 0
        var instructions: [AVMutableVideoCompositionInstruction] = []
        func layer(_ track: AVMutableCompositionTrack) -> AVMutableVideoCompositionLayerInstruction {
            let l = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            l.setTransform(transform, at: .zero)
            return l
        }
        func instruction(_ a: Double, _ b: Double, _ layers: [AVMutableVideoCompositionLayerInstruction]) {
            guard b - a > 0.0005 else { return }
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = range(a, b)
            ins.backgroundColor = CGColor(gray: 0, alpha: 1)
            ins.layerInstructions = layers
            instructions.append(ins)
        }
        for (i, seg) in segs.enumerated() {
            let inFade = i > 0 ? fades[i - 1] : 0
            let soloStart = seg.start + inFade, soloEnd = seg.end - fades[i]
            let solo = layer(vTracks[i % 2])
            if i == 0, endFade > 0 { solo.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: range(soloStart, soloStart + endFade)) }
            if i == segs.count - 1, endFade > 0 { solo.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range(soloEnd - endFade, soloEnd)) }
            instruction(soloStart, soloEnd, [solo])
            if fades[i] > 0 {
                let outgoing = layer(vTracks[i % 2])
                outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range(soloEnd, seg.end))
                let incoming = layer(vTracks[(i + 1) % 2])
                instruction(soloEnd, seg.end, [outgoing, incoming])
            }
        }
        // Instructions must cover the whole timeline without gaps (rounding to 1/600 s).
        if let last = instructions.last { last.timeRange = CMTimeRange(start: last.timeRange.start, end: comp.duration) }
        let video = AVMutableVideoComposition()
        video.renderSize = CGSize(width: (render.width / 2).rounded() * 2, height: (render.height / 2).rounded() * 2)
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps > 1 ? fps.rounded() : 30))
        video.instructions = instructions

        // Sound
        var mix: AVMutableAudioMix?
        if !aTracks.isEmpty {
            let params: [AVMutableAudioMixInputParameters] = aTracks.map { AVMutableAudioMixInputParameters(track: $0) }
            for (i, seg) in segs.enumerated() {
                let p = params[min(i % 2, params.count - 1)]
                let inFade = i > 0 ? fades[i - 1] : 0
                if inFade > 0 {
                    p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: range(seg.start, seg.start + inFade))
                } else if i == 0, endFade > 0 {
                    p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: range(seg.start, seg.start + endFade))
                } else {
                    p.setVolume(1, at: t(seg.start))
                }
                if fades[i] > 0 {
                    p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range(seg.end - fades[i], seg.end))
                } else if i == segs.count - 1, endFade > 0 {
                    p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range(seg.end - endFade, seg.end))
                }
            }
            let m = AVMutableAudioMix()
            m.inputParameters = params
            mix = m
        }

        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure(message: "Cannot export the highlight video.")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = video
        export.audioMix = mix
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(export.progress))
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        await export.export()
        poll.cancel()
        if let err = export.error { throw err }
        guard export.status == .completed else { throw Failure(message: "Export stopped (\(export.status.rawValue)).") }
        progress(1)
        return total
    }
}
#endif

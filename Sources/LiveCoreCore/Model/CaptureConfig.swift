/// Settings of a camera / capture-card input, chosen when it is added and editable afterwards.
/// nil size / frame rate = automatic (closest to the output format).
public struct CaptureConfig: Codable, Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    /// Mirror the picture horizontally (webcams facing the presenter).
    public var mirror: Bool
    public init(width: Int? = nil, height: Int? = nil, frameRate: Double? = nil, mirror: Bool = false) {
        self.width = width; self.height = height; self.frameRate = frameRate; self.mirror = mirror
    }
    public var isAutomatic: Bool { width == nil || height == nil }
}

/// One format a capture device reports: size and the frame-rate ranges it supports.
public struct CaptureFormatCandidate: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRateRanges: [ClosedRange<Double>]
    public init(width: Int, height: Int, frameRateRanges: [ClosedRange<Double>]) {
        self.width = width; self.height = height; self.frameRateRanges = frameRateRanges
    }
    /// True when a range can deliver `fps` (NTSC 29.97 counts as 30).
    public func supports(_ fps: Double) -> Bool {
        frameRateRanges.contains { $0.lowerBound - 0.1 <= fps && $0.upperBound + 0.1 >= fps }
    }
    /// Distinct frame rates worth offering in a menu (range ends and common rates inside ranges).
    public var offeredFrameRates: [Double] {
        var out: [Double] = []
        for r in frameRateRanges {
            for f in [r.lowerBound, r.upperBound] + [24, 25, 30, 50, 60] where r.lowerBound - 0.01 <= f && f <= r.upperBound + 0.01 {
                let v = (f * 100).rounded() / 100
                if !out.contains(where: { abs($0 - v) < 0.05 }) { out.append(v) }
            }
        }
        return out.sorted()
    }
}

public enum CaptureFormatPicker {
    /// Index of the format to use. An explicit size in `config` is matched exactly (preferring a
    /// format that supports the wanted frame rate); otherwise the format closest to the output size
    /// that supports the frame rate, preferring downscale over upscale.
    public static func pick(_ formats: [CaptureFormatCandidate], config: CaptureConfig,
                            outputWidth: Int, outputHeight: Int, outputFPS: Double) -> Int? {
        guard !formats.isEmpty else { return nil }
        let fps = config.frameRate ?? outputFPS
        if let w = config.width, let h = config.height {
            let same = formats.indices.filter { formats[$0].width == w && formats[$0].height == h }
            if let i = same.first(where: { formats[$0].supports(fps) }) ?? same.first { return i }
        }
        let want = Double(outputWidth * outputHeight)
        var best: Int?
        var bestScore = Double.greatestFiniteMagnitude
        for (i, f) in formats.enumerated() where f.width > 0 && f.height > 0 {
            let px = Double(f.width * f.height)
            var score = px >= want ? px - want : (want - px) * 4
            if !f.supports(fps) { score += 1e12 }
            if score < bestScore { bestScore = score; best = i }
        }
        return best
    }
}

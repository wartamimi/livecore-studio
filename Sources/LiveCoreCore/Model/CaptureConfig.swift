/// Settings of a camera / capture-card input, chosen when it is added and editable afterwards.
/// nil size / frame rate = automatic (closest to the output format).
public struct CaptureConfig: Codable, Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    /// Mirror the picture horizontally (webcams facing the presenter).
    public var mirror: Bool
    /// Advanced (0.28.0): the device's own video format as a FourCC ("yuvs", "420v", "dmb1"...),
    /// e.g. uncompressed YUV instead of MJPEG. nil = automatic.
    public var codec: String?
    /// Advanced (0.28.0): keep late frames in a short queue (smoother) instead of dropping them
    /// for the lowest latency. nil / false = lowest latency (the behaviour before 0.28.0).
    public var bufferFrames: Bool?
    public init(width: Int? = nil, height: Int? = nil, frameRate: Double? = nil, mirror: Bool = false,
                codec: String? = nil, bufferFrames: Bool? = nil) {
        self.width = width; self.height = height; self.frameRate = frameRate; self.mirror = mirror
        self.codec = codec; self.bufferFrames = bufferFrames
    }
    public var isAutomatic: Bool { width == nil || height == nil }
}

/// Names of the video formats capture devices report (FourCC media subtypes).
public enum CaptureCodec {
    /// Uncompressed formats: no compression artefacts, but much more USB bandwidth.
    public static func isUncompressed(_ fourCC: String) -> Bool {
        ["yuvs", "yuv2", "2vuy", "YUY2", "UYVY", "420v", "420f", "NV12", "v210", "BGRA", "x420", "xf20", "I420"].contains(fourCC)
    }

    /// Cost of an uncompressed mode for an 8-bit pipeline (0.46.1): 8-bit 4:2:0 is the lightest on
    /// the USB link and in conversion, 4:2:2 next, 10-bit last (the extra bits are thrown away).
    /// Compressed and unknown codecs return 0 (they are ranked elsewhere).
    public static func uncompressedCost(_ fourCC: String) -> Double {
        switch fourCC {
        case "420v", "NV12", "I420": return 0
        // Full-range NV12 last among 8-bit 4:2:0: UVC cards usually send limited-range video,
        // which in a full-range format comes out grey (0.46.2).
        case "420f": return 0.05
        case "yuvs", "yuv2", "YUY2", "2vuy", "UYVY": return 0.1
        case "x420", "xf20", "v210": return 0.3
        case "BGRA": return 0.2
        default: return 0
        }
    }

    public static func label(_ fourCC: String) -> String {
        switch fourCC {
        case "yuvs", "yuv2", "YUY2": return "YUY2 4:2:2 (uncompressed)"
        case "2vuy", "UYVY": return "UYVY 4:2:2 (uncompressed)"
        case "420v", "NV12": return "NV12 4:2:0 video range (uncompressed)"
        case "420f": return "NV12 4:2:0 full range (uncompressed)"
        case "x420": return "P010 4:2:0 10-bit (uncompressed)"
        case "xf20": return "P010 4:2:0 10-bit full range (uncompressed)"
        case "v210": return "v210 4:2:2 10-bit (uncompressed)"
        case "BGRA": return "BGRA 8-bit RGB (uncompressed)"
        case "I420": return "I420 4:2:0 (uncompressed)"
        case "dmb1", "jpeg", "mjpa", "mjpb", "MJPG": return "MJPEG (compressed)"
        case "avc1", "H264": return "H.264 (compressed)"
        case "hvc1", "hev1": return "HEVC (compressed)"
        case "": return "?"
        default: return fourCC
        }
    }

    /// True for formats the device compresses (MJPEG, H.264, HEVC), the modes a USB 2 link
    /// falls back to; uncompressed formats need a USB 3 (or faster) link.
    public static func isCompressed(_ fourCC: String) -> Bool {
        ["dmb1", "jpeg", "mjpa", "mjpb", "MJPG", "avc1", "H264", "hvc1", "hev1"].contains(fourCC)
    }

    /// FourCC of a CoreMedia media subtype (e.g. 0x79757673 → "yuvs").
    public static func fourCC(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return String(code) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// One format a capture device reports: size and the frame-rate ranges it supports.
public struct CaptureFormatCandidate: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRateRanges: [ClosedRange<Double>]
    /// FourCC of the device format (see `CaptureCodec`); "" when unknown.
    public var codec: String
    public init(width: Int, height: Int, frameRateRanges: [ClosedRange<Double>], codec: String = "") {
        self.width = width; self.height = height; self.frameRateRanges = frameRateRanges; self.codec = codec
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
        // A chosen device format (codec) narrows the choice where the device offers it; the
        // explicit size wins over the codec when both cannot be had together.
        func preferCodec(_ list: [Int]) -> [Int] {
            guard let c = config.codec, !c.isEmpty else { return list }
            let withCodec = list.filter { formats[$0].codec == c }
            return withCodec.isEmpty ? list : withCodec
        }
        // Without a chosen codec, uncompressed (USB 3 class) modes come first; compressed
        // modes are only used when no uncompressed mode delivers the size and frame rate.
        func preferUncompressed(_ list: [Int]) -> [Int] {
            guard config.codec?.isEmpty ?? true else { return list }
            let plain = list.filter { !CaptureCodec.isCompressed(formats[$0].codec) }
                .sorted { CaptureCodec.uncompressedCost(formats[$0].codec) < CaptureCodec.uncompressedCost(formats[$1].codec) }
            return plain + list.filter { CaptureCodec.isCompressed(formats[$0].codec) }
        }
        if let w = config.width, let h = config.height {
            let same = preferUncompressed(preferCodec(formats.indices.filter { formats[$0].width == w && formats[$0].height == h }))
            if let i = same.first(where: { formats[$0].supports(fps) }) ?? same.first { return i }
        }
        let pool = preferCodec(Array(formats.indices))
        let want = Double(outputWidth * outputHeight)
        var best: Int?
        var bestScore = Double.greatestFiniteMagnitude
        for i in pool {
            let f = formats[i]
            guard f.width > 0 && f.height > 0 else { continue }
            let px = Double(f.width * f.height)
            var score = px >= want ? px - want : (want - px) * 4
            if !f.supports(fps) { score += 1e12 }
            if config.codec?.isEmpty ?? true {
                score += CaptureCodec.isCompressed(f.codec) ? 0.5 : CaptureCodec.uncompressedCost(f.codec)
            }
            if score < bestScore { bestScore = score; best = i }
        }
        return best
    }
}

/// Pairs a capture card's picture with its audio device (0.46.1). Cards such as the Datavideo
/// CAP-2 list the two as e.g. "CAP-2 Video" and "CAP-2 Audio", so plain substring matching
/// misses; names are compared without words like video / audio / capture / usb.
public enum CaptureAudioMatch {
    static let noise: Set<String> = ["video", "audio", "capture", "usb", "device", "input", "hdmi", "sdi", "uvc", "digital", "interface"]

    static func tokens(_ name: String) -> [String] {
        name.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { !noise.contains($0) }
    }

    /// Index of the audio device that belongs to `videoName`, or nil.
    public static func partner(videoName: String, audioNames: [String]) -> Int? {
        let v = tokens(videoName)
        guard !v.isEmpty else { return nil }
        var best: (index: Int, score: Int)?
        for (i, a) in audioNames.enumerated() {
            let t = tokens(a)
            guard !t.isEmpty else { continue }
            let common = Set(v).intersection(t).count
            // Every remaining word of the shorter name must appear in the other.
            guard common > 0, common == min(Set(v).count, Set(t).count) else { continue }
            if best == nil || common > best!.score { best = (i, common) }
        }
        return best?.index
    }
}

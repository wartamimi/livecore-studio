import Foundation

/// Second output in portrait 9:16 (0.42.0): a crop of Program that follows the people in it,
/// streamed and recorded on its own (TikTok, Instagram, YouTube Shorts) next to the 16:9 output.
public struct VerticalSettings: Codable, Equatable, Sendable {
    public enum Follow: String, Codable, Sendable, CaseIterable {
        case faces     // keep the detected faces in frame
        case center
        case manual    // `manualX`
    }
    /// The vertical picture is made (monitor, recording); streaming is started on its own.
    public var enabled: Bool = false
    public var size: PixelSize = PixelSize(width: 720, height: 1280)
    public var follow: Follow = .faces
    /// Crop centre for `manual` (0 = left edge of Program, 1 = right).
    public var manualX: Double = 0.5
    /// How fast the crop moves to the subject: 0.02 (slow, smooth) … 0.3 (fast).
    public var smoothing: Double = 0.06
    /// RTMP(S) server of the vertical stream; its key lives in the Keychain under `keychainAccount`.
    public var streamURL: String = ""
    public var keychainAccount: String = "vertical"
    public var bitrateKbps: Int = 4500
    /// Also record the vertical output whenever RECORD runs (file "<name> - Vertical").
    public var recordWithProgram: Bool = true

    // 0.46.0
    /// How Program fills the portrait frame.
    public enum Fill: String, Codable, Sendable, CaseIterable {
        case crop        // a full-height crop that follows the subject
        case fitBlur     // the whole 16:9 picture, with a blurred copy filling the rest
        case fitBlack    // the whole 16:9 picture on black
    }
    public var fill: Fill = .crop
    /// Extra zoom of the crop: 1 = full height of Program … 2.5 = tight.
    public var zoom: Double = 1
    /// Vertical crop centre when zoomed (0 = top, 1 = bottom); 0.4 keeps more headroom.
    public var centerY: Double = 0.45
    /// How far the subject must move before the crop follows (0.01 … 0.2 of the width).
    public var deadZone: Double = 0.04
    /// Where the fitted 16:9 picture sits in `fitBlur` / `fitBlack` (0 = top, 1 = bottom).
    public var fitPosition: Double = 0.5
    /// Blur radius for `fitBlur` (pixels at the output size).
    public var blurRadius: Double = 30
    /// Audio bitrate of the vertical stream.
    public var audioBitrateKbps: Int = 128
    /// Keyframe interval of the vertical stream in seconds (Shorts / TikTok like 2).
    public var keyframeSeconds: Double = 2
    public init() {}

    public static let sizes = [PixelSize(width: 720, height: 1280), PixelSize(width: 1080, height: 1920),
                               PixelSize(width: 1080, height: 1350), PixelSize(width: 1080, height: 1080)]

    private enum CodingKeys: String, CodingKey {
        case enabled, size, follow, manualX, smoothing, streamURL, keychainAccount, bitrateKbps, recordWithProgram
        case fill, zoom, centerY, deadZone, fitPosition, blurRadius, audioBitrateKbps, keyframeSeconds
    }

    /// Tolerant: settings saved by older versions (without the 0.46.0 fields) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VerticalSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        size = try c.decodeIfPresent(PixelSize.self, forKey: .size) ?? d.size
        follow = (try? c.decodeIfPresent(Follow.self, forKey: .follow)) ?? d.follow
        manualX = try c.decodeIfPresent(Double.self, forKey: .manualX) ?? d.manualX
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
        streamURL = try c.decodeIfPresent(String.self, forKey: .streamURL) ?? d.streamURL
        keychainAccount = try c.decodeIfPresent(String.self, forKey: .keychainAccount) ?? d.keychainAccount
        bitrateKbps = try c.decodeIfPresent(Int.self, forKey: .bitrateKbps) ?? d.bitrateKbps
        recordWithProgram = try c.decodeIfPresent(Bool.self, forKey: .recordWithProgram) ?? d.recordWithProgram
        fill = (try? c.decodeIfPresent(Fill.self, forKey: .fill)) ?? d.fill
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? d.zoom
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? d.centerY
        deadZone = try c.decodeIfPresent(Double.self, forKey: .deadZone) ?? d.deadZone
        fitPosition = try c.decodeIfPresent(Double.self, forKey: .fitPosition) ?? d.fitPosition
        blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? d.blurRadius
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? d.audioBitrateKbps
        keyframeSeconds = try c.decodeIfPresent(Double.self, forKey: .keyframeSeconds) ?? d.keyframeSeconds
    }
}

public enum VerticalCrop {
    /// The 9:16 (or `aspect`) crop of a `source`-sized frame, full height, centred on `centerX`
    /// (0…1) and kept inside the frame. Returned in pixels, origin top left.
    /// `zoom` > 1 crops tighter; the crop then sits at `centerY` (0 top … 1 bottom), kept inside.
    public static func rect(source: PixelSize, aspect: Double, centerX: Double,
                            zoom: Double = 1, centerY: Double = 0.5) -> (x: Double, y: Double, width: Double, height: Double) {
        let H = Double(source.height), W = Double(source.width)
        let z = min(max(zoom, 1), 4)
        var w = H * aspect / z, h = H / z
        if w > W { w = W; h = W / aspect }
        let cx = min(max(centerX * W, w / 2), W - w / 2)
        let cy = min(max(centerY * H, h / 2), H - h / 2)
        return (cx - w / 2, cy - h / 2, w, h)
    }

    /// Where a whole `source` picture sits when fitted to the width of `output` (letterbox), at
    /// `position` (0 = top … 1 = bottom). Pixels, origin top left.
    public static func fitRect(source: PixelSize, output: PixelSize, position: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let ow = Double(output.width), oh = Double(output.height)
        let scale = min(ow / Double(max(source.width, 1)), oh / Double(max(source.height, 1)))
        let w = Double(source.width) * scale, h = Double(source.height) * scale
        let p = min(max(position, 0), 1)
        return ((ow - w) / 2, (oh - h) * p, w, h)
    }

    /// Where the crop should look given faces as (centerX, width) in 0…1, biggest faces weighted
    /// most. Nil when there are no faces.
    public static func target(faces: [(x: Double, width: Double)]) -> Double? {
        guard !faces.isEmpty else { return nil }
        let wsum = faces.reduce(0) { $0 + $1.width * $1.width }
        guard wsum > 0 else { return faces[0].x }
        return faces.reduce(0) { $0 + $1.x * $1.width * $1.width } / wsum
    }
}

/// Moves the crop centre smoothly toward a target, ignoring small changes (dead zone) so the
/// picture does not wobble while a speaker moves a little.
public struct CropFollower: Equatable, Sendable {
    public private(set) var x: Double
    public var target: Double
    public var deadZone: Double
    public init(x: Double = 0.5, deadZone: Double = 0.04) { self.x = x; target = x; self.deadZone = deadZone }

    /// One output frame: moves by `smoothing` of the distance (critically damped feel).
    public mutating func step(smoothing: Double) -> Double {
        let d = target - x
        x = abs(d) < 0.0005 ? target : x + d * min(max(smoothing, 0.005), 1)
        return x
    }

    /// New subject position; ignored inside the dead zone around where the crop already aims.
    public mutating func aim(at t: Double) {
        if abs(t - target) > deadZone { target = min(max(t, 0), 1) }
    }
}

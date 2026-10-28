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
    public init() {}

    public static let sizes = [PixelSize(width: 720, height: 1280), PixelSize(width: 1080, height: 1920)]
}

public enum VerticalCrop {
    /// The 9:16 (or `aspect`) crop of a `source`-sized frame, full height, centred on `centerX`
    /// (0…1) and kept inside the frame. Returned in pixels, origin top left.
    public static func rect(source: PixelSize, aspect: Double, centerX: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let H = Double(source.height), W = Double(source.width)
        var w = H * aspect, h = H
        if w > W { w = W; h = W / aspect }
        let cx = min(max(centerX * W, w / 2), W - w / 2)
        return (cx - w / 2, (H - h) / 2, w, h)
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

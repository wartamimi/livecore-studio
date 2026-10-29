/// Detects a capture card that sends limited-range video (black at 16, white at 235) which then
/// reaches the picture as if it were full range: the image looks grey and washed out (0.46.2).
/// Fed with luma samples (0…255) from a few frames; it only answers when the picture has both
/// near-16 blacks and near-235 whites and nothing beyond them, so a dark or low-contrast scene
/// does not trigger it.
public struct LevelProbe: Equatable, Sendable {
    private var histogram = [Int](repeating: 0, count: 256)
    public private(set) var frames = 0
    /// Frames needed before a verdict.
    public static let framesNeeded = 12

    public init() {}

    public mutating func add(luma: [UInt8]) {
        guard !luma.isEmpty else { return }
        for v in luma { histogram[Int(v)] += 1 }
        frames += 1
    }

    /// Luma below which `fraction` of the samples lie.
    func percentile(_ fraction: Double) -> Int {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0 }
        let limit = Double(total) * fraction
        var sum = 0
        for (v, n) in histogram.enumerated() {
            sum += n
            if Double(sum) >= limit { return v }
        }
        return 255
    }

    /// nil until enough frames were seen; then `.limitedToFull` when the picture is limited range
    /// shown as full, otherwise `.none`.
    public var verdict: InputAdjust.RangeFix? {
        guard frames >= Self.framesNeeded else { return nil }
        let lo = percentile(0.005), hi = percentile(0.995)
        let blacks = (11...24).contains(lo), whites = (224...240).contains(hi)
        return blacks && whites && hi - lo > 150 ? .limitedToFull : InputAdjust.RangeFix.none
    }

    /// Luma (BT.709) of a BGRA pixel.
    public static func luma(b: UInt8, g: UInt8, r: UInt8) -> UInt8 {
        UInt8(min(255, (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded()))
    }
}

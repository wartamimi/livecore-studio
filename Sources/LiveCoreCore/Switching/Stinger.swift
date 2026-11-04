/// Stinger transition configuration: which input (a video file, normally with an alpha channel)
/// plays as the stinger, and where in the clip Program cuts from A to B.
/// Stored in the project because it refers to an input.
public struct StingerConfig: Codable, Equatable, Sendable {
    public var source: InputID?
    /// Seconds into the clip at which A cuts to B (normally when the clip fully covers the
    /// screen). nil = middle of the clip.
    public var cutPoint: Double?

    public init(source: InputID? = nil, cutPoint: Double? = nil) { self.source = source; self.cutPoint = cutPoint }

    /// Resolves the parameters for a clip of `clipDuration` seconds; nil if not usable.
    public func params(clipDuration: Double) -> StingerParams? {
        guard let source, clipDuration.isFinite, clipDuration >= 0.1 else { return nil }
        let cut = min(max(cutPoint ?? clipDuration / 2, 0), clipDuration)
        return StingerParams(source: source, clipDuration: clipDuration, cutPoint: cut)
    }
}

/// Resolved stinger of a running transition.
public struct StingerParams: Codable, Equatable, Sendable {
    public var source: InputID
    public var clipDuration: Double
    public var cutPoint: Double

    public init(source: InputID, clipDuration: Double, cutPoint: Double) {
        self.source = source; self.clipDuration = clipDuration; self.cutPoint = cutPoint
    }

    /// Transition progress (0...1) at which Program switches from A to B.
    public var cutFraction: Double { clipDuration > 0 ? min(max(cutPoint / clipDuration, 0), 1) : 0.5 }
}

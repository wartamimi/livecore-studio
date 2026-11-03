import Foundation

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

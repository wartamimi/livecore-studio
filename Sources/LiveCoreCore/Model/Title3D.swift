#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 3D look and motion for titles, lower thirds and running text (0.59.0).
///
/// The look is an extrusion (the title drawn many times towards a vanishing direction in a darker
/// side colour), a bevel shine on the face and an optional fixed perspective tilt. The motion turns
/// the finished title in 3D space when it goes on and off air (flip, swing, spin, tumble…).
/// The maths (pose over time, perspective projection) lives here so it is unit tested on Linux;
/// the macOS renderer draws with CoreGraphics and Core Image's perspective transform.

public enum Motion3D: String, Codable, Sendable, CaseIterable {
    case off
    /// Turns up into place around its bottom edge (like a card standing up).
    case flipUp
    /// Turns down into place around its top edge.
    case flipDown
    /// Opens like a door hinged on its left edge.
    case swingLeft
    /// Opens like a door hinged on its right edge.
    case swingRight
    /// Half a turn around the vertical axis, ending face on.
    case spin
    /// Comes from far away, turning on both axes.
    case tumble
    /// Rolls in like the face of a turning cube (around the horizontal centre line).
    case cube
}

/// Where the title is in 3D at one moment of its motion.
public struct Pose3D: Equatable, Sendable {
    /// Rotation around the horizontal / vertical axis, degrees.
    public var rotX: Double
    public var rotY: Double
    /// Distance pushed away from the viewer, in content heights.
    public var depth: Double
    public var opacity: Double
    /// Rotation centre in the content box: 0…1 from left / from top.
    public var pivotX: Double
    public var pivotY: Double
    public init(rotX: Double = 0, rotY: Double = 0, depth: Double = 0, opacity: Double = 1, pivotX: Double = 0.5, pivotY: Double = 0.5) {
        self.rotX = rotX; self.rotY = rotY; self.depth = depth; self.opacity = opacity; self.pivotX = pivotX; self.pivotY = pivotY
    }
    public static let rest = Pose3D()
    public var isRest: Bool { abs(rotX) < 0.01 && abs(rotY) < 0.01 && abs(depth) < 0.0001 }
    /// 0 = face on, 1 = edge on (for darkening the face while it turns).
    public var turn: Double {
        let r = Double.pi / 180
        return min(max(1 - abs(cos(rotX * r) * cos(rotY * r)), 0), 1)
    }
}

public extension Motion3D {
    /// Pose at `progress` (0 = hidden, 1 = in place). Going out plays the same motion backwards.
    func pose(progress: Double) -> Pose3D {
        let p = min(max(progress, 0), 1)
        if self == .off || p >= 1 { return .rest }
        // Ease-out back: lands with a small overshoot, like broadcast 3D packages.
        let c1 = 1.2, c3 = c1 + 1, m = p - 1
        let e = 1 + c3 * m * m * m + c1 * m * m
        let o = 1 - (1 - p) * (1 - p) * (1 - p)
        let fade = min(1, p * 4)
        switch self {
        case .off: return .rest
        case .flipUp: return Pose3D(rotX: 90 * (1 - e), opacity: fade, pivotY: 1)
        case .flipDown: return Pose3D(rotX: -90 * (1 - e), opacity: fade, pivotY: 0)
        case .swingLeft: return Pose3D(rotY: 90 * (1 - e), opacity: fade, pivotX: 0)
        case .swingRight: return Pose3D(rotY: -90 * (1 - e), opacity: fade, pivotX: 1)
        case .spin:
            // 180° → 0°: the back half is skipped (fully transparent) so text never shows mirrored.
            let a = 180 * (1 - o)
            return Pose3D(rotY: a, depth: 0.6 * (1 - o), opacity: a > 90 ? 0 : fade)
        case .tumble: return Pose3D(rotX: 50 * (1 - o), rotY: -70 * (1 - o), depth: 3 * (1 - o), opacity: min(1, p * 2.5))
        case .cube: return Pose3D(rotX: 90 * (1 - o), depth: 0.5 * sin(Double.pi * p), opacity: fade, pivotY: 0.5)
        }
    }
}

/// The 3D settings of a title. Sizes are in points of a 1080-line canvas.
public struct Title3D: Codable, Equatable, Sendable {
    /// Extrusion depth (0 = flat face).
    public var depth: Double
    /// Direction the extrusion goes, degrees (0 = right, 90 = up, 270 = down; default down-right).
    public var direction: Double
    /// Side colour; nil = a darker shade of each part's own colour.
    public var sideColor: ProjectColor?
    /// Light shine across the top of the face.
    public var bevel: Bool
    /// Fixed perspective tilt of the finished title, degrees (−35…35).
    public var tiltX: Double
    public var tiltY: Double
    /// In / out motion (played when the title goes on and off air).
    public var motion: Motion3D
    /// Seconds (0.2…3).
    public var duration: Double

    public init(depth: Double = 10, direction: Double = 300, sideColor: ProjectColor? = nil, bevel: Bool = true,
                tiltX: Double = 0, tiltY: Double = 0, motion: Motion3D = .flipUp, duration: Double = 0.9) {
        self.depth = depth; self.direction = direction; self.sideColor = sideColor; self.bevel = bevel
        self.tiltX = tiltX; self.tiltY = tiltY; self.motion = motion; self.duration = duration
    }

    /// No 3D at all (what turning 3D off stores, so a template's default never comes back).
    public static let flat = Title3D(depth: 0, bevel: false, motion: .off)

    public var clamped: Title3D {
        func c(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? min(max(v, lo), hi) : lo }
        var t = self
        t.depth = c(depth, 0, 60)
        t.direction = c(direction, 0, 360)
        t.tiltX = c(tiltX, -35, 35)
        t.tiltY = c(tiltY, -35, 35)
        t.duration = c(duration, 0.2, 3)
        return t
    }

    public var hasLook: Bool { depth > 0.01 || bevel || abs(tiltX) > 0.01 || abs(tiltY) > 0.01 }
    public var hasMotion: Bool { motion != .off }
    public var isActive: Bool { hasLook || hasMotion }

    /// Offset of extrusion layer `i` of `n` in pixels (CoreGraphics y-up), for `unit` px per point.
    public func extrusionStep(unit: Double) -> (dx: Double, dy: Double) {
        let r = direction * Double.pi / 180
        return (cos(r) * unit, sin(r) * unit)
    }

    /// Fixed tilt combined with the motion pose.
    public func pose(progress: Double) -> Pose3D {
        var p = motion.pose(progress: progress)
        p.rotX += tiltX; p.rotY += tiltY
        return p
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Title3D()
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? cur }
        depth = v(.depth, d.depth)
        direction = v(.direction, d.direction)
        sideColor = (try? c.decodeIfPresent(ProjectColor.self, forKey: .sideColor)) ?? nil
        bevel = v(.bevel, d.bevel)
        tiltX = v(.tiltX, d.tiltX)
        tiltY = v(.tiltY, d.tiltY)
        motion = (try? c.decodeIfPresent(Motion3D.self, forKey: .motion)) ?? .off
        duration = v(.duration, d.duration)
        self = clamped
    }
}

/// Perspective projection of a flat rectangle turned in 3D.
public enum Projection3D {
    /// Corners (top-left, top-right, bottom-right, bottom-left) of the box `x, y, w, h` (y-down
    /// pixels) after `pose`, seen by a camera `distance` pixels in front of the canvas plane.
    public static func corners(x: Double, y: Double, w: Double, h: Double, pose: Pose3D,
                               distance: Double) -> [(x: Double, y: Double)] {
        let px = x + w * pose.pivotX, py = y + h * pose.pivotY
        let r = Double.pi / 180
        let ax = pose.rotX * r, ay = pose.rotY * r
        let f = max(distance, 1)
        let push = pose.depth * h
        let pts = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
        return pts.map { p in
            var X = p.0 - px, Y = p.1 - py, Z = 0.0
            // Around the horizontal axis (positive = top edge away from the viewer).
            let y1 = Y * cos(ax) - Z * sin(ax), z1 = Y * sin(ax) + Z * cos(ax)
            Y = y1; Z = z1
            // Around the vertical axis (positive = right edge away from the viewer).
            let x2 = X * cos(ay) + Z * sin(ay), z2 = -X * sin(ay) + Z * cos(ay)
            X = x2; Z = z2
            Z = -Z + push   // depth grows away from the viewer
            let s = f / max(f + Z, 1)
            return (px + X * s, py + Y * s)
        }
    }
}

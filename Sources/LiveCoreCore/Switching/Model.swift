/// Identifier of an input (a camera, a file, an image, a text generator, ...).
/// Core stays Foundation-free, so IDs are strings (the engine uses UUID().uuidString).
public struct InputID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// Rectangle in normalized output space: (0,0) top-left, (1,1) bottom-right.
public struct NormRect: Equatable, Codable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = NormRect(x: 0, y: 0, width: 1, height: 1)
}

/// Pixel-space rectangle in the output canvas.
public struct PixelRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct PixelSize: Equatable, Codable, Sendable, Hashable {
    public var width: Int, height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var aspect: Double { height == 0 ? 0 : Double(width) / Double(height) }
}

public enum ScaleMode: String, Codable, Sendable, CaseIterable {
    case fit      // letterbox / pillarbox, whole source visible
    case fill     // crop to fill, no bars
    case stretch  // ignore aspect ratio
}

/// One source drawn inside a composition.
public struct Layer: Equatable, Codable, Sendable {
    public var source: InputID
    public var rect: NormRect
    public var scaleMode: ScaleMode
    public var opacity: Double
    public init(source: InputID, rect: NormRect = .full, scaleMode: ScaleMode = .fit, opacity: Double = 1) {
        self.source = source; self.rect = rect; self.scaleMode = scaleMode; self.opacity = opacity
    }
}

/// Layout presets used by overlay channels and scene layers (PiP, lower third...).
public enum LayoutPreset: String, Codable, Sendable, CaseIterable {
    case fullScreen
    case pipTopRight, pipTopLeft, pipBottomRight, pipBottomLeft
    case lowerThird
    case sideBySideLeft, sideBySideRight

    public var rect: NormRect {
        let pw = 0.30, ph = 0.30, m = 0.04
        switch self {
        case .fullScreen: return .full
        case .pipTopRight: return NormRect(x: 1 - pw - m, y: m, width: pw, height: ph)
        case .pipTopLeft: return NormRect(x: m, y: m, width: pw, height: ph)
        case .pipBottomRight: return NormRect(x: 1 - pw - m, y: 1 - ph - m, width: pw, height: ph)
        case .pipBottomLeft: return NormRect(x: m, y: 1 - ph - m, width: pw, height: ph)
        case .lowerThird: return NormRect(x: 0, y: 0.70, width: 1, height: 0.25)
        case .sideBySideLeft: return NormRect(x: 0, y: 0.25, width: 0.5, height: 0.5)
        case .sideBySideRight: return NormRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        }
    }
}

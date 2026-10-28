import Foundation

/// A vMix GT title template (.gtzip) imported for playback: the boxes, texts and pictures with
/// their final positions, and the "in" storyboard (0.39.0). Coordinates are in the template's
/// own pixels with the origin at the top left; the renderer scales them to the output.
public struct GTTemplate: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var elements: [GTElement]
    public var animations: [GTAnimation]
    public init(width: Double, height: Double, elements: [GTElement] = [], animations: [GTAnimation] = []) {
        self.width = width; self.height = height; self.elements = elements; self.animations = animations
    }

    /// Names of the text elements, in drawing order: the fields the operator can change.
    public var textFields: [String] { elements.compactMap { $0.kind == .text ? $0.name : nil } }

    public func animation(for name: String) -> GTAnimation? { animations.first { $0.object == name } }

    /// Seconds until the last "in" animation has finished.
    public var inDuration: Double { animations.map { $0.delay + $0.duration }.max() ?? 0 }
}

public struct GTColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let clear = GTColor(r: 0, g: 0, b: 0, a: 0)
    public static let white = GTColor(r: 1, g: 1, b: 1)

    /// "#AARRGGBB" or "#RRGGBB".
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 8 || s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
        } else {
            self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255,
                      a: Double(v >> 24) / 255)
        }
    }
}

/// A solid colour, or a linear / radial gradient between `start` and `end` (0…1 of the shape).
public struct GTBrush: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case solid, linear, radial }
    public var kind: Kind = .solid
    public var color: GTColor = .clear
    public var stops: [(position: Double, color: GTColor)] = []
    public var start = (x: 0.0, y: 0.0)
    public var end = (x: 1.0, y: 1.0)
    public init(kind: Kind = .solid, color: GTColor = .clear) { self.kind = kind; self.color = color }

    public static func == (a: GTBrush, b: GTBrush) -> Bool {
        a.kind == b.kind && a.color == b.color && a.start == b.start && a.end == b.end
            && a.stops.count == b.stops.count && zip(a.stops, b.stops).allSatisfy { $0.position == $1.position && $0.color == $1.color }
    }
}

public struct GTElement: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case rectangle, ellipse, text, image }
    public var kind: Kind
    public var name: String
    /// Top-left corner and size in template pixels.
    public var x = 0.0, y = 0.0, width = 0.0, height = 0.0
    public var fill = GTBrush()
    public var stroke: GTColor?
    public var strokeThickness = 0.0
    public var cornerRadius = 0.0
    /// Horizontal skew in degrees (WPF style: lower edge moves right for positive angles).
    public var skewX = 0.0
    public var shadow: (x: Double, y: Double)?
    /// The layer box the element is cut to (template pixels), nil when not inside a layer.
    public var clip: (x: Double, y: Double, width: Double, height: Double)?
    // Text
    public var text = ""
    public var fontFamily = "Arial"
    public var fontSize = 36.0
    public var bold = false
    public var italic = false
    public var alignment = "Left"          // Left, Center, Right
    public var verticalAlignment = "Top"   // Top, Center, Bottom
    // Image: the picture's bytes from the .gtzip (PNG / JPEG).
    public var imageData: Data?

    public init(kind: Kind, name: String) { self.kind = kind; self.name = name }

    public static func == (a: GTElement, b: GTElement) -> Bool {
        a.kind == b.kind && a.name == b.name && a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
            && a.fill == b.fill && a.stroke == b.stroke && a.strokeThickness == b.strokeThickness && a.cornerRadius == b.cornerRadius
            && a.skewX == b.skewX && a.clip?.x == b.clip?.x && a.clip?.y == b.clip?.y
            && a.clip?.width == b.clip?.width && a.clip?.height == b.clip?.height && a.shadow?.x == b.shadow?.x && a.shadow?.y == b.shadow?.y && a.text == b.text
            && a.fontFamily == b.fontFamily && a.fontSize == b.fontSize && a.bold == b.bold && a.italic == b.italic
            && a.alignment == b.alignment && a.verticalAlignment == b.verticalAlignment && a.imageData == b.imageData
    }
}

/// One "in" animation of the storyboard. Supported: Reveal (wipe), Expand (grow from the centre or
/// an edge), Zoom (scale from the centre), Fade. Other types simply appear at their delay.
public struct GTAnimation: Equatable, Sendable {
    public var type: String
    public var object: String
    public var delay: Double
    public var duration: Double
    public var direction: String?   // Left, Right, Top, Bottom
    public init(type: String, object: String, delay: Double = 0, duration: Double = 0.5, direction: String? = nil) {
        self.type = type; self.object = object; self.delay = delay; self.duration = duration; self.direction = direction
    }

    /// 0 before the animation, 1 when done (eased), at `t` seconds after the title went on air.
    public func progress(at t: Double) -> Double {
        guard duration > 0 else { return t >= delay ? 1 : 0 }
        let p = min(max((t - delay) / duration, 0), 1)
        return 1 - pow(1 - p, 3)   // ease out
    }

    /// What to draw of the element at progress `p`: a clip of its box (0…1 in each axis), a scale
    /// about the given anchor (0…1 of the box) and an opacity.
    public struct Frame: Equatable, Sendable {
        public var clip = (x0: 0.0, y0: 0.0, x1: 1.0, y1: 1.0)
        public var scale = (x: 1.0, y: 1.0)
        public var anchor = (x: 0.5, y: 0.5)
        public var opacity = 1.0
        public init() {}
        public static func == (a: Frame, b: Frame) -> Bool {
            a.clip == b.clip && a.scale == b.scale && a.anchor == b.anchor && a.opacity == b.opacity
        }
    }

    public func frame(progress p: Double) -> Frame {
        var f = Frame()
        let dir = (direction ?? "").lowercased()
        switch type.lowercased() {
        case "reveal", "wipe":
            switch dir {
            case "right": f.clip.x0 = 1 - p
            case "top": f.clip.y1 = p
            case "bottom": f.clip.y0 = 1 - p
            default: f.clip.x1 = p
            }
        case "expand":
            switch dir {
            case "top": f.scale.y = p; f.anchor.y = 0
            case "bottom": f.scale.y = p; f.anchor.y = 1
            case "left": f.scale.x = p; f.anchor.x = 0
            case "right": f.scale.x = p; f.anchor.x = 1
            default: f.scale.x = p
            }
        case "zoom":
            f.scale = (p, p)
        case "fade":
            f.opacity = p
        default:
            f.opacity = p > 0 ? 1 : 0
        }
        return f
    }
}

/// An imported GT title input in a project: the .gtzip file and the operator's texts by field name.
public struct ProjectGTTitle: Codable, Equatable, Sendable {
    public var file: ProjectMediaRef
    public var fields: [String: String]
    public init(file: ProjectMediaRef, fields: [String: String] = [:]) { self.file = file; self.fields = fields }
}

import Foundation

// LiveCore's own PowerPoint (.pptx) reader (0.80.0): what is on each slide, in points, ready to
// draw. It covers what most event decks use: backgrounds, text boxes and placeholders with the
// layout / master / theme styles, pictures, basic and freeform shapes, groups and simple tables.
// Not covered: animations and transitions, video and audio, charts, SmartArt, WordArt effects,
// shadows / glow / 3-D, gradient detail (the first colour is used) and EMF/WMF pictures.

public struct PPTXColor: Equatable, Sendable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let black = PPTXColor(r: 0, g: 0, b: 0)
    public static let white = PPTXColor(r: 1, g: 1, b: 1)
}

public struct PPTXRect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public struct PPTXRun: Equatable, Sendable {
    public var text: String
    public var size: Double
    public var bold = false, italic = false, underline = false
    public var color: PPTXColor
    public var font: String?
    public init(text: String, size: Double, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                color: PPTXColor, font: String? = nil) {
        self.text = text; self.size = size; self.bold = bold; self.italic = italic; self.underline = underline
        self.color = color; self.font = font
    }
}

public struct PPTXParagraph: Equatable, Sendable {
    public enum Align: String, Sendable { case left = "l", center = "ctr", right = "r", justify = "just" }
    public var runs: [PPTXRun] = []
    public var align: Align = .left
    /// Bullet text drawn before the paragraph ("•", "3."), nil = none.
    public var bullet: String?
    /// Left margin and first-line offset (negative = hanging bullet), points.
    public var marginLeft = 0.0, firstLine = 0.0
    /// Line height as a multiple of the font's; nil = single.
    public var lineSpacing: Double?
    public var spaceBefore = 0.0
}

public struct PPTXText: Equatable, Sendable {
    public enum Anchor: String, Sendable { case top = "t", middle = "ctr", bottom = "b" }
    public var paragraphs: [PPTXParagraph]
    public var anchor: Anchor = .top
    /// Left, top, right, bottom insets in points.
    public var insets = [7.2, 3.6, 7.2, 3.6]
    public var wrap = true
    /// "Shrink text on overflow".
    public var shrink = false
}

public enum PPTXPathCommand: Equatable, Sendable {
    /// Coordinates are fractions of the shape's frame.
    case move(Double, Double), line(Double, Double), cubic(Double, Double, Double, Double, Double, Double), close
}

public struct PPTXShape: Equatable, Sendable {
    public enum Geometry: String, Sendable { case rect, roundRect, ellipse, line, triangle, rtTriangle, diamond, custom }
    public var frame: PPTXRect
    public var rotation = 0.0
    public var flipH = false, flipV = false
    public var geometry: Geometry = .rect
    public var path: [PPTXPathCommand] = []
    public var fill: PPTXColor?
    public var line: PPTXColor?
    public var lineWidth = 0.75
    /// Picture file and the part of it shown (left, top, right, bottom cropped, fractions).
    public var image: String?
    public var crop = [0.0, 0, 0, 0]
    public var text: PPTXText?
}

public struct PPTXSlide: Equatable, Sendable {
    public var background: PPTXColor = .white
    public var backgroundImage: String?
    public var shapes: [PPTXShape] = []
}

public struct PPTXDeck: Equatable, Sendable {
    /// Slide size in points (16:9 = 960 × 540).
    public var width = 960.0, height = 540.0
    public var slides: [PPTXSlide] = []
}

/// vMix GT title inputs were removed in 0.62.0. These types stay only so projects saved by
/// 0.39.0–0.61.x still open (the GT input is skipped with a warning).

/// An imported GT title input in a project: the .gtzip file and the operator's texts by field name.
public struct ProjectGTTitle: Codable, Equatable, Sendable {
    public var file: ProjectMediaRef
    public var fields: [String: String]
    /// Element changes made in the GT editor, by element name (0.40.0).
    public var overrides: [String: GTElementOverride]?
    /// Animation speed, 1 = as designed.
    public var speed: Double?
    public init(file: ProjectMediaRef, fields: [String: String] = [:], overrides: [String: GTElementOverride]? = nil,
                speed: Double? = nil) {
        self.file = file; self.fields = fields; self.overrides = overrides; self.speed = speed
    }
}

/// The operator's changes to one element of an imported GT title (0.40.0). Nil fields keep the
/// template's value.
public struct GTElementOverride: Codable, Equatable, Sendable {
    public var hidden: Bool?
    public var x: Double?, y: Double?, width: Double?, height: Double?
    public var fontFamily: String?
    public var fontSize: Double?
    public var bold: Bool?, italic: Bool?
    public var alignment: String?
    public var verticalAlignment: String?
    /// Solid fill / text colour as "#AARRGGBB".
    public var color: String?
    public var strokeColor: String?
    public var strokeThickness: Double?
    public var cornerRadius: Double?
    public var skewX: Double?
    public var opacity: Double?
    /// Replacement picture for an image element.
    public var image: ProjectMediaRef?
    /// Animation: type ("None" removes it), direction, delay and duration.
    public var animation: String?
    public var direction: String?
    public var delay: Double?
    public var duration: Double?
    public init() {}
    public var isEmpty: Bool { self == GTElementOverride() }
}

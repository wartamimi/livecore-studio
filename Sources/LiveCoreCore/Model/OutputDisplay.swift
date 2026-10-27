/// Which display the fullscreen Program output goes to. Pure so it is unit-tested on Linux;
/// the window itself lives in the UI target.
public struct DisplayInfo: Equatable, Sendable {
    public var id: UInt32          // CGDirectDisplayID
    public var name: String
    public var isMain: Bool        // the display that holds the menu bar
    public init(id: UInt32, name: String, isMain: Bool) { self.id = id; self.name = name; self.isMain = isMain }
}

public enum OutputDisplayPicker {
    /// The saved display when it is still connected (matched by id, then by name, since ids can
    /// change after a reconnect); otherwise the first external display; otherwise the main one.
    /// With nothing saved, `extraIndex` picks among the displays other than the main one (0 = the
    /// first, 1 = the second...), so outputs 1, 2 and 3 land on the 2nd, 3rd and 4th display.
    public static func choose(savedID: UInt32?, savedName: String?, displays: [DisplayInfo], extraIndex: Int = 0) -> DisplayInfo? {
        if let savedID, let d = displays.first(where: { $0.id == savedID }) { return d }
        if let savedName, !savedName.isEmpty, let d = displays.first(where: { $0.name == savedName }) { return d }
        let extras = displays.filter { !$0.isMain }
        if extras.indices.contains(extraIndex) { return extras[extraIndex] }
        return extras.last ?? displays.first
    }

    /// Whether the open fullscreen output must close because its display went away.
    public static func lost(_ current: DisplayInfo, in displays: [DisplayInfo]) -> Bool {
        !displays.contains { $0.id == current.id }
    }
}

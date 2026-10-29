/// Window / display capture input (Zoom, Teams, Meet, slides, a browser...). Pure model and
/// matching rules; the ScreenCaptureKit source lives in the engine.
public struct ProjectScreenCapture: Codable, Equatable, Sendable {
    public enum Target: String, Codable, Sendable { case window, display }
    public var target: Target
    /// Window: the owning app and the window title when it was picked. Window ids change
    /// between launches, so a saved window is found again by app + title.
    public var bundleID: String
    public var appName: String
    public var windowTitle: String
    /// Display: CGDirectDisplayID.
    public var displayID: UInt32
    /// Capture the app's (window) or the system's (display) audio into a mixer channel.
    public var captureAudio: Bool
    public var fps: Int
    public var showsCursor: Bool

    public init(target: Target, bundleID: String = "", appName: String = "", windowTitle: String = "",
                displayID: UInt32 = 0, captureAudio: Bool = true, fps: Int = 30, showsCursor: Bool = false) {
        self.target = target; self.bundleID = bundleID; self.appName = appName; self.windowTitle = windowTitle
        self.displayID = displayID; self.captureAudio = captureAudio; self.fps = fps; self.showsCursor = showsCursor
    }

    /// Same window (app + title) or same display: capturing it twice would only duplicate it.
    public func sameTarget(as o: ProjectScreenCapture) -> Bool {
        guard target == o.target else { return false }
        switch target {
        case .window: return bundleID == o.bundleID && windowTitle == o.windowTitle
        case .display: return displayID == o.displayID
        }
    }

    public var displayName: String {
        switch target {
        case .window: return windowTitle.isEmpty ? appName : "\(appName) – \(windowTitle)"
        case .display: return "Display \(displayID)"
        }
    }

    public static func clampFPS(_ fps: Int) -> Int { min(max(fps, 1), 60) }
}

/// A capturable window as listed by the system.
public struct WindowCandidate: Equatable, Sendable {
    public var windowID: UInt32
    public var bundleID: String
    public var appName: String
    public var title: String
    public init(windowID: UInt32, bundleID: String, appName: String, title: String) {
        self.windowID = windowID; self.bundleID = bundleID; self.appName = appName; self.title = title
    }
}

public enum WindowMatcher {
    /// Finds the saved window again: same app and title, else same app and a title that
    /// contains the saved one (or vice versa: meeting titles gain/lose a suffix), else the
    /// app's only window. Nil when the app is not running or the choice is ambiguous.
    public static func find(_ saved: ProjectScreenCapture, in windows: [WindowCandidate]) -> WindowCandidate? {
        let app = windows.filter { $0.bundleID == saved.bundleID }
        if let w = app.first(where: { $0.title == saved.windowTitle }) { return w }
        if !saved.windowTitle.isEmpty {
            let fuzzy = app.filter { !$0.title.isEmpty && ($0.title.contains(saved.windowTitle) || saved.windowTitle.contains($0.title)) }
            if fuzzy.count == 1 { return fuzzy[0] }
        }
        return app.count == 1 ? app[0] : nil
    }

    /// Windows worth offering in the picker: titled, not our own app, apps grouped together.
    public static func pickerList(_ windows: [WindowCandidate], ownBundleID: String) -> [WindowCandidate] {
        windows.filter { !$0.title.isEmpty && $0.bundleID != ownBundleID }
            .sorted { ($0.appName.lowercased(), $0.title.lowercased()) < ($1.appName.lowercased(), $1.title.lowercased()) }
    }
}

/// Names and ids shared by the app and the LiveCore virtual camera (a CoreMediaIO Camera
/// Extension, like OBS's). This file is also compiled into the extension target (project.yml),
/// so it must stay free of imports.
public enum VirtualCameraIdentity {
    /// Bundle id of the extension; it must start with the app's bundle id.
    public static let extensionBundleID = "studio.livecore.LiveCoreStudio.CameraExtension"
    /// Camera name shown in Zoom, Meet, OBS, QuickTime...
    public static let deviceName = "LiveCore Virtual Camera"
    public static let manufacturer = "LiveCore Studio"
    /// CoreMediaIO device id; the device's UID property is this UUID string.
    public static let deviceUUID = "5C1D2E3F-4A5B-4C6D-8E7F-1A2B3C4D5E6F"
    /// Stream that apps read (the camera picture).
    public static let sourceStreamUUID = "5C1D2E3F-4A5B-4C6D-8E7F-1A2B3C4D5E70"
    /// Stream LiveCore Studio writes its output into (the "sink", as in OBS).
    public static let sinkStreamUUID = "5C1D2E3F-4A5B-4C6D-8E7F-1A2B3C4D5E71"
    /// Picture size and rate the camera offers; other output sizes are scaled to this.
    public static let width: Int32 = 1920
    public static let height: Int32 = 1080
    public static let frameRate: Int32 = 30
}

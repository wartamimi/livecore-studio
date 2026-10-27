#if os(macOS)
import os

/// Unified logging categories. Stream keys must never be passed to these loggers; URLs are
/// logged via `RTMPURL.tcUrl`, which by construction excludes the key.
public enum Log {
    public static let subsystem = "studio.livecore.LiveCoreStudio"
    public static let video = Logger(subsystem: subsystem, category: "video")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let stream = Logger(subsystem: subsystem, category: "stream")
    public static let record = Logger(subsystem: subsystem, category: "record")
    public static let devices = Logger(subsystem: subsystem, category: "devices")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
#endif

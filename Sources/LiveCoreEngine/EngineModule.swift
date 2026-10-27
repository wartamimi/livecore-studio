// LiveCoreEngine contains the macOS media engines. Every file is wrapped in `#if os(macOS)`
// so the package still resolves and the portable targets build/test on Linux CI.
public enum LiveCoreEngineInfo {
    public static let version = "0.1.0"
    #if os(macOS)
    public static let isSupportedPlatform = true
    #else
    public static let isSupportedPlatform = false
    #endif
}

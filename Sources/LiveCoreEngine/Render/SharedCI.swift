#if os(macOS)
import CoreImage
import Metal

/// Process-wide Core Image contexts. Each `CIContext` holds its own GPU caches and command
/// queue, so sources and outputs share these two instead of creating their own.
public enum SharedCI {
    private static let device = MTLCreateSystemDefaultDevice()

    /// Color-managed (Core Image default working space).
    public static let standard: CIContext = {
        if let device { return CIContext(mtlDevice: device, options: [.cacheIntermediates: false]) }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    /// No color management: pixel values pass through unchanged (vertical output, sampling).
    public static let passthrough: CIContext = {
        let o: [CIContextOption: Any] = [.cacheIntermediates: false, .workingColorSpace: NSNull()]
        if let device { return CIContext(mtlDevice: device, options: o) }
        return CIContext(options: o)
    }()
}
#endif

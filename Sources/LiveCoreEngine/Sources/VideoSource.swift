#if os(macOS)
import CoreVideo
import Foundation
import LiveCoreCore

public enum InputKind: String, Codable, Sendable {
    case camera, image, videoFile, color, text, browser, timer, screen, replay
}

public enum SourceStatus: Equatable, Sendable {
    case starting
    case live
    case noSignal(String)     // device present but no frames (unplugged, interrupted...)
    case error(String)

    public var isHealthy: Bool { if case .live = self { return true }; return false }
    public var label: String {
        switch self {
        case .starting: return "Starting"
        case .live: return "Live"
        case let .noSignal(s): return "No signal: \(s)"
        case let .error(s): return "Error: \(s)"
        }
    }
}

/// A producer of video frames. Implementations must make `currentFrame()` cheap, non-blocking
/// and safe to call from the render queue; it returns the most recent frame (BGRA,
/// IOSurface-backed, Metal-compatible) or nil if none is available yet.
public protocol VideoSource: AnyObject {
    var id: InputID { get }
    var kind: InputKind { get }
    var name: String { get set }
    var status: SourceStatus { get }
    var onStatusChange: ((SourceStatus) -> Void)? { get set }
    func start()
    func stop()
    func currentFrame() -> CVPixelBuffer?
}

/// Thread-safe "latest frame" mailbox written by a capture/decoder thread and read by the
/// render thread. Holds exactly one buffer so capture pools are never starved.
public final class FrameSlot: @unchecked Sendable {
    private let lock = UnfairLock()
    private var buffer: CVPixelBuffer?
    private var stamp: Double = 0

    public init() {}

    public func put(_ pb: CVPixelBuffer) {
        let now = HostClock.now()
        lock.withLock { buffer = pb; stamp = now }
    }
    public func get() -> CVPixelBuffer? { lock.withLock { buffer } }
    public var lastUpdate: Double { lock.withLock { stamp } }
    public func clear() { lock.withLock { buffer = nil } }
}

/// Attributes for every pixel buffer we create: BGRA, IOSurface-backed (zero-copy to Metal,
/// VideoToolbox and CALayer) and Metal-compatible.
public enum PixelBufferFactory {
    public static func attributes(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
    }

    public static func make(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                     attributes(width: width, height: height) as CFDictionary, &pb)
        return st == kCVReturnSuccess ? pb : nil
    }

    public static func makePool(width: Int, height: Int, minimumCount: Int = 4) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: minimumCount]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                attributes(width: width, height: height) as CFDictionary, &pool)
        return pool
    }

    /// Draws with CoreGraphics into a new BGRA (premultiplied alpha) buffer.
    public static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CVPixelBuffer? {
        guard let pb = make(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        body(ctx)
        return pb
    }
}
#endif

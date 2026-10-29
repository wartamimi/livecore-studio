#if os(macOS)
import CNDI
import CoreVideo
import Foundation
import LiveCoreCore

/// The NDI® runtime installed on this Mac by NDI Tools or the NDI Runtime installer. LiveCore
/// does not ship it; it is loaded on first use, and a runtime installed later needs a restart.
public enum NDIRuntime {
    public static var isAvailable: Bool { lc_ndi_load() }
    public static var version: String? { lc_ndi_version().map { String(cString: $0) } }
    public static var libraryPath: String? { lc_ndi_loaded_path().map { String(cString: $0) } }
    public static let downloadURL = URL(string: LC_NDI_REDIST_URL)!
}

/// One NDI source, announced as "<Mac name> (<name>)". Video is sent on the sender's own queue;
/// a frame that arrives while the previous one is still being compressed is dropped, so the
/// render thread never waits. Audio goes through the same queue and is never dropped.
public final class NDISender: @unchecked Sendable {
    public let name: String
    private let handle: OpaquePointer
    private let queue: DispatchQueue
    private let busy = AtomicBool()
    private let frameRate: Int32
    public let droppedFrames = AtomicCounter()

    /// nil when the runtime is missing or the source could not be created.
    public init?(name: String, frameRate: Int) {
        guard let h = lc_ndi_sender_create(name) else { return nil }
        self.name = name
        handle = h
        self.frameRate = Int32(max(1, frameRate))
        queue = DispatchQueue(label: "livecore.ndi.\(name)", qos: .userInitiated)
    }

    deinit {
        // Every queued send holds `self`, so nothing is in flight any more.
        let h = handle
        DispatchQueue.global(qos: .utility).async { lc_ndi_sender_destroy(h) }
    }

    /// Receivers connected right now (NDI Virtual Input, OBS, vMix, Studio Monitor...).
    public var connections: Int { Int(lc_ndi_connections(handle)) }

    /// Sends a 32BGRA frame (other formats are skipped).
    public func send(_ pb: CVPixelBuffer) {
        guard !busy.value else { droppedFrames.add(); return }
        busy.value = true
        queue.async { [self] in
            defer { busy.value = false }
            guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            lc_ndi_send_video(handle, base, Int32(CVPixelBufferGetWidth(pb)), Int32(CVPixelBufferGetHeight(pb)),
                              Int32(CVPixelBufferGetBytesPerRow(pb)), frameRate, 1)
        }
    }

    /// Sends stereo audio (the Program mix).
    public func send(left: [Float], right: [Float], sampleRate: Int) {
        let n = min(left.count, right.count)
        guard n > 0 else { return }
        queue.async { [self] in
            let planar = Array(left.prefix(n)) + Array(right.prefix(n))
            planar.withUnsafeBufferPointer { lc_ndi_send_audio(handle, $0.baseAddress, 2, Int32(n), Int32(sampleRate)) }
        }
    }
}
#endif

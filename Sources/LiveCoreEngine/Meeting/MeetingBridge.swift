#if os(macOS)
import Accelerate
import CoreVideo
import Foundation
import LiveCoreCore

/// Video-conference integration (Zoom Meeting SDK). The SDK is proprietary and not part of the
/// open-source build: the app target provides an implementation only when it is built with the
/// SDK (CI fetches it from a private repository). Without it `MeetingBridgeRegistry.make` is nil
/// and the UI says so.
public protocol MeetingBridge: AnyObject {
    /// Main thread. Called by the bridge whenever state or the participant list changes.
    var onChange: (() -> Void)? { get set }
    /// SDK thread: a video frame (I420) of a subscribed participant.
    var onVideoFrame: ((_ userID: UInt32, _ frame: I420Frame) -> Void)? { get set }
    /// SDK thread: mixed meeting audio (everyone except us), interleaved Int16.
    var onMixedAudio: ((_ samples: UnsafePointer<Int16>, _ frames: Int, _ channels: Int, _ sampleRate: Int) -> Void)? { get set }

    var state: MeetingState { get }
    /// Waiting-for-host / waiting-room notes and the last error.
    var statusMessage: String { get }
    var participants: [MeetingParticipant] { get }
    var sdkVersion: String { get }

    /// Initialises the SDK and authorises with a JWT made from the Client ID/Secret.
    func authorize(jwt: String)
    /// `sendVideo`/`sendAudio`: install the virtual camera / microphone (decided before joining).
    func join(meetingNumber: Int64, passcode: String, displayName: String, sendVideo: Bool, sendAudio: Bool)
    func leave()
    /// Asks the host for the local-recording privilege needed for raw video/audio.
    func requestRawDataPermission()
    /// Starts/stops receiving a participant's video (`onVideoFrame`).
    func subscribe(userID: UInt32)
    func unsubscribe(userID: UInt32)

    /// Return feed: whether the meeting currently accepts our virtual camera / microphone.
    var canSendVideo: Bool { get }
    var canSendAudio: Bool { get }
    /// Program out as our camera in the meeting (I420, any thread).
    func sendVideo(_ frame: I420Frame)
    /// A bus as our microphone in the meeting (mono Int16 at 48 kHz, any thread).
    func sendAudio(_ samples: UnsafePointer<Int16>, frames: Int)
}

public enum MeetingState: Equatable, Sendable {
    case notAuthorized
    case authorizing
    case ready                    // authorised, not in a meeting
    case joining
    case inMeeting(rawData: RawDataState)
    case failed(String)

    public enum RawDataState: Equatable, Sendable { case notAllowed, requested, allowed }

    public var inMeeting: Bool { if case .inMeeting = self { return true }; return false }
}

public struct MeetingParticipant: Equatable, Identifiable, Sendable {
    public var id: UInt32
    public var name: String
    public var isHost: Bool
    public var videoOn: Bool
    public var isMe: Bool
    public init(id: UInt32, name: String, isHost: Bool, videoOn: Bool, isMe: Bool) {
        self.id = id; self.name = name; self.isHost = isHost; self.videoOn = videoOn; self.isMe = isMe
    }
}

/// A borrowed I420 frame (planes valid only during the callback).
public struct I420Frame {
    public var width: Int
    public var height: Int
    public var y: UnsafeMutablePointer<UInt8>
    public var u: UnsafeMutablePointer<UInt8>
    public var v: UnsafeMutablePointer<UInt8>
    public var yStride: Int
    public var uvStride: Int
    public var fullRange: Bool
    public init(width: Int, height: Int, y: UnsafeMutablePointer<UInt8>, u: UnsafeMutablePointer<UInt8>, v: UnsafeMutablePointer<UInt8>,
                yStride: Int, uvStride: Int, fullRange: Bool) {
        self.width = width; self.height = height; self.y = y; self.u = u; self.v = v
        self.yStride = yStride; self.uvStride = uvStride; self.fullRange = fullRange
    }
}

public enum MeetingBridgeRegistry {
    /// Set by the app target when it is built with the Zoom SDK.
    public static var make: (() -> MeetingBridge)?
}

/// I420 <-> BGRA with vImage (BT.601, as Zoom uses).
public final class I420Converter {
    private var toRGB: vImage_YpCbCrToARGB?
    private var toRGBFull: Bool?
    private var fromRGB: vImage_ARGBToYpCbCr?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var scratch: [UInt8] = []

    public init() {}

    /// BGRA pixel buffer (IOSurface-backed, Metal-compatible) from an I420 frame.
    public func bgra(from f: I420Frame) -> CVPixelBuffer? {
        guard f.width > 1, f.height > 1 else { return nil }
        if toRGB == nil || toRGBFull != f.fullRange {
            var info = vImage_YpCbCrToARGB()
            var range = f.fullRange
                ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
                : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
            guard vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range, &info,
                                                                 kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
            toRGB = info; toRGBFull = f.fullRange
        }
        if pool == nil || poolSize != (f.width, f.height) {
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                    PixelBufferFactory.attributes(width: f.width, height: f.height) as CFDictionary, &p)
            pool = p; poolSize = (f.width, f.height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        var yb = vImage_Buffer(data: f.y, height: vImagePixelCount(f.height), width: vImagePixelCount(f.width), rowBytes: f.yStride)
        var ub = vImage_Buffer(data: f.u, height: vImagePixelCount(f.height / 2), width: vImagePixelCount(f.width / 2), rowBytes: f.uvStride)
        var vb = vImage_Buffer(data: f.v, height: vImagePixelCount(f.height / 2), width: vImagePixelCount(f.width / 2), rowBytes: f.uvStride)
        var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(f.height), width: vImagePixelCount(f.width),
                                rowBytes: CVPixelBufferGetBytesPerRow(pb))
        // ARGB channel order permuted to BGRA: [B, G, R, A] = [3, 2, 1, 0].
        let permute: [UInt8] = [3, 2, 1, 0]
        guard var info = toRGB,
              vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&yb, &ub, &vb, &dst, &info, permute, 255, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        return pb
    }

    /// I420 copy of a BGRA pixel buffer in one contiguous block (Y, U, V; strides width and
    /// width/2), as the Zoom SDK wants it. `body` gets the frame while it is valid.
    public func i420(from pb: CVPixelBuffer, _ body: (I420Frame) -> Void) {
        let w = CVPixelBufferGetWidth(pb) & ~1, h = CVPixelBufferGetHeight(pb) & ~1
        guard w > 1, h > 1 else { return }
        if fromRGB == nil {
            var info = vImage_ARGBToYpCbCr()
            var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
            guard vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &info,
                                                                 kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return }
            fromRGB = info
        }
        let ySize = w * h, cSize = (w / 2) * (h / 2)
        if scratch.count != ySize + 2 * cSize { scratch = [UInt8](repeating: 0, count: ySize + 2 * cSize) }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(h), width: vImagePixelCount(w),
                                rowBytes: CVPixelBufferGetBytesPerRow(pb))
        scratch.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let y = base, u = base + ySize, v = base + ySize + cSize
            var yb = vImage_Buffer(data: y, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            var ub = vImage_Buffer(data: u, height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2), rowBytes: w / 2)
            var vb = vImage_Buffer(data: v, height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2), rowBytes: w / 2)
            // Source is BGRA: present it as ARGB with permute [3, 2, 1, 0].
            let permute: [UInt8] = [3, 2, 1, 0]
            guard var info = fromRGB,
                  vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(&src, &yb, &ub, &vb, &info, permute, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            else { return }
            body(I420Frame(width: w, height: h, y: y, u: u, v: v, yStride: w, uvStride: w / 2, fullRange: false))
        }
    }
}

/// One meeting participant as a video input. Frames arrive on the SDK thread.
public final class MeetingParticipantSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .meeting
    public var name: String
    public let userID: UInt32
    public private(set) var status: SourceStatus = .noSignal("waiting for video") {
        didSet { if status != oldValue { let s = status; DispatchQueue.main.async { self.onStatusChange?(s) } } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    private let slot = FrameSlot()
    private let converter = I420Converter()
    private let lock = UnfairLock()

    public init(id: InputID, userID: UInt32, name: String) { self.id = id; self.userID = userID; self.name = name }

    public func start() {}
    public func stop() { slot.clear() }
    public func currentFrame() -> CVPixelBuffer? { slot.get() }

    /// SDK thread.
    public func push(_ f: I420Frame) {
        guard let pb = lock.withLock({ converter.bgra(from: f) }) else { return }
        slot.put(pb)
        if status != .live { status = .live }
    }

    public func videoStopped() { status = .noSignal("video off") }
}
#endif

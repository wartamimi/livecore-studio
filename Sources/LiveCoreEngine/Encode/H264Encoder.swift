#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import LiveCoreCore

/// Hardware-accelerated H.264 encoder (VideoToolbox). Apple Silicon uses the media engine;
/// Intel Macs use Intel Quick Sync or the Apple T2 encoder where present. If no hardware
/// encoder is available VideoToolbox falls back to its software encoder and
/// `isHardwareAccelerated` reports false (shown in the UI).
///
/// B-frames are disabled (AllowFrameReordering = false) so DTS == PTS, which keeps FLV/RTMP
/// timestamps simple and lowers latency.
public final class H264Encoder {
    public struct EncodedFrame {
        public var avcc: [UInt8]          // NAL units with 4-byte length prefixes
        public var pts: CMTime
        public var keyframe: Bool
        public var sps: [UInt8]
        public var pps: [UInt8]
    }

    public enum EncoderError: Error, LocalizedError {
        case create(OSStatus)
        public var errorDescription: String? {
            switch self { case let .create(s): return "Cannot create H.264 encoder (VideoToolbox status \(s))." }
        }
    }

    public let size: PixelSize
    public let frameRate: Int
    public private(set) var isHardwareAccelerated = false
    public var onFrame: ((EncodedFrame) -> Void)?
    public let encodedFrames = AtomicCounter()
    public let droppedFrames = AtomicCounter()

    private var session: VTCompressionSession?
    private let forceKeyframe = AtomicBool(true)

    public init(size: PixelSize, frameRate: Int, settings: VideoEncoderSettings) throws {
        self.size = size
        self.frameRate = frameRate
        let spec: [String: Any] = settings.preferHardware
            ? [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true] : [:]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(size.width), height: Int32(size.height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw EncoderError.create(st) }
        session = s

        let profile: CFString
        switch settings.profile {
        case .baseline: profile = kVTProfileLevel_H264_Baseline_AutoLevel
        case .main: profile = kVTProfileLevel_H264_Main_AutoLevel
        case .high: profile = kVTProfileLevel_H264_High_AutoLevel
        }
        let bps = settings.bitrateKbps * 1000
        let gop = max(1, Int(Double(frameRate) * settings.keyframeIntervalSeconds))
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, profile)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bps))
        // Cap bursts at 1.5x average over 1 s (CBR-like behaviour that RTMP ingest servers expect).
        set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: Double(bps) * 1.5 / 8), NSNumber(value: 1.0)] as CFArray)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: gop))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: settings.keyframeIntervalSeconds))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate))
        VTCompressionSessionPrepareToEncodeFrames(s)

        var hw: CFBoolean?
        if VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                 allocator: nil, valueOut: &hw) == noErr {
            isHardwareAccelerated = hw == kCFBooleanTrue
        }
        Log.stream.info("H.264 encoder \(size.width)x\(size.height)@\(frameRate) \(settings.bitrateKbps) kbps hw=\(self.isHardwareAccelerated)")
    }

    deinit { invalidate() }

    private func set(_ key: CFString, _ value: CFTypeRef) {
        guard let session else { return }
        let st = VTSessionSetProperty(session, key: key, value: value)
        if st != noErr { Log.stream.warning("VTSessionSetProperty \(key as String, privacy: .public) failed: \(st)") }
    }

    public func requestKeyframe() { forceKeyframe.value = true }

    /// Thread-safe; called from the render completion thread.
    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        var props: CFDictionary?
        if forceKeyframe.value {
            forceKeyframe.value = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                 duration: duration, frameProperties: props, infoFlagsOut: nil) { [weak self] status, flags, sample in
            guard let self else { return }
            if status != noErr || flags.contains(.frameDropped) { self.droppedFrames.add(); return }
            guard let sample, let frame = Self.extract(sample) else { return }
            self.encodedFrames.add()
            self.onFrame?(frame)
        }
        if st != noErr { droppedFrames.add() }
    }

    public func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    static func extract(_ sb: CMSampleBuffer) -> EncodedFrame? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb), let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var notSync = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        }
        func parameterSet(_ index: Int) -> ([UInt8], Int32)? {
            var ptr: UnsafePointer<UInt8>?
            var size = 0, count = 0
            var nalLen: Int32 = 0
            let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: index, parameterSetPointerOut: &ptr,
                                                                       parameterSetSizeOut: &size, parameterSetCountOut: &count,
                                                                       nalUnitHeaderLengthOut: &nalLen)
            guard st == noErr, let ptr else { return nil }
            return (Array(UnsafeBufferPointer(start: ptr, count: size)), nalLen)
        }
        guard let spsSet = parameterSet(0), let ppsSet = parameterSet(1) else { return nil }
        let sps = spsSet.0, nalLen = spsSet.1, pps = ppsSet.0
        let length = CMBlockBufferGetDataLength(block)
        var data = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data) == noErr else { return nil }
        if nalLen != 4, let nals = try? AVC.splitAVCC(data, lengthSize: Int(nalLen)) {
            data = AVC.avcc(from: nals)
        }
        return EncodedFrame(avcc: data, pts: CMSampleBufferGetPresentationTimeStamp(sb), keyframe: !notSync, sps: sps, pps: pps)
    }
}
#endif

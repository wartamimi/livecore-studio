// LiveCore Virtual Camera: a CoreMediaIO Camera Extension, built the same way as OBS's.
//
// The device has two streams. LiveCore Studio writes its output into the *sink* stream; the
// extension forwards each frame to the *source* stream that Zoom, Meet, OBS, QuickTime... read.
// While LiveCore Studio is not sending, the camera shows a black picture.
//
// macOS only loads a camera extension that is signed with an Apple Developer ID (and installed
// through an app in /Applications that has the system-extension entitlement). See
// docs/VIRTUAL_CAMERA.md.
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import VideoToolbox

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: VirtualCameraIdentity.deviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("LiveCore Virtual Camera: cannot add device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = VirtualCameraIdentity.manufacturer }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: StreamSource!
    private var sinkSource: SinkSource!

    private var formatDescription: CMVideoFormatDescription!
    private var pool: CVPixelBufferPool!
    private var transfer: VTPixelTransferSession?
    private let queue = DispatchQueue(label: "studio.livecore.vcam", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var streamingCount = 0
    private var sinkClient: CMIOExtensionClient?
    private var lastSinkFrame: UInt64 = 0
    private var tick = 0

    init(localizedName: String) {
        super.init()
        let deviceID = UUID(uuidString: VirtualCameraIdentity.deviceUUID)!
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

        let w = VirtualCameraIdentity.width, h = VirtualCameraIdentity.height
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: w, height: h, extensions: nil, formatDescriptionOut: &formatDescription)
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: Int(w),
            kCVPixelBufferHeightKey as String: Int(h),
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)

        let duration = CMTime(value: 1, timescale: VirtualCameraIdentity.frameRate)
        let format = CMIOExtensionStreamFormat(formatDescription: formatDescription, maxFrameDuration: duration,
                                               minFrameDuration: duration, validFrameDurations: nil)
        streamSource = StreamSource(localizedName: "LiveCore Video", streamID: UUID(uuidString: VirtualCameraIdentity.sourceStreamUUID)!,
                                    format: format, device: self, direction: .source)
        sinkSource = SinkSource(localizedName: "LiveCore Video Sink", streamID: UUID(uuidString: VirtualCameraIdentity.sinkStreamUUID)!,
                                format: format, device: self)
        do {
            try device.addStream(streamSource.stream)
            try device.addStream(sinkSource.stream)
        } catch {
            fatalError("LiveCore Virtual Camera: cannot add streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = VirtualCameraIdentity.deviceName }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Streaming

    /// An app opened the camera.
    func startStreaming() {
        queue.async {
            self.streamingCount += 1
            self.startTimerIfNeeded()
        }
    }

    func stopStreaming() {
        queue.async {
            self.streamingCount = max(0, self.streamingCount - 1)
            self.stopTimerIfIdle()
        }
    }

    /// LiveCore Studio started writing into the sink.
    func startSink(client: CMIOExtensionClient) {
        queue.async {
            self.sinkClient = client
            self.startTimerIfNeeded()
        }
    }

    func stopSink() {
        queue.async {
            self.sinkClient = nil
            self.stopTimerIfIdle()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        // Twice the camera rate: frames from the sink are forwarded as soon as they arrive.
        t.schedule(deadline: .now(), repeating: 1.0 / Double(VirtualCameraIdentity.frameRate * 2), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        timer = t
    }

    private func stopTimerIfIdle() {
        guard streamingCount == 0 && sinkClient == nil else { return }
        timer?.cancel()
        timer = nil
    }

    private func onTick() {
        tick += 1
        let now = mach_absolute_time()
        if let client = sinkClient {
            sinkSource.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, sequence, _, _, _ in
                guard let self, let sbuf else { return }
                self.queue.async { self.forward(sbuf, sequence: sequence) }
            }
        }
        // Black picture while LiveCore Studio is not sending (after half a second without frames).
        let idle = lastSinkFrame == 0 || Self.seconds(now - lastSinkFrame) > 0.5
        if streamingCount > 0 && idle && tick % 2 == 0, let pb = blackFrame() {
            send(pb)
        }
    }

    private func forward(_ sbuf: CMSampleBuffer, sequence: UInt64) {
        lastSinkFrame = mach_absolute_time()
        let hostNs = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
        sinkSource.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: hostNs))
        guard streamingCount > 0, let image = CMSampleBufferGetImageBuffer(sbuf) else { return }
        if CVPixelBufferGetWidth(image) == Int(VirtualCameraIdentity.width) && CVPixelBufferGetHeight(image) == Int(VirtualCameraIdentity.height)
            && CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA {
            send(image)
        } else if let scaled = scale(image) {
            send(scaled)
        }
    }

    private func send(_ pb: CVPixelBuffer) {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: VirtualCameraIdentity.frameRate),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
                                                 makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                                                 sampleTiming: &timing, sampleBufferOut: &sbuf) == noErr, let sbuf else { return }
        streamSource.stream.send(sbuf, discontinuity: [],
                                 hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
    }

    private func scale(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transfer, let out = newBuffer() else { return nil }
        return VTPixelTransferSessionTransferImage(transfer, from: image, to: out) == noErr ? out : nil
    }

    private func blackFrame() -> CVPixelBuffer? {
        guard let pb = newBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bytes = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
            // BGRA opaque black.
            let words = base.bindMemory(to: UInt32.self, capacity: bytes / 4)
            for i in 0..<(bytes / 4) { words[i] = 0xFF00_0000 }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private func newBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
        return CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux, &pb) == kCVReturnSuccess ? pb : nil
    }

    private static func seconds(_ machTicks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(machTicks) * Double(info.numer) / Double(info.denom) / 1e9
    }
}

/// The camera picture other apps read.
final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let deviceSource: DeviceSource

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource,
         direction: CMIOExtensionStream.Direction) {
        self.format = format
        self.deviceSource = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: direction,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: VirtualCameraIdentity.frameRate) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { deviceSource.startStreaming() }

    func stopStream() throws { deviceSource.stopStreaming() }
}

/// Where LiveCore Studio writes its output.
final class SinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let deviceSource: DeviceSource
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.deviceSource = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: VirtualCameraIdentity.frameRate) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client else { return }
        deviceSource.startSink(client: client)
    }

    func stopStream() throws { deviceSource.stopSink() }
}

#if os(macOS)
import CoreMediaIO
import CoreMedia
import CoreVideo
import Foundation
import LiveCoreCore
import SystemExtensions

/// Sends frames into the LiveCore Virtual Camera, the way OBS feeds its camera extension:
/// find the camera's *sink* stream through CoreMediaIO, start it and enqueue sample buffers.
/// `connect()`/`disconnect()` on the main thread; `send` from any thread.
public final class VirtualCameraSender {
    public enum State: Equatable {
        case off
        /// The extension is not installed or not running (not activated, or not signed).
        case notFound
        case running
        case failed(String)
    }

    public private(set) var state: State = .off
    private var deviceID = CMIODeviceID(0)
    private var streamID = CMIOStreamID(0)
    private let queue = Locked<CMSimpleQueue?>(nil)

    public init() {}

    public var isRunning: Bool { state == .running }

    /// True when the camera device is visible to apps (the extension is active).
    public static func isInstalled() -> Bool { findDevice() != nil }

    @discardableResult
    public func connect() -> State {
        disconnect()
        guard let device = Self.findDevice() else { state = .notFound; return state }
        let streams = Self.streams(of: device)
        // The sink is the stream LiveCore writes into (direction 1 = input to the device);
        // the extension adds it second, so fall back to the last stream.
        guard let sink = streams.first(where: { Self.direction(of: $0) == 1 }) ?? (streams.count > 1 ? streams.last : nil) else {
            state = .failed("The virtual camera has no input stream.")
            return state
        }
        var unmanaged: Unmanaged<CMSimpleQueue>?
        let proc: CMIODeviceStreamQueueAlteredProc = { _, _, _ in }
        var err = CMIOStreamCopyBufferQueue(sink, proc, nil, &unmanaged)
        guard err == noErr, let q = unmanaged?.takeRetainedValue() else {
            state = .failed("Cannot open the virtual camera (CoreMediaIO error \(err)).")
            return state
        }
        err = CMIODeviceStartStream(device, sink)
        guard err == noErr else {
            state = .failed("Cannot start the virtual camera (CoreMediaIO error \(err)).")
            return state
        }
        deviceID = device
        streamID = sink
        queue.mutate { $0 = q }
        state = .running
        return state
    }

    public func disconnect() {
        let had = queue.mutate { q -> Bool in let had = q != nil; q = nil; return had }
        if had { _ = CMIODeviceStopStream(deviceID, streamID) }
        deviceID = 0
        streamID = 0
        if state == .running { state = .off }
    }

    /// Enqueues one frame; dropped when the camera has not taken the previous one yet.
    public func send(_ pb: CVPixelBuffer, pts: CMTime) {
        guard let q = queue.current, CMSimpleQueueGetCount(q) < CMSimpleQueueGetCapacity(q) else { return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                           formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sbuf) == noErr, let sbuf else { return }
        let element = Unmanaged.passRetained(sbuf).toOpaque()
        if CMSimpleQueueEnqueue(q, element: element) != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
        }
    }

    // MARK: CoreMediaIO lookup

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objectIDs(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func direction(of stream: CMIOStreamID) -> UInt32? {
        var addr = address(kCMIOStreamPropertyDirection)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr else { return nil }
        return value
    }

    private static func streams(of device: CMIODeviceID) -> [CMIOStreamID] {
        objectIDs(device, kCMIODevicePropertyStreams)
    }

    private static func findDevice() -> CMIODeviceID? {
        let devices = objectIDs(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
        return devices.first { string($0, kCMIODevicePropertyDeviceUID) == VirtualCameraIdentity.deviceUUID }
            ?? devices.first { string($0, kCMIOObjectPropertyName) == VirtualCameraIdentity.deviceName }
    }
}

/// Activates / removes the camera extension through the System Extensions framework (the app
/// must be in /Applications and signed with a Developer ID that has the system-extension
/// entitlement; otherwise macOS refuses and `onResult` reports why). Main thread.
public final class VirtualCameraInstaller: NSObject, OSSystemExtensionRequestDelegate {
    public enum Outcome: Equatable {
        case activated
        case removed
        /// Waiting for the user to allow it in System Settings → General → Login Items & Extensions.
        case needsApproval
        case willCompleteAfterReboot
        case failed(Failure)
    }

    public enum Failure: Equatable {
        /// The app is not signed with the system-extension entitlement (the unsigned build).
        case notSigned
        /// The app must run from /Applications.
        case notInApplications
        case extensionMissing
        case signatureInvalid
        case cancelled
        case other(String)
    }

    public var onResult: ((Outcome) -> Void)?
    private var removing = false

    public func activate() {
        removing = false
        let r = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: VirtualCameraIdentity.extensionBundleID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    public func deactivate() {
        removing = true
        let r = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: VirtualCameraIdentity.extensionBundleID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                        withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onResult?(.needsApproval)
    }

    public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if result == .willCompleteAfterReboot { onResult?(.willCompleteAfterReboot); return }
        onResult?(removing ? .removed : .activated)
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        let failure: Failure
        if ns.domain == OSSystemExtensionErrorDomain, let code = OSSystemExtensionError.Code(rawValue: ns.code) {
            switch code {
            case .missingEntitlement, .unknownExtensionCategory: failure = .notSigned
            case .unsupportedParentBundleLocation: failure = .notInApplications
            case .extensionNotFound: failure = .extensionMissing
            case .codeSignatureInvalid, .validationFailed, .forbiddenBySystemPolicy: failure = .signatureInvalid
            case .requestCanceled, .requestSuperseded, .authorizationRequired: failure = .cancelled
            default: failure = .other(ns.localizedDescription)
            }
        } else {
            failure = .other(ns.localizedDescription)
        }
        onResult?(.failed(failure))
    }
}

#endif

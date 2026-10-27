#if os(macOS)
import AVFoundation
import Foundation

/// Discovers capture devices and permission state, and reports hot-plug changes.
///
/// Video: built-in cameras, USB/UVC cameras and UVC-class HDMI/SDI capture devices
///        (`.externalUnknown` on macOS 13, `.external` on macOS 14+). Continuity Camera and
///        Desk View devices are included on macOS 14+.
/// Audio: built-in microphones and every Core Audio input device exposed to AVFoundation
///        (USB interfaces, capture-card audio, virtual devices).
public final class DeviceManager {
    public struct Device: Identifiable, Hashable {
        public var id: String           // AVCaptureDevice.uniqueID (== Core Audio UID for audio)
        public var name: String
        public var model: String
        public var isConnected: Bool
    }

    public private(set) var videoDevices: [Device] = []
    public private(set) var audioDevices: [Device] = []
    public var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    public init() {
        refresh()
        let nc = NotificationCenter.default
        for name in [Notification.Name.AVCaptureDeviceWasConnected, .AVCaptureDeviceWasDisconnected] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                if let d = n.object as? AVCaptureDevice {
                    Log.devices.info("\(name.rawValue, privacy: .public): \(d.localizedName, privacy: .public)")
                }
                self?.refresh()
                self?.onChange?()
            })
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    public func refresh() {
        videoDevices = Self.discover(.video).map { Device(id: $0.uniqueID, name: $0.localizedName, model: $0.modelID, isConnected: $0.isConnected) }
        audioDevices = Self.discover(.audio).map { Device(id: $0.uniqueID, name: $0.localizedName, model: $0.modelID, isConnected: $0.isConnected) }
    }

    public static func discover(_ media: AVMediaType) -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType]
        if media == .video {
            types = [.builtInWideAngleCamera]
            if #available(macOS 14.0, *) { types += [.external, .continuityCamera, .deskViewCamera] } else { types += [.externalUnknown] }
        } else {
            if #available(macOS 14.0, *) { types = [.microphone, .external] } else { types = [.builtInMicrophone, .externalUnknown] }
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: media, position: .unspecified).devices
    }

    public static func device(uniqueID: String) -> AVCaptureDevice? { AVCaptureDevice(uniqueID: uniqueID) }

    // MARK: Permissions

    public enum Permission: Equatable { case notDetermined, authorized, denied, restricted }

    public static func permission(for media: AVMediaType) -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

    /// Requests access if needed; completion on main.
    public static func requestAccess(_ media: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: media) { ok in DispatchQueue.main.async { completion(ok) } }
        default: completion(false)
        }
    }
}
#endif

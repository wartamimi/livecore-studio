#if os(macOS)
import Foundation
import LiveCoreEngine

/// `MeetingBridge` on top of the Objective-C Zoom SDK wrapper. Registered at launch by
/// `LCZoomRegistrar.register()` only when the app was built with the SDK.
final class ZoomBridge: MeetingBridge {
    private let sdk = LCZoomSDK.shared()

    var onChange: (() -> Void)?
    var onVideoFrame: ((UInt32, I420Frame) -> Void)?
    var onMixedAudio: ((UnsafePointer<Int16>, Int, Int, Int) -> Void)?

    init() {
        sdk.onChange = { [weak self] in self?.onChange?() }
        sdk.onVideo = { [weak self] userID, w, h, y, u, v, ys, uvs, full in
            self?.onVideoFrame?(userID, I420Frame(width: Int(w), height: Int(h), y: y, u: u, v: v,
                                                  yStride: Int(ys), uvStride: Int(uvs), fullRange: full))
        }
        sdk.onMixedAudio = { [weak self] samples, frames, channels, rate in
            self?.onMixedAudio?(samples, Int(frames), Int(channels), Int(rate))
        }
    }

    var state: MeetingState {
        switch sdk.state {
        case .notAuthorized: return .notAuthorized
        case .authorizing: return .authorizing
        case .ready: return .ready
        case .joining: return .joining
        case .inMeeting:
            switch sdk.rawState {
            case .allowed: return .inMeeting(rawData: .allowed)
            case .requested: return .inMeeting(rawData: .requested)
            default: return .inMeeting(rawData: .notAllowed)
            }
        case .failed: return .failed(sdk.errorMessage)
        @unknown default: return .failed(sdk.errorMessage)
        }
    }

    var statusMessage: String { sdk.errorMessage }
    var participants: [MeetingParticipant] {
        sdk.participants.map { MeetingParticipant(id: $0.userID, name: $0.name, isHost: $0.isHost, videoOn: $0.videoOn, isMe: $0.isMe) }
    }
    var sdkVersion: String { sdk.version }

    func authorize(jwt: String) { sdk.authorize(withJWT: jwt) }
    func join(meetingNumber: Int64, passcode: String, displayName: String, sendVideo: Bool, sendAudio: Bool) {
        sdk.sendVideo = sendVideo
        sdk.sendAudio = sendAudio
        sdk.joinMeeting(meetingNumber, passcode: passcode, displayName: displayName)
    }
    func leave() { sdk.leave() }
    func requestRawDataPermission() { sdk.requestRawData() }
    func subscribe(userID: UInt32) { sdk.subscribeUser(userID) }
    func unsubscribe(userID: UInt32) { sdk.unsubscribeUser(userID) }

    var canSendVideo: Bool { sdk.canSendVideo }
    var canSendAudio: Bool { sdk.canSendAudio }
    func sendVideo(_ frame: I420Frame) {
        // The converter hands over one contiguous Y|U|V block starting at `y`.
        sdk.sendI420(frame.y, width: Int32(frame.width), height: Int32(frame.height))
    }
    func sendAudio(_ samples: UnsafePointer<Int16>, frames: Int) {
        sdk.sendAudio(samples, frames: Int32(frames))
    }
}

@objc(LCZoomRegistrar) final class LCZoomRegistrar: NSObject {
    @objc static func register() {
        guard LCZoomSDK.isAvailable() else { return }
        MeetingBridgeRegistry.make = { ZoomBridge() }
    }
}
#endif

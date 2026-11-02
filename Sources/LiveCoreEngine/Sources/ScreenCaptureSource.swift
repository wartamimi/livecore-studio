#if os(macOS)
import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import LiveCoreCore

/// Captures a window (Zoom, Teams, Meet, Keynote...) or a whole display with ScreenCaptureKit,
/// optionally with that app's audio (window) or the system audio (display) into a mixer
/// channel. Needs the Screen Recording permission (System Settings › Privacy & Security).
///
/// Frames arrive IOSurface-backed BGRA from the window server (no copy). The app's own audio
/// is excluded so the mixer output never loops back into itself.
public final class ScreenCaptureSource: NSObject, VideoSource, SCStreamOutput, SCStreamDelegate {
    public let id: InputID
    public let kind: InputKind = .screen
    public var name: String
    public private(set) var config: ProjectScreenCapture
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { let s = status; DispatchQueue.main.async { self.onStatusChange?(s) } } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    /// Called on the main thread before audio starts; must return the mixer channel to feed.
    public var audioChannelProvider: (() -> MixerChannel)?

    private var stream: SCStream?
    private let slot = FrameSlot()
    private let videoQueue = DispatchQueue(label: "livecore.screen.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "livecore.screen.audio", qos: .userInteractive)
    private var audioChannel: MixerChannel?
    private var stopped = false

    public init(id: InputID, config: ProjectScreenCapture) {
        self.id = id
        self.config = config
        self.name = config.displayName
        super.init()
    }

    // MARK: Listing

    /// Capturable windows and displays. Fails without the Screen Recording permission.
    public static func shareable(completion: @escaping (Result<(windows: [WindowCandidate], displays: [DisplayInfo]), Error>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let content else { return completion(.failure(error ?? NSError(domain: "LiveCore", code: 40))) }
                let windows = content.windows.compactMap { w -> WindowCandidate? in
                    guard let app = w.owningApplication, w.windowLayer == 0 else { return nil }
                    return WindowCandidate(windowID: w.windowID, bundleID: app.bundleIdentifier,
                                           appName: app.applicationName, title: w.title ?? "")
                }
                let main = CGMainDisplayID()
                let displays = content.displays.map {
                    DisplayInfo(id: $0.displayID, name: "Display \($0.displayID) (\($0.width)×\($0.height))", isMain: $0.displayID == main)
                }
                completion(.success((WindowMatcher.pickerList(windows, ownBundleID: Bundle.main.bundleIdentifier ?? ""), displays)))
            }
        }
    }

    // MARK: Lifecycle (main thread)

    public func start() {
        stopped = false
        status = .starting
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async { self?.begin(content: content, error: error) }
        }
    }

    public func stop() {
        stopped = true
        stream?.stopCapture { _ in }
        stream = nil
    }

    /// Changes what is captured (picked again from the menu) and restarts.
    public func reconfigure(_ c: ProjectScreenCapture) {
        config = c
        stop()
        start()
    }

    public func currentFrame() -> CVPixelBuffer? { slot.get() }

    private func begin(content: SCShareableContent?, error: Error?) {
        guard !stopped else { return }
        guard let content else {
            status = .error("Screen Recording permission needed: System Settings › Privacy & Security › Screen Recording (\(error?.localizedDescription ?? "denied"))")
            return
        }
        let filter: SCContentFilter
        var size = CGSize(width: 1920, height: 1080)
        var scale: CGFloat = 1
        switch config.target {
        case .window:
            let candidates = content.windows.compactMap { w -> WindowCandidate? in
                guard let app = w.owningApplication else { return nil }
                return WindowCandidate(windowID: w.windowID, bundleID: app.bundleIdentifier, appName: app.applicationName, title: w.title ?? "")
            }
            guard let match = WindowMatcher.find(config, in: candidates),
                  let window = content.windows.first(where: { $0.windowID == match.windowID }) else {
                status = .noSignal("\(config.appName) window not found (is the app open?)")
                return
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
            scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == config.displayID }) ?? content.displays.first else {
                status = .noSignal("display not found")
                return
            }
            // Never capture LiveCore itself on a display capture (no hall-of-mirrors).
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            size = CGSize(width: display.width, height: display.height)
            scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.backingScaleFactor ?? 1
        }
        let cfg = SCStreamConfiguration()
        // Native pixels, capped at 4K so a 5K display does not cost more than the output needs.
        let px = ScreenCaptureSource.fit(width: size.width * scale, height: size.height * scale, maxWidth: 3840, maxHeight: 2160)
        cfg.width = px.0
        cfg.height = px.1
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ProjectScreenCapture.clampFPS(config.fps)))
        cfg.queueDepth = 6
        cfg.showsCursor = config.showsCursor
        cfg.capturesAudio = config.captureAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2

        if config.captureAudio, audioChannel == nil, let provider = audioChannelProvider { audioChannel = provider() }

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            if config.captureAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        } catch {
            status = .error("Cannot start capture: \(error.localizedDescription)")
            return
        }
        stream = s
        s.startCapture { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.status = .error("Capture failed: \(error.localizedDescription)") }
        }
    }

    static func fit(width: CGFloat, height: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> (Int, Int) {
        let k = min(1, maxWidth / max(width, 1), maxHeight / max(height, 1))
        return (max(Int(width * k) & ~1, 2), max(Int(height * k) & ~1, 2))
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            // Only complete frames carry new pixels (idle/blank frames repeat the last one).
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            slot.put(pb)
            if status != .live { DispatchQueue.main.async { self.status = .live } }
        case .audio:
            writeAudio(sb)
        @unknown default:
            break
        }
    }

    private func writeAudio(_ sb: CMSampleBuffer) {
        guard let channel = audioChannel else { return }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return }
        try? sb.withAudioBufferList { abl, _ in
            guard let l = abl.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
            let r = abl.count > 1 ? (abl[1].mData?.assumingMemoryBound(to: Float.self) ?? l) : l
            channel.ringL.write(l, count: frames)
            channel.ringR.write(r, count: frames)
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard !self.stopped else { return }
            self.stream = nil
            self.status = .noSignal("capture stopped (\(error.localizedDescription)) – window closed?")
        }
    }
}
#endif

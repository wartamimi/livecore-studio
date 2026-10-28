#if os(macOS)
import AVFoundation
import CoreVideo
import CObjCSupport
import LiveCoreCore

/// USB/UVC cameras, built-in FaceTime cameras and HDMI/SDI capture devices that present
/// themselves to macOS as AVFoundation video devices (UVC capture dongles, Elgato Cam Link,
/// Blackmagic UltraStudio/Web Presenter in webcam mode, ...). Devices that require a vendor
/// SDK (e.g. Blackmagic DeckLink via the Desktop Video SDK) are NOT handled here — see
/// docs/CAPTURE_DEVICES.md.
public final class CameraSource: NSObject, VideoSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    public let id: InputID
    public let kind: InputKind = .camera
    public var name: String
    public let deviceUniqueID: String
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    public private(set) var activeFormatDescription: String = ""

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue: DispatchQueue
    private let slot = FrameSlot()
    private let target: OutputFormat
    /// Format and options chosen by the operator (automatic by default).
    public var config: CaptureConfig { configLock.withLock { _config } }
    private var _config: CaptureConfig
    private let configLock = UnfairLock()
    private var observers: [NSObjectProtocol] = []
    private let liveReported = AtomicBool(false)

    public init(id: InputID, device: AVCaptureDevice, target: OutputFormat, config: CaptureConfig = CaptureConfig()) {
        self.id = id
        self._config = config
        self.name = device.localizedName
        self.deviceUniqueID = device.uniqueID
        self.target = target
        self.queue = DispatchQueue(label: "livecore.camera.\(device.uniqueID)", qos: .userInteractive)
        super.init()
    }

    public func currentFrame() -> CVPixelBuffer? { slot.get() }

    public func start() {
        queue.async { [weak self] in self?.configureAndRun() }
    }

    /// Re-selects the format / mirroring with new settings while the input keeps running.
    public func apply(_ c: CaptureConfig) {
        configLock.withLock { _config = c }
        queue.async { [weak self] in
            guard let self, let device = AVCaptureDevice(uniqueID: self.deviceUniqueID) else { return }
            if (try? device.lockForConfiguration()) != nil {
                self.selectFormat(device, config: c)
                device.unlockForConfiguration()
            }
            self.applyMirror(c.mirror)
            self.output.alwaysDiscardsLateVideoFrames = c.bufferFrames != true
        }
    }

    /// Closes and reopens the device (capture cards that froze or lost the signal format).
    public func restartDevice() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.setStatus(.starting)
            self.configureAndRun()
        }
    }

    // MARK: Signal statistics (capture queue writes, any thread reads)

    /// What the device actually delivers: measured frames per second and frames dropped since
    /// the input started (late frames, or frames the app could not take in time).
    public struct SignalStats: Equatable, Sendable {
        public var fps: Double = 0
        public var dropped: Int = 0
        public var codec: String = ""
        public var size: String = ""
    }
    public var signalStats: SignalStats { statsLock.withLock { _stats } }
    private var _stats = SignalStats()
    private let statsLock = UnfairLock()
    private var windowStart: Double = 0
    private var windowFrames = 0

    /// Formats the device reports, for the capture settings sheet.
    public static func formats(of device: AVCaptureDevice) -> [CaptureFormatCandidate] {
        var out: [CaptureFormatCandidate] = []
        _ = lc_catch_objc_exception {
            out = device.formats.map { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return CaptureFormatCandidate(width: Int(d.width), height: Int(d.height),
                                              frameRateRanges: f.videoSupportedFrameRateRanges.map { min($0.minFrameRate, $0.maxFrameRate)...max($0.minFrameRate, $0.maxFrameRate) },
                                              codec: CaptureCodec.fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription)))
            }
        }
        return out
    }

    private func applyMirror(_ on: Bool) {
        guard let conn = output.connection(with: .video) else { return }
        _ = lc_catch_objc_exception {
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = on
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.observers.forEach { NotificationCenter.default.removeObserver($0) }
            self.observers.removeAll()
        }
    }

    private func setStatus(_ s: SourceStatus) {
        if s != .live { liveReported.value = false }
        DispatchQueue.main.async { [weak self] in self?.status = s }
    }

    private func configureAndRun() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            setStatus(.error("Camera permission not granted. Enable it in System Settings › Privacy & Security › Camera."))
            return
        }
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            setStatus(.noSignal("device not connected"))
            return
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw NSError(domain: "LiveCore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add device input"]) }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            setStatus(.error("Cannot open camera: \(error.localizedDescription)"))
            return
        }
        if session.outputs.isEmpty {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            output.alwaysDiscardsLateVideoFrames = config.bufferFrames != true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()
        let cfg = config
        // The format is set with the device locked and the lock is held across startRunning:
        // otherwise the session preset can replace it with its own choice on start (seen as a
        // USB 3 card opening in a compressed, USB 2 class mode after a restart).
        let locked: Bool
        do { try device.lockForConfiguration(); locked = true } catch {
            Log.devices.error("lockForConfiguration failed: \(error.localizedDescription, privacy: .public)")
            locked = false
        }
        if locked { selectFormat(device, config: cfg) }
        applyMirror(cfg.mirror)
        installObservers(device)
        session.startRunning()
        if locked { device.unlockForConfiguration() }
        if !session.isRunning { setStatus(.error("Capture session failed to start")) }
    }

    /// Uses the operator's format when one is set, otherwise the format closest to the program
    /// resolution that supports the program frame rate (`CaptureFormatPicker`).
    ///
    /// Robustness: capture-card drivers often report frame-rate ranges they do not accept
    /// (e.g. 29.97 vs 30, or legacy DAL plug-ins that reject any explicit duration). Durations are
    /// therefore taken from the range itself, and every setter runs inside an Objective-C
    /// exception guard: if the driver refuses, the device keeps its own default and is still used.
    /// The caller holds the device's configuration lock.
    private func selectFormat(_ device: AVCaptureDevice, config: CaptureConfig) {
        let fps = config.frameRate ?? Double(target.frameRate)
        let formats = device.formats
        let candidates = Self.formats(of: device)
        guard candidates.count == formats.count,
              let index = CaptureFormatPicker.pick(candidates, config: config, outputWidth: target.size.width,
                                                   outputHeight: target.size.height, outputFPS: Double(target.frameRate))
        else {
            Log.devices.info("camera \(self.name, privacy: .public): no formats reported, using device default")
            activeFormatDescription = "default"
            return
        }
        let best = (format: formats[index], range: Self.matchingRange(formats[index].videoSupportedFrameRateRanges, fps: fps))
        do {
            if let err = lc_catch_objc_exception({ device.activeFormat = best.format }) {
                Log.devices.error("camera \(self.name, privacy: .public): activeFormat rejected: \(err, privacy: .public)")
            } else if let range = best.range {
                let duration = Self.frameDuration(in: range, fps: fps)
                if let err = lc_catch_objc_exception({
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                }) {
                    Log.devices.error("camera \(self.name, privacy: .public): frame duration rejected, keeping driver default: \(err, privacy: .public)")
                }
            }
        }
        var desc = "default", codec = ""
        _ = lc_catch_objc_exception {
            let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            desc = "\(d.width)×\(d.height)"
            codec = CaptureCodec.fourCC(CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription))
        }
        statsLock.withLock { _stats.codec = codec; _stats.size = desc }
        activeFormatDescription = desc
        Log.devices.info("camera \(self.name, privacy: .public) format \(desc, privacy: .public)")
    }

    /// A range that can deliver `fps` (NTSC rates such as 29.97 count as 30).
    static func matchingRange(_ ranges: [AVFrameRateRange], fps: Double) -> AVFrameRateRange? {
        let tol = 0.1
        return ranges.first { $0.minFrameRate - tol <= fps && $0.maxFrameRate + tol >= fps }
    }

    /// A duration the range itself advertises: its fixed rate for single-rate ranges (exact NTSC
    /// timescales like 1001/30000), otherwise 1/fps clamped into the range.
    static func frameDuration(in range: AVFrameRateRange, fps: Double) -> CMTime {
        if abs(range.maxFrameRate - range.minFrameRate) < 0.001 { return range.minFrameDuration }
        let want = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        if CMTimeCompare(want, range.minFrameDuration) < 0 { return range.minFrameDuration }
        if CMTimeCompare(want, range.maxFrameDuration) > 0 { return range.maxFrameDuration }
        return want
    }

    private func installObservers(_ device: AVCaptureDevice) {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] n in
            let err = n.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.setStatus(.error(err?.localizedDescription ?? "capture runtime error"))
            // Attempt a restart; a transient error (e.g. device reset) often recovers.
            self?.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, AVCaptureDevice(uniqueID: self.deviceUniqueID) != nil else { return }
                self.session.startRunning()
            }
        })
        observers.append(nc.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil) { [weak self] _ in
            self?.setStatus(.noSignal("device disconnected"))
        })
        observers.append(nc.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil) { [weak self] n in
            guard let self, let dev = n.object as? AVCaptureDevice, dev.uniqueID == self.deviceUniqueID else { return }
            Log.devices.info("camera reconnected: \(dev.localizedName, privacy: .public)")
            self.setStatus(.starting)
            self.queue.async { [weak self] in
                guard let self else { return }
                self.observers.forEach { nc.removeObserver($0) }
                self.observers.removeAll()
                if self.session.isRunning { self.session.stopRunning() }
                self.configureAndRun()
            }
        })
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate (capture queue)

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        slot.put(pb)
        if !liveReported.value { liveReported.value = true; setStatus(.live) }
        // Measured frame rate over ~1 s windows.
        let now = HostClock.now()
        windowFrames += 1
        if windowStart == 0 { windowStart = now }
        let span = now - windowStart
        if span >= 1 {
            let fps = Double(windowFrames - 1) / span
            statsLock.withLock { _stats.fps = max(fps, 0) }
            windowStart = now; windowFrames = 1
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Late frames are dropped by design (alwaysDiscardsLateVideoFrames); counted for the
        // signal info in the capture settings.
        statsLock.withLock { _stats.dropped += 1 }
    }
}
#endif

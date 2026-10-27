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
    private var observers: [NSObjectProtocol] = []
    private let liveReported = AtomicBool(false)

    public init(id: InputID, device: AVCaptureDevice, target: OutputFormat) {
        self.id = id
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
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()
        selectFormat(device)
        installObservers(device)
        session.startRunning()
        if !session.isRunning { setStatus(.error("Capture session failed to start")) }
    }

    /// Chooses the device format closest to the program resolution that supports the program
    /// frame rate (so the camera does not deliver more pixels than we need).
    ///
    /// Robustness: capture-card drivers often report frame-rate ranges they do not accept
    /// (e.g. 29.97 vs 30, or legacy DAL plug-ins that reject any explicit duration). Durations are
    /// therefore taken from the range itself, and every setter runs inside an Objective-C
    /// exception guard: if the driver refuses, the device keeps its own default and is still used.
    private func selectFormat(_ device: AVCaptureDevice) {
        let want = target.size
        let fps = Double(target.frameRate)
        var best: (format: AVCaptureDevice.Format, range: AVFrameRateRange?)?
        var bestScore = Double.greatestFiniteMagnitude
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width > 0, d.height > 0 else { continue }
            let range = Self.matchingRange(f.videoSupportedFrameRateRanges, fps: fps)
            let pixels = Double(d.width) * Double(d.height)
            let wantPixels = Double(want.width * want.height)
            // Prefer a matching frame rate, then >= target size (downscale beats upscale), then closest.
            var score = pixels >= wantPixels ? pixels - wantPixels : (wantPixels - pixels) * 4
            if range == nil { score += 1e12 }
            if score < bestScore { bestScore = score; best = (f, range) }
        }
        guard let best else {
            Log.devices.info("camera \(self.name, privacy: .public): no formats reported, using device default")
            activeFormatDescription = "default"
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
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
        } catch {
            Log.devices.error("lockForConfiguration failed: \(error.localizedDescription, privacy: .public)")
        }
        var desc = "default"
        _ = lc_catch_objc_exception {
            let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            desc = "\(d.width)×\(d.height)"
        }
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
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Late frames are dropped by design (alwaysDiscardsLateVideoFrames).
    }
}
#endif

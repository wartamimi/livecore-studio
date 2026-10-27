#if os(macOS)
import AVFoundation
import CoreVideo
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
    private func selectFormat(_ device: AVCaptureDevice) {
        let want = target.size
        let fps = Double(target.frameRate)
        var best: AVCaptureDevice.Format?
        var bestScore = Double.greatestFiniteMagnitude
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard f.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps + 0.01 && $0.maxFrameRate >= fps - 0.01 }) else { continue }
            let pixels = Double(d.width) * Double(d.height)
            let wantPixels = Double(want.width * want.height)
            // Prefer >= target (downscale is better than upscale), then closest.
            let score = pixels >= wantPixels ? pixels - wantPixels : (wantPixels - pixels) * 4
            if score < bestScore { bestScore = score; best = f }
        }
        do {
            try device.lockForConfiguration()
            if let best {
                device.activeFormat = best
                let duration = CMTime(value: 1, timescale: CMTimeScale(target.frameRate))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            Log.devices.error("lockForConfiguration failed: \(error.localizedDescription, privacy: .public)")
        }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        activeFormatDescription = "\(d.width)×\(d.height)"
        Log.devices.info("camera \(self.name, privacy: .public) format \(self.activeFormatDescription, privacy: .public)")
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

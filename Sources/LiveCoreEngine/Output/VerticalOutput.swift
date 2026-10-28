#if os(macOS)
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import LiveCoreCore
import Metal
import Vision

/// Portrait 9:16 output (0.42.0): crops each Program frame around the people in it (Vision face
/// detection, with upper bodies as fallback) and scales it to the vertical size on the GPU. The
/// crop glides toward the subject (`CropFollower`) instead of jumping. Frames go to the sinks
/// (vertical stream encoder, vertical recorder) and to the monitor.
public final class VerticalOutput {
    public struct Sinks {
        var encoder: H264Encoder?
        var recorder: RecordingEngine?
        var monitor = false
    }
    let sinks = Locked(Sinks())
    private let config = Locked(VerticalSettings())
    private let follower = Locked(CropFollower())
    private let queue = DispatchQueue(label: "livecore.vertical", qos: .userInitiated)
    private let detectQueue = DispatchQueue(label: "livecore.vertical-detect", qos: .utility)
    private let inFlight = Locked(0)
    private let detecting = Locked(false)
    private var frameIndex = 0
    private var lastFaceTime = 0.0
    private let ci: CIContext
    private var pool: CVPixelBufferPool?
    private var poolSize = PixelSize(width: 0, height: 0)
    private let latest = Locked<CVPixelBuffer?>(nil)

    public init() {
        if let dev = MTLCreateSystemDefaultDevice() {
            ci = CIContext(mtlDevice: dev, options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
        } else {
            ci = CIContext(options: [.workingColorSpace: NSNull()])
        }
    }

    public var settings: VerticalSettings {
        get { config.current }
        set { config.mutate { $0 = newValue } }
    }

    /// True while anything uses the vertical picture (frames are only made then).
    public var isActive: Bool { sinks.read { $0.encoder != nil || $0.recorder != nil || $0.monitor } }
    public func setMonitor(_ on: Bool) { sinks.mutate { $0.monitor = on } }
    public func latestFrame() -> CVPixelBuffer? { latest.current }
    /// Where the crop is (0 = left edge of Program, 1 = right), for the monitor.
    public var cropCenter: Double { follower.read { $0.x } }

    /// Called for every Program frame (render callback); returns at once.
    func process(_ program: CVPixelBuffer, pts: CMTime) {
        guard inFlight.mutate({ n -> Bool in if n >= 2 { return false }; n += 1; return true }) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.inFlight.mutate { $0 -= 1 } }
            self.make(program, pts: pts)
        }
    }

    private func make(_ program: CVPixelBuffer, pts: CMTime) {
        let s = config.current
        let src = PixelSize(width: CVPixelBufferGetWidth(program), height: CVPixelBufferGetHeight(program))
        frameIndex += 1
        switch s.follow {
        case .faces:
            // About 6 detections a second, off this queue; the crop keeps gliding in between.
            if frameIndex % 5 == 0, detecting.mutate({ d -> Bool in if d { return false }; d = true; return true }) {
                detectQueue.async { [weak self] in self?.detect(program, pts: pts.seconds) }
            }
        case .center:
            follower.mutate { $0.aim(at: 0.5) }
        case .manual:
            follower.mutate { $0.aim(at: s.manualX) }
        }
        let x = follower.mutate { $0.step(smoothing: s.follow == .faces ? s.smoothing : 0.25) }
        let out = s.size
        let aspect = Double(out.width) / Double(max(out.height, 1))
        let r = VerticalCrop.rect(source: src, aspect: aspect, centerX: x)
        // CoreImage is y-up.
        let crop = CGRect(x: r.x, y: Double(src.height) - r.y - r.height, width: r.width, height: r.height)
        let sx = Double(out.width) / r.width, sy = Double(out.height) / r.height
        let img = CIImage(cvPixelBuffer: program).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        guard let pb = buffer(out) else { return }
        ci.render(img, to: pb, bounds: CGRect(x: 0, y: 0, width: out.width, height: out.height), colorSpace: nil)
        latest.mutate { $0 = pb }
        let k = sinks.current
        k.encoder?.encode(pb, pts: pts)
        k.recorder?.append(video: pb, pts: pts)
    }

    private func detect(_ program: CVPixelBuffer, pts: Double) {
        defer { detecting.mutate { $0 = false } }
        let faces = VNDetectFaceRectanglesRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        let h = VNImageRequestHandler(cvPixelBuffer: program, options: [:])
        try? h.perform([faces])
        var boxes = (faces.results ?? []).map { ($0.boundingBox.midX, $0.boundingBox.width) }
        if boxes.isEmpty {
            try? h.perform([bodies])
            boxes = (bodies.results ?? []).map { ($0.boundingBox.midX, $0.boundingBox.width * 0.5) }
        }
        if let t = VerticalCrop.target(faces: boxes.map { (x: Double($0.0), width: Double($0.1)) }) {
            lastFaceTime = pts
            follower.mutate { $0.aim(at: t) }
        } else if pts - lastFaceTime > 4 {
            // Nobody for a while: drift back to the middle.
            follower.mutate { $0.aim(at: 0.5) }
        }
    }

    private func buffer(_ size: PixelSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, PixelBufferFactory.attributes(width: size.width, height: size.height) as CFDictionary, &p)
            pool = p; poolSize = size
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}
#endif

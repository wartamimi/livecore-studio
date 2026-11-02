#if os(macOS)
import CoreImage
import CoreVideo
import Foundation
import LiveCoreCore
import Metal
import Vision

public enum AISupport {
    /// Apple Silicon (Neural Engine). Intel Macs keep the AI effects off so the frame rate holds.
    public static let isAvailable: Bool = {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }()
}

/// Background removal and auto-framing for one input (0.43.0). Frames are processed on their
/// own queue; the render loop gets the latest result at once (one frame of delay) and never
/// waits. When the Mac falls behind, frames are skipped here, not on Program.
final class AIProcessor {
    private let queue: DispatchQueue
    private let busy = Locked(false)
    private let latest = Locked<CVPixelBuffer?>(nil)
    private let config: Locked<InputAI>
    private var fx = CropFollower(x: 0.5, deadZone: 0.03), fy = CropFollower(x: 0.5, deadZone: 0.03)
    private var frameIndex = 0
    private var pool: CVPixelBufferPool?
    private var poolSize = PixelSize(width: 0, height: 0)
    private static let ci: CIContext = {
        if let d = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: d, options: [.cacheIntermediates: false]) }
        return CIContext()
    }()
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    init(id: InputID, settings: InputAI) {
        queue = DispatchQueue(label: "livecore.ai.\(id)", qos: .userInitiated)
        config = Locked(settings)
    }

    var settings: InputAI {
        get { config.current }
        set { config.mutate { $0 = newValue } }
    }

    /// Hands a camera frame over and returns the newest processed frame (or this one until the
    /// first is ready).
    func process(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        if busy.mutate({ b -> Bool in if b { return false }; b = true; return true }) {
            queue.async { [weak self] in
                guard let self else { return }
                let out = self.work(pb)
                self.latest.mutate { $0 = out }
                self.busy.mutate { $0 = false }
            }
        }
        return latest.current ?? pb
    }

    private func work(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        let s = config.current
        let size = PixelSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        let W = Double(size.width), H = Double(size.height)
        frameIndex += 1
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        if s.autoFrame, frameIndex % 4 == 1 {
            let faces = VNDetectFaceRectanglesRequest()
            try? handler.perform([faces])
            // Vision is y-up; AutoFrame works top-left.
            let list = (faces.results ?? []).map { (x: Double($0.boundingBox.midX), y: 1 - Double($0.boundingBox.midY),
                                                    height: Double($0.boundingBox.height)) }
            if let t = AutoFrame.target(faces: list, zoom: s.zoom) { fx.aim(at: t.x); fy.aim(at: t.y) }
        }
        var img = CIImage(cvPixelBuffer: pb)
        var mask: CIImage?
        if s.removeBackground {
            try? handler.perform([segmentation])
            if let m = segmentation.results?.first?.pixelBuffer {
                let mi = CIImage(cvPixelBuffer: m)
                mask = mi.transformed(by: CGAffineTransform(scaleX: W / mi.extent.width, y: H / mi.extent.height))
            }
        }
        if let mask {
            img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                     kCIInputMaskImageKey: mask])
        }
        if s.autoFrame {
            let x = fx.step(smoothing: 0.08), y = fy.step(smoothing: 0.08)
            let r = AutoFrame.rect(source: size, zoom: s.zoom, cx: x, cy: y)
            let crop = CGRect(x: r.x, y: H - r.y - r.height, width: r.width, height: r.height)   // CI is y-up
            img = img.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: W / r.width, y: H / r.height))
        }
        guard let out = buffer(size) else { return nil }
        Self.ci.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: W, height: H), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return out
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
        // Transparent where the background was removed.
        if let pb {
            CVPixelBufferLockBaseAddress(pb, [])
            memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
        }
        return pb
    }
}
#endif

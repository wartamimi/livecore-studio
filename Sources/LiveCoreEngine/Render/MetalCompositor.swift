#if os(macOS)
import CoreVideo
import Foundation
import Metal
import LiveCoreCore

/// GPU compositor. Turns a `FramePlan` into:
///   * the Program frame (output resolution) -> encoders + Program monitor
///   * the Preview frame (half resolution)   -> Preview monitor
///   * input thumbnails (low rate)           -> Input panel
///
/// Pixel format policy: everything is 8-bit BGRA (premultiplied alpha), IOSurface-backed.
/// Camera frames arrive as BGRA from AVCaptureVideoDataOutput (converted in the capture
/// hardware path), are wrapped as MTLTextures with CVMetalTextureCache (no CPU copy), and the
/// program output buffer is handed to VideoToolbox / AVAssetWriter without copies.
public final class MetalCompositor {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let layerPipeline: MTLRenderPipelineState
    private let layerPipelineOpaque: MTLRenderPipelineState
    private let transitionPipeline: MTLRenderPipelineState
    private let keyPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var intermediateA: MTLTexture?
    private var intermediateB: MTLTexture?
    private var programPool: CVPixelBufferPool?
    private var previewPool: CVPixelBufferPool?
    private var thumbPool: CVPixelBufferPool?
    public private(set) var outputSize: PixelSize
    public var previewSize: PixelSize { LayoutMath.evenSize(PixelSize(width: outputSize.width / 2, height: outputSize.height / 2)) }
    /// Input thumbnails, also used by the Multiview window (large enough for a 4-column grid).
    public static let thumbnailSize = PixelSize(width: 384, height: 216)

    public enum CompositorError: Error, LocalizedError {
        case noMetalDevice, pipeline(String)
        public var errorDescription: String? {
            switch self {
            case .noMetalDevice: return "No Metal-capable GPU found."
            case let .pipeline(s): return "Metal pipeline error: \(s)"
            }
        }
    }

    public init(outputSize: PixelSize) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CompositorError.noMetalDevice
        }
        self.device = device
        self.queue = queue
        self.outputSize = outputSize
        do {
            let lib = try device.makeLibrary(source: ShaderSource.code, options: nil)
            func pipeline(_ fragment: String, blend: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: "quad_vertex")
                d.fragmentFunction = lib.makeFunction(name: fragment)
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                if blend {
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
                    c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            layerPipeline = try pipeline("layer_fragment", blend: true)
            layerPipelineOpaque = try pipeline("layer_fragment", blend: false)
            transitionPipeline = try pipeline("transition_fragment", blend: false)
            keyPipeline = try pipeline("key_fragment", blend: true)
        } catch {
            throw CompositorError.pipeline(error.localizedDescription)
        }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        configure(outputSize: outputSize)
    }

    /// Changing resolution re-creates pools; only allowed while no output is running.
    public func configure(outputSize: PixelSize) {
        self.outputSize = outputSize
        programPool = PixelBufferFactory.makePool(width: outputSize.width, height: outputSize.height, minimumCount: 6)
        previewPool = PixelBufferFactory.makePool(width: previewSize.width, height: previewSize.height, minimumCount: 4)
        thumbPool = PixelBufferFactory.makePool(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height, minimumCount: 24)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: outputSize.width,
                                                          height: outputSize.height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        intermediateA = device.makeTexture(descriptor: td)
        intermediateB = device.makeTexture(descriptor: td)
    }

    public struct Result {
        public var program: CVPixelBuffer?
        public var preview: CVPixelBuffer?
        public var thumbnails: [InputID: CVPixelBuffer]
        public var gpuMs: Double
    }

    /// Encodes one frame. `frames` maps input IDs to their current CVPixelBuffer (missing = black).
    /// `completion` runs on a Metal completion thread once the GPU finished; the returned buffers
    /// are safe to read/encode from then on.
    /// `keys` holds the enabled chroma keys, so thumbnails show the keyed picture too.
    public func render(plan: FramePlan, frames: [InputID: CVPixelBuffer], thumbnailsFor: [InputID],
                       keys: [InputID: ChromaKey] = [:],
                       completion: @escaping (Result) -> Void) -> Bool {
        guard let cb = queue.makeCommandBuffer(), let programPool, let previewPool,
              let programPB = makeBuffer(programPool), let previewPB = makeBuffer(previewPool),
              let programTex = texture(for: programPB), let previewTex = texture(for: previewPB)
        else { return false }
        var keepAlive: [CVMetalTexture] = [programTex.cv, previewTex.cv]
        var textures: [InputID: (MTLTexture, PixelSize)] = [:]
        for (id, pb) in frames {
            if let t = texture(for: pb) {
                keepAlive.append(t.cv)
                textures[id] = (t.tex, PixelSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
            }
        }

        // Program (with optional transition) + overlays.
        if let t = plan.transition, t.kind != .cut, let a = intermediateA, let b = intermediateB {
            drawComposition(cb, target: a, size: outputSize, layers: plan.program, textures: textures, load: .clear)
            drawComposition(cb, target: b, size: outputSize, layers: t.incoming, textures: textures, load: .clear)
            let rp = passDescriptor(programTex.tex, load: .dontCare)
            if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
                enc.setRenderPipelineState(transitionPipeline)
                var verts = quad(dest: PixelRect(x: 0, y: 0, width: Double(outputSize.width), height: Double(outputSize.height)),
                                 uv: (0, 0, 1, 1), canvas: outputSize)
                enc.setVertexBytes(&verts, length: MemoryLayout<Float>.stride * verts.count, index: 0)
                var params = TransitionParamsGPU(progress: Float(t.progress), kind: Int32(t.kind.rawValue))
                enc.setFragmentBytes(&params, length: MemoryLayout<TransitionParamsGPU>.stride, index: 0)
                enc.setFragmentTexture(a, index: 0)
                enc.setFragmentTexture(b, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
            drawComposition(cb, target: programTex.tex, size: outputSize, layers: plan.overlays, textures: textures, load: .load)
        } else {
            drawComposition(cb, target: programTex.tex, size: outputSize, layers: plan.program + plan.overlays,
                            textures: textures, load: .clear)
        }
        drawComposition(cb, target: previewTex.tex, size: previewSize, layers: plan.preview, textures: textures, load: .clear)

        // Thumbnails (caller decides the rate).
        var thumbs: [InputID: CVPixelBuffer] = [:]
        if let thumbPool {
            for id in thumbnailsFor {
                guard textures[id] != nil, let pb = makeBuffer(thumbPool, threshold: 96), let t = texture(for: pb) else { continue }
                keepAlive.append(t.cv)
                drawComposition(cb, target: t.tex, size: Self.thumbnailSize,
                                layers: [DrawCommand(source: id, rect: .full, scaleMode: .fit, opacity: 1, key: keys[id])],
                                textures: textures, load: .clear)
                thumbs[id] = pb
            }
        }

        cb.addCompletedHandler { buffer in
            _ = keepAlive // CVMetalTextures must outlive GPU use
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            let ok = buffer.status == .completed
            completion(Result(program: ok ? programPB : nil, preview: ok ? previewPB : nil, thumbnails: ok ? thumbs : [:], gpuMs: gpuMs))
        }
        cb.commit()
        return true
    }

    // MARK: Helpers

    private struct TransitionParamsGPU { var progress: Float; var kind: Int32 }
    /// Matches `KeyParams` in the shader (float2 members are 8-byte aligned: 4 floats, then 2 + 2).
    private struct KeyParamsGPU {
        var opacity: Float, similarity: Float, smoothness: Float, spill: Float
        var keyCb: Float, keyCr: Float, pad0: Float = 0, pad1: Float = 0
    }

    private func drawComposition(_ cb: MTLCommandBuffer, target: MTLTexture, size: PixelSize, layers: [DrawCommand],
                                 textures: [InputID: (MTLTexture, PixelSize)], load: MTLLoadAction) {
        let rp = passDescriptor(target, load: load)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        let canvas = PixelRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
        for (i, layer) in layers.enumerated() {
            guard let entry = textures[layer.source], layer.opacity > 0.001 else { continue }
            let (tex, srcSize) = entry
            let box = LayoutMath.toPixels(layer.rect, canvas: size)
            let placed = LayoutMath.place(source: srcSize, in: box, mode: layer.scaleMode)
            // Clip to the layer box (crop for .fill) and to the canvas; derive matching UVs.
            guard let clipBox = LayoutMath.intersect(placed, box), let dest = LayoutMath.intersect(clipBox, canvas) else { continue }
            let u0 = (dest.x - placed.x) / placed.width, v0 = (dest.y - placed.y) / placed.height
            let u1 = (dest.x + dest.width - placed.x) / placed.width, v1 = (dest.y + dest.height - placed.y) / placed.height
            // The first layer drawn onto a cleared (opaque black) target is a plain copy when it is
            // fully opaque content; everything else uses premultiplied "over" blending.
            let opaqueCopy = i == 0 && load == .clear && layer.opacity >= 0.999 && layer.rect == .full
                && layer.scaleMode != .fit && layer.key == nil
            var verts = quad(dest: dest, uv: (Float(u0), Float(v0), Float(u1), Float(v1)), canvas: size)
            enc.setVertexBytes(&verts, length: MemoryLayout<Float>.stride * verts.count, index: 0)
            if let key = layer.key {
                enc.setRenderPipelineState(keyPipeline)
                let kc = ChromaKey.chroma(r: key.keyColor.r, g: key.keyColor.g, b: key.keyColor.b)
                var params = KeyParamsGPU(opacity: Float(layer.opacity), similarity: Float(key.similarity),
                                          smoothness: Float(key.smoothness), spill: Float(key.spill),
                                          keyCb: Float(kc.cb), keyCr: Float(kc.cr))
                enc.setFragmentBytes(&params, length: MemoryLayout<KeyParamsGPU>.stride, index: 0)
            } else {
                enc.setRenderPipelineState(opaqueCopy ? layerPipelineOpaque : layerPipeline)
                var opacity = Float(layer.opacity)
                enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
            }
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
    }

    private func passDescriptor(_ tex: MTLTexture, load: MTLLoadAction) -> MTLRenderPassDescriptor {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = load
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        return rp
    }

    /// Triangle strip: TL, BL, TR, BR as (x, y, u, v) in NDC.
    private func quad(dest r: PixelRect, uv: (Float, Float, Float, Float), canvas: PixelSize) -> [Float] {
        let w = Double(canvas.width), h = Double(canvas.height)
        let x0 = Float(r.x / w * 2 - 1), x1 = Float((r.x + r.width) / w * 2 - 1)
        let y0 = Float(1 - r.y / h * 2), y1 = Float(1 - (r.y + r.height) / h * 2)
        return [x0, y0, uv.0, uv.1,
                x0, y1, uv.0, uv.3,
                x1, y0, uv.2, uv.1,
                x1, y1, uv.2, uv.3]
    }

    private func makeBuffer(_ pool: CVPixelBufferPool, threshold: Int = 12) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        // Threshold bounds pool growth: if the consumers hold too many buffers we drop a frame
        // instead of allocating without limit. Thumbnails need more (several per input in flight).
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: threshold] as CFDictionary
        let st = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux, &pb)
        return st == kCVReturnSuccess ? pb : nil
    }

    private func texture(for pb: CVPixelBuffer) -> (tex: MTLTexture, cv: CVMetalTexture)? {
        guard let cache = textureCache, CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        var cvTex: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm,
                                                           CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cvTex)
        guard st == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (tex, cvTex)
    }

    /// Periodically flush stale cache entries (call ~1 Hz).
    public func flushCache() { if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) } }
}
#endif

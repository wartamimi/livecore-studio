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
    private let straightPipeline: MTLRenderPipelineState
    private let styledPipeline: MTLRenderPipelineState
    private let adjustPipeline: MTLRenderPipelineState
    /// Corrected copies of adjusted inputs (render queue only), reused frame to frame.
    private var adjustTextures: [InputID: MTLTexture] = [:]
    private let quadVertex: MTLFunction
    /// User shader for `TransitionKind.custom`; swapped from the main thread, read on the render queue.
    private let customLock = NSLock()
    private var customPipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var intermediateA: MTLTexture?
    private var intermediateB: MTLTexture?
    private var programPool: CVPixelBufferPool?
    private var previewPool: CVPixelBufferPool?
    private var thumbPool: CVPixelBufferPool?
    private var detailPool: CVPixelBufferPool?
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
            guard let vertex = lib.makeFunction(name: "quad_vertex") else { throw CompositorError.pipeline("quad_vertex missing") }
            quadVertex = vertex
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
            straightPipeline = try pipeline("straight_fragment", blend: true)
            styledPipeline = try pipeline("styled_fragment", blend: true)
            adjustPipeline = try pipeline("adjust_fragment", blend: false)
        } catch {
            throw CompositorError.pipeline(error.localizedDescription)
        }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        configure(outputSize: outputSize)
    }

    /// Compiles a user transition (`CustomTransitionSource`) and makes it the one `.custom` uses.
    /// Returns the compiler's message on failure (nothing is changed then).
    /// Compiling takes a few hundred milliseconds: call it off the render queue.
    public func loadCustomTransition(code: String) -> String? {
        if let problem = CustomTransitionSource.validate(code) { return Self.describe(problem) }
        do {
            let lib = try device.makeLibrary(source: CustomTransitionSource.wrap(code), options: nil)
            guard let fn = lib.makeFunction(name: CustomTransitionSource.entryPoint) else { return "Entry point missing." }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = quadVertex
            d.fragmentFunction = fn
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            let state = try device.makeRenderPipelineState(descriptor: d)
            customLock.lock(); customPipeline = state; customLock.unlock()
            return nil
        } catch {
            // Keep only the user's lines of the compiler output; they are numbered like the user's file.
            let text = (error as NSError).localizedDescription
            let lines = text.split(separator: "\n").filter { $0.contains("transition:") && $0.contains("error") }
            return lines.isEmpty ? text : lines.prefix(5).joined(separator: "\n")
        }
    }

    public func clearCustomTransition() {
        customLock.lock(); customPipeline = nil; customLock.unlock()
    }

    private func currentCustomPipeline() -> MTLRenderPipelineState? {
        customLock.lock(); defer { customLock.unlock() }
        return customPipeline
    }

    static func describe(_ p: CustomTransitionSource.Problem) -> String {
        switch p {
        case .empty: return "The shader file is empty."
        case .tooLarge: return "The shader file is larger than 64 KB."
        case .missingFunction: return "The file must define: float4 transition(float2 uv, float progress, float ratio, texture2d<float> from, texture2d<float> to, sampler s)."
        case let .forbidden(w): return "\"\(w)\" is not allowed in a transition shader."
        }
    }

    /// Changing resolution re-creates pools; only allowed while no output is running.
    public func configure(outputSize: PixelSize) {
        self.outputSize = outputSize
        programPool = PixelBufferFactory.makePool(width: outputSize.width, height: outputSize.height, minimumCount: 6)
        previewPool = PixelBufferFactory.makePool(width: previewSize.width, height: previewSize.height, minimumCount: 4)
        thumbPool = PixelBufferFactory.makePool(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height, minimumCount: 24)
        detailPool = PixelBufferFactory.makePool(width: outputSize.width, height: outputSize.height, minimumCount: 3)
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
        /// Full-size picture of `FramePlan.detail` (transparent background), nil when not requested.
        public var detail: CVPixelBuffer? = nil
        public var gpuMs: Double
    }

    /// Encodes one frame. `frames` maps input IDs to their current CVPixelBuffer (missing = black).
    /// `completion` runs on a Metal completion thread once the GPU finished; the returned buffers
    /// are safe to read/encode from then on.
    /// `keys` holds the enabled chroma keys, so thumbnails show the keyed picture too.
    public func render(plan: FramePlan, frames: [InputID: CVPixelBuffer],
                       adjusts: [InputID: InputAdjust] = [:],
                       completion: @escaping (Result) -> Void) -> Bool {
        guard let cb = queue.makeCommandBuffer(), let programPool, let previewPool,
              let programPB = makeBuffer(programPool), let previewPB = makeBuffer(previewPool),
              let programTex = texture(for: programPB), let previewTex = texture(for: previewPB)
        else { return false }
        var keepAlive: [CVMetalTexture] = [programTex.cv, previewTex.cv]
        var textures: [InputID: (MTLTexture, PixelSize)] = [:]
        var straightSources = Set<InputID>()
        for (id, pb) in frames {
            if let t = texture(for: pb) {
                keepAlive.append(t.cv)
                textures[id] = (t.tex, PixelSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
                // Clips with an alpha channel (ProRes 4444, HEVC with alpha) are tagged as straight
                // alpha by VideoFileSource; they are premultiplied while drawing.
                if Self.isTaggedStraight(pb) { straightSources.insert(id) }
            }
        }

        // Colour correction / flips: each adjusted input is drawn once into its own texture, which
        // then replaces the input everywhere in this frame (premultiplied from here on).
        for (id, adj) in adjusts where !adj.isIdentity {
            guard let entry = textures[id], let dst = adjustTexture(id, size: entry.1) else { continue }
            let (src, size) = entry
            let rp = passDescriptor(dst, load: .dontCare)
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { continue }
            let a = adj.clamped
            let u0: Float = a.flipHorizontal ? 1 : 0, u1: Float = a.flipHorizontal ? 0 : 1
            let v0: Float = a.flipVertical ? 1 : 0, v1: Float = a.flipVertical ? 0 : 1
            var verts = quad(dest: PixelRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height)),
                             uv: (u0, v0, u1, v1), canvas: size)
            enc.setRenderPipelineState(adjustPipeline)
            enc.setVertexBytes(&verts, length: MemoryLayout<Float>.stride * verts.count, index: 0)
            var params = AdjustParamsGPU(brightness: Float(a.brightness), contrast: Float(a.contrast),
                                         saturation: Float(a.saturation), invGamma: Float(1 / a.gamma),
                                         straight: straightSources.contains(id) ? 1 : 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<AdjustParamsGPU>.stride, index: 0)
            enc.setFragmentTexture(src, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            textures[id] = (dst, size)
            straightSources.remove(id)
        }
        for id in adjustTextures.keys where adjusts[id] == nil || adjusts[id]!.isIdentity { adjustTextures[id] = nil }

        // Stinger clip on top of everything. Decoders tag alpha as straight or premultiplied;
        // untagged clips are treated as straight (what ProRes 4444 / HEVC-alpha exports normally are).
        var top: [DrawCommand] = []
        if var s = plan.stinger, let pb = frames[s.source] {
            s.premultiply = Self.hasStraightAlpha(pb)
            top.append(s)
        }

        // Program (with optional transition) + overlays.
        if let t = plan.transition, t.kind != .cut, let a = intermediateA, let b = intermediateB {
            drawComposition(cb, target: a, size: outputSize, layers: plan.program, textures: textures, load: .clear, straight: straightSources)
            drawComposition(cb, target: b, size: outputSize, layers: t.incoming, textures: textures, load: .clear, straight: straightSources)
            let rp = passDescriptor(programTex.tex, load: .dontCare)
            if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
                var verts = quad(dest: PixelRect(x: 0, y: 0, width: Double(outputSize.width), height: Double(outputSize.height)),
                                 uv: (0, 0, 1, 1), canvas: outputSize)
                enc.setVertexBytes(&verts, length: MemoryLayout<Float>.stride * verts.count, index: 0)
                if t.kind == .custom, let custom = currentCustomPipeline() {
                    enc.setRenderPipelineState(custom)
                    var params = CustomParamsGPU(progress: Float(t.progress), ratio: Float(outputSize.aspect),
                                                 time: Float(HostClock.now().truncatingRemainder(dividingBy: 3600)))
                    enc.setFragmentBytes(&params, length: MemoryLayout<CustomParamsGPU>.stride, index: 0)
                } else {
                    // A custom transition without a compiled shader falls back to a dissolve.
                    enc.setRenderPipelineState(transitionPipeline)
                    let kind = t.kind == .custom ? TransitionKind.dissolve : t.kind
                    var params = TransitionParamsGPU(progress: Float(t.progress), kind: Int32(kind.rawValue),
                                                     aspect: Float(outputSize.aspect))
                    enc.setFragmentBytes(&params, length: MemoryLayout<TransitionParamsGPU>.stride, index: 0)
                }
                enc.setFragmentTexture(a, index: 0)
                enc.setFragmentTexture(b, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
            drawComposition(cb, target: programTex.tex, size: outputSize, layers: plan.overlays + top, textures: textures, load: .load,
                            straight: straightSources)
        } else {
            drawComposition(cb, target: programTex.tex, size: outputSize, layers: plan.program + plan.overlays + top,
                            textures: textures, load: .clear, straight: straightSources)
        }
        drawComposition(cb, target: previewTex.tex, size: previewSize, layers: plan.preview, textures: textures, load: .clear,
                        straight: straightSources)

        // Thumbnails (caller decides the rate): each input's whole scene on a transparent background.
        var thumbs: [InputID: CVPixelBuffer] = [:]
        if let thumbPool {
            for (id, layers) in plan.thumbnails {
                guard layers.contains(where: { textures[$0.source] != nil }),
                      let pb = makeBuffer(thumbPool, threshold: 96), let t = texture(for: pb) else { continue }
                keepAlive.append(t.cv)
                drawComposition(cb, target: t.tex, size: Self.thumbnailSize, layers: layers, textures: textures,
                                load: .clear, transparent: true, straight: straightSources)
                thumbs[id] = pb
            }
        }
        // Per-input viewer at full output size.
        var detailPB: CVPixelBuffer?
        if let layers = plan.detail, let detailPool, let pb = makeBuffer(detailPool), let t = texture(for: pb) {
            keepAlive.append(t.cv)
            drawComposition(cb, target: t.tex, size: outputSize, layers: layers, textures: textures,
                            load: .clear, transparent: true, straight: straightSources)
            detailPB = pb
        }

        cb.addCompletedHandler { buffer in
            _ = keepAlive // CVMetalTextures must outlive GPU use
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            let ok = buffer.status == .completed
            completion(Result(program: ok ? programPB : nil, preview: ok ? previewPB : nil, thumbnails: ok ? thumbs : [:],
                              detail: ok ? detailPB : nil, gpuMs: gpuMs))
        }
        cb.commit()
        return true
    }

    // MARK: Helpers

    /// Explicitly tagged as straight alpha (untagged buffers are our own premultiplied ones or opaque).
    static func isTaggedStraight(_ pb: CVPixelBuffer) -> Bool {
        guard let mode = CVBufferCopyAttachment(pb, kCVImageBufferAlphaChannelModeKey, nil) as? String else { return false }
        return mode == (kCVImageBufferAlphaChannelMode_StraightAlpha as String)
    }

    static func hasStraightAlpha(_ pb: CVPixelBuffer) -> Bool {
        guard let mode = CVBufferCopyAttachment(pb, kCVImageBufferAlphaChannelModeKey, nil) as? String else { return true }
        return mode != (kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String)
    }

    /// Matches `AdjustParams` in the shader (4 floats, 4 ints).
    private struct AdjustParamsGPU {
        var brightness: Float, contrast: Float, saturation: Float, invGamma: Float
        var straight: Int32, pad0: Int32 = 0, pad1: Int32 = 0, pad2: Int32 = 0
    }

    private func adjustTexture(_ id: InputID, size: PixelSize) -> MTLTexture? {
        if let t = adjustTextures[id], t.width == size.width, t.height == size.height { return t }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(1, size.width),
                                                          height: max(1, size.height), mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        let t = device.makeTexture(descriptor: td)
        adjustTextures[id] = t
        return t
    }

    private struct CustomParamsGPU { var progress: Float; var ratio: Float; var time: Float; var pad: Float = 0 }
    private struct TransitionParamsGPU { var progress: Float; var kind: Int32; var aspect: Float; var pad: Float = 0 }
    /// Matches `KeyParams` in the shader (float2 members are 8-byte aligned: 4 floats, then 2 + 2).
    /// Matches `StyleParams` in the shader (float4, float4, 3 floats, 2 ints; 64-byte stride both sides).
    private struct StyleParamsGPU {
        var maskRect: SIMD4<Float>
        var borderColor: SIMD4<Float>
        var opacity: Float
        var radius: Float
        var border: Float
        var ellipse: Int32
        var premultiply: Int32
    }
    private struct KeyParamsGPU {
        var opacity: Float, similarity: Float, smoothness: Float, spill: Float
        var keyCb: Float, keyCr: Float, pad0: Float = 0, pad1: Float = 0
    }

    private func drawComposition(_ cb: MTLCommandBuffer, target: MTLTexture, size: PixelSize, layers: [DrawCommand],
                                 textures: [InputID: (MTLTexture, PixelSize)], load: MTLLoadAction,
                                 transparent: Bool = false, straight: Set<InputID> = []) {
        let rp = passDescriptor(target, load: load, transparent: transparent)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        let canvas = PixelRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
        for (i, layer) in layers.enumerated() {
            guard let entry = textures[layer.source], layer.opacity > 0.001 else { continue }
            var layer = layer
            if straight.contains(layer.source) { layer.premultiply = true }
            let (tex, srcSize) = entry
            // Clip to the layer box (crop for .fill, plus the layer's own crop) and to the canvas.
            guard let draw = LayerDraw.compute(rect: layer.rect, source: srcSize, mode: layer.scaleMode,
                                               crop: layer.style?.crop ?? .none, canvas: size) else { continue }
            let dest = draw.dest
            let masked = layer.key == nil && (layer.style?.needsMask ?? false)
            // The first layer drawn onto a cleared (opaque black) target is a plain copy when it is
            // fully opaque content; everything else uses premultiplied "over" blending.
            let opaqueCopy = !transparent && i == 0 && load == .clear && layer.opacity >= 0.999 && layer.rect == .full
                && layer.scaleMode != .fit && layer.key == nil && !masked && (layer.style?.crop.isNone ?? true)
            var verts = quad(dest: dest, uv: (Float(draw.uv.0), Float(draw.uv.1), Float(draw.uv.2), Float(draw.uv.3)), canvas: size)
            enc.setVertexBytes(&verts, length: MemoryLayout<Float>.stride * verts.count, index: 0)
            if let key = layer.key {
                enc.setRenderPipelineState(keyPipeline)
                let kc = ChromaKey.chroma(r: key.keyColor.r, g: key.keyColor.g, b: key.keyColor.b)
                var params = KeyParamsGPU(opacity: Float(layer.opacity), similarity: Float(key.similarity),
                                          smoothness: Float(key.smoothness), spill: Float(key.spill),
                                          keyCb: Float(kc.cb), keyCr: Float(kc.cr))
                enc.setFragmentBytes(&params, length: MemoryLayout<KeyParamsGPU>.stride, index: 0)
            } else if masked, let style = layer.style {
                enc.setRenderPipelineState(styledPipeline)
                let m = draw.maskRect
                let bc = style.borderColor
                var params = StyleParamsGPU(maskRect: SIMD4(Float(m.x), Float(m.y), Float(m.width), Float(m.height)),
                                            borderColor: SIMD4(Float(bc.r), Float(bc.g), Float(bc.b), 1),
                                            opacity: Float(layer.opacity),
                                            radius: Float(style.cornerRadius * min(m.width, m.height)),
                                            border: Float(style.borderWidth * Double(size.height)),
                                            ellipse: style.shape == .ellipse ? 1 : 0,
                                            premultiply: layer.premultiply ? 1 : 0)
                enc.setFragmentBytes(&params, length: MemoryLayout<StyleParamsGPU>.stride, index: 0)
            } else {
                enc.setRenderPipelineState(layer.premultiply ? straightPipeline : (opaqueCopy ? layerPipelineOpaque : layerPipeline))
                var opacity = Float(layer.opacity)
                enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
            }
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
    }

    private func passDescriptor(_ tex: MTLTexture, load: MTLLoadAction, transparent: Bool = false) -> MTLRenderPassDescriptor {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = load
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: transparent ? 0 : 1)
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

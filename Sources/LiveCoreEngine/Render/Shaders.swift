#if os(macOS)
/// Metal shader source, compiled at runtime with `MTLDevice.makeLibrary(source:options:)`.
/// Embedding the source keeps the build identical under SwiftPM and Xcode (SwiftPM's command
/// line build does not compile .metal resources).
enum ShaderSource {
    static let code = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadVertex { float2 position; float2 uv; };
    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut quad_vertex(uint vid [[vertex_id]], constant QuadVertex *verts [[buffer(0)]]) {
        VOut o;
        o.position = float4(verts[vid].position, 0.0, 1.0);
        o.uv = verts[vid].uv;
        return o;
    }

    // Layer: textures are premultiplied BGRA; opacity scales all channels (premultiplied blend).
    fragment float4 layer_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                   constant float &opacity [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        return tex.sample(s, in.uv) * opacity;
    }

    // Chroma key (see LiveCoreCore.ChromaKey for the reference maths and parameter ranges).
    struct KeyParams { float opacity; float similarity; float smoothness; float spill; float2 keyChroma; float2 pad; };

    float2 chroma709(float3 c) {
        float y = dot(c, float3(0.2126, 0.7152, 0.0722));
        return float2((c.b - y) / 1.8556, (c.r - y) / 1.5748);
    }

    fragment float4 key_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                 constant KeyParams &k [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 c = tex.sample(s, in.uv);
        float3 rgb = c.a > 0.0001 ? c.rgb / c.a : float3(0.0);
        float d = distance(chroma709(rgb), k.keyChroma) - k.similarity;
        float alpha = smoothstep(0.0, 1.0, clamp(d / k.smoothness, 0.0, 1.0));
        // Spill suppression: pull colours that are still close to the key towards their luma.
        float spillMix = smoothstep(0.0, 1.0, clamp(d / k.spill, 0.0, 1.0));
        float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luma), rgb, spillMix);
        float a = c.a * alpha * k.opacity;
        return float4(rgb * a, a);
    }

    struct TransitionParams { float progress; int kind; float aspect; float pad; };

    // B appears where coord > edge; the edge sweeps from 1+soft to -soft (LiveCoreCore.TransitionMath).
    float wipe_mask(float coord, float t) {
        const float soft = 0.02;
        float edge = mix(1.0 + soft, -soft, t);
        return smoothstep(edge - soft, edge + soft, coord);
    }

    // kind: see LiveCoreCore.TransitionKind (1 dissolve, 2 fade, 3-6 wipes, 7-8 push, 9-10 slide, 11 iris)
    fragment float4 transition_fragment(VOut in [[stage_in]], texture2d<float> a [[texture(0)]],
                                        texture2d<float> b [[texture(1)]], constant TransitionParams &p [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = in.uv;
        float t = clamp(p.progress, 0.0, 1.0);
        float4 c;
        if (p.kind == 2) {
            c = t < 0.5 ? a.sample(s, uv) * (1.0 - 2.0 * t) : b.sample(s, uv) * (2.0 * t - 1.0);
        } else if (p.kind >= 3 && p.kind <= 6) {
            float coord = p.kind == 3 ? uv.x : (p.kind == 4 ? 1.0 - uv.x : (p.kind == 5 ? uv.y : 1.0 - uv.y));
            c = mix(a.sample(s, uv), b.sample(s, uv), wipe_mask(coord, t));
        } else if (p.kind == 7) {
            c = uv.x < 1.0 - t ? a.sample(s, float2(uv.x + t, uv.y)) : b.sample(s, float2(uv.x - (1.0 - t), uv.y));
        } else if (p.kind == 8) {
            c = uv.x >= t ? a.sample(s, float2(uv.x - t, uv.y)) : b.sample(s, float2(uv.x + (1.0 - t), uv.y));
        } else if (p.kind == 9) {
            c = uv.x >= 1.0 - t ? b.sample(s, float2(uv.x - (1.0 - t), uv.y)) : a.sample(s, uv);
        } else if (p.kind == 10) {
            c = uv.x < t ? b.sample(s, float2(uv.x + (1.0 - t), uv.y)) : a.sample(s, uv);
        } else if (p.kind == 11) {
            const float soft = 0.02;
            float2 d = float2((uv.x - 0.5) * p.aspect, uv.y - 0.5);
            float maxR = sqrt(p.aspect * p.aspect / 4.0 + 0.25) + soft;
            float r = t * maxR;
            float m = t >= 1.0 ? 1.0 : 1.0 - smoothstep(r - soft, r, length(d));
            c = mix(a.sample(s, uv), b.sample(s, uv), m);
        } else {
            c = mix(a.sample(s, uv), b.sample(s, uv), t);
        }
        return float4(c.rgb, 1.0);
    }
    """
}
#endif

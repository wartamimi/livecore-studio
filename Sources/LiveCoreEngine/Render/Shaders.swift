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

    struct TransitionParams { float progress; int kind; };

    // kind: 1 dissolve, 2 fade-to-black, 3 wipe-left (see LiveCoreCore.TransitionKind)
    fragment float4 transition_fragment(VOut in [[stage_in]], texture2d<float> a [[texture(0)]],
                                        texture2d<float> b [[texture(1)]], constant TransitionParams &p [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 ca = a.sample(s, in.uv);
        float4 cb = b.sample(s, in.uv);
        float t = clamp(p.progress, 0.0, 1.0);
        float4 c;
        if (p.kind == 2) {
            c = t < 0.5 ? ca * (1.0 - 2.0 * t) : cb * (2.0 * t - 1.0);
        } else if (p.kind == 3) {
            const float soft = 0.02;
            float edge = mix(1.0 + soft, -soft, t);
            float m = smoothstep(edge - soft, edge + soft, in.uv.x);
            c = mix(ca, cb, m);
        } else {
            c = mix(ca, cb, t);
        }
        return float4(c.rgb, 1.0);
    }
    """
}
#endif

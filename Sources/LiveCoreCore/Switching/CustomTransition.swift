/// User-written transitions (`TransitionKind.custom`). The user writes one Metal function,
///
///     float4 transition(float2 uv, float progress, float ratio,
///                       texture2d<float> from, texture2d<float> to, sampler s)
///
/// which returns the colour at `uv` ((0,0) top-left) for `progress` 0...1; `ratio` is width/height.
/// `FROM(p)` / `TO(p)` sample the outgoing / incoming picture. The app wraps it with a fixed
/// header and fragment entry point (`wrap`) and compiles it at runtime on the GPU's device.
public enum CustomTransitionSource {
    public static let maxBytes = 64 * 1024
    public static let entryPoint = "custom_transition_fragment"

    public enum Problem: Equatable, Sendable {
        case empty
        case tooLarge
        case missingFunction
        /// Construct that is not allowed in user code (`#include`, entry points, …).
        case forbidden(String)
    }

    /// Display name from a `// name: …` line, else `fallback`.
    public static func name(in code: String, fallback: String) -> String {
        for raw in code.split(separator: "\n", omittingEmptySubsequences: true).prefix(20) {
            let line = trim(Substring(raw))
            guard line.hasPrefix("//") else { continue }
            let body = trim(line.dropFirst(2))
            if body.lowercased().hasPrefix("name:") {
                let n = trim(body.dropFirst(5))
                if !n.isEmpty { return String(n.prefix(40)) }
            }
        }
        return fallback
    }

    /// Checks the user code before it is compiled. nil = acceptable.
    public static func validate(_ code: String) -> Problem? {
        if trim(Substring(code)).isEmpty { return .empty }
        if code.utf8.count > maxBytes { return .tooLarge }
        let stripped = stripComments(code)
        for word in ["#include", "#import", "#pragma", "fragment ", "vertex ", "kernel ", "[[buffer", "[[texture", "device "] {
            if contains(stripped, word) { return .forbidden(String(trim(Substring(word)))) }
        }
        if !contains(stripped, "transition(") || !contains(stripped, "float4") { return .missingFunction }
        return nil
    }

    /// Complete Metal source for the user code. Compiler line numbers inside the user code match
    /// the user's file (`#line`).
    public static func wrap(_ code: String) -> String {
        """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 position [[position]]; float2 uv; };
        struct CustomTransitionParams { float progress; float ratio; float time; float pad; };
        #define FROM(p) from.sample(s, (p))
        #define TO(p) to.sample(s, (p))
        #line 1 "transition"
        \(code)
        #line 10000 "livecore"
        fragment float4 \(entryPoint)(VOut in [[stage_in]], texture2d<float> from [[texture(0)]],
                                      texture2d<float> to [[texture(1)]],
                                      constant CustomTransitionParams &p [[buffer(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float t = clamp(p.progress, 0.0, 1.0);
            if (t <= 0.0) { return from.sample(s, in.uv); }
            if (t >= 1.0) { return to.sample(s, in.uv); }
            return transition(in.uv, t, p.ratio, from, to, s);
        }

        """
    }

    /// Identifier stored in settings: built-ins and files in the user's transitions folder.
    public static func builtInID(_ key: String) -> String { "builtin:" + key }
    public static func fileID(_ fileName: String) -> String { "file:" + fileName }
    public static func fileName(fromID id: String) -> String? {
        guard id.hasPrefix("file:") else { return nil }
        let name = String(id.dropFirst(5))
        // Only plain file names inside the transitions folder.
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name.hasSuffix(".metal") else { return nil }
        return name
    }

    // MARK: Helpers (Foundation-free)

    private static func trim(_ s: Substring) -> Substring {
        var s = s
        while let c = s.first, c == " " || c == "\t" || c == "\r" || c == "\n" { s = s.dropFirst() }
        while let c = s.last, c == " " || c == "\t" || c == "\r" || c == "\n" { s = s.dropLast() }
        return s
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        let h = Array(haystack.utf8), n = Array(needle.utf8)
        guard !n.isEmpty, h.count >= n.count else { return n.isEmpty }
        outer: for i in 0...(h.count - n.count) {
            for j in 0..<n.count where h[i + j] != n[j] { continue outer }
            return true
        }
        return false
    }

    /// Removes // and /* */ comments (so a forbidden word in a comment is harmless).
    static func stripComments(_ code: String) -> String {
        var out: [UInt8] = []
        let b = Array(code.utf8)
        var i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "/"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "/") {
                while i < b.count, b[i] != UInt8(ascii: "\n") { i += 1 }
            } else if b[i] == UInt8(ascii: "/"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i + 1 < b.count, !(b[i] == UInt8(ascii: "*") && b[i + 1] == UInt8(ascii: "/")) { i += 1 }
                i += 2
                out.append(UInt8(ascii: " "))
            } else {
                out.append(b[i]); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Example transitions shipped with the app, written exactly as a user would write them.
public struct BuiltInTransition: Equatable, Sendable {
    public let key: String
    public let code: String
    public var id: String { CustomTransitionSource.builtInID(key) }
    public var name: String { CustomTransitionSource.name(in: code, fallback: key) }

    public static func find(id: String) -> BuiltInTransition? { all.first { $0.id == id } }

    /// Starting point offered to users when they create a new transition file.
    public static let template = """
    // name: My Transition
    // LiveCore Studio custom transition (Metal Shading Language).
    // uv: 0..1, (0,0) = top-left. progress: 0 (all FROM) .. 1 (all TO). ratio: width / height.
    // FROM(p) and TO(p) sample the outgoing and incoming picture at p.
    float4 transition(float2 uv, float progress, float ratio,
                      texture2d<float> from, texture2d<float> to, sampler s) {
        // Example: soft diagonal wipe.
        float d = (uv.x + uv.y) * 0.5;
        float edge = mix(-0.05, 1.05, progress);
        float m = 1.0 - smoothstep(edge - 0.05, edge, d);
        return mix(FROM(uv), TO(uv), m);
    }

    """

    public static let all: [BuiltInTransition] = [
        BuiltInTransition(key: "diagonal", code: """
        // name: Wipe Diagonal
        float4 transition(float2 uv, float progress, float ratio,
                          texture2d<float> from, texture2d<float> to, sampler s) {
            float d = (uv.x + uv.y) * 0.5;
            float edge = mix(-0.05, 1.05, progress);
            float m = 1.0 - smoothstep(edge - 0.05, edge, d);
            return mix(FROM(uv), TO(uv), m);
        }
        """),
        BuiltInTransition(key: "clock", code: """
        // name: Clock Wipe
        float4 transition(float2 uv, float progress, float ratio,
                          texture2d<float> from, texture2d<float> to, sampler s) {
            float2 c = float2((uv.x - 0.5) * ratio, uv.y - 0.5);
            float a = fract(atan2(c.x, -c.y) / (2.0 * M_PI_F) + 1.0);   // 0 at 12 o'clock, clockwise
            float m = smoothstep(a, a + 0.004, progress);
            return mix(FROM(uv), TO(uv), m);
        }
        """),
        BuiltInTransition(key: "doors", code: """
        // name: Doors Open
        float4 transition(float2 uv, float progress, float ratio,
                          texture2d<float> from, texture2d<float> to, sampler s) {
            float d = abs(uv.x - 0.5) * 2.0;
            float m = 1.0 - smoothstep(progress - 0.02, progress, d);
            return mix(FROM(uv), TO(uv), m);
        }
        """),
        BuiltInTransition(key: "blinds", code: """
        // name: Blinds
        float4 transition(float2 uv, float progress, float ratio,
                          texture2d<float> from, texture2d<float> to, sampler s) {
            float f = fract(uv.y * 10.0);
            return progress >= f ? TO(uv) : FROM(uv);
        }
        """),
        BuiltInTransition(key: "zoom", code: """
        // name: Zoom Dissolve
        float4 transition(float2 uv, float progress, float ratio,
                          texture2d<float> from, texture2d<float> to, sampler s) {
            float2 ua = (uv - 0.5) / (1.0 + 0.5 * progress) + 0.5;
            float2 ub = (uv - 0.5) / (1.5 - 0.5 * progress) + 0.5;
            return mix(FROM(ua), TO(ub), smoothstep(0.0, 1.0, progress));
        }
        """),
        BuiltInTransition(key: "pixelate", code: """
        // name: Pixelate
        float4 transition(float2 uv, float progress, float ratio,
                          texture2d<float> from, texture2d<float> to, sampler s) {
            float k = 1.0 - abs(progress * 2.0 - 1.0);              // 0 -> 1 -> 0
            float cells = mix(480.0, 16.0, k);
            float2 grid = float2(cells, max(cells / ratio, 1.0));
            float2 p = (floor(uv * grid) + 0.5) / grid;
            return progress < 0.5 ? FROM(p) : TO(p);
        }
        """),
    ]
}

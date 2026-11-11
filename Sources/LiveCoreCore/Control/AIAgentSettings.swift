import Foundation

/// AI Assistant settings tools (0.68.0): read and change (almost) every setting of an input, the
/// audio mixer and the transition. Input settings are the app's own Codable models (title design,
/// running text, QR code, timer, virtual set, frame, colour correction, chroma key, layers); the
/// assistant reads them as JSON and sends a JSON merge patch (RFC 7396), which is applied, decoded
/// back into the model (so invalid values are refused) and then applied to the input.
/// The "title" section: text plus the template design.
public struct AITitleSettings: Codable, Equatable {
    public var title: String
    public var subtitle: String
    public var design: TitleDesign?
    public init(title: String, subtitle: String, design: TitleDesign?) { self.title = title; self.subtitle = subtitle; self.design = design }
}

/// The "name" section.
public struct AINameSettings: Codable, Equatable {
    public var name: String
    public init(name: String) { self.name = name }
}

extension AIAgent {
    public static let inputSections = ["name", "title", "ticker", "qr", "timer", "virtualSet",
                                       "adjust", "chromaKey", "layers"]

    /// Mixer controls the assistant may set, with their range (Bool controls have nil).
    public static let audioControls: [(name: String, range: ClosedRange<Double>?)] = [
        ("fader", 0...1), ("gainDB", -24...24), ("pan", -1...1), ("muted", nil), ("solo", nil),
        ("toProgram", nil), ("toBusA", nil), ("toBusB", nil), ("toBusC", nil), ("toBusD", nil),
        ("compressor", nil), ("compThreshold", -60...0), ("compRatio", 1...20),
        ("gate", nil), ("gateThreshold", -90...0), ("highPass", nil), ("highPassHz", 20...400),
        ("eq", nil), ("eqLow", -15...15), ("eqMid", -15...15), ("eqHigh", -15...15),
        ("lowPass", nil), ("lowPassHz", 1000...20000), ("limiter", nil), ("limiterCeiling", -20...0),
    ]

    public static var settingsTools: [[String: Any]] {
        let audioProps: [String: Any] = Dictionary(uniqueKeysWithValues: audioControls.map { c in
            (c.name, c.range == nil ? ["type": "boolean"] as [String: Any]
                                    : ["type": "number", "description": "\(c.range!.lowerBound)…\(c.range!.upperBound)"] as [String: Any])
        })
        return [
            [
                "name": "get_input_settings",
                "description": "Returns every setting of one input as JSON, by section (name, title, ticker, qr, timer, virtualSet, adjust = colour correction, chromaKey, layers). Read this before set_input_settings.",
                "input_schema": [
                    "type": "object",
                    "properties": ["input": ["type": "integer"]],
                    "required": ["input"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "set_input_settings",
                "description": "Changes settings of one input: patch_json is a JSON merge patch (only the keys to change, same names and value types as get_input_settings shows) for one section. Colours are objects {r,g,b,a} from 0 to 1. layers takes the whole array.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "input": ["type": "integer"],
                        "section": ["type": "string", "enum": inputSections],
                        "patch_json": ["type": "string", "description": "e.g. {\"design\":{\"titleSize\":64,\"boxColor\":{\"r\":0.8,\"g\":0.6,\"b\":0.1,\"a\":1}}}"],
                    ] as [String: Any],
                    "required": ["input", "section", "patch_json"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "set_audio",
                "description": "Changes an audio mixer channel (id or name from get_state, or \"master\" for the master fader). fader is the fader position 0-1 (0.75 = 0 dB). Only the given controls change.",
                "input_schema": [
                    "type": "object",
                    "properties": audioProps.merging(["channel": ["type": "string"]]) { a, _ in a },
                    "required": ["channel"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "set_transition",
                "description": "Sets the transition used by AUTO: kind (one of the names listed) and/or duration in seconds (0.1-10).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": TransitionKind.allCases.map { "\($0)" }],
                        "duration": ["type": "number"],
                    ] as [String: Any],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "delete_input",
                "description": "Removes an input from the show. Not allowed for the input on Program. Only when the operator asks for it.",
                "input_schema": [
                    "type": "object",
                    "properties": ["input": ["type": "integer"]],
                    "required": ["input"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
        ]
    }

    /// RFC 7396 JSON merge patch: objects merge key by key, null removes, anything else replaces.
    public static func mergePatch(_ target: Any, _ patch: Any) -> Any {
        guard let p = patch as? [String: Any] else { return patch }
        var t = target as? [String: Any] ?? [:]
        for (k, v) in p {
            if v is NSNull { t[k] = nil } else { t[k] = mergePatch(t[k] ?? NSNull(), v) }
        }
        return t
    }

    /// A Codable value as a JSON object (for get_input_settings).
    public static func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let d = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    /// Applies a merge patch (given as JSON text) to a Codable value. Fails when the text is not
    /// JSON or the result no longer decodes (wrong type, unknown enum value...).
    public static func patched<T: Codable>(_ value: T, patchJSON: String) -> Result<T, StepError> {
        guard let patch = try? JSONSerialization.jsonObject(with: Data(patchJSON.utf8), options: [.fragmentsAllowed]) else {
            return .failure(.init("patch_json is not valid JSON"))
        }
        guard let base = jsonObject(value) else { return .failure(.init("cannot read the current settings")) }
        let merged = mergePatch(base, patch)
        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged) else {
            return .failure(.init("the patch must be a JSON object (or an array for layers)"))
        }
        do { return .success(try JSONDecoder().decode(T.self, from: data)) }
        catch { return .failure(.init("the new settings are not valid: \(describe(error))")) }
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "\(error)" }
        func path(_ c: DecodingError.Context) -> String { c.codingPath.map(\.stringValue).joined(separator: ".") }
        switch e {
        case let .typeMismatch(_, c), let .valueNotFound(_, c), let .dataCorrupted(c): return "\(path(c)): \(c.debugDescription)"
        case let .keyNotFound(k, c): return "\(path(c)).\(k.stringValue) is missing"
        @unknown default: return "\(e)"
        }
    }

    /// Checks one mixer control value against `audioControls`.
    public static func audioValue(_ name: String, _ v: Any?) -> Result<Any, StepError> {
        guard let c = audioControls.first(where: { $0.name == name }) else { return .failure(.init("unknown control \(name)")) }
        if c.range == nil {
            guard let b = v as? Bool else { return .failure(.init("\(name) must be true or false")) }
            return .success(b)
        }
        guard let d = doubleValue(v), d.isFinite else { return .failure(.init("\(name) must be a number")) }
        return .success(min(max(d, c.range!.lowerBound), c.range!.upperBound))
    }
}

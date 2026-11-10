import Foundation

/// AI Assistant (0.66.0): the operator types a command in plain words ("put camera 2 on air with a
/// dissolve, then show the lower third") and Claude, through the Anthropic Messages API with tool
/// use, answers by calling the app's own tools. The tools only run what macros can run (switching,
/// overlays, audio on/off, video play/pause, waits, stream / record), so the assistant can never do
/// more than an operator could put in a macro. Pure logic (request body, answer parsing, turning a
/// tool call into macro steps) so it is tested on Linux; the app does the HTTP calls and runs steps.
public enum AIAgent {
    public static let keychainAccount = "anthropic-api-key"
    public static let url = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    public static let defaultModel = "claude-opus-5-5"
    public static let models: [(String, String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 (best understanding)"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 (faster)"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (fastest, cheapest)"),
    ]
    /// Model calls per command at most (each tool round is one call).
    public static let maxRounds = 8
    /// Longest wait step the assistant may use (a macro may wait up to an hour).
    public static let maxWait: Double = 30
    /// Steps that start or stop the stream or the recording: only when the operator allows them.
    public static let outputKinds: Set<MacroStepKind> = [.streamStart, .streamStop, .recordStart, .recordStop]

    public static func systemPrompt(allowOutputs: Bool) -> String {
        """
        You are the AI Assistant inside LiveCore Studio, a live video production app for macOS (a \
        vision mixer like vMix). The operator gives you commands during a live show, in Indonesian or \
        English. Carry them out with the tools, then answer in one or two short sentences in the \
        operator's language, saying what you did.

        - Call get_state first when you need input numbers, overlay channels, audio channel ids or \
        macro numbers. Never guess a number or id that get_state did not show.
        - Inputs are named by number. "Preview" is the next shot, "Program" is on air. "cut" swaps \
        Preview and Program at once; "auto" swaps them with the current transition. To put an input \
        on air with the transition use the step kind "transition"; to cut straight to it use "program".
        - Overlay channels are 1 to 4 (lower thirds, titles, logos are usually on an overlay channel).
        - Do everything a command asks in one run_steps call when you can; a "wait" step pauses \
        (at most \(Int(maxWait)) s).
        - If a command is unclear or names something that does not exist, do nothing and ask a short \
        question instead.
        \(allowOutputs
          ? "- You may start or stop the stream and the recording, but only when the operator asks for it in so many words."
          : "- You may NOT start or stop the stream or the recording: the operator has switched that off. Tell them to do it themselves.")
        """
    }

    /// The tool definitions sent with every request (kept in a fixed order so prompt caching works).
    public static var tools: [[String: Any]] {
        let kinds = MacroStepKind.allCases.map(\.rawValue)
        return [
            [
                "name": "get_state",
                "description": "Returns the current show as JSON: inputs (number, name, kind), which input number is on preview and on program, overlay channels 1-4 (on/off and their input), audio channels (id, name, fader 0-1, muted), macros (number, name), and whether streaming / recording is running.",
                "input_schema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
            ],
            [
                "name": "run_steps",
                "description": """
                Runs steps in order, like a macro, and returns when they have finished. Step kinds: \
                cut, auto (swap preview and program, auto uses the current transition); preview (input to preview); \
                program (input straight to program, a cut); transition (input on air with the current transition); \
                overlayOn / overlayOff / overlayToggle (overlay channel 1-4); audioOn / audioOff (unmute / mute an \
                audio channel by id); videoPlay / videoPause / videoRestart (a video input); wait (seconds); \
                streamStart / streamStop / recordStart / recordStop; snapshot (save a still of program); \
                highlight (mark a highlight in the recording).
                """,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "steps": [
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 20,
                            "items": [
                                "type": "object",
                                "properties": [
                                    "kind": ["type": "string", "enum": kinds],
                                    "input": ["type": "integer", "description": "Input number (for preview, program, transition, video steps)."],
                                    "overlay": ["type": "integer", "description": "Overlay channel 1-4."],
                                    "channel": ["type": "string", "description": "Audio channel id from get_state."],
                                    "seconds": ["type": "number", "description": "Length of a wait step."],
                                ],
                                "required": ["kind"],
                                "additionalProperties": false,
                            ] as [String: Any],
                        ] as [String: Any],
                    ],
                    "required": ["steps"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "run_macro",
                "description": "Runs one of the operator's saved macros by its number (see get_state) and returns when it has finished.",
                "input_schema": [
                    "type": "object",
                    "properties": ["number": ["type": "integer", "minimum": 1]],
                    "required": ["number"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
        ]
    }

    /// The JSON body for one Messages API call. `messages` is the whole conversation so far, with the
    /// assistant turns exactly as the API returned them (thinking blocks included).
    public static func requestBody(model: String, messages: [[String: Any]], allowOutputs: Bool) -> Data {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": [["type": "text", "text": systemPrompt(allowOutputs: allowOutputs),
                        "cache_control": ["type": "ephemeral"]]],
            "tools": tools,
            "messages": messages,
            // Live commands: answer quickly.
            "output_config": ["effort": "low"],
        ]
        if usesFallback(model) { body["fallbacks"] = "default" }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Server-side fallback on a refusal (not offered for Haiku).
    public static func usesFallback(_ model: String) -> Bool { model.hasPrefix("claude-opus") || model.hasPrefix("claude-sonnet") }

    public struct ToolUse: Equatable {
        public let id: String
        public let name: String
        public let inputJSON: String
        public init(id: String, name: String, inputJSON: String) { self.id = id; self.name = name; self.inputJSON = inputJSON }
        public var input: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        }
    }

    public struct Reply {
        /// The assistant turn as returned, to send back unchanged next round.
        public let content: [[String: Any]]
        public let text: String
        public let toolUses: [ToolUse]
        public let stopReason: String
    }

    public static func parse(_ data: Data) -> Reply? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = o["content"] as? [[String: Any]] else { return nil }
        var text: [String] = []
        var uses: [ToolUse] = []
        for b in content {
            switch b["type"] as? String {
            case "text": if let t = b["text"] as? String { text.append(t) }
            case "tool_use":
                guard let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                let input = b["input"] ?? [String: Any]()
                let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                uses.append(ToolUse(id: id, name: name, inputJSON: json))
            default: break
            }
        }
        return Reply(content: content, text: text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                     toolUses: uses, stopReason: o["stop_reason"] as? String ?? "")
    }

    /// The `error.message` of an API error answer, else the raw text (shortened).
    public static func errorText(_ data: Data) -> String {
        if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
    }

    public static func toolResult(_ id: String, _ text: String, isError: Bool = false) -> [String: Any] {
        var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": text]
        if isError { r["is_error"] = true }
        return r
    }

    /// What the show has, to check the assistant's steps against.
    public struct Show {
        public var inputs: [(number: Int, id: InputID)]
        public var channels: [(id: String, name: String)]
        public init(inputs: [(number: Int, id: InputID)], channels: [(id: String, name: String)]) {
            self.inputs = inputs; self.channels = channels
        }
    }

    /// Turns a run_steps call into macro steps, or says what is wrong (sent back to the model, which
    /// then fixes the call or asks the operator). Nothing runs unless every step is valid.
    public static func steps(from input: [String: Any], show: Show, allowOutputs: Bool) -> Result<[MacroStep], StepError> {
        guard let raw = input["steps"] as? [[String: Any]], !raw.isEmpty else { return .failure(.init("steps is missing or empty")) }
        guard raw.count <= 20 else { return .failure(.init("at most 20 steps per call")) }
        var out: [MacroStep] = []
        for (k, s) in raw.enumerated() {
            let n = k + 1
            guard let name = s["kind"] as? String, let kind = MacroStepKind(rawValue: name) else {
                return .failure(.init("step \(n): unknown kind \(s["kind"].map { "\($0)" } ?? "nil")"))
            }
            if outputKinds.contains(kind) && !allowOutputs {
                return .failure(.init("step \(n): the operator has not allowed the assistant to start or stop the stream or the recording"))
            }
            var step = MacroStep(kind)
            if kind.needsInput {
                guard let num = intValue(s["input"]) else { return .failure(.init("step \(n) (\(name)): input number is missing")) }
                guard let i = show.inputs.first(where: { $0.number == num }) else {
                    return .failure(.init("step \(n): there is no input \(num)"))
                }
                step.input = i.id
            }
            if kind.needsOverlay {
                guard let o = intValue(s["overlay"]), (1...4).contains(o) else {
                    return .failure(.init("step \(n) (\(name)): overlay must be 1 to 4"))
                }
                step.overlay = o
            }
            if kind.needsChannel {
                let c = (s["channel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard let ch = show.channels.first(where: { $0.id == c })
                        ?? show.channels.first(where: { $0.name.caseInsensitiveCompare(c) == .orderedSame }) else {
                    return .failure(.init("step \(n): there is no audio channel \"\(c)\""))
                }
                step.channel = ch.id
            }
            if kind == .wait {
                let sec = doubleValue(s["seconds"]) ?? 1
                step.seconds = min(max(sec.isFinite ? sec : 1, 0), maxWait)
            }
            out.append(step)
        }
        return .success(out)
    }

    public struct StepError: Error, Equatable {
        public let message: String
        public init(_ m: String) { message = m }
    }

    static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = doubleValue(v) { return d.isFinite && d == d.rounded() && abs(d) < 1e9 ? Int(d) : nil }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func doubleValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    /// One line per step for the assistant window, e.g. "transition → input 2".
    public static func describe(_ steps: [MacroStep], number: (InputID) -> Int?) -> String {
        steps.map { s in
            var t = s.kind.rawValue
            if let i = s.input, let n = number(i) { t += " → input \(n)" }
            if let o = s.overlay { t += " → overlay \(o)" }
            if let c = s.channel { t += " → \(c)" }
            if s.kind == .wait { t += " \(String(format: "%.1f", s.waitSeconds)) s" }
            return t
        }.joined(separator: ", ")
    }
}

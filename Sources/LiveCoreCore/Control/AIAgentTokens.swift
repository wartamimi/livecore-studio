import Foundation

// AI Assistant 0.70.3: fewer tokens per command. A command used to resend the whole history
// (tool calls, tool results, a full JSON copy of the show on every turn) on every round. Now:
// a short text picture of the show rides only on the newest command, finished commands are kept
// as one short user / assistant pair, the history is capped, Anthropic caches the system prompt
// and the tools, and the chat shows how many tokens each command used.

/// Tokens of one call or one command.
public struct AIUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    /// Part of `input` read from the provider's prompt cache (much cheaper, often 10 %).
    public var cached = 0
    public init() {}
    public init(input: Int, output: Int, cached: Int) { self.input = input; self.output = output; self.cached = cached }

    /// Anthropic `usage`: input_tokens excludes cache reads and writes, so they are added.
    public init(anthropic u: [String: Any]?) {
        guard let u else { return }
        let read = AIAgent.intValue(u["cache_read_input_tokens"]) ?? 0
        let write = AIAgent.intValue(u["cache_creation_input_tokens"]) ?? 0
        input = (AIAgent.intValue(u["input_tokens"]) ?? 0) + read + write
        output = AIAgent.intValue(u["output_tokens"]) ?? 0
        cached = read
    }

    /// OpenAI-style `usage`: prompt_tokens includes the cached part.
    public init(openAI u: [String: Any]?) {
        guard let u else { return }
        input = AIAgent.intValue(u["prompt_tokens"]) ?? 0
        output = AIAgent.intValue(u["completion_tokens"]) ?? 0
        cached = AIAgent.intValue((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]) ?? 0
    }

    public var total: Int { input + output }
    public static func + (a: AIUsage, b: AIUsage) -> AIUsage {
        AIUsage(input: a.input + b.input, output: a.output + b.output, cached: a.cached + b.cached)
    }

    /// "4.2k tokens (in 3.9k, of which 2.8k cached; out 310)".
    public var label: String {
        func k(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
        var s = "\(k(total)) tokens (in \(k(input))"
        if cached > 0 { s += ", \(k(cached)) cached" }
        return s + "; out \(k(output)))"
    }
}

extension AIAgent {
    /// Finished commands kept as context (each one user + one assistant message).
    public static let historyCommands = 6

    /// Anthropic: the tools with a cache mark on the last one, so system prompt + tools (the big,
    /// unchanging part) are read from the cache on every round after the first.
    static var cachedTools: [[String: Any]] {
        var t = tools
        if !t.isEmpty { t[t.count - 1]["cache_control"] = ["type": "ephemeral"] }
        return t
    }

    /// The show as short text lines (a fraction of the JSON size).
    public static func compactState(_ s: RemoteState) -> String {
        var out: [String] = []
        func n(_ v: Int?) -> String { v.map(String.init) ?? "none" }
        out.append("Program: \(n(s.program)) · Preview: \(n(s.preview)) · Transition: \(s.transition) \(String(format: "%.1f", s.transitionDuration)) s")
        out.append("Stream: \(s.streaming ? "ON" : "off")\(s.streamLocked ? " (locked)" : "") · Record: \(s.recording ? "ON" : "off")\(s.recordLocked ? " (locked)" : "")")
        out.append("Inputs: " + (s.inputs.isEmpty ? "none" : s.inputs.map { i in
            "\(i.number) \(i.name) [\(i.kind)\(i.ptz ? ", PTZ" : "")\(i.data ? ", data" : "")]"
        }.joined(separator: "; ")))
        let ov = s.overlays.map { o in
            "\(o.index): " + (o.input.map { "input \($0)" } ?? "empty") + (o.on ? " ON AIR" : "") + (o.onPreview ? " on preview" : "")
        }
        if !ov.isEmpty { out.append("Overlays: " + ov.joined(separator: "; ")) }
        let ch = s.channels.map { c in "\(c.id) \"\(c.name)\" fader \(String(format: "%.2f", c.fader))\(c.muted ? " MUTED" : "")" }
        if !ch.isEmpty { out.append("Audio: " + ch.joined(separator: "; ")) }
        if !s.macros.isEmpty { out.append("Macros: " + s.macros.map { "\($0.number) \($0.name)" }.joined(separator: "; ")) }
        if !s.qrs.isEmpty { out.append("QR inputs: " + s.qrs.map { "\($0.number) item \($0.item)/\($0.items.count)\($0.on ? " ON" : "")" }.joined(separator: "; ")) }
        return out.joined(separator: "\n")
    }

    /// A finished command as one plain user / assistant pair (no tool calls or results), which
    /// keeps the context the next command needs at a small size.
    public static func compactTurn(command: String, answers: [String], actions: [String], _ p: AIProvider) -> [[String: Any]] {
        var reply = answers.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !actions.isEmpty { reply += (reply.isEmpty ? "" : "\n") + "[done: " + actions.prefix(12).joined(separator: "; ") + "]" }
        if reply.isEmpty { reply = "(no answer)" }
        if reply.count > 1500 { reply = String(reply.prefix(1500)) + "…" }
        return userTurn(command, p) + [["role": "assistant", "content": reply]]
    }

    /// Keeps the last `historyCommands` pairs.
    public static func trimmedHistory(_ m: [[String: Any]]) -> [[String: Any]] {
        m.count > historyCommands * 2 ? Array(m.suffix(historyCommands * 2)) : m
    }
}

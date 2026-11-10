import Foundation

/// Who answers the AI Assistant (0.66.1). Claude uses the Anthropic Messages API; OpenAI, Google
/// Gemini and Ollama (a model running on this Mac) use the OpenAI-style Chat Completions format
/// with function tools. The tools and the checks on every step are the same for all of them.
public enum AIProvider: String, CaseIterable, Codable, Sendable {
    case anthropic, openAI, gemini, ollama

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (local, on this Mac)"
        }
    }

    /// Keychain entry of the API key (Ollama needs none).
    public var keychainAccount: String? {
        switch self {
        case .anthropic: return AIAgent.keychainAccount
        case .openAI: return "openai-api-key"
        case .gemini: return "gemini-api-key"
        case .ollama: return nil
        }
    }

    public var keyHint: String {
        switch self {
        case .anthropic: return "sk-ant-…  (console.anthropic.com)"
        case .openAI: return "sk-…  (platform.openai.com)"
        case .gemini: return "AIza…  (aistudio.google.com)"
        case .ollama: return ""
        }
    }

    /// Suggested models; the model field can also be typed by hand (providers add models often).
    public var models: [(String, String)] {
        switch self {
        case .anthropic: return AIAgent.models
        case .openAI: return [("gpt-4.1", "GPT-4.1"), ("gpt-4.1-mini", "GPT-4.1 mini (faster, cheaper)"), ("gpt-4o", "GPT-4o")]
        case .gemini: return [("gemini-2.5-flash", "Gemini 2.5 Flash"), ("gemini-2.5-pro", "Gemini 2.5 Pro")]
        case .ollama: return [("qwen2.5:7b", "Qwen 2.5 7B"), ("llama3.1:8b", "Llama 3.1 8B"), ("mistral-nemo", "Mistral Nemo")]
        }
    }

    public var defaultModel: String { models[0].0 }

    public var usesOpenAIFormat: Bool { self != .anthropic }

    /// Chat endpoint. `ollamaBase` is the Ollama server (default http://localhost:11434).
    public func endpoint(ollamaBase: String = "http://localhost:11434") -> URL? {
        switch self {
        case .anthropic: return AIAgent.url
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        case .ollama:
            var b = ollamaBase.trimmingCharacters(in: .whitespacesAndNewlines)
            while b.hasSuffix("/") { b.removeLast() }
            if b.isEmpty { b = "http://localhost:11434" }
            if !b.contains("://") { b = "http://" + b }
            return URL(string: b + "/v1/chat/completions")
        }
    }
}

extension AIAgent {
    // MARK: OpenAI-style Chat Completions (OpenAI, Gemini, Ollama)

    /// The same three tools as function tools.
    public static var openAITools: [[String: Any]] {
        tools.map { t in
            ["type": "function",
             "function": ["name": t["name"] ?? "", "description": t["description"] ?? "",
                          "parameters": t["input_schema"] ?? [String: Any]()] as [String: Any]]
        }
    }

    public static func openAIRequestBody(model: String, messages: [[String: Any]], allowOutputs: Bool) -> Data {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": systemPrompt(allowOutputs: allowOutputs)]] + messages,
            "tools": openAITools,
            "tool_choice": "auto",
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Parses `choices[0].message`. `content` holds that message unchanged (Gemini's thought
    /// signatures ride along in it); the stop reason is mapped to the Anthropic names.
    public static func parseOpenAI(_ data: Data) -> Reply? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choice = (o["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any] else { return nil }
        var uses: [ToolUse] = []
        for (k, c) in ((msg["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
            guard let f = c["function"] as? [String: Any], let name = f["name"] as? String else { continue }
            let args: String
            if let s = f["arguments"] as? String { args = s.isEmpty ? "{}" : s }
            else if let obj = f["arguments"], JSONSerialization.isValidJSONObject(obj),
                    let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                args = String(data: d, encoding: .utf8) ?? "{}"
            } else { args = "{}" }
            uses.append(ToolUse(id: c["id"] as? String ?? "call_\(k)", name: name, inputJSON: args))
        }
        // Send the message back with ids on every call (some local servers leave them out).
        var back = msg
        if !uses.isEmpty, var calls = msg["tool_calls"] as? [[String: Any]] {
            for k in calls.indices where calls[k]["id"] == nil && k < uses.count { calls[k]["id"] = uses[k].id }
            back["tool_calls"] = calls
        }
        if back["content"] == nil || back["content"] is NSNull { back["content"] = "" }
        let finish = choice["finish_reason"] as? String ?? ""
        let stop: String
        if !uses.isEmpty { stop = "tool_use" }
        else if finish == "length" { stop = "max_tokens" }
        else if finish == "content_filter" { stop = "refusal" }
        else { stop = "end_turn" }
        let text = (msg["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Reply(content: [back], text: text, toolUses: uses, stopReason: stop)
    }

    /// Error text of an OpenAI-style error answer (`error.message`, or Gemini's list form).
    public static func openAIErrorText(_ data: Data) -> String {
        if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let e = arr.first?["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return errorText(data)
    }

    // MARK: Conversation turns per provider

    public static func userTurn(_ text: String, _ p: AIProvider) -> [[String: Any]] {
        [["role": "user", "content": text]]
    }

    public static func assistantTurn(_ r: Reply, _ p: AIProvider) -> [[String: Any]] {
        p.usesOpenAIFormat ? r.content : [["role": "assistant", "content": r.content]]
    }

    /// Tool results: one user turn of tool_result blocks (Anthropic) or one "tool" message per call.
    public static func toolTurn(_ results: [(id: String, text: String, isError: Bool)], _ p: AIProvider) -> [[String: Any]] {
        if p.usesOpenAIFormat {
            return results.map { ["role": "tool", "tool_call_id": $0.id, "content": $0.isError ? "Error: \($0.text)" : $0.text] }
        }
        return [["role": "user", "content": results.map { toolResult($0.id, $0.text, isError: $0.isError) }]]
    }
}

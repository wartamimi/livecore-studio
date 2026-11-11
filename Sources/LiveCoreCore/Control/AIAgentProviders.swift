import Foundation

/// Who answers the AI Assistant (0.66.1). Claude uses the Anthropic Messages API; OpenAI, Google
/// Gemini and Ollama (a model running on this Mac) use the OpenAI-style Chat Completions format
/// with function tools. The tools and the checks on every step are the same for all of them.
public enum AIProvider: String, CaseIterable, Codable, Sendable {
    case anthropic, openAI, gemini, groq, openRouter, tokenMurah, exa, ollama

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq (free tier)"
        case .openRouter: return "OpenRouter (free models)"
        case .tokenMurah: return "TokenMurah (bayar Rupiah)"
        case .exa: return "Exa (web answers)"
        case .ollama: return "Ollama (local, on this Mac)"
        }
    }

    /// Keychain entry of the API key (Ollama needs none).
    public var keychainAccount: String? {
        switch self {
        case .anthropic: return AIAgent.keychainAccount
        case .openAI: return "openai-api-key"
        case .gemini: return "gemini-api-key"
        case .groq: return "groq-api-key"
        case .openRouter: return "openrouter-api-key"
        case .tokenMurah: return "tokenmurah-api-key"
        case .exa: return AIAgent.exaKeychainAccount
        case .ollama: return nil
        }
    }

    public var keyHint: String {
        switch self {
        case .anthropic: return "sk-ant-…  (console.anthropic.com)"
        case .openAI: return "sk-…  (platform.openai.com)"
        case .gemini: return "AIza…  (aistudio.google.com)"
        case .groq: return "gsk_…  (console.groq.com)"
        case .openRouter: return "sk-or-…  (openrouter.ai/keys)"
        case .tokenMurah: return "sk-tm-… atau sk-tp-…  (tokenmurah.net/dashboard)"
        case .exa: return "Exa key  (dashboard.exa.ai)"
        case .ollama: return ""
        }
    }

    /// Suggested models; the model field can also be typed by hand (providers add models often).
    public var models: [(String, String)] {
        switch self {
        case .anthropic: return AIAgent.models
        case .openAI: return [("gpt-4.1", "GPT-4.1"), ("gpt-4.1-mini", "GPT-4.1 mini (faster, cheaper)"), ("gpt-4o", "GPT-4o")]
        // 2.5 models are closed to new keys (Google answers 404 and names gemini-3.8-flash).
        case .gemini: return [("gemini-3.8-flash", "Gemini 3.8 Flash")]
        case .groq: return [("llama-3.3-70b-versatile", "Llama 3.3 70B"), ("openai/gpt-oss-120b", "GPT-OSS 120B"),
                            ("llama-3.1-8b-instant", "Llama 3.1 8B (fastest)")]
        // ":free" models cost nothing (daily limits); "Check models" lists the current free ones.
        case .openRouter: return [("meta-llama/llama-3.3-70b-instruct:free", "Llama 3.3 70B (free)"),
                                  ("openrouter/auto", "Auto (OpenRouter picks, paid)")]
        // One gateway for Claude, GPT, Gemini, DeepSeek, Kimi, GLM (paid in rupiah). "Check models"
        // lists exactly what the key's catalogue holds (sk-tm- pay as you go, sk-tp- token package).
        case .tokenMurah: return [("claude-sonnet-5.5", "Claude Sonnet 5.5"), ("claude-opus-5.5", "Claude Opus 5.5"),
                                  ("gpt-5.6-terra", "GPT-5.6 Terra"), ("gpt-5.6-luna", "GPT-5.6 Luna (cheap)"),
                                  ("deepseek-3.2", "DeepSeek 3.2"), ("kimi-k3", "Kimi K3"), ("glm-5", "GLM-5")]
        // Exa answers questions from the web; it has no tools, so it cannot control the app.
        case .exa: return [("exa", "Exa answer (web search)")]
        case .ollama: return [("qwen2.5:7b", "Qwen 2.5 7B"), ("llama3.1:8b", "Llama 3.1 8B"), ("mistral-nemo", "Mistral Nemo")]
        }
    }

    public var defaultModel: String { models[0].0 }

    public var usesOpenAIFormat: Bool { self != .anthropic }

    /// Can call the app's tools (Exa only answers questions).
    public var supportsTools: Bool { self != .exa }

    /// Chat endpoint. `ollamaBase` is the Ollama server (default http://localhost:11434).
    public func endpoint(ollamaBase: String = "http://localhost:11434") -> URL? {
        switch self {
        case .anthropic: return AIAgent.url
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        case .groq: return URL(string: "https://api.groq.com/openai/v1/chat/completions")
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")
        case .tokenMurah: return URL(string: "https://tokenmurah.net/v1/chat/completions")
        case .exa: return URL(string: "https://api.exa.ai/chat/completions")
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

    public static func openAIRequestBody(model: String, messages: [[String: Any]], allowOutputs: Bool,
                                         provider: AIProvider = .openAI) -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": systemPrompt(allowOutputs: allowOutputs)]] + messages,
        ]
        if provider.supportsTools {
            body["tools"] = openAITools
            body["tool_choice"] = "auto"
        }
        // Gemini 2.5 thinks before answering by default; live commands need a quick answer.
        if provider == .gemini { body["reasoning_effort"] = "low" }
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
        var r = Reply(content: [back], text: text, toolUses: uses, stopReason: stop)
        r.usage = AIUsage(openAI: o["usage"] as? [String: Any])
        return r
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

// MARK: Live model list (0.68.2)

extension AIProvider {
    /// Where the provider lists the models this key can use.
    public func modelsURL(ollamaBase: String = "http://localhost:11434") -> URL? {
        switch self {
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/models?limit=100")
        case .openAI: return URL(string: "https://api.openai.com/v1/models")
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models")
        case .groq: return URL(string: "https://api.groq.com/openai/v1/models")
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/models?supported_parameters=tools")
        case .tokenMurah: return URL(string: "https://tokenmurah.net/v1/models")
        case .exa: return nil
        case .ollama:
            guard let chat = endpoint(ollamaBase: ollamaBase)?.absoluteString else { return nil }
            return URL(string: chat.replacingOccurrences(of: "/v1/chat/completions", with: "/api/tags"))
        }
    }

    /// Model ids from a models answer, chat models only, sorted (newest names first).
    public func parseModels(_ data: Data) -> [String] {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var ids: [String]
        if self == .openRouter {
            // Only models that can call tools; free ones first, then the rest by name.
            let rows = ((o["data"] as? [[String: Any]]) ?? []).filter { r in
                guard let p = r["supported_parameters"] as? [String] else { return true }
                return p.contains("tools")
            }.compactMap { $0["id"] as? String }
            let free = rows.filter { $0.hasSuffix(":free") }.sorted()
            return free + rows.filter { !$0.hasSuffix(":free") }.sorted().prefix(max(0, 40 - free.count))
        }
        if self == .ollama {
            ids = ((o["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        } else {
            ids = ((o["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        }
        ids = ids.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
        switch self {
        case .anthropic: ids = ids.filter { $0.hasPrefix("claude") }
        case .openAI:
            ids = ids.filter { id in
                (id.hasPrefix("gpt-") || id.hasPrefix("o")) &&
                !["audio", "realtime", "transcribe", "tts", "image", "search", "embedding", "instruct"].contains { id.contains($0) }
            }
        case .gemini:
            ids = ids.filter { id in
                id.hasPrefix("gemini") && !["embedding", "image", "tts", "audio", "live", "aqa"].contains { id.contains($0) }
            }
        case .groq:
            ids = ids.filter { id in !["whisper", "tts", "guard", "playai", "orpheus", "distil"].contains { id.contains($0) } }
        case .tokenMurah:
            ids = ids.filter { id in !["embedding", "image", "video", "tts", "whisper", "veo", "sora", "dall-e", "imagen"].contains { id.lowercased().contains($0) } }
        case .openRouter, .exa, .ollama: break
        }
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    }
}

#if os(macOS)
import Foundation
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices

/// AI Assistant (0.66.0): sends the operator's command to Claude (Anthropic Messages API, the
/// operator's own API key) with three tools (get_state, run_steps, run_macro) and runs the tool
/// calls through the macro runner, so the assistant can only do what a macro can do. Every action
/// it takes is listed in the window.
public final class AIAgentSession: ObservableObject {
    public struct Line: Identifiable, Equatable {
        public enum Role { case user, assistant, action, error }
        public let id = UUID()
        public let role: Role
        public let text: String
    }

    @Published public private(set) var lines: [Line] = []
    @Published public private(set) var busy = false

    static let runID = "ai-assistant"
    static let modelKey = "aiAgent.model"
    static let providerKey = "aiAgent.provider"
    static let ollamaURLKey = "aiAgent.ollamaURL"
    static let allowOutputsKey = "aiAgent.allowOutputs"

    private weak var model: AppModel?
    /// The conversation as sent to the API (assistant turns unchanged, thinking blocks included).
    private var messages: [[String: Any]] = []
    private var task: Task<Void, Never>?
    private var messagesProvider: AIProvider = .anthropic

    init(model: AppModel) { self.model = model }

    public var provider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: Self.providerKey) ?? "") ?? .anthropic
    }
    /// Model per provider (typed freely; empty = the provider's first suggestion).
    static func modelKey(_ p: AIProvider) -> String { p == .anthropic ? modelKey : "\(modelKey).\(p.rawValue)" }
    public var modelID: String {
        let m = (UserDefaults.standard.string(forKey: Self.modelKey(provider)) ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? provider.defaultModel : m
    }
    public var allowOutputs: Bool { UserDefaults.standard.bool(forKey: Self.allowOutputsKey) }

    public func clear() {
        stop()
        lines = []
        messages = []
    }

    public func stop() {
        task?.cancel()
        task = nil
        model?.stopMacro(Self.runID)
        // A cancelled tool round would leave a tool call without its result: start afresh.
        if busy { messages = [] }
        busy = false
    }

    public func send(_ command: String) {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        let p = provider
        var key = ""
        if let account = p.keychainAccount {
            guard let k = (try? KeychainStore.load(account: account)) ?? nil, !k.isEmpty else {
                lines.append(Line(role: .error, text: "Enter your \(p.displayName) API key first."))
                return
            }
            key = k
        }
        // A conversation cannot move between providers (different message formats).
        if p != messagesProvider { messages = []; messagesProvider = p }
        lines.append(Line(role: .user, text: text))
        // Keep the conversation short: the last few commands are enough context for a live show.
        if messages.count > 24 { messages = [] }
        messages += AIAgent.userTurn(text, p)
        busy = true
        let modelID = self.modelID, allow = allowOutputs
        task = Task { @MainActor [weak self] in
            await self?.loop(provider: p, key: key, modelID: modelID, allowOutputs: allow)
            self?.busy = false
            self?.task = nil
        }
    }

    @MainActor
    private func loop(provider p: AIProvider, key: String, modelID: String, allowOutputs: Bool) async {
        for _ in 0..<AIAgent.maxRounds {
            guard !Task.isCancelled else { return }
            let ollama = UserDefaults.standard.string(forKey: Self.ollamaURLKey) ?? ""
            guard let url = p.endpoint(ollamaBase: ollama) else { fail("The Ollama address is not valid."); return }
            // A local model can take long for its first answer (loading into memory).
            var req = URLRequest(url: url, timeoutInterval: p == .ollama ? 180 : 60)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            if p.usesOpenAIFormat {
                if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
                req.httpBody = AIAgent.openAIRequestBody(model: modelID, messages: messages, allowOutputs: allowOutputs)
            } else {
                req.setValue(key, forHTTPHeaderField: "x-api-key")
                req.setValue(AIAgent.apiVersion, forHTTPHeaderField: "anthropic-version")
                if AIAgent.usesFallback(modelID) { req.setValue(AIAgent.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
                req.httpBody = AIAgent.requestBody(model: modelID, messages: messages, allowOutputs: allowOutputs)
            }
            let data: Data, code: Int
            do {
                let (d, resp) = try await URLSession.shared.data(for: req)
                data = d
                code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                if !Task.isCancelled {
                    fail(p == .ollama ? "Cannot reach Ollama at \(url.host ?? "") (is Ollama running?): \(error.localizedDescription)"
                                      : "Cannot reach \(p.displayName): \(error.localizedDescription)")
                }
                return
            }
            guard !Task.isCancelled else { return }
            let parsed = p.usesOpenAIFormat ? AIAgent.parseOpenAI(data) : AIAgent.parse(data)
            guard code == 200, let reply = parsed else {
                let detail = p.usesOpenAIFormat ? AIAgent.openAIErrorText(data) : AIAgent.errorText(data)
                FileLog.shared.error("ai assistant HTTP \(code): \(detail)")
                fail(code == 401 || code == 403 ? "\(p.displayName) refused the API key: \(detail)" : "\(p.displayName) HTTP \(code): \(detail)")
                return
            }
            messages += AIAgent.assistantTurn(reply, p)
            if !reply.text.isEmpty { lines.append(Line(role: .assistant, text: reply.text)) }
            if reply.stopReason == "refusal" {
                fail("The model declined this command.")
                return
            }
            guard reply.stopReason == "tool_use", !reply.toolUses.isEmpty else {
                if reply.stopReason == "max_tokens" { lines.append(Line(role: .error, text: "The answer was cut off.")) }
                return
            }
            var results: [(id: String, text: String, isError: Bool)] = []
            for use in reply.toolUses {
                guard !Task.isCancelled else { return }
                results.append(await run(use, allowOutputs: allowOutputs))
            }
            messages += AIAgent.toolTurn(results, p)
        }
        lines.append(Line(role: .error, text: "Stopped after \(AIAgent.maxRounds) steps with the model."))
    }

    /// The failed turn is dropped so the next command starts from a valid conversation.
    @MainActor
    private func fail(_ text: String) {
        lines.append(Line(role: .error, text: text))
        messages = []
    }

    @MainActor
    private func run(_ use: AIAgent.ToolUse, allowOutputs: Bool) async -> (id: String, text: String, isError: Bool) {
        guard let model else { return (use.id, "The app is closing.", true) }
        switch use.name {
        case "get_state":
            return (use.id, model.makeRemoteState().json, false)
        case "run_macro":
            let n = AIAgent.intValue(use.input["number"]) ?? 0
            guard let m = model.macroBook.macro(number: n) else {
                return (use.id, "There is no macro \(n).", true)
            }
            if !allowOutputs, m.steps.contains(where: { AIAgent.outputKinds.contains($0.kind) }) {
                return (use.id, "Macro \(n) starts or stops the stream or recording, which the operator has not allowed.", true)
            }
            lines.append(Line(role: .action, text: "macro \(n) \"\(m.name)\""))
            model.runMacro(m.id)
            await waitWhileRunning(m.id, model)
            return (use.id, "Macro \(n) finished.", false)
        case "run_steps":
            let show = AIAgent.Show(inputs: model.inputs.map { (number: $0.number, id: $0.id) },
                                    channels: model.audioChannels.map { (id: $0.id, name: $0.name) })
            switch AIAgent.steps(from: use.input, show: show, allowOutputs: allowOutputs) {
            case let .failure(e):
                return (use.id, e.message, true)
            case let .success(steps):
                let inputs = model.inputs
                lines.append(Line(role: .action, text: AIAgent.describe(steps) { id in inputs.first { $0.id == id }?.number }))
                FileLog.shared.info("ai assistant runs \(steps.count) steps")
                model.runSteps(steps, runID: Self.runID)
                await waitWhileRunning(Self.runID, model)
                return (use.id, Task.isCancelled ? "Stopped by the operator." : "Done.", false)
            }
        default:
            return (use.id, "Unknown tool \(use.name).", true)
        }
    }

    /// Steps run on the main thread one after another; wait for them (at most 2 minutes).
    @MainActor
    private func waitWhileRunning(_ id: String, _ model: AppModel) async {
        let end = Date().addingTimeInterval(120)
        while model.runningMacros.contains(id), Date() < end, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
#endif

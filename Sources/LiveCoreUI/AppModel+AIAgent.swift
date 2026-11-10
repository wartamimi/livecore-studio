#if os(macOS)
import AppKit
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
        /// Ready answers the operator can tap (0.69.1).
        public var suggestions: [String] = []
        public init(role: Role, text: String, suggestions: [String] = []) {
            self.role = role; self.text = text; self.suggestions = suggestions
        }
    }

    @Published public internal(set) var lines: [Line] = []
    @Published public private(set) var busy = false
    /// Models the provider says this key can use (0.68.2), and a short note on the last check.
    @Published public private(set) var liveModels: [AIProvider: [String]] = [:]
    @Published public private(set) var modelsNote = ""

    /// Asks the provider which models this key can use (Ollama: the models pulled on this Mac).
    public func refreshModels() {
        let p = provider
        let base = UserDefaults.standard.string(forKey: Self.ollamaURLKey) ?? ""
        if p == .exa { modelsNote = "Exa has one model: exa (answers from the web, cannot control the app)."; return }
        guard let url = p.modelsURL(ollamaBase: base) else { modelsNote = "The Ollama address is not valid."; return }
        var key = ""
        if let account = p.keychainAccount {
            guard let k = (try? KeychainStore.load(account: account)) ?? nil, !k.isEmpty else {
                modelsNote = "Enter your \(p.displayName) API key first."; return
            }
            key = k
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        if p == .anthropic {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue(AIAgent.apiVersion, forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        modelsNote = "Checking…"
        Task { @MainActor [weak self] in
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    self?.modelsNote = "\(p.displayName) HTTP \(code): \(p == .anthropic ? AIAgent.errorText(data) : AIAgent.openAIErrorText(data))"
                    return
                }
                let ids = p.parseModels(data)
                self?.liveModels[p] = ids
                self?.modelsNote = ids.isEmpty ? "No chat models found for this key." : "\(ids.count) models available for your key."
            } catch {
                self?.modelsNote = "Cannot reach \(p.displayName): \(error.localizedDescription)"
            }
        }
    }

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
        lastCommand = nil
    }

    public func stop() {
        task?.cancel()
        task = nil
        model?.stopMacro(Self.runID)
        // A cancelled tool round would leave a tool call without its result: start afresh.
        if busy { messages = [] }
        busy = false
    }

    /// The last command and the conversation / chat before it, for Regenerate (0.69.0).
    private var lastCommand: String?
    private var messagesBeforeLast: [[String: Any]] = []
    private var linesBeforeLast = 0
    /// Opens an app window (set by the AI panel, which has SwiftUI's openWindow).
    public var openWindow: ((String) -> Void)?

    public var canRegenerate: Bool { !busy && lastCommand != nil && messagesProvider == provider }

    /// Asks again for the last command: its answer and actions are dropped from the chat and
    /// the model answers anew (actions it takes run again).
    public func regenerate() {
        guard canRegenerate, let cmd = lastCommand else { return }
        messages = messagesBeforeLast
        lines = Array(lines.prefix(linesBeforeLast))
        send(cmd, again: true)
    }

    func show(_ model: AppModel) -> AIAgent.Show {
        AIAgent.Show(inputs: model.inputs.map { (number: $0.number, id: $0.id) },
                     channels: model.audioChannels.map { (id: $0.id, name: $0.name) },
                     names: Dictionary(model.inputs.map { ($0.number, $0.name) }, uniquingKeysWith: { a, _ in a }))
    }

    public func send(_ command: String, again: Bool = false) {
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
        // Keep the conversation short: the last few commands are enough context for a live show.
        if messages.count > 24 { messages = [] }
        if !again {
            lastCommand = text
            messagesBeforeLast = messages
            linesBeforeLast = lines.count + 1
            lines.append(Line(role: .user, text: text))
        }
        // The show as it is now rides along, so the model knows the inputs without asking.
        let state = p.supportsTools ? model.map { AIAgent.withState(text, stateJSON: $0.makeRemoteState().json) } : nil
        messages += AIAgent.userTurn(state ?? text, p)
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
            var req = URLRequest(url: url, timeoutInterval: p == .ollama ? 180 : 120)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            if p.usesOpenAIFormat {
                if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
                req.httpBody = AIAgent.openAIRequestBody(model: modelID, messages: messages, allowOutputs: allowOutputs, provider: p)
            } else {
                req.setValue(key, forHTTPHeaderField: "x-api-key")
                req.setValue(AIAgent.apiVersion, forHTTPHeaderField: "anthropic-version")
                if AIAgent.usesFallback(modelID) { req.setValue(AIAgent.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
                req.httpBody = AIAgent.requestBody(model: modelID, messages: messages, allowOutputs: allowOutputs)
            }
            var data = Data(), code = 0
            do {
                // Busy / rate-limited servers (429, 500, 502, 503, 529): wait and try again, up to 3 times.
                for attempt in 0...3 {
                    let (d, resp) = try await URLSession.shared.data(for: req)
                    data = d
                    let http = resp as? HTTPURLResponse
                    code = http?.statusCode ?? 0
                    guard [429, 500, 502, 503, 529].contains(code), attempt < 3, !Task.isCancelled else { break }
                    let after = Double(http?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 0
                    let wait = min(max(after, pow(2, Double(attempt + 1))), 20)
                    lines.append(Line(role: .error, text: "\(p.displayName) is busy (HTTP \(code)); trying again in \(Int(wait)) s…"))
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            } catch {
                if !Task.isCancelled {
                    let code = (error as? URLError).map { " [URLError \($0.errorCode)]" } ?? ""
                    FileLog.shared.error("ai assistant \(p.rawValue) network error: \(error)")
                    fail(p == .ollama ? "Cannot reach Ollama at \(url.host ?? "") (is Ollama running?): \(error.localizedDescription)\(code)"
                                      : "Cannot reach \(p.displayName) (\(url.host ?? "")): \(error.localizedDescription)\(code)")
                }
                return
            }
            guard !Task.isCancelled else { return }
            let parsed = p.usesOpenAIFormat ? AIAgent.parseOpenAI(data) : AIAgent.parse(data)
            guard code == 200, let reply = parsed else {
                let detail = p.usesOpenAIFormat ? AIAgent.openAIErrorText(data) : AIAgent.errorText(data)
                FileLog.shared.error("ai assistant HTTP \(code): \(detail)")
                if code == 401 || code == 403 {
                    fail("\(p.displayName) refused the API key: \(detail)")
                } else if [429, 500, 502, 503, 529].contains(code) {
                    fail("\(p.displayName) is still busy (HTTP \(code)): \(detail) Try again in a minute, or pick another model or provider under ⚙︎.")
                } else {
                    fail("\(p.displayName) HTTP \(code): \(detail)")
                }
                return
            }
            messages += AIAgent.assistantTurn(reply, p)
            let split = AIAgent.splitSuggestions(reply.text)
            let shown = AIAgent.plainText(split.text)
            if !shown.isEmpty || !split.suggestions.isEmpty {
                lines.append(Line(role: .assistant, text: shown.isEmpty ? "…" : shown, suggestions: split.suggestions))
            }
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
            let show = show(model)
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
        case "create_title":
            switch AIAgent.titleRequest(from: use.input) {
            case let .failure(e): return (use.id, e.message, true)
            case let .success(r):
                guard let engine = model.engine else { return (use.id, "No engine.", true) }
                var style = TextSource.Style(template: r.template, title: r.title, subtitle: r.subtitle)
                style.design = r.design
                let id = engine.addTitle(style)
                return await finishCreated(use, id, name: r.name ?? r.title, overlay: r.overlay, model,
                                           what: "title \(r.template.rawValue) \"\(r.title)\"")
            }
        case "create_input":
            guard let engine = model.engine else { return (use.id, "No engine.", true) }
            let name = (use.input["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch use.input["kind"] as? String {
            case "colorBars":
                let id = engine.addColorBars(name: name ?? L10n.t("inputs.colorbars"))
                return await finishCreated(use, id, name: name ?? L10n.t("inputs.colorbars"), overlay: nil, model, what: "colour bars")
            case "color":
                guard let c = AIAgent.color(use.input["color"]) else { return (use.id, "color must be #RRGGBB.", true) }
                let ns = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
                let n = name ?? "Colour"
                let id = engine.addColor(ns, name: n)
                return await finishCreated(use, id, name: n, overlay: nil, model, what: "colour input")
            default:
                return (use.id, "kind must be colorBars or color.", true)
            }
        case "create_ticker":
            switch AIAgent.tickerRequest(from: use.input) {
            case let .failure(e): return (use.id, e.message, true)
            case let .success(r):
                guard let engine = model.engine else { return (use.id, "No engine.", true) }
                let id = engine.addTicker(r.config)
                return await finishCreated(use, id, name: r.name ?? "Running text", overlay: r.overlay, model,
                                           what: "running text \"\(r.config.text.prefix(40))\"")
            }
        case "update_title":
            guard let n = show(model).inputNumber(use.input["input"]),
                  let i = model.inputs.first(where: { $0.number == n }),
                  let src = model.engine?.source(i.id) as? TextSource else {
                return (use.id, "Input \(use.input["input"].map { "\($0)" } ?? "?") is not a title.", true)
            }
            var style = src.style
            if let t = use.input["title"] as? String { style.title = t }
            if let t = use.input["subtitle"] as? String { style.subtitle = t }
            model.updateTitle(i.id, style: style)
            lines.append(Line(role: .action, text: "update title input \(n): \"\(style.title)\""))
            return (use.id, "Input \(n) now reads \"\(style.title)\" / \"\(style.subtitle)\".", false)
        case "create_macro":
            let show = show(model)
            switch AIAgent.macroRequest(from: use.input, show: show) {
            case let .failure(e): return (use.id, e.message, true)
            case let .success(m):
                model.macroBook.macros.append(m)
                let n = model.macroBook.macros.count
                lines.append(Line(role: .action, text: "new macro \(n) \"\(m.name)\" (\(m.steps.count) steps)"))
                return (use.id, n <= MacroBook.maxNumber ? "Saved as macro \(n)." : "Saved (macro \(n); only 1-\(MacroBook.maxNumber) can be run by number).", false)
            }
        case "app_action":
            switch AIAppAction.parse(use.input, show: show(model)) {
            case let .failure(e): return (use.id, e.message, true)
            case let .success(a):
                if case let .openWindow(w) = a {
                    guard let open = openWindow else { return (use.id, "Windows cannot be opened from here.", true) }
                    open(w)
                } else {
                    model.performAIAction(a)
                }
                lines.append(Line(role: .action, text: a.label))
                return (use.id, "Done: \(a.label).", false)
            }
        case "web_search":
            let q = (use.input["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return (use.id, "query is missing.", true) }
            guard let key = (try? KeychainStore.load(account: AIAgent.exaKeychainAccount)) ?? nil, !key.isEmpty else {
                return (use.id, "No Exa API key saved (choose Exa under ⚙︎ and save a key to enable web search). Answer from what you know and say so.", true)
            }
            lines.append(Line(role: .action, text: "web search: \(q)"))
            var req = URLRequest(url: AIAgent.exaAnswerURL, timeoutInterval: 60)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.httpBody = AIAgent.exaAnswerBody(q)
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let text = AIAgent.exaAnswerText(data) else {
                    return (use.id, "Exa HTTP \(code): \(AIAgent.errorText(data))", true)
                }
                return (use.id, String(text.prefix(6000)), false)
            } catch {
                return (use.id, "Cannot reach Exa: \(error.localizedDescription)", true)
            }
        default:
            if let r = settingsTool(use, model) { return r }
            return (use.id, "Unknown tool \(use.name).", true)
        }
    }

    /// A new input: name it, optionally load it on an overlay channel, and report its number
    /// (the input list updates on the next main-thread pass).
    @MainActor
    private func finishCreated(_ use: AIAgent.ToolUse, _ id: InputID, name: String, overlay: Int?, _ model: AppModel,
                               what: String) async -> (id: String, text: String, isError: Bool) {
        model.rename(id, String(name.prefix(60)))
        if let o = overlay { model.configureOverlay(o, source: id, preset: .fullScreen) }
        var number: Int?
        for _ in 0..<20 {
            if let i = model.inputs.first(where: { $0.id == id }) { number = i.number; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        lines.append(Line(role: .action, text: "new \(what)" + (number.map { " → input \($0)" } ?? "")
                          + (overlay.map { ", overlay \($0)" } ?? "")))
        return (use.id, "Created" + (number.map { " as input \($0)" } ?? "") + (overlay.map { ", loaded on overlay \($0) (not shown yet)" } ?? "") + ".", false)
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

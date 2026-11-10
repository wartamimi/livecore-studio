import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.66.0: AI Assistant (Claude tool use) and the Groq removal.
final class V066Tests: XCTestCase {
    private let show = AIAgent.Show(inputs: [(1, InputID("cam1")), (2, InputID("cam2")), (3, InputID("clip"))],
                                    channels: [("ch-a", "Mic 1"), ("ch-b", "Music")])

    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    func testStepsFromToolCall() throws {
        let r = AIAgent.steps(from: json(#"{"steps":[{"kind":"transition","input":2},{"kind":"overlayOn","overlay":1},{"kind":"audioOff","channel":"music"},{"kind":"wait","seconds":120}]}"#),
                              show: show, allowOutputs: false)
        let steps = try r.get()
        XCTAssertEqual(steps.map(\.kind), [.transition, .overlayOn, .audioOff, .wait])
        XCTAssertEqual(steps[0].input, InputID("cam2"))
        XCTAssertEqual(steps[1].overlay, 1)
        XCTAssertEqual(steps[2].channel, "ch-b")                 // found by name, case-insensitive
        XCTAssertEqual(steps[3].waitSeconds, AIAgent.maxWait)    // capped
        let shown = show
        XCTAssertTrue(AIAgent.describe(steps) { id in shown.inputs.first { $0.id == id }?.number }.hasPrefix("transition → input 2"))
    }

    func testInvalidCallsRunNothing() {
        func err(_ s: String, allow: Bool = false) -> String? {
            if case let .failure(e) = AIAgent.steps(from: json(s), show: show, allowOutputs: allow) { return e.message }
            return nil
        }
        XCTAssertNotNil(err(#"{"steps":[]}"#))
        XCTAssertNotNil(err(#"{"steps":[{"kind":"explode"}]}"#))
        XCTAssertNotNil(err(#"{"steps":[{"kind":"preview","input":9}]}"#))
        XCTAssertNotNil(err(#"{"steps":[{"kind":"preview"}]}"#))
        XCTAssertNotNil(err(#"{"steps":[{"kind":"overlayOn","overlay":5}]}"#))
        XCTAssertNotNil(err(#"{"steps":[{"kind":"audioOn","channel":"nope"}]}"#))
        // Stream / record only when the operator allows it.
        XCTAssertNotNil(err(#"{"steps":[{"kind":"cut"},{"kind":"streamStart"}]}"#))
        XCTAssertNil(err(#"{"steps":[{"kind":"cut"},{"kind":"streamStart"}]}"#, allow: true))
    }

    func testRequestBodyAndParse() throws {
        let body = AIAgent.requestBody(model: "claude-opus-5-5", messages: [["role": "user", "content": "cut"]], allowOutputs: false)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(o["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(o["fallbacks"] as? String, "default")
        XCTAssertEqual((o["tools"] as? [Any])?.count, 15)
        XCTAssertNil(o["temperature"])
        let haiku = try XCTUnwrap(try JSONSerialization.jsonObject(with: AIAgent.requestBody(model: "claude-haiku-5-5", messages: [], allowOutputs: true)) as? [String: Any])
        XCTAssertNil(haiku["fallbacks"])

        let answer = #"{"content":[{"type":"thinking","thinking":"","signature":"x"},{"type":"text","text":"Oke."},{"type":"tool_use","id":"tu1","name":"run_steps","input":{"steps":[{"kind":"cut"}]}}],"stop_reason":"tool_use"}"#
        let r = try XCTUnwrap(AIAgent.parse(Data(answer.utf8)))
        XCTAssertEqual(r.content.count, 3)        // thinking kept to send back
        XCTAssertEqual(r.text, "Oke.")
        XCTAssertEqual(r.stopReason, "tool_use")
        XCTAssertEqual(r.toolUses.first?.name, "run_steps")
        XCTAssertEqual((r.toolUses.first?.input["steps"] as? [Any])?.count, 1)
        XCTAssertEqual(AIAgent.errorText(Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)), "invalid x-api-key")
    }

    func testGroqProjectsOpenAsApple() throws {
        let old = #"{"provider":"groq","locale":"id-ID"}"#
        let s = try JSONDecoder().decode(SubtitleStyle.self, from: Data(old.utf8))
        XCTAssertEqual(s.provider, .apple)
    }
}

/// 0.66.1: OpenAI, Gemini and Ollama for the AI Assistant (OpenAI-style function tools).
final class V0661Tests: XCTestCase {
    func testOpenAIBodyAndToolCall() throws {
        let body = AIAgent.openAIRequestBody(model: "gpt-4.1", messages: AIAgent.userTurn("cut", .openAI), allowOutputs: false)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let msgs = try XCTUnwrap(o["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.first?["role"] as? String, "system")
        XCTAssertEqual(msgs.last?["content"] as? String, "cut")
        let tools = try XCTUnwrap(o["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 15)
        XCTAssertEqual((tools[1]["function"] as? [String: Any])?["name"] as? String, "run_steps")

        let answer = #"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"run_steps","arguments":"{\"steps\":[{\"kind\":\"preview\",\"input\":2}]}"}}]}}]}"#
        let r = try XCTUnwrap(AIAgent.parseOpenAI(Data(answer.utf8)))
        XCTAssertEqual(r.stopReason, "tool_use")
        XCTAssertEqual(r.toolUses.first?.id, "call_1")
        XCTAssertEqual(AIAgent.intValue((r.toolUses.first?.input["steps"] as? [[String: Any]])?.first?["input"]), 2)
        XCTAssertEqual(AIAgent.assistantTurn(r, .openAI).first?["content"] as? String, "")
        let tool = AIAgent.toolTurn([(id: "call_1", text: "Done.", isError: false)], .openAI)
        XCTAssertEqual(tool.first?["role"] as? String, "tool")
        XCTAssertEqual(tool.first?["tool_call_id"] as? String, "call_1")
        // Anthropic keeps one user turn of tool_result blocks.
        XCTAssertEqual(AIAgent.toolTurn([(id: "t", text: "x", isError: true)], .anthropic).first?["role"] as? String, "user")
    }

    func testOllamaArgumentsAsObjectAndPlainAnswer() throws {
        let answer = #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_state","arguments":{}}}]}}]}"#
        let r = try XCTUnwrap(AIAgent.parseOpenAI(Data(answer.utf8)))
        XCTAssertEqual(r.toolUses.first?.name, "get_state")
        XCTAssertEqual(r.toolUses.first?.id, "call_0")
        let plain = try XCTUnwrap(AIAgent.parseOpenAI(Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Oke, sudah."}}]}"#.utf8)))
        XCTAssertEqual(plain.stopReason, "end_turn")
        XCTAssertEqual(plain.text, "Oke, sudah.")
        XCTAssertEqual(AIProvider.ollama.endpoint(ollamaBase: "192.168.1.5:11434/")?.absoluteString, "http://192.168.1.5:11434/v1/chat/completions")
        XCTAssertEqual(AIProvider.ollama.endpoint(ollamaBase: "")?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(AIProvider.ollama.keychainAccount)
        XCTAssertEqual(AIAgent.openAIErrorText(Data(#"[{"error":{"code":400,"message":"API key not valid"}}]"#.utf8)), "API key not valid")
    }
}

/// 0.67.0: AI Assistant content tools (titles, running text, macros).
final class V067Tests: XCTestCase {
    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    func testToolsListed() {
        XCTAssertEqual(AIAgent.tools.compactMap { $0["name"] as? String },
                       ["get_state", "run_steps", "run_macro", "create_title", "create_input", "update_title", "create_ticker", "create_macro", "get_input_settings", "set_input_settings", "set_audio", "set_transition", "delete_input", "app_action", "web_search"])
        XCTAssertEqual(AIAgent.openAITools.count, 15)
    }

    func testTitleRequest() throws {
        let r = try AIAgent.titleRequest(from: json(##"{"template":"weddingScript","title":"Budi & Ani","subtitle":"12.12.2026","box_color":"#C9A227","title_color":"FFFFFFCC","font":"Snell Roundhand","overlay":2}"##)).get()
        XCTAssertEqual(r.template, .weddingScript)
        XCTAssertEqual(r.title, "Budi & Ani")
        XCTAssertEqual(r.design.boxColor.r, 0xC9 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(r.design.titleColor.a, 0xCC / 255.0, accuracy: 1e-9)
        XCTAssertEqual(r.design.fontFamily, "Snell Roundhand")
        XCTAssertEqual(r.overlay, 2)
        XCTAssertThrowsError(try AIAgent.titleRequest(from: json(#"{"template":"nope","title":"x"}"#)).get())
        XCTAssertThrowsError(try AIAgent.titleRequest(from: json(#"{"template":"pill","title":"  "}"#)).get())
        XCTAssertThrowsError(try AIAgent.titleRequest(from: json(#"{"template":"pill","title":"x","overlay":7}"#)).get())
        XCTAssertNil(AIAgent.color("#12345"))
    }

    func testTickerAndMacroRequests() throws {
        let t = try AIAgent.tickerRequest(from: json(#"{"text":"Selamat datang"}"#)).get()
        XCTAssertEqual(t.config.text, "Selamat datang")
        XCTAssertThrowsError(try AIAgent.tickerRequest(from: json(#"{"text":"x","template":"zzz"}"#)).get())
        let show = AIAgent.Show(inputs: [(1, InputID("a"))], channels: [])
        let m = try AIAgent.macroRequest(from: json(#"{"name":"Opening","steps":[{"kind":"transition","input":1},{"kind":"streamStart"}]}"#), show: show).get()
        XCTAssertEqual(m.name, "Opening")
        XCTAssertEqual(m.steps.map(\.kind), [.transition, .streamStart])
        XCTAssertThrowsError(try AIAgent.macroRequest(from: json(#"{"name":"","steps":[{"kind":"cut"}]}"#), show: show).get())
    }
}

/// 0.68.0: AI settings tools (JSON merge patch on the app's models, mixer values).
final class V068Tests: XCTestCase {
    func testMergePatch() throws {
        let m = AIAgent.mergePatch(["a": 1, "b": ["c": 2, "d": 3]], ["b": ["c": 5, "d": NSNull()], "e": "x"]) as? [String: Any]
        XCTAssertEqual(m?["a"] as? Int, 1)
        XCTAssertEqual((m?["b"] as? [String: Any])?["c"] as? Int, 5)
        XCTAssertNil((m?["b"] as? [String: Any])?["d"])
        XCTAssertEqual(m?["e"] as? String, "x")
    }

    func testPatchedTitleKeepsOtherFields() throws {
        let t = AITitleSettings(title: "A", subtitle: "B", design: TitleTemplate.classicStrap.defaultDesign)
        let p = try AIAgent.patched(t, patchJSON: #"{"title":"Budi","design":{"titleSize":72,"boxColor":{"r":1,"g":0,"b":0,"a":1}}}"#).get()
        XCTAssertEqual(p.title, "Budi")
        XCTAssertEqual(p.subtitle, "B")
        XCTAssertEqual(p.design?.titleSize, 72)
        XCTAssertEqual(p.design?.boxColor.r, 1)
        XCTAssertEqual(p.design?.template, .classicStrap)
        XCTAssertThrowsError(try AIAgent.patched(t, patchJSON: "not json").get())
        XCTAssertThrowsError(try AIAgent.patched(t, patchJSON: #"{"title":5}"#).get())
        let layers = try AIAgent.patched([Layer](), patchJSON: "[]").get()
        XCTAssertTrue(layers.isEmpty)
    }

    func testAudioValues() {
        if case let .success(v) = AIAgent.audioValue("fader", 3) { XCTAssertEqual(v as? Double, 1) } else { XCTFail() }
        if case let .success(v) = AIAgent.audioValue("muted", true) { XCTAssertEqual(v as? Bool, true) } else { XCTFail() }
        if case .success = AIAgent.audioValue("muted", 1.5) { XCTFail() }
        if case .success = AIAgent.audioValue("volume", 1) { XCTFail() }
    }
}

final class V0682Tests: XCTestCase {
    func testModelLists() {
        let g = #"{"object":"list","data":[{"id":"models/gemini-3.8-flash"},{"id":"models/gemini-embedding-001"},{"id":"models/gemini-3.8-pro"},{"id":"models/imagen-4"}]}"#
        XCTAssertEqual(AIProvider.gemini.parseModels(Data(g.utf8)), ["gemini-3.8-pro", "gemini-3.8-flash"])
        let o = #"{"data":[{"id":"gpt-5"},{"id":"gpt-4o-realtime-preview"},{"id":"text-embedding-3-small"},{"id":"o4-mini"},{"id":"dall-e-3"}]}"#
        XCTAssertEqual(AIProvider.openAI.parseModels(Data(o.utf8)), ["o4-mini", "gpt-5"])
        XCTAssertEqual(AIProvider.ollama.parseModels(Data(#"{"models":[{"name":"qwen2.5:7b"}]}"#.utf8)), ["qwen2.5:7b"])
        XCTAssertEqual(AIProvider.ollama.modelsURL(ollamaBase: "")?.absoluteString, "http://localhost:11434/api/tags")
        XCTAssertEqual(AIProvider.anthropic.parseModels(Data(#"{"data":[{"id":"claude-opus-5-5"}]}"#.utf8)), ["claude-opus-5-5"])
    }

    func testGroqOpenRouter() {
        XCTAssertEqual(AIProvider.groq.endpoint()?.host, "api.groq.com")
        XCTAssertEqual(AIProvider.openRouter.keychainAccount, "openrouter-api-key")
        let g = #"{"data":[{"id":"llama-3.3-70b-versatile"},{"id":"whisper-large-v3"},{"id":"meta-llama/llama-guard-4-12b"}]}"#
        XCTAssertEqual(AIProvider.groq.parseModels(Data(g.utf8)), ["llama-3.3-70b-versatile"])
        let r = #"{"data":[{"id":"x/b","supported_parameters":["tools"]},{"id":"x/a:free","supported_parameters":["tools"]},{"id":"x/c:free","supported_parameters":["temperature"]}]}"#
        XCTAssertEqual(AIProvider.openRouter.parseModels(Data(r.utf8)), ["x/a:free", "x/b"])
    }
}

final class V069Tests: XCTestCase {
    func testPlainText() {
        XCTAssertEqual(AIAgent.plainText("Ini **obat** dan __x__ `y`"), "Ini obat dan x y")
        XCTAssertEqual(AIAgent.plainText("## Judul\n- satu\n* dua\n---\n[Exa](https://exa.ai)"), "Judul\n• satu\n• dua\nExa (https://exa.ai)")
        XCTAssertEqual(AIAgent.plainText("2 * 3 = 6"), "2 * 3 = 6")
    }

    func testForgivingSteps() {
        let a = InputID("a"), b = InputID("b")
        let show = AIAgent.Show(inputs: [(1, a), (2, b)], channels: [(id: "mic1", name: "Mic Host")],
                                names: [1: "Camera Wide", 2: "Logo"])
        XCTAssertEqual(AIAgent.stepKind("overlay_on"), .overlayOn)
        XCTAssertEqual(AIAgent.stepKind("Mute"), .audioOff)
        XCTAssertEqual(show.inputNumber("input 2"), 2)
        XCTAssertEqual(show.inputNumber("logo"), 2)
        XCTAssertEqual(show.inputNumber("Wide"), 1)
        let r = AIAgent.steps(from: ["steps": [["kind": "Transition", "input": "Logo"], ["kind": "mute", "channel": "host"]]],
                              show: show, allowOutputs: false)
        guard case let .success(steps) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(steps.map(\.kind), [.transition, .audioOff])
        XCTAssertEqual(steps[0].input, b)
        XCTAssertEqual(steps[1].channel, "mic1")
        guard case let .failure(e) = AIAgent.steps(from: ["steps": [["kind": "program", "input": 9]]], show: show, allowOutputs: false) else { return XCTFail() }
        XCTAssertTrue(e.message.contains("1 Camera Wide, 2 Logo"))
    }

    func testAppActionAndExa() {
        let show = AIAgent.Show(inputs: [(3, InputID("p"))], channels: [], names: [3: "PTZ"])
        XCTAssertEqual(try AIAppAction.parse(["action": "ptz_preset", "input": "PTZ", "number": 2], show: show).get(), .ptzPreset(input: 3, preset: 2))
        XCTAssertEqual(try AIAppAction.parse(["action": "tbar", "value": 50], show: show).get(), .tbar(0.5))
        XCTAssertEqual(try AIAppAction.parse(["action": "open_window", "window": "Multiview"], show: show).get(), .openWindow("multiview"))
        if case .success = AIAppAction.parse(["action": "qr_show", "input": 7], show: show) { XCTFail() }
        XCTAssertTrue(AIAgent.tools.contains { $0["name"] as? String == "app_action" })
        XCTAssertFalse(AIProvider.exa.supportsTools)
        let body = String(data: AIAgent.openAIRequestBody(model: "exa", messages: [], allowOutputs: false, provider: .exa), encoding: .utf8)!
        XCTAssertFalse(body.contains("\"tools\""))
        let ans = #"{"answer":"Final 2-1","citations":[{"title":"BBC","url":"https://bbc.co.uk/x"}]}"#
        XCTAssertEqual(AIAgent.exaAnswerText(Data(ans.utf8)), "Final 2-1\n\nSources: BBC (https://bbc.co.uk/x)")
    }
}

final class V0691Tests: XCTestCase {
    func testSuggestions() {
        let r = AIAgent.splitSuggestions("Macro seperti apa?\n<suggest>\n1. Buat macro A\n- **Buat macro B**\nBuat macro A\n</suggest>")
        XCTAssertEqual(r.text, "Macro seperti apa?")
        XCTAssertEqual(r.suggestions, ["Buat macro A", "Buat macro B"])
        let open = AIAgent.splitSuggestions("Done.\n<suggest>\nCut ke input 2")
        XCTAssertEqual(open.text, "Done.")
        XCTAssertEqual(open.suggestions, ["Cut ke input 2"])
        XCTAssertEqual(AIAgent.splitSuggestions("Plain").suggestions, [])
        XCTAssertTrue(AIAgent.systemPrompt(allowOutputs: false).contains("<suggest>"))
    }
}

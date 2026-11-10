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
        XCTAssertEqual((o["tools"] as? [Any])?.count, 3)
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

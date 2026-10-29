import XCTest
import Foundation
@testable import LiveCoreCore

final class CustomTransitionTests: XCTestCase {
    func testBuiltInsAndTemplateValidate() {
        XCTAssertNil(CustomTransitionSource.validate(BuiltInTransition.template))
        for t in BuiltInTransition.all {
            XCTAssertNil(CustomTransitionSource.validate(t.code), t.key)
            XCTAssertNotEqual(t.name, t.key, "built-in \(t.key) needs a // name: line")
            XCTAssertEqual(BuiltInTransition.find(id: t.id), t)
        }
        XCTAssertEqual(Set(BuiltInTransition.all.map(\.key)).count, BuiltInTransition.all.count)
    }

    func testRejectsUnsafeOrIncompleteCode() {
        XCTAssertEqual(CustomTransitionSource.validate("  \n "), .empty)
        XCTAssertEqual(CustomTransitionSource.validate("float4 foo() { return 0; }"), .missingFunction)
        XCTAssertEqual(CustomTransitionSource.validate("#include \"/etc/passwd\"\nfloat4 transition()"), .forbidden("#include"))
        XCTAssertEqual(CustomTransitionSource.validate("kernel void k() {}\nfloat4 transition()"), .forbidden("kernel"))
        XCTAssertEqual(CustomTransitionSource.validate(String(repeating: "x", count: 70_000)), .tooLarge)
        // Forbidden words inside comments are fine.
        XCTAssertNil(CustomTransitionSource.validate("// kernel and #include are only words here\n/* fragment */\nfloat4 transition(float2 uv) { return 0; }"))
    }

    func testWrapAddsEntryPointAndKeepsUserLines() {
        let src = CustomTransitionSource.wrap(BuiltInTransition.template)
        XCTAssertTrue(src.contains("fragment float4 \(CustomTransitionSource.entryPoint)("))
        XCTAssertTrue(src.contains("#line 1 \"transition\"\n// name: My Transition"))
        XCTAssertTrue(src.contains("#define FROM(p)"))
    }

    func testNameAndIDs() {
        XCTAssertEqual(CustomTransitionSource.name(in: "  // Name:  Heart Wipe \nfloat4 transition()", fallback: "x"), "Heart Wipe")
        XCTAssertEqual(CustomTransitionSource.name(in: "float4 transition()", fallback: "file"), "file")
        XCTAssertEqual(CustomTransitionSource.fileName(fromID: "file:heart.metal"), "heart.metal")
        XCTAssertNil(CustomTransitionSource.fileName(fromID: "file:../x.metal"))
        XCTAssertNil(CustomTransitionSource.fileName(fromID: "file:.hidden.metal"))
        XCTAssertNil(CustomTransitionSource.fileName(fromID: "file:x.txt"))
        XCTAssertNil(CustomTransitionSource.fileName(fromID: "builtin:clock"))
    }

    func testCustomKindIsDissolveOnCPUAndSettingsDecodeOldFiles() throws {
        XCTAssertEqual(TransitionMath.sample(.custom, t: 0.25, u: 0.1, v: 0.1), .mix(weightB: 0.25))
        var s = ProductionSettings()
        s.transition = .custom
        s.customTransition = "builtin:clock"
        let back = try JSONDecoder().decode(ProductionSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.customTransition, "builtin:clock")
    }
}

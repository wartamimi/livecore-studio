import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.48.0: 3D LUTs (.cube read / write), the LUT generator and LUTs on inputs.
final class Release048Tests: XCTestCase {
    func testIdentityRoundTripsThroughCubeText() throws {
        let lut = CubeLUT.identity(size: 5)
        let back = try CubeLUT.parse(lut.cubeText(comment: "test"))
        XCTAssertEqual(back.size, 5)
        XCTAssertEqual(back.title, "Identity")
        XCTAssertEqual(back.values.count, 5 * 5 * 5 * 3)
        for (a, b) in zip(lut.values, back.values) { XCTAssertEqual(a, b, accuracy: 1e-5) }
        let c = back.sample(RGB(0.3, 0.6, 0.9))
        XCTAssertEqual(c.r, 0.3, accuracy: 1e-5); XCTAssertEqual(c.g, 0.6, accuracy: 1e-5); XCTAssertEqual(c.b, 0.9, accuracy: 1e-5)
    }

    func testParseOrderDomainAndErrors() throws {
        // Red changes fastest: line 2 is (r=1, g=0, b=0).
        let text = """
        # comment
        TITLE "Swap"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 2 2 2
        0 0 0
        0 0 2
        0 2 0
        0 2 2
        2 0 0
        2 0 2
        2 2 0
        2 2 2
        """
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.title, "Swap")
        let red = lut.sample(RGB(1, 0, 0))
        XCTAssertEqual(red.b, 1, accuracy: 1e-6)
        XCTAssertEqual(red.r, 0, accuracy: 1e-6)
        XCTAssertThrowsError(try CubeLUT.parse("0 0 0\n")) { XCTAssertEqual($0 as? CubeLUT.ParseError, .missingSize) }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n")) {
            XCTAssertEqual($0 as? CubeLUT.ParseError, .wrongCount(expected: 8, found: 1))
        }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 1024\n")) { XCTAssertEqual($0 as? CubeLUT.ParseError, .only1D) }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 300\n")) { XCTAssertEqual($0 as? CubeLUT.ParseError, .badSize(300)) }
    }

    func testNeutralLookIsIdentityAndPresetsStayInRange() {
        XCTAssertTrue(LUTLook().isIdentity)
        for v in stride(from: 0.0, through: 1.0, by: 0.125) {
            let o = LUTLook().apply(RGB(v, 1 - v, v * 0.5))
            XCTAssertEqual(o.r, v, accuracy: 1e-9); XCTAssertEqual(o.g, 1 - v, accuracy: 1e-9)
        }
        XCTAssertGreaterThanOrEqual(LUTPreset.all.count, 12)
        XCTAssertEqual(Set(LUTPreset.all.map(\.id)).count, LUTPreset.all.count)
        for p in LUTPreset.all {
            let lut = p.look.makeLUT(title: p.name, size: 9)
            XCTAssertEqual(lut.values.count, 9 * 9 * 9 * 3, p.id)
            XCTAssertTrue(lut.values.allSatisfy { $0 >= 0 && $0 <= 1 && $0.isFinite }, p.id)
        }
    }

    func testLookControlsMoveTheRightWay() {
        var warm = LUTLook(); warm.temperature = 0.8
        let g = RGB(0.5, 0.5, 0.5)
        let w = warm.apply(g)
        XCTAssertGreaterThan(w.r, w.b)
        var mono = LUTLook(); mono.monochrome = true
        let m = mono.apply(RGB(0.9, 0.2, 0.1))
        XCTAssertEqual(m.r, m.g, accuracy: 1e-9); XCTAssertEqual(m.g, m.b, accuracy: 1e-9)
        var con = LUTLook(); con.contrast = 1.5
        XCTAssertLessThan(con.apply(RGB(0.25, 0.25, 0.25)).r, 0.25)
        XCTAssertGreaterThan(con.apply(RGB(0.75, 0.75, 0.75)).r, 0.75)
        XCTAssertEqual(con.apply(g).r, 0.5, accuracy: 1e-9)
        var fade = LUTLook(); fade.fade = 0.1
        XCTAssertEqual(fade.apply(RGB(0, 0, 0)).r, 0.1, accuracy: 1e-9)
        var roll = LUTLook(); roll.highlightRolloff = 1
        XCTAssertEqual(roll.apply(RGB(1, 1, 1)).r, 1, accuracy: 1e-9)
        var last = 0.0
        for v in stride(from: 0.0, through: 1.0, by: 0.01) {
            let o = roll.apply(RGB(v, v, v)).r
            XCTAssertGreaterThanOrEqual(o + 1e-12, last); last = o
        }
    }

    func testInputAdjustCarriesLUT() throws {
        var a = InputAdjust()
        XCTAssertTrue(a.isIdentity)
        a.lut = "/tmp/look.cube"
        XCTAssertFalse(a.isIdentity)
        XCTAssertEqual(a.activeLUT, "/tmp/look.cube")
        a.lutStrength = 0
        XCTAssertNil(a.activeLUT)
        XCTAssertTrue(a.isIdentity)
        a.lutStrength = 0.6
        let back = try JSONDecoder().decode(InputAdjust.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back.lut, "/tmp/look.cube")
        XCTAssertEqual(back.lutStrength, 0.6, accuracy: 1e-9)
        // Older projects have no LUT keys.
        let old = try JSONDecoder().decode(InputAdjust.self, from: Data(#"{"brightness":0.1}"#.utf8))
        XCTAssertNil(old.lut)
        XCTAssertEqual(old.lutStrength, 1)
        XCTAssertEqual(a.clamped.lut, a.lut)
    }
}

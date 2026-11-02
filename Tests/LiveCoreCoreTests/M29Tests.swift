import XCTest
@testable import LiveCoreCore

/// 0.29.0: NDI® inputs.
final class M29Tests: XCTestCase {
    func testSourceNames() {
        XCTAssertEqual(NDISourceName.split("STUDIO-MAC (OBS)").machine, "STUDIO-MAC")
        XCTAssertEqual(NDISourceName.split("STUDIO-MAC (OBS)").name, "OBS")
        XCTAssertEqual(NDISourceName.split("IPHONE (NDI HX Camera (Back))").name, "NDI HX Camera (Back)",
                       "the machine ends at the first bracket")
        XCTAssertEqual(NDISourceName.split("plain").name, "plain")
        XCTAssertEqual(NDISourceName.split("plain").machine, "")
        XCTAssertEqual(NDISourceName.split("X ()").name, "X ()")
        XCTAssertTrue(NDISourceName.isOwnOutput("MAC (LiveCore Output 1)"))
        XCTAssertFalse(NDISourceName.isOwnOutput("MAC (vMix - Output 1)"))
    }

    func testDefaultsAndDisplayName() {
        let c = ProjectNDI(sourceName: "PC (vMix - Output 1)")
        XCTAssertTrue(c.wantsAudio)
        XCTAssertFalse(c.wantsLowBandwidth)
        XCTAssertEqual(c.displayName, "vMix - Output 1")
    }

    func testProjectRoundTrip() throws {
        let src = ProjectSource.ndi(ProjectNDI(sourceName: "PHONE (Camera)", lowBandwidth: true, audio: false))
        let back = try JSONDecoder().decode(ProjectSource.self, from: JSONEncoder().encode(src))
        XCTAssertEqual(back, src)
        let minimal = try JSONDecoder().decode(ProjectNDI.self, from: Data(#"{"sourceName":"A (B)"}"#.utf8))
        XCTAssertTrue(minimal.wantsAudio)
    }
}

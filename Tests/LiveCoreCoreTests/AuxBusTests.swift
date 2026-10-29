import XCTest
@testable import LiveCoreCore

final class AuxBusTests: XCTestCase {
    func testChannelsAreNotSentToAuxByDefault() {
        let c = ChannelControls()
        XCTAssertFalse(c.toBusA.value)
        XCTAssertFalse(c.toBusB.value)
        XCTAssertTrue(c.toProgram.value)
    }

    func testAuxRoundTripsThroughProject() throws {
        var doc = ProjectDocument()
        doc.audio.aux = [ProjectAuxBus(faderDB: -6, muted: false, outputDeviceUID: "BuiltInHeadphoneOutputDevice"),
                         ProjectAuxBus(faderDB: 0, muted: true)]
        var ch = ProjectAudioChannel(deviceUniqueID: "mic", name: "Mic")
        ch.toBusA = true
        doc.audio.channels = [ch]
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.audio.aux, doc.audio.aux)
        XCTAssertEqual(back.audio.channels.first?.toBusA, true)
        XCTAssertNil(back.audio.channels.first?.toBusB)
    }

    func testOldProjectsWithoutAuxStillLoad() throws {
        let json = #"{"masterFaderDB":0,"limiterEnabled":true,"monitorVolume":1,"syncOffsetMs":0,"channels":[{"name":"Mic","faderDB":0,"gainDB":0,"pan":0,"muted":false,"toProgram":true,"compressorEnabled":false,"compThresholdDB":-18,"compRatio":3,"gateEnabled":false,"gateThresholdDB":-50}]}"#
        let a = try JSONDecoder().decode(ProjectAudio.self, from: Data(json.utf8))
        XCTAssertNil(a.aux)
        XCTAssertNil(a.channels.first?.toBusA)
        // A bus saved with only some keys decodes with defaults.
        let bus = try JSONDecoder().decode(ProjectAuxBus.self, from: Data(#"{"outputDeviceUID":"x"}"#.utf8))
        XCTAssertEqual(bus, ProjectAuxBus(faderDB: 0, muted: false, outputDeviceUID: "x"))
    }
}
